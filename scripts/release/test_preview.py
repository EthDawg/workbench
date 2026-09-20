"""Installer safety regressions; all filesystem mutations stay in temporary homes."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("workbench_preview", Path(__file__).with_name("preview.py"))
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


class PreviewTests(unittest.TestCase):
    def test_configuration_never_targets_production(self):
        config = preview.configuration()
        self.assertTrue(config["identifier"].endswith(".preview"))
        self.assertTrue(config["executable"].endswith("Preview"))
        self.assertTrue(config["bundle"].endswith(" Preview.app"))
        self.assertNotEqual(config["archive"], config["preview_archive"])

    def test_bundle_rejects_production_and_disposable_signature(self):
        config = preview.configuration()
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / config["bundle"]
            (app / "Contents").mkdir(parents=True)
            info = preview.update_bundle_info({"NSServices": [{"NSMessage": "readSelection"}]}, config, "1")
            info["CFBundleIdentifier"] = config["identifier"].removesuffix(".preview")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            with self.assertRaises(RuntimeError):
                preview.validate_bundle(app, config)
            info["CFBundleIdentifier"] = config["identifier"]
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            with patch.object(preview, "run", return_value=SimpleNamespace(stderr="Signature=adhoc\nTeamIdentifier=not set\n")):
                with self.assertRaises(RuntimeError):
                    preview.validate_bundle(app, config)
                # Existing ad-hoc installs can be upgraded once to Developer ID;
                # only the incoming replacement must be persistently signed.
                preview.validate_bundle(app, config, allow_ad_hoc=True)

    def test_preview_service_uses_distinct_title_and_port(self):
        config = preview.configuration()
        source = {"NSServices": [{"NSMessage": "readSelection", "NSPortName": "Workbench",
                                  "NSMenuItem": {"default": "Read Selection in Workbench"}}]}
        info = preview.update_bundle_info(source, config, "123")
        service = info["NSServices"][0]
        self.assertEqual(service["NSPortName"], "Workbench Preview")
        self.assertEqual(service["NSMenuItem"]["default"], "Read Selection in Workbench Preview")
        self.assertEqual(info["CFBundleExecutable"], "WorkbenchPreview")

    def run_update(self, fail=False, legacy=False):
        config = preview.configuration()
        signature = "Authority=Developer ID Application: Example\nTeamIdentifier=ABCDEFGHIJ\n"
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            installed = home / "Applications" / config["bundle"]
            installed.mkdir(parents=True)
            (installed / "version").write_text("old")
            production = installed.with_name(config["production_bundle"])
            production.mkdir()
            (production / "version").write_text("production")
            data = home / "Library/Application Support/example"
            data.mkdir(parents=True)
            (data / "state.json").write_text("saved settings")
            archive = home / "incoming"
            incoming = archive / config["bundle"]
            incoming.mkdir(parents=True)
            (incoming / "version").write_text("new")
            for app, has_services in [(installed, not legacy), (incoming, True)]:
                (app / "Contents").mkdir()
                source = {"NSServices": [{"NSMessage": "readSelection"}]} if has_services else {}
                info = preview.update_bundle_info(source, config, "1")
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            actual_validate = preview.validate_bundle
            backup = home / config["preview_archive"]
            backup.parent.mkdir(parents=True, exist_ok=True)

            def command(*args, **kwargs):
                if args[:4] == ("ditto", "-x", "-k", archive):
                    shutil.copytree(incoming, Path(args[4]) / config["bundle"])
                elif args[:2] == ("ditto", "-c"):
                    Path(args[-1]).write_text("rollback archive")
                return SimpleNamespace(stderr=signature)

            def validate(app, *args, **kwargs):
                if fail and app == installed and (app / "version").read_text() == "new":
                    raise RuntimeError("injected verification failure")
                return actual_validate(app, *args, **kwargs)

            with patch.object(Path, "home", return_value=home), patch.object(preview, "ROOT", home), \
                 patch.object(preview, "run", side_effect=command), \
                 patch.object(preview, "validate_bundle", side_effect=validate), \
                 patch.object(preview.subprocess, "run", return_value=SimpleNamespace(returncode=1)):
                if fail:
                    with self.assertRaises(RuntimeError):
                        preview.install(config, archive, open_app=False)
                else:
                    preview.install(config, archive, open_app=False)
            self.assertEqual((installed / "version").read_text(), "old" if fail else "new")
            self.assertEqual((production / "version").read_text(), "production")
            self.assertEqual((data / "state.json").read_text(), "saved settings")
            self.assertTrue(backup.with_name("Previous-" + backup.name).exists())

    def test_upgrade_from_bundle_without_services(self):
        self.run_update(legacy=True)

    def test_failed_upgrade_restores_bundle_without_services(self):
        self.run_update(fail=True, legacy=True)

    def test_service_validation_is_only_optional_for_previous_bundles(self):
        config = preview.configuration()
        signature = "Authority=Developer ID Application: Example\nTeamIdentifier=ABCDEFGHIJ\n"
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / config["bundle"]
            (app / "Contents").mkdir(parents=True)
            info = preview.update_bundle_info({}, config, "1")
            plist = app / "Contents/Info.plist"
            plist.write_bytes(plistlib.dumps(info))
            with patch.object(preview, "run", return_value=SimpleNamespace(stderr=signature)) as run:
                with self.assertRaisesRegex(RuntimeError, "Services identity"):
                    preview.validate_bundle(app, config)
                preview.validate_bundle(app, config, require_services=False)
                self.assertTrue(any(call.args[:2] == ("codesign", "--verify") for call in run.call_args_list))
                info["CFBundleIdentifier"] = "invalid.previous.identity"
                plist.write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(RuntimeError, "exact selected identity"):
                    preview.validate_bundle(app, config, require_services=False)

    def test_update_preserves_production_and_saved_data(self):
        self.run_update()

    def test_failed_update_restores_previous_app(self):
        self.run_update(fail=True)

    def test_process_inventory_failure_never_updates_an_app(self):
        with patch.object(preview.subprocess, "run", return_value=SimpleNamespace(returncode=3)):
            with self.assertRaisesRegex(RuntimeError, "Unable to inspect"):
                preview.install(preview.configuration(), Path("unused.zip"))

    def test_production_selection_uses_existing_identity(self):
        config = preview.configuration(production=True)
        self.assertEqual(config["channel"], "production")
        self.assertEqual(config["bundle"], config["production_bundle"])
        self.assertFalse(config["identifier"].endswith(".preview"))
        self.assertFalse(config["executable"].endswith("Preview"))

    def test_installer_refuses_running_preview(self):
        with patch.object(preview.subprocess, "run", return_value=SimpleNamespace(returncode=0)):
            with self.assertRaisesRegex(RuntimeError, "Quit"):
                preview.install(preview.configuration(), Path("unused.zip"))


if __name__ == "__main__":
    unittest.main()
