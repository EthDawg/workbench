"""Regression checks for release rejection and nested signing order."""
import importlib.util
import hashlib
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("workbench_release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    ROOT = Path(__file__).resolve().parents[2]
    IDENTITY = "A" * 40
    TEAM = "ABCDEFGHIJ"
    SIGNATURE = "Authority=Developer ID Application: Example\nTeamIdentifier=ABCDEFGHIJ\nflags=0x10000(runtime)\nTimestamp=Sep 8, 2026\n"
    ACTION = {"fullyQualifiedTypeName": "LocalVoice.TranscribeWithWorkbench", "isDiscoverable": True,
              "openAppWhenRun": False, "parameters": [{"name": "audio"}], "outputType": {"type": "string"}}

    def make_app(self, root, config):
        app = root / config["bundle"]
        executable = app / "Contents/MacOS" / config["executable"]
        executable.parent.mkdir(parents=True)
        executable.write_bytes(bytes.fromhex("cffaedfe") + b"fixture")
        info = {"CFBundleIdentifier": config["identifier"], "CFBundleExecutable": config["executable"],
                "CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "42"}
        if config["channel"] == "preview":
            info["WorkbenchChannel"] = "preview"
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        metadata = app / "Contents/Resources/Metadata.appintents/extract.actionsdata"
        metadata.parent.mkdir(parents=True)
        metadata.write_text(json.dumps({"actions": {"TranscribeWithWorkbench": self.ACTION}}))
        return app

    def pack(self, app, archive):
        with zipfile.ZipFile(archive, "w") as package:
            for path in app.rglob("*"):
                if path.is_file():
                    package.write(path, path.relative_to(app.parent))

    def test_configuration_preserves_production_and_isolates_preview(self):
        production = release.configuration(self.ROOT)
        preview = release.configuration(self.ROOT, preview=True)
        original = json.loads((self.ROOT / "scripts/release/config.json").read_text())
        for key in ("bundle", "identifier", "executable", "archive", "build", "regressions", "checks", "entitlements"):
            self.assertEqual(production[key], original[key])
        self.assertEqual(production["channel"], "production")
        self.assertEqual(production["preview_archive"], original["archive"])
        self.assertEqual(preview["bundle"], "Workbench Preview.app")
        self.assertEqual(preview["identifier"], original["identifier"] + ".preview")
        self.assertEqual(preview["executable"], original["executable"] + "Preview")
        self.assertEqual(Path(preview["preview_archive"]).name, "Workbench Preview.zip")
        self.assertEqual(release.release_directory(self.ROOT, "1.4.0", "42", "production"), self.ROOT / ".build/releases/1.4.0-42")
        self.assertNotEqual(release.release_directory(self.ROOT, "1.4.0", "42", "preview"), release.release_directory(self.ROOT, "1.4.0", "42", "production"))

    def test_preview_reuses_builder_while_production_keeps_original_command(self):
        for preview in (False, True):
            config = release.configuration(self.ROOT, preview=preview)
            with patch.dict(release.os.environ, {"REQUIRE_APP_INTENTS": "0"}), \
                 patch.object(release, "run") as run, patch.object(release, "preview_tools") as helper:
                def build(*args, **kwargs):
                    self.assertEqual(release.os.environ["REQUIRE_APP_INTENTS"], "1")
                    return Path("preview.zip")
                helper.return_value.build.side_effect = build
                run.side_effect = build
                result = release.build_archive(self.ROOT, config, self.IDENTITY)
                if preview:
                    helper.return_value.build.assert_called_once_with(config, identity=self.IDENTITY, photo_cloud_profile=None)
                    run.assert_not_called()
                    self.assertEqual(result, Path("preview.zip"))
                else:
                    run.assert_called_once_with(*config["build"])
                    helper.assert_not_called()
                    self.assertEqual(result, self.ROOT / config.get("component_archive", config["archive"]))
                self.assertEqual(release.os.environ["REQUIRE_APP_INTENTS"], "0")

    def test_cloud_profile_passes_only_to_preview_and_build_failure_restores_environment(self):
        profile = Path("/fixture/paired.provisionprofile")
        preview = release.configuration(self.ROOT, preview=True)
        production = release.configuration(self.ROOT)
        with patch.dict(release.os.environ, {}, clear=True), patch.object(release, "preview_tools") as helper:
            helper.return_value.build.side_effect = RuntimeError("injected build failure")
            with self.assertRaisesRegex(RuntimeError, "injected build"):
                release.build_archive(self.ROOT, preview, self.IDENTITY, photo_cloud_profile=profile)
            helper.return_value.build.assert_called_once_with(preview, identity=self.IDENTITY, photo_cloud_profile=profile)
            self.assertNotIn("REQUIRE_APP_INTENTS", release.os.environ)
        with patch.object(release, "run") as run, patch.object(release, "preview_tools") as helper:
            with self.assertRaisesRegex(RuntimeError, "only supported.*Preview"):
                release.build_archive(self.ROOT, production, self.IDENTITY, photo_cloud_profile=profile)
            run.assert_not_called(); helper.assert_not_called()

    def test_cli_rejects_production_cloud_or_missing_profile_before_apple_operations(self):
        arguments = ["release.py", "--identity", self.IDENTITY, "--team-id", self.TEAM,
                     "--keychain-profile", "fixture", "--photo-cloud-profile", "/missing/profile"]
        for extra, reason in [([], "requires --preview"), (["--preview"], "existing provisioning profile")]:
            with self.subTest(extra=extra), patch("sys.argv", arguments + extra), \
                 patch("sys.stderr", new_callable=io.StringIO) as errors, patch.object(release, "run") as run:
                with self.assertRaises(SystemExit) as stopped:
                    release.main()
                self.assertEqual(stopped.exception.code, 2)
                self.assertIn(reason, errors.getvalue())
                run.assert_not_called()

    def test_archive_must_contain_usable_shortcuts_metadata(self):
        config = release.configuration(self.ROOT, preview=True)
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(Path(temporary), config)
            metadata = app / "Contents/Resources/Metadata.appintents/extract.actionsdata"
            release.validate_app_intents(app)
            invalid = ["", "not json", "{}", "[]", json.dumps({"actions": {"TranscribeWithWorkbench": None}})]
            for key, value in [("fullyQualifiedTypeName", "Wrong.Action"), ("isDiscoverable", False),
                               ("openAppWhenRun", True), ("parameters", []), ("outputType", None)]:
                invalid.append(json.dumps({"actions": {"TranscribeWithWorkbench": {**self.ACTION, key: value}}}))
            for value in invalid:
                metadata.write_text(value)
                with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, "App Intents metadata"):
                    release.validate_app_intents(app)
            metadata.unlink()
            with self.assertRaisesRegex(RuntimeError, "App Intents metadata"):
                release.validate_app_intents(app)

    def test_unrequested_cloud_marker_cannot_be_released_as_disabled(self):
        config = release.configuration(self.ROOT, preview=True)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self.make_app(root, config)
            path = app / "Contents/Info.plist"
            info = plistlib.loads(path.read_bytes())
            for marker in [True, "YES", "false", 1]:
                path.write_bytes(plistlib.dumps({**info, "WorkbenchPhotoCloudProvisioned": marker}))
                with self.subTest(marker=marker), patch.object(release, "run") as run:
                    with self.assertRaisesRegex(RuntimeError, "explicit --photo-cloud-profile"):
                        release.validate_cloud(app, root, self.TEAM, False)
                    run.assert_not_called()

    def test_both_channels_reject_wrong_bundle_executable_or_channel(self):
        for preview in (False, True):
            config = release.configuration(self.ROOT, preview=preview)
            with tempfile.TemporaryDirectory() as temporary:
                app = self.make_app(Path(temporary), config)
                path = app / "Contents/Info.plist"
                original = plistlib.loads(path.read_bytes())
                release.validate_identity(app, config)
                for key, value in (("CFBundleIdentifier", "wrong.app"), ("CFBundleExecutable", "wrong"),
                                   ("WorkbenchChannel", "production" if preview else "preview"),
                                   ("CFBundleVersion", "../../elsewhere")):
                    path.write_bytes(plistlib.dumps({**original, key: value}))
                    with self.subTest(preview=preview, key=key), self.assertRaises(RuntimeError):
                        release.validate_identity(app, config)
                path.write_bytes(plistlib.dumps(original))
                renamed = app.with_name("Wrong.app")
                app.rename(renamed)
                with self.assertRaises(RuntimeError):
                    release.validate_identity(renamed, config)

    def test_archive_rejects_wrong_app_traversal_and_duplicate_paths(self):
        config = release.configuration(self.ROOT, preview=True)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self.make_app(root, config)
            archive = root / "preview.zip"
            self.pack(app, archive)
            release.validate_archive(archive, config)
            for name in ("Workbench.app/Contents/Info.plist", "../outside", "/outside", "__MACOSX/Other.app/._Info.plist",
                         f"{config['bundle']}/Contents/./Info.plist"):
                self.pack(app, archive)
                with zipfile.ZipFile(archive, "a") as package:
                    package.writestr(name, "unexpected")
                with self.subTest(name=name), self.assertRaises(RuntimeError):
                    release.validate_archive(archive, config)

    def test_clean_commit_is_rechecked_and_source_changes_rejected(self):
        with patch.object(release, "run", return_value=SimpleNamespace(stdout=" M app.swift\n")):
            with self.assertRaisesRegex(RuntimeError, "Commit or set aside"):
                release.require_clean_source()
        with patch.object(release, "run", side_effect=[SimpleNamespace(stdout=""), SimpleNamespace(stdout="different\n")]):
            with self.assertRaisesRegex(RuntimeError, "source commit changed"):
                release.require_clean_source(expected="original")

    def run_release_fixture(self, preview=False, fail_final_gatekeeper=False, cloud=False,
                            fail_cloud=None, corrupt_final_intents=False):
        config = release.configuration(self.ROOT, preview=preview)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = self.make_app(root / "fixture", config)
            profile = root / "paired.provisionprofile"
            profile.write_bytes(b"synthetic fixture; Apple tools are mocked")
            if cloud:
                info_path = app / "Contents/Info.plist"
                info = plistlib.loads(info_path.read_bytes())
                info.update(WorkbenchPhotoCloudProvisioned=True,
                            WorkbenchPhotoCloudContainer="iCloud.com.ethdawg.workbench.preview",
                            WorkbenchPhotoCloudEnvironment="Production")
                info_path.write_bytes(plistlib.dumps(info))
            archive = root / "built.zip"
            self.pack(app, archive)
            commands = []
            cloud_checks = []

            def command(*args, **kwargs):
                commands.append(args)
                if args[:3] == ("git", "status", "--porcelain"):
                    return SimpleNamespace(stdout="")
                if args[:3] == ("git", "rev-parse", "HEAD"):
                    return SimpleNamespace(stdout="fixture-commit\n")
                if args[0] == "security":
                    return SimpleNamespace(stdout=f'{self.IDENTITY} "Developer ID Application: Example ({self.TEAM})"\n')
                if args[:3] == ("ditto", "-x", "-k"):
                    with zipfile.ZipFile(args[3]) as package:
                        package.extractall(args[4])
                    if Path(args[4]).name == "verify" and corrupt_final_intents:
                        (Path(args[4]) / config["bundle"] / "Contents/Resources/Metadata.appintents/extract.actionsdata").unlink()
                elif args[:2] == ("ditto", "-c"):
                    self.pack(Path(args[-2]), Path(args[-1]))
                elif args[:2] == ("lipo", "-archs"):
                    return SimpleNamespace(stdout="arm64\n")
                elif args[:3] == ("xcrun", "notarytool", "submit"):
                    return SimpleNamespace(stdout=json.dumps({"id": "submission-id"}))
                elif args[:3] == ("xcrun", "notarytool", "info"):
                    return SimpleNamespace(stdout=json.dumps({"id": "submission-id", "status": "Accepted"}))
                elif args[:3] == ("xcrun", "notarytool", "log"):
                    Path(args[-1]).write_text("{}")
                elif args[0] == "spctl" and "verify" in Path(args[-1]).parts and fail_final_gatekeeper:
                    raise RuntimeError("injected final archive Gatekeeper failure")
                elif args[:2] == (release.sys.executable, root / "scripts/check-photo-cloud.py"):
                    self.assertEqual(args[2:-1], ("--platform", "macos", "--team", self.TEAM,
                                                 "--environment", "Production", "--app"))
                    cloud_checks.append(Path(args[-1]))
                    if (len(cloud_checks) == 1 and fail_cloud == "before") or (len(cloud_checks) == 2 and fail_cloud == "final"):
                        raise RuntimeError("injected cloud profile validation failure")
                return SimpleNamespace(stdout="{}", stderr=self.SIGNATURE)

            arguments = ["release.py", "--identity", self.IDENTITY, "--team-id", self.TEAM, "--keychain-profile", "fixture"]
            if preview:
                arguments.append("--preview")
            if cloud:
                arguments += ["--photo-cloud-profile", str(profile)]
            with patch.object(release, "__file__", str(root / "scripts/release/release.py")), \
                 patch.object(release, "configuration", return_value=config), \
                 patch.object(release, "build_archive", return_value=archive) as build_archive, \
                 patch.object(release, "run", side_effect=command), \
                 patch.object(release.os, "chdir"), patch.object(release.subprocess, "run"), \
                 patch("sys.argv", arguments):
                failure = ("cloud profile validation" if fail_cloud else "App Intents metadata" if corrupt_final_intents
                           else "final archive Gatekeeper" if fail_final_gatekeeper else None)
                if failure:
                    with self.assertRaisesRegex(RuntimeError, failure):
                        release.main()
                else:
                    release.main()
                build_archive.assert_called_once_with(root, config, self.IDENTITY,
                                                       photo_cloud_profile=profile if cloud else None)
            output = release.release_directory(root, "1.4.0", "42", config["channel"])
            self.assertEqual(json.loads((output / "candidate.json").read_text())["channel"], config["channel"])
            submitted = fail_cloud != "before"
            self.assertEqual((output / "submission.json").exists(), submitted)
            if submitted:
                self.assertEqual(json.loads((output / "submission.json").read_text())["id"], "submission-id")
                self.assertEqual((output / "submission-SHA256SUMS.txt").read_text().split()[0], hashlib.sha256((output / "submission.zip").read_bytes()).hexdigest())
            final = output / Path(config["preview_archive"]).name
            self.assertEqual(final.exists(), failure is None)
            self.assertEqual((output / "release.json").exists(), failure is None)
            self.assertEqual((output / "SHA256SUMS.txt").exists(), failure is None)
            if not failure:
                evidence = json.loads((output / "release.json").read_text())
                self.assertEqual(evidence["channel"], config["channel"])
                self.assertEqual(evidence["bundle"], config["identifier"])
                self.assertEqual(evidence["executable"], config["executable"])
                self.assertEqual(evidence["sha256"], hashlib.sha256(final.read_bytes()).hexdigest())
                self.assertEqual((output / "SHA256SUMS.txt").read_text(), f"{evidence['sha256']}  {final.name}\n")
                expected_cloud = {"enabled": True, "container": "iCloud.com.ethdawg.workbench.preview", "environment": "Production"} if cloud else {"enabled": False}
                self.assertEqual(evidence["icloud"], expected_cloud)
                self.assertEqual(json.loads((output / "candidate.json").read_text())["icloud"], expected_cloud)
                with zipfile.ZipFile(final) as package:
                    self.assertIn(config["bundle"] + "/Contents/Resources/Metadata.appintents/extract.actionsdata", package.namelist())
            self.assertEqual(sum(args[:3] == ("xcrun", "notarytool", "submit") for args in commands), int(submitted))
            self.assertEqual(sum(args[:3] == ("git", "status", "--porcelain") for args in commands), 2)
            if cloud:
                self.assertEqual(len(cloud_checks), 1 if fail_cloud == "before" else 2)
                if submitted:
                    first_check = next(i for i, args in enumerate(commands) if args[:2] == (release.sys.executable, root / "scripts/check-photo-cloud.py"))
                    submit = next(i for i, args in enumerate(commands) if args[:3] == ("xcrun", "notarytool", "submit"))
                    self.assertLess(first_check, submit)
                    self.assertIn("verify", cloud_checks[-1].parts)
            else:
                self.assertEqual(cloud_checks, [])
            if not fail_cloud and not corrupt_final_intents:
                self.assertTrue(any(args[0] == "spctl" and "verify" in Path(args[-1]).parts for args in commands))

    def test_full_production_pipeline_preserved_without_apple_operations(self):
        self.run_release_fixture()

    def test_preview_pipeline_keeps_identity_channel_and_final_archive_evidence(self):
        self.run_release_fixture(preview=True)

    def test_failed_final_archive_retains_recovery_but_emits_no_release(self):
        self.run_release_fixture(preview=True, fail_final_gatekeeper=True)

    def test_cloud_preview_is_verified_before_submission_and_after_final_extraction(self):
        self.run_release_fixture(preview=True, cloud=True)

    def test_cloud_profile_failure_prevents_submission(self):
        self.run_release_fixture(preview=True, cloud=True, fail_cloud="before")

    def test_final_cloud_profile_failure_retains_submission_and_emits_no_release(self):
        self.run_release_fixture(preview=True, cloud=True, fail_cloud="final")

    def test_final_archive_missing_shortcuts_metadata_emits_no_release(self):
        self.run_release_fixture(preview=True, corrupt_final_intents=True)

    def test_only_explicit_acceptance_passes(self):
        for result in [{}, {"status": "Invalid"}, {"status": "In Progress"}, {"status": "Rejected"}]:
            with self.subTest(result=result), self.assertRaises(RuntimeError):
                release.require_accepted(result)
        release.require_accepted({"status": "Accepted"})

    def test_reject_wrong_team_or_weakened_signature(self):
        valid = "Authority=Developer ID Application: Example\nTeamIdentifier=ABCDEFGHIJ\nflags=0x10000(runtime)\nTimestamp=Sep 8, 2026\n"
        for missing in ["Authority=Developer ID Application:", "TeamIdentifier=ABCDEFGHIJ", "runtime", "Timestamp="]:
            with self.subTest(missing=missing), patch.object(release, "run", return_value=SimpleNamespace(stderr=valid.replace(missing, ""))):
                with self.assertRaises(RuntimeError):
                    release.check_signature(Path("Example.app"), "ABCDEFGHIJ")

    def test_nested_code_precedes_its_enclosing_bundle(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "Example.app"
            helper = app / "Contents/XPCServices/Helper.xpc"
            executable = helper / "Contents/MacOS/Helper"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(bytes.fromhex("cffaedfe") + b"test")
            (helper / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Helper"}))
            resource = app / "Contents/Resources/Data.bundle"
            resource.mkdir(parents=True)
            (resource / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "test.resources"}))
            alias = executable.with_name("Alias")
            alias.symlink_to(executable)
            targets = release.signing_targets(app)
            self.assertEqual(targets, [executable, helper, app])


if __name__ == "__main__":
    unittest.main()
