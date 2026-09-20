#!/usr/bin/env python3
"""Build or update an isolated Workbench Preview without changing production.

Mirrored in both repositories. Uses the existing Developer ID from Keychain;
never handles credentials. No publication, app-data removal or TCC reset.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(*args, capture=False):
    return subprocess.run([str(a) for a in args], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)


def configuration(root=ROOT, production=False):
    config = json.loads((root / "scripts/release/config.json").read_text())
    config["production_bundle"] = config["bundle"]
    config["channel"] = "production" if production else "preview"
    if production:
        config["preview_archive"] = config["archive"]
        return config
    config["bundle"] = config["bundle"].removesuffix(".app") + " Preview.app"
    config["identifier"] += ".preview"
    config["executable"] += "Preview"
    config["preview_archive"] = str(Path(config["archive"]).with_name(config["bundle"].removesuffix(".app") + ".zip"))
    return config


def update_bundle_info(info, config, build_version):
    """Apply the selected app identity, including its distinct Services port."""
    info.update(CFBundleIdentifier=config["identifier"], CFBundleExecutable=config["executable"],
                CFBundleName=config["bundle"].removesuffix(".app"),
                CFBundleDisplayName=config["bundle"].removesuffix(".app"),
                CFBundleVersion=build_version)
    if config["channel"] == "preview":
        info["WorkbenchChannel"] = "preview"
    else:
        info.pop("WorkbenchChannel", None)
    for service in info.get("NSServices", []):
        if service.get("NSMessage") != "readSelection":
            continue
        service["NSPortName"] = config["bundle"].removesuffix(".app")
        service.setdefault("NSMenuItem", {})["default"] = (
            "Read Selection in Workbench Preview" if config["channel"] == "preview"
            else "Read Selection in Workbench"
        )
    return info


def developer_identity(requested=None):
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True).stdout
    candidates = re.findall(r'([A-Fa-f0-9]{40}) "Developer ID Application:[^\n]+\(([A-Z0-9]{10})\)"', identities)
    if requested:
        candidates = [item for item in candidates if item[0].lower() == requested.lower()]
    if len(candidates) != 1:
        raise RuntimeError("Expected one available Developer ID Application certificate and private key. Unlock Keychain, or select its fingerprint with --identity. Use --ad-hoc only for disposable builds; its permissions may need reapproval.")
    return candidates[0]


def validate_bundle(app, config, allow_ad_hoc=False):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleIdentifier": config["identifier"], "CFBundleExecutable": config["executable"], "WorkbenchChannel": None if config["channel"] == "production" else "preview"}
    if any(info.get(key) != value for key, value in expected.items()):
        raise RuntimeError("Refusing a bundle without the exact selected identity, executable and channel")
    reading_services = [service for service in info.get("NSServices", []) if service.get("NSMessage") == "readSelection"]
    service_title = "Read Selection in Workbench Preview" if config["channel"] == "preview" else "Read Selection in Workbench"
    service_port = config["bundle"].removesuffix(".app")
    if len(reading_services) != 1 or reading_services[0].get("NSPortName") != service_port \
            or reading_services[0].get("NSMenuItem", {}).get("default") != service_title:
        raise RuntimeError("Refusing a bundle without the exact selected-app Services identity")
    run("codesign", "--verify", "--deep", "--strict", app)
    signature = run("codesign", "-d", "--verbose=4", app, capture=True).stderr
    if not allow_ad_hoc and "Authority=Developer ID Application:" not in signature:
        raise RuntimeError("Refusing to install an ad-hoc build as a persistent app")
    return signature


def build(config, identity=None, ad_hoc=False, native=False, photo_cloud_profile=None):
    if ad_hoc and identity:
        raise RuntimeError("Choose Developer ID signing or --ad-hoc, not both")
    selected, team = (None, None) if ad_hoc else developer_identity(identity)
    if photo_cloud_profile:
        if ad_hoc or config["identifier"] != "com.ethdawg.workbench.preview":
            raise RuntimeError("Photo handoff requires the signed Workbench Preview identity")
        photo_cloud_profile = Path(photo_cloud_profile).resolve()
        run(sys.executable, ROOT / "scripts/check-photo-cloud.py", "--platform", "macos",
            "--team", team, "--environment", "Production", "--profile", photo_cloud_profile)
    command = config["build"][:]
    # StageMark has no architecture-specific dependency. Voice's FluidAudio
    # backend remains Apple Silicon until its Intel path is independently tested.
    if config["executable"] == "StageMarkPreview" and not native:
        command.append("--universal")
    run(*command)
    spec = importlib.util.spec_from_file_location("workbench_release", ROOT / "scripts/release/release.py")
    release = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(release)
    archive = ROOT / config["preview_archive"]
    with tempfile.TemporaryDirectory(prefix="preview-", dir=ROOT / ".build") as temporary:
        staging = Path(temporary)
        run("ditto", "-x", "-k", ROOT / config["archive"], staging)
        original = staging / config["production_bundle"]
        app = staging / config["bundle"]
        original.rename(app)
        info_path = app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        executable.rename(executable.with_name(config["executable"]))
        update_bundle_info(info, config, datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"))
        photo_entitlements = None
        if photo_cloud_profile:
            photo_entitlements = staging / "photo-cloud.entitlements"
            run(sys.executable, ROOT / "scripts/check-photo-cloud.py", "--platform", "macos",
                "--team", team, "--environment", "Production", "--profile", photo_cloud_profile,
                "--entitlements-out", photo_entitlements)
            shutil.copyfile(photo_cloud_profile, app / "Contents/embedded.provisionprofile")
            info.update(WorkbenchPhotoCloudProvisioned=True,
                        WorkbenchPhotoCloudContainer="iCloud.com.ethdawg.workbench.preview",
                        WorkbenchPhotoCloudEnvironment="Production")
        info_path.write_bytes(plistlib.dumps(info))
        for path in release.signing_targets(app):
            command = ["codesign", "--force", "--sign", selected or "-"]
            if selected:
                command += ["--timestamp", "--options", "runtime"]
                if path == app and (photo_entitlements or config.get("entitlements")):
                    command += ["--entitlements", str(photo_entitlements or ROOT / config["entitlements"])]
            run(*command, path)
        validate_bundle(app, config, ad_hoc)
        if team:
            release.check_signature(app, team)
        if photo_cloud_profile:
            run(sys.executable, ROOT / "scripts/check-photo-cloud.py", "--platform", "macos",
                "--team", team, "--environment", "Production", "--app", app)
        temporary_archive = staging / archive.name
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, temporary_archive)
        # Keep the last good package if this build fails before validation.
        os.replace(temporary_archive, archive)
    print(f"Preview built: {archive}", flush=True)
    return archive


def install(config, archive, ad_hoc=False, open_app=True):
    # Separate executable names mean production can remain installed and running.
    # The user chooses which app owns the shared global shortcuts at launch.
    running = subprocess.run(["pgrep", "-x", config["executable"]], stdout=subprocess.DEVNULL)
    if running.returncode == 0:
        raise RuntimeError(f"Quit {config['bundle'].removesuffix('.app')} before updating it. Production does not need to be removed.")
    if running.returncode != 1:
        raise RuntimeError("Unable to inspect running apps. Install from a terminal with process access; no app was replaced.")
    applications = Path("/Applications") if config["channel"] == "production" and config["executable"] == "StageMark" else Path.home() / "Applications"
    applications.mkdir(exist_ok=True)
    destination = applications / config["bundle"]
    with tempfile.TemporaryDirectory(prefix=".workbench-preview-", dir=applications) as temporary:
        staging = Path(temporary)
        run("ditto", "-x", "-k", archive, staging)
        app = staging / config["bundle"]
        signature = validate_bundle(app, config, ad_hoc)
        if config["channel"] == "production":
            run("xcrun", "stapler", "validate", app)
            run("spctl", "--assess", "--type", "execute", app)
        if destination.exists():
            if config["channel"] == "production" and (destination / "Contents/_MASReceipt/receipt").exists():
                raise RuntimeError("This production copy is managed by the Mac App Store. Update it there to retain its sandbox data and permissions.")
            previous = validate_bundle(destination, config, allow_ad_hoc=True)
            # Never silently replace an established signer with a different team
            # or a disposable ad-hoc signature, which may orphan OS permissions.
            teams = [re.search(r"^TeamIdentifier=(.*)$", details, re.M) for details in (previous, signature)]
            if teams[0] and teams[0].group(1) != "not set" and (not teams[1] or teams[0].group(1) != teams[1].group(1)):
                raise RuntimeError("Preview signing team changed. Keep the original identity for this update.")
            backup = ROOT / config["preview_archive"]
            backup = backup.with_name("Previous-" + backup.name)
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", destination, staging / backup.name)
            os.replace(staging / backup.name, backup)
        old = staging / "previous.app"
        moved_new = False
        try:
            if destination.exists():
                destination.rename(old)
            app.rename(destination)
            moved_new = True
            validate_bundle(destination, config, ad_hoc)
        except Exception:
            if moved_new and destination.exists():
                shutil.rmtree(destination)
            if old.exists():
                old.rename(destination)
            raise
        run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", destination)
    if open_app:
        run("open", destination)
    print(f"Installed: {destination}\nAll saved app data and the other channel were preserved.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["build", "install"])
    parser.add_argument("--identity", help="Developer ID certificate SHA-1 fingerprint; auto-selects when exactly one exists")
    parser.add_argument("--ad-hoc", action="store_true", help="Disposable developer build; permissions may need reapproval")
    parser.add_argument("--photo-cloud-profile", type=Path, help="Verified Developer ID CloudKit profile for the private paired Preview; no service is created")
    parser.add_argument("--native", action="store_true", help="StageMark: build only this Mac's architecture")
    parser.add_argument("--no-open", action="store_true", help="Install without opening the app")
    parser.add_argument("--archive", type=Path, help="Install an already built signed ZIP without rebuilding")
    parser.add_argument("--production", action="store_true", help="Explicitly update production from a notarized --archive; never builds an unsigned replacement")
    args = parser.parse_args()
    if args.archive and args.command != "install":
        parser.error("--archive is only supported for install")
    if args.production and (args.command != "install" or not args.archive or args.ad_hoc):
        parser.error("Production updates require install --production --archive PATH_TO_NOTARIZED_ZIP")
    if args.photo_cloud_profile and (args.ad_hoc or args.production or args.archive):
        parser.error("--photo-cloud-profile is only for building a signed Workbench Preview")
    os.chdir(ROOT)
    config = configuration(production=args.production)
    archive = args.archive.resolve() if args.archive else build(config, args.identity, args.ad_hoc, args.native, args.photo_cloud_profile)
    if args.command == "install":
        install(config, archive, args.ad_hoc, not args.no_open)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Update stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
