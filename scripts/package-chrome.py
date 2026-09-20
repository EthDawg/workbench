#!/usr/bin/env python3
"""Validate and reproducibly ZIP the Chrome adapter's explicit runtime allowlist.

No build dependencies, source minification, network access or account actions.
The manifest stays at ZIP root. Development files and store artwork are excluded.
"""

import argparse
import base64
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path, PurePosixPath
import re
import struct
import tempfile
import zipfile


PROJECT = Path(__file__).resolve().parents[1]
RUNTIME_FILES = (
    "manifest.json", "background.js", "core.js", "native.js", "popup.js",
    "popup.html", "popup.css", "privacy.html",
    "icons/icon16.png", "icons/icon32.png", "icons/icon48.png", "icons/icon128.png",
)
ALLOWED_MANIFEST_KEYS = {
    "manifest_version", "name", "version", "description", "homepage_url", "icons",
    "minimum_chrome_version", "permissions", "optional_host_permissions", "incognito",
    "background", "action", "content_security_policy", "key",
}
MAX_FILE_BYTES = 1_048_576
MAX_TOTAL_BYTES = 4_194_304


class PackageError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise PackageError(message)


def extension_id(public_key):
    try:
        key = base64.b64decode(public_key, validate=True)
    except (ValueError, TypeError) as error:
        raise PackageError("Manifest key is not a valid base64 public key.") from error
    require(128 <= len(key) <= 8192 and key[0] == 0x30, "Manifest key is not a DER public key.")
    digest = hashlib.sha256(key).hexdigest()[:32]
    return "".join(chr(ord("a") + int(character, 16)) for character in digest)


def png_size(data):
    require(data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR" and len(data) >= 33,
            "Icons must be valid PNG files.")
    require(data[25] == 6, "Icons must have an RGBA transparency channel.")
    return struct.unpack(">II", data[16:24])


class AssetReferences(HTMLParser):
    def __init__(self):
        super().__init__()
        self.references = []

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        require(not any(key.lower().startswith("on") for key in attrs), "Inline event handlers cannot be packaged.")
        if tag in ("script", "img", "iframe"):
            require(tag != "iframe", "Frames are outside this adapter's package.")
            if tag == "script":
                require(bool(attrs.get("src")), "Inline scripts cannot be packaged.")
            if attrs.get("src"):
                self.references.append(attrs["src"])
        if tag == "link" and attrs.get("href"):
            self.references.append(attrs["href"])
        if tag == "a" and attrs.get("target") == "_blank":
            require({"noopener", "noreferrer"}.issubset(set(attrs.get("rel", "").split())),
                    "New-tab links must use noopener and noreferrer.")


def check_reference(source_name, reference, files):
    require(reference and not re.match(r"[a-z][a-z0-9+.-]*:", reference, re.I)
            and not reference.startswith("/"), f"Remote or absolute runtime asset in {source_name}.")
    path = PurePosixPath(source_name).parent / reference
    require(".." not in path.parts and str(path) in files, f"Runtime asset outside the allowlist in {source_name}: {reference}")


