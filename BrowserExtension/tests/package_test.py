"""Exercise the publication archive with synthetic extra files and mutations."""

import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile


PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_chrome", PROJECT / "scripts/package-chrome.py")
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)


class ChromePackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="workbench-package-test-")
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "BrowserExtension"
        shutil.copytree(PROJECT / "BrowserExtension", self.source)

    def tearDown(self):
        self.temporary.cleanup()

    def manifest(self, change):
        file = self.source / "manifest.json"
        value = json.loads(file.read_text())
        change(value)
        file.write_text(json.dumps(value))

    def test_zip_contains_exact_runtime_bytes_and_no_development_or_private_extras(self):
        (self.source / ".env").write_text("SYNTHETIC_PRIVATE_VALUE=do-not-package")
        result = PACKAGER.package(self.source, self.directory / "release.zip")
        with zipfile.ZipFile(result["artifact"]) as archive:
            self.assertEqual(archive.namelist(), list(PACKAGER.RUNTIME_FILES))
            self.assertEqual(archive.read("manifest.json"), (self.source / "manifest.json").read_bytes())
            self.assertNotIn("README.md", archive.namelist())
            self.assertNotIn("store/promo-440x280.png", archive.namelist())
        self.assertEqual(result["unpacked_extension_id"], "ajafaiojgpdgmeblldllnhhfnafiiieo")

    def test_archive_is_reproducible(self):
        first = PACKAGER.package(self.source, self.directory / "first.zip")
        second = PACKAGER.package(self.source, self.directory / "second.zip")
        self.assertEqual(first["sha256"], second["sha256"])

    def test_rejects_symlinked_runtime_file(self):
        path = self.source / "core.js"
        path.unlink()
        path.symlink_to(PROJECT / "BrowserExtension/core.js")
        with self.assertRaisesRegex(PACKAGER.PackageError, "symlinked runtime"):
            PACKAGER.validate(self.source)

    def test_rejects_missing_asset(self):
        (self.source / "icons/icon128.png").unlink()
        with self.assertRaises(PACKAGER.PackageError):
            PACKAGER.validate(self.source)

    def test_rejects_wrong_icon_dimensions(self):
        shutil.copyfile(self.source / "icons/icon32.png", self.source / "icons/icon128.png")
        with self.assertRaisesRegex(PACKAGER.PackageError, "dimensions"):
            PACKAGER.validate(self.source)

    def test_rejects_unreviewed_permissions(self):
        self.manifest(lambda value: value["permissions"].append("tabs"))
        with self.assertRaisesRegex(PACKAGER.PackageError, "permissions"):
            PACKAGER.validate(self.source)

    def test_rejects_remote_runtime_asset_but_allows_help_links(self):
        PACKAGER.validate(self.source)
        path = self.source / "popup.html"
        path.write_text(path.read_text().replace('src="popup.js"', 'src="https://example.test/code.js"'))
        with self.assertRaisesRegex(PACKAGER.PackageError, "Remote"):
            PACKAGER.validate(self.source)

    def test_rejects_runtime_import_of_unpackaged_development_file(self):
        path = self.source / "core.js"
        path.write_text(path.read_text() + '\nimport test from "./tests/core.test.js";\n')
        with self.assertRaisesRegex(PACKAGER.PackageError, "allowlist"):
            PACKAGER.validate(self.source)

    def test_rejects_invalid_version_and_oversize_description(self):
        self.manifest(lambda value: value.update(version="01.2"))
        with self.assertRaisesRegex(PACKAGER.PackageError, "version"):
            PACKAGER.validate(self.source)
        self.manifest(lambda value: value.update(version="0.1.0", description="x" * 133))
        with self.assertRaisesRegex(PACKAGER.PackageError, "Description"):
            PACKAGER.validate(self.source)


if __name__ == "__main__":
    unittest.main()
