#!/usr/bin/env python3
"""Build, sign, notarize and verify an official Workbench direct-download release.

Production is the default. --preview releases the isolated Workbench Preview.
Credentials are read by notarytool from Keychain; this script never accepts
passwords or private-key files. It does not install or publish the result.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


def run(*args, capture=False, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None, **kwargs)


def signing_targets(app):
    """Nested Mach-O code first, then enclosing code bundles, then the app."""
    targets = []
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_file():
            with path.open("rb") as stream:
                magic = stream.read(4)
            if magic in {bytes.fromhex(value) for value in
                         ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}:
                targets.append(path)
        elif path.suffix in {".app", ".framework", ".xpc", ".bundle"}:
            # Resource-only SwiftPM bundles need no independent signature.
            candidates = [path / "Contents/Info.plist", path / "Info.plist",
                          path / "Resources/Info.plist"]
            for info in candidates:
                if info.exists():
                    if plistlib.loads(info.read_bytes()).get("CFBundleExecutable"):
                        targets.append(path)
                    break
    return sorted(set(targets), key=lambda p: (-len(p.parts), str(p))) + [app]


def check_signature(app, team):
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
    details = run("codesign", "-d", "--verbose=4", app, capture=True).stderr
    if (f"TeamIdentifier={team}" not in details
            or "Authority=Developer ID Application:" not in details
            or "runtime" not in details or "Timestamp=" not in details):
        raise RuntimeError("Signature is missing the expected Developer ID, team, timestamp or hardened runtime")
    return details


def require_accepted(result):
    if result.get("status") != "Accepted":
        raise RuntimeError(f"Notarization not accepted: {result.get('status', 'unknown')}. See the saved log.")


def preview_tools():
    spec = importlib.util.spec_from_file_location("workbench_preview_release", Path(__file__).with_name("preview.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def configuration(root, preview=False):
    """Use exactly the installer/build helper's channel identities."""
    return preview_tools().configuration(root=root, production=not preview)


def require_clean_source(expected=None):
    if run("git", "status", "--porcelain", capture=True).stdout.strip():
        raise RuntimeError("Commit or set aside working changes before making an official release")
    source = run("git", "rev-parse", "HEAD", capture=True).stdout.strip()
    if expected is not None and source != expected:
        raise RuntimeError("The source commit changed during the release. Start again from one clean commit")
    return source


def build_archive(root, config, identity, photo_cloud_profile=None):
    if photo_cloud_profile and config["channel"] != "preview":
        raise RuntimeError("Photo cloud provisioning is only supported for Workbench Preview")
    # The Preview helper starts its own build subprocess. Require real action
    # metadata through that entire chain, even if the caller disabled the gate.
    previous_release = os.environ.get("WORKBENCH_RELEASE")
    os.environ["WORKBENCH_RELEASE"] = "1"
    previous = os.environ.get("REQUIRE_APP_INTENTS")
    os.environ["REQUIRE_APP_INTENTS"] = "1"
    try:
        if config["channel"] == "preview":
            return preview_tools().build(config, identity=identity,
                                         photo_cloud_profile=photo_cloud_profile)
        run(*config["build"])
        return root / config.get("component_archive", config["archive"])
    finally:
        if previous_release is None:
            os.environ.pop("WORKBENCH_RELEASE", None)
        else:
            os.environ["WORKBENCH_RELEASE"] = previous_release
        if previous is None:
            os.environ.pop("REQUIRE_APP_INTENTS", None)
        else:
            os.environ["REQUIRE_APP_INTENTS"] = previous


def validate_app_intents(app):
    """Check the actual archive, as well as requiring metadata during its build."""
    path = app / "Contents/Resources/Metadata.appintents/extract.actionsdata"
    try:
        if path.is_symlink():
            raise ValueError("Metadata is a symbolic link")
        action = json.loads(path.read_text())["actions"]["TranscribeWithWorkbench"]
        if (action.get("fullyQualifiedTypeName") != "LocalVoice.TranscribeWithWorkbench"
                or action.get("isDiscoverable") is not True
                or action.get("openAppWhenRun") is not False
                or not isinstance(action.get("parameters"), list)
                or len(action["parameters"]) != 1 or not action.get("outputType")):
            raise ValueError("Required action contract is missing")
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise RuntimeError("Release requires valid Transcribe with Workbench App Intents metadata") from error