def validate(source):
    source = Path(source).absolute()
    require(source.is_dir() and not source.is_symlink(), "Extension source must be a regular directory.")
    files = {}
    for name in RUNTIME_FILES:
        path = source / name
        require(path.is_file() and not path.is_symlink(), f"Missing or symlinked runtime file: {name}")
        for parent in path.parents:
            if parent == source:
                break
            require(not parent.is_symlink(), f"Symlinked runtime directory: {name}")
        require(path.stat().st_size <= MAX_FILE_BYTES, f"Runtime file is unexpectedly large: {name}")
        files[name] = path.read_bytes()
    require(sum(map(len, files.values())) <= MAX_TOTAL_BYTES, "Extension runtime exceeds its package limit.")
    try:
        manifest = json.loads(files["manifest.json"])
    except (ValueError, UnicodeError) as error:
        raise PackageError("Manifest must be UTF-8 JSON without comments.") from error
    require(isinstance(manifest, dict), "Manifest must be an object.")
    require(set(manifest).issubset(ALLOWED_MANIFEST_KEYS), "Unexpected manifest capability; review the package allowlist.")
    require(manifest.get("manifest_version") == 3, "Only Manifest V3 is supported.")
    require(manifest.get("name") == "Workbench Preview", "Store name must be Workbench Preview.")
    version = manifest.get("version", "")
    require(isinstance(version, str) and re.fullmatch(r"(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){0,3}", version), "Invalid Chrome version number.")
    require(all(int(part) <= 65535 for part in version.split(".")) and any(int(part) for part in version.split(".")), "Invalid Chrome version component.")
    description = manifest.get("description", "")
    require(isinstance(description, str) and 1 <= len(description) <= 132, "Description must be 1–132 characters.")
    require("macOS" in description and "companion" in description, "Description must disclose the macOS companion requirement.")
    require(manifest.get("permissions") == ["nativeMessaging", "activeTab", "storage", "alarms"], "Unexpected required permissions.")
    require(manifest.get("optional_host_permissions") == ["http://*/*", "https://*/*"], "Unexpected optional host permissions.")
    require(manifest.get("incognito") == "not_allowed", "Incognito must remain disabled.")
    require(manifest.get("background") == {"service_worker": "background.js", "type": "module"}, "Unexpected service worker.")
    require(manifest.get("action", {}).get("default_popup") == "popup.html", "Unexpected popup entry point.")
    require(manifest.get("content_security_policy", {}).get("extension_pages") == "script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'", "Unexpected extension CSP.")
    identity = extension_id(manifest.get("key"))
    expected_icons = {str(size): f"icons/icon{size}.png" for size in (16, 32, 48, 128)}
    require(manifest.get("icons") == expected_icons, "Manifest needs the four standard PNG icons.")
    require(manifest.get("action", {}).get("default_icon") == {str(size): f"icons/icon{size}.png" for size in (16, 32)}, "Toolbar icons must be 16 and 32 pixels.")
    for size, name in expected_icons.items():
        require(png_size(files[name]) == (int(size), int(size)), f"Wrong pixel dimensions: {name}")
    for name, data in files.items():
        if name.endswith(".html"):
            parser = AssetReferences()
            parser.feed(data.decode("utf-8"))
            for reference in parser.references:
                check_reference(name, reference, files)
        if name.endswith(".js"):
            text = data.decode("utf-8")
            for reference in re.findall(r"\bfrom\s*[\"']([^\"']+)[\"']", text):
                check_reference(name, reference, files)
            require(not re.search(r"\b(?:import\s*\(|eval\s*\(|new\s+Function\b)", text), "Dynamic runtime code cannot be packaged.")
        if name.endswith(".css"):
            require(not re.search(r"@import|url\s*\(", data.decode("utf-8")), "Review newly referenced CSS assets before packaging.")
    return manifest, identity, files


def package(source, output):
    manifest, identity, files = validate(source)
    output = Path(output).absolute()
    require(output.suffix == ".zip" and not output.is_symlink(), "Output must be a regular .zip destination.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".workbench-chrome-", suffix=".zip", dir=output.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with zipfile.ZipFile(temporary_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, data in files.items():
                entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, data, compresslevel=9)
        with zipfile.ZipFile(temporary_path) as archive:
            require(archive.namelist() == list(RUNTIME_FILES), "Packaged file list differs from the allowlist.")
            require(archive.testzip() is None, "ZIP integrity check failed.")
            for name, data in files.items():
                require(archive.read(name) == data, f"Packaged bytes differ: {name}")
        temporary_path.replace(output)
    finally:
        temporary_path.unlink(missing_ok=True)
    checksum = hashlib.sha256(output.read_bytes()).hexdigest()
    return {"artifact": str(output), "name": manifest["name"], "version": manifest["version"],
            "unpacked_extension_id": identity, "files": list(RUNTIME_FILES), "bytes": output.stat().st_size,
            "sha256": checksum}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=PROJECT / "BrowserExtension")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true", help="Validate sources without writing an archive")
    arguments = parser.parse_args()
    try:
        manifest, identity, files = validate(arguments.source)
        if arguments.check:
            result = {"valid": True, "version": manifest["version"], "unpacked_extension_id": identity,
                      "files": list(files), "uncompressed_bytes": sum(map(len, files.values()))}
        else:
            output = arguments.output or PROJECT / "dist" / f"WorkbenchPreview-Chrome-{manifest['version']}.zip"
            result = package(arguments.source, output)
        print(json.dumps(result, indent=2))
    except (PackageError, OSError, UnicodeError) as error:
        parser.exit(1, f"Chrome package failed: {error}\n")


if __name__ == "__main__":
    main()
