#!/usr/bin/env python3
"""Exercise the classifier against real Git changes, including renames/deletions."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("ci_scope", Path(__file__).with_name("ci-scope.py"))
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old_cwd = os.getcwd()
        os.chdir(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Synthetic test")
        for path in ("Sources/App.swift", "docs/distribution.md"):
            self.write(path)
        self.base = self.commit()

    def tearDown(self):
        os.chdir(self.old_cwd)
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL).decode().strip()

    def write(self, path):
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("synthetic\n")

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def test_release_promotion(self):
        for path in ("site/updates/production.json", "site/updates/production.xml", "docs/releases/2.4.md"):
            self.write(path)
        Path("docs/distribution.md").write_text("new release\n")
        self.assertFalse(scope.native_required(self.base, self.commit()))

    def test_unknown_paths_require_native(self):
        for path in ("Sources/New.swift", "scripts/build.sh", ".github/workflows/ci.yml", "site/build.mjs", "Package.swift", "docs/releases/tool.py"):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path)
                self.assertTrue(scope.native_required(self.base, self.commit()))

    def test_native_deletion(self):
        Path("Sources/App.swift").unlink()
        self.assertTrue(scope.native_required(self.base, self.commit()))

    def test_native_renamed_to_release_note(self):
        Path("docs/releases").mkdir()
        Path("Sources/App.swift").rename("docs/releases/moved.md")
        self.assertTrue(scope.native_required(self.base, self.commit()))

    def test_release_note_deletion(self):
        Path("docs/distribution.md").unlink()
        self.assertFalse(scope.native_required(self.base, self.commit()))

    def test_empty_diff(self):
        self.assertTrue(scope.native_required(self.base, self.base))

    def test_missing_or_invalid_history(self):
        for base in ("", "--output=bad", "0" * 40):
            with self.subTest(base=base):
                self.assertTrue(scope.native_required(base, self.base))


if __name__ == "__main__":
    unittest.main()