def validate_cloud(app, root, team, enabled):
    """Report enabled cloud capabilities only after the signed profile gate passes."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if not enabled:
        if info.get("WorkbenchPhotoCloudProvisioned") not in (None, False):
            raise RuntimeError("Cloud-enabled releases require an explicit --photo-cloud-profile")
        return {"enabled": False}
    run(sys.executable, root / "scripts/check-photo-cloud.py", "--platform", "macos",
        "--team", team, "--environment", "Production", "--app", app)
    return {"enabled": True, "container": info["WorkbenchPhotoCloudContainer"],
            "environment": info["WorkbenchPhotoCloudEnvironment"]}


def validate_identity(app, config):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {
        "CFBundleIdentifier": config["identifier"],
        "CFBundleExecutable": config["executable"],
        "WorkbenchChannel": "preview" if config["channel"] == "preview" else None,
    }
    if app.name != config["bundle"] or any(info.get(key) != value for key, value in expected.items()):
        raise RuntimeError("Unexpected bundle name, identifier, executable or release channel")
    executable = app / "Contents/MacOS" / config["executable"]
    if not executable.is_file() or executable.is_symlink():
        raise RuntimeError("Expected channel executable is missing or is a symbolic link")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if not isinstance(info.get(key), str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", info[key]):
            raise RuntimeError("Unexpected version format")
    return info


def validate_archive(archive, config):
    """Only the selected app and its ditto resource metadata may be extracted."""
    with zipfile.ZipFile(archive) as package:
        entries = package.namelist()
        if len(entries) != len({str(PurePosixPath(name)) for name in entries}):
            raise RuntimeError("Release archive contains duplicate entries")
        for name in entries:
            path = PurePosixPath(name)
            if not path.parts or path.is_absolute() or ".." in path.parts or "\\" in name or "\x00" in name:
                raise RuntimeError("Release archive contains an unsafe path")
            parts = path.parts
            if parts[0] == "__MACOSX":
                if len(parts) > 1 and parts[1] not in (config["bundle"], "._" + config["bundle"]):
                    raise RuntimeError("Release archive contains unrelated resource metadata")
            elif parts[0] != config["bundle"]:
                raise RuntimeError("Release archive contains an unexpected application or file")
        required = {f"{config['bundle']}/Contents/Info.plist", f"{config['bundle']}/Contents/MacOS/{config['executable']}"}
        if not required.issubset(entries):
            raise RuntimeError("Release archive is missing the selected app identity or executable")


def release_directory(root, version, build, channel):
    if channel not in ("production", "preview"):
        raise RuntimeError("Unknown release channel")
    # Preserve the production output convention. Preview cannot collide with it.
    suffix = "-preview" if channel == "preview" else ""
    return root / ".build/releases" / f"{version}-{build}{suffix}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True, help="SHA-1 fingerprint of a Developer ID Application identity")
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--keychain-profile", required=True, help="Existing notarytool Keychain profile name")
    parser.add_argument("--preview", action="store_true", help="Sign and notarize the separate Workbench Preview; production is the default")
    parser.add_argument("--photo-cloud-profile", type=Path,
                        help="Existing Developer ID CloudKit profile; requires --preview")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", args.identity):
        parser.error("--identity must be the certificate SHA-1 fingerprint, not an ad-hoc identity")
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("Invalid Apple team ID")
    if args.photo_cloud_profile:
        if not args.preview:
            parser.error("--photo-cloud-profile requires --preview")
        args.photo_cloud_profile = args.photo_cloud_profile.resolve()
        if not args.photo_cloud_profile.is_file():
            parser.error("--photo-cloud-profile must be an existing provisioning profile file")
    root = Path(__file__).resolve().parents[2]
    os.chdir(root)
    config = configuration(root, preview=args.preview)
    source = require_clean_source()
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True).stdout
    match = next((line for line in identities.splitlines() if args.identity.upper() in line.upper()), "")
    if "Developer ID Application:" not in match or f"({args.team_id})" not in match:
        raise RuntimeError("Expected Developer ID Application identity and private key are not available in Keychain")
    # Check authentication before spending time on builds. No secret is printed.
    run("xcrun", "notarytool", "history", "--keychain-profile", args.keychain_profile,
        "--output-format", "json", capture=True)
    run(*config["regressions"])
    archive = build_archive(root, config, args.identity, photo_cloud_profile=args.photo_cloud_profile)
    # Regressions/builds must not silently change the commit being released.
    require_clean_source(expected=source)
    validate_archive(archive, config)
    with tempfile.TemporaryDirectory(prefix="workbench-release-") as temporary:
        staging = Path(temporary)
        run("ditto", "-x", "-k", archive, staging)
        app = staging / config["bundle"]
        info = validate_identity(app, config)
        version = info["CFBundleShortVersionString"]
        build = info["CFBundleVersion"]
        output = release_directory(root, version, build, config["channel"])
        output.mkdir(parents=True, exist_ok=False)  # Never replace a release.
        candidate = {"source": source, "channel": config["channel"], "bundle": config["identifier"],
                     "executable": config["executable"], "version": version, "build": build, "team": args.team_id}
        (output / "candidate.json").write_text(json.dumps(candidate, indent=2) + "\n")
        # Preview's channel conversion already signed inside-out. Production
        # retains the original build-then-sign route.
        for path in signing_targets(app) if config["channel"] == "production" else []:
            command = ["codesign", "--force", "--sign", args.identity,
                       "--timestamp", "--options", "runtime"]
            if path != app:
                command += ["--preserve-metadata=entitlements"]
            if path == app and config.get("entitlements"):
                command += ["--entitlements", str(root / config["entitlements"])]
            run(*command, path)
        signature = check_signature(app, args.team_id)
        (output / "signature.txt").write_text(signature)
        validate_app_intents(app)
        candidate["icloud"] = validate_cloud(app, root, args.team_id, bool(args.photo_cloud_profile))
        (output / "candidate.json").write_text(json.dumps(candidate, indent=2) + "\n")
        executable = app / "Contents/MacOS" / config["executable"]
        architectures = run("lipo", "-archs", executable, capture=True).stdout.strip()
        if "arm64" not in architectures.split():
            raise RuntimeError("Apple Silicon executable is missing")
        for check in config["checks"]:
            run(executable, *check)
        upload = staging / "notarization.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, upload)
        # Keep the exact submitted bytes for recovery if Apple's service or
        # stapler fails after acceptance. This is not the final release ZIP.
        shutil.copy2(upload, output / "submission.zip")
        (output / "submission-SHA256SUMS.txt").write_text(f"{hashlib.sha256(upload.read_bytes()).hexdigest()}  submission.zip\n")
        # Submit once, persist the ID before waiting, so an interrupted run can
        # be recovered through notarytool info/log without duplicate submissions.
        submission = json.loads(run("xcrun", "notarytool", "submit", upload,
            "--keychain-profile", args.keychain_profile, "--output-format", "json", capture=True).stdout)
        (output / "submission.json").write_text(json.dumps(submission, indent=2) + "\n")
        submission_id = submission["id"]
        print(f"Notarization submitted: {submission_id}", flush=True)
        # A rejected submission can make wait return nonzero; still retrieve its
        # status and diagnostic log before rejecting the release.
        subprocess.run(["xcrun", "notarytool", "wait", submission_id,
                        "--keychain-profile", args.keychain_profile], check=False)
        result = json.loads(run("xcrun", "notarytool", "info", submission_id,
            "--keychain-profile", args.keychain_profile, "--output-format", "json", capture=True).stdout)
        (output / "notarization.json").write_text(json.dumps(result, indent=2) + "\n")
        run("xcrun", "notarytool", "log", submission_id, "--keychain-profile",
            args.keychain_profile, output / "notarization-log.json")
        require_accepted(result)
        run("xcrun", "stapler", "staple", app)
        run("xcrun", "stapler", "validate", app)
        check_signature(app, args.team_id)
        run("spctl", "--assess", "--type", "execute", "--verbose=4", app)
        final = output / Path(config["preview_archive"]).name
        packaged = staging / final.name
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, packaged)
        # Verify the exact archive after repackaging the stapled app.
        validate_archive(packaged, config)
        extracted = staging / "verify"
        run("ditto", "-x", "-k", packaged, extracted)
        delivered = extracted / config["bundle"]
        final_info = validate_identity(delivered, config)
        if any(final_info[key] != info[key] for key in ("CFBundleShortVersionString", "CFBundleVersion")):
            raise RuntimeError("The final archive version does not match the notarized candidate")
        check_signature(delivered, args.team_id)
        validate_app_intents(delivered)
        if validate_cloud(delivered, root, args.team_id, bool(args.photo_cloud_profile)) != candidate["icloud"]:
            raise RuntimeError("The final archive cloud configuration does not match the notarized candidate")
        run("xcrun", "stapler", "validate", delivered)
        run("spctl", "--assess", "--type", "execute", "--verbose=4", delivered)
        # Test session creation from the exact extracted, notarized download.
        run(delivered / "Contents/MacOS" / config["executable"], "--check-readback-resources")
        run(delivered / "Contents/MacOS" / config["executable"], "--check-readback-pack")
        digest = hashlib.sha256(packaged.read_bytes()).hexdigest()
        shutil.copy2(packaged, final)
        (output / "SHA256SUMS.txt").write_text(f"{digest}  {final.name}\n")
        (output / "release.json").write_text(json.dumps({
            **candidate, "archive": final.name,
            "build": build, "architectures": architectures, "team": args.team_id,
            "notarization": submission_id, "sha256": digest,
            "fresh_mac_interactive_test": "not recorded by this helper",
            "acceptance_policy": "scripts/release/README.md"
        }, indent=2) + "\n")
        print(f"Signed, notarized and stapled: {final}")
        print("Native first-run and live workflow results are separate. Apply the Preview or production acceptance policy in scripts/release/README.md before publication.")
        print("No assets were uploaded to GitHub.")


if __name__ == "__main__":
    main()
