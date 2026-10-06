#!/usr/bin/env python3
"""Negative and positive fixtures for scripts/verify-preview.sh.

Builds synthetic Preview bundles in a temporary directory with an inert executable, and puts
shims for `codesign` and `log` on PATH, so the helper's refusals and failures are exercised
without an installed app, a real signature or a real log probe. Nothing here opens UI."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().with_name("verify-preview.sh")
MODE_COUNT = 10


class VerifyPreviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="verify-preview-"))
        self.addCleanup(shutil.rmtree, self.temp, ignore_errors=True)
        self.shims = self.temp / "shims"; self.shims.mkdir()
        self.invocations = self.temp / "invocations.txt"
        self.shim("codesign", f'''#!/bin/bash
for a in "$@"; do if [ "$a" = "-d" ]; then echo "Authority=Developer ID Application: Synthetic (TEAM)" >&2; fi; done
exit "${{CODESIGN_EXIT:-0}}"
''')
        self.shim("log", '#!/bin/bash\nexit "${LOG_EXIT:-0}"\n')
        self.env = dict(os.environ, PATH=f"{self.shims}:{os.environ['PATH']}", VERIFY_PREVIEW_SETTLE="0",
                        INVOCATIONS=str(self.invocations))

    def shim(self, name, body):
        path = self.shims / name
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def bundle(self, name="Workbench Preview.app", **overrides):
        app = self.temp / name
        (app / "Contents/MacOS").mkdir(parents=True)
        info = {"CFBundleIdentifier": "com.ethdawg.workbench.preview", "CFBundleExecutable": "WorkbenchPreview",
                "WorkbenchChannel": "preview", "CFBundleShortVersionString": "2.4.1", "CFBundleVersion": "20261006084435",
                "WorkbenchSourceRevision": "5d12768f14b2033acee418215e8ddee1a4672e9a", "WorkbenchSourceDirty": False,
                "NSServices": [{"NSMessage": "readSelection", "NSPortName": "Workbench Preview",
                                "NSMenuItem": {"default": "Read Selection in Workbench Preview"}}]}
        for key, value in overrides.items():
            if value is None: info.pop(key, None)
            else: info[key] = value
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        executable = app / "Contents/MacOS/WorkbenchPreview"
        executable.write_text('#!/bin/bash\necho "$1" >> "$INVOCATIONS"\n'
                              'if [ "$1" = "${FAIL_MODE:-}" ]; then echo "CHECK FAILED" >&2; exit 1; fi\n'
                              'echo "SYNTHETIC_CHECKS_OK: $1"\n')
        executable.chmod(executable.stat().st_mode | stat.S_IEXEC)
        return app

    def run_script(self, app, out=None, **env):
        out = out or (self.temp / "out")
        result = subprocess.run(["bash", str(SCRIPT), str(app), str(out)], env=dict(self.env, **env),
                                capture_output=True, text=True)
        return result, out

    def modes_run(self):
        return self.invocations.read_text().split() if self.invocations.exists() else []

    def test_valid_bundle_passes_and_keeps_receipts(self):
        result, out = self.run_script(self.bundle())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("VERIFY OK", result.stdout)
        rows = (out / "summary.txt").read_text().splitlines()
        self.assertEqual(len(rows), MODE_COUNT + 1)
        self.assertTrue(all(row.split()[1] == "0" for row in rows[1:]))
        receipt = json.loads((out / "build.json").read_text())
        self.assertEqual((receipt["version"], receipt["build"], receipt["source_dirty"]), ("2.4.1", "20261006084435", False))
        self.assertIn("Developer ID", receipt["authority"])
        self.assertEqual(len(self.modes_run()), MODE_COUNT)

    def test_missing_source_revision_is_refused_before_any_mode(self):
        for key in ("WorkbenchSourceRevision", "CFBundleVersion", "CFBundleShortVersionString", "WorkbenchSourceDirty"):
            with self.subTest(key=key):
                self.invocations.unlink(missing_ok=True)
                result, _ = self.run_script(self.bundle(name=f"{key}.app", **{key: None}), out=self.temp / f"out-{key}")
                self.assertEqual(result.returncode, 2)
                self.assertIn("refused", result.stdout + result.stderr)
                self.assertEqual(self.modes_run(), [])

    def test_stable_identity_ad_hoc_and_bad_signature_are_refused(self):
        result, _ = self.run_script(self.bundle(name="Stable.app", CFBundleIdentifier="com.ethdawg.workbench"), out=self.temp / "o1")
        self.assertEqual(result.returncode, 2); self.assertEqual(self.modes_run(), [])
        # A bad signature: the Developer ID shim's strict verification fails.
        result, _ = self.run_script(self.bundle(name="Bad.app"), out=self.temp / "o2", CODESIGN_EXIT="1")
        self.assertEqual(result.returncode, 2); self.assertEqual(self.modes_run(), [])
        # An ad-hoc signature: verification passes but no Developer ID authority is listed.
        self.shim("codesign", '#!/bin/bash\nfor a in "$@"; do if [ "$a" = "-d" ]; then echo "Signature=adhoc" >&2; fi; done\nexit "${CODESIGN_EXIT:-0}"\n')
        result, _ = self.run_script(self.bundle(name="AdHoc.app"), out=self.temp / "o3")
        self.assertEqual(result.returncode, 2); self.assertEqual(self.modes_run(), [])

    def test_executable_outside_the_bundle_is_refused(self):
        app = self.bundle(name="Linked.app")
        outside = self.temp / "elsewhere"; outside.write_text("#!/bin/bash\nexit 0\n"); outside.chmod(0o755)
        (app / "Contents/MacOS/WorkbenchPreview").unlink()
        (app / "Contents/MacOS/WorkbenchPreview").symlink_to(outside)
        result, _ = self.run_script(app)
        self.assertEqual(result.returncode, 2); self.assertIn("inside the bundle", result.stdout + result.stderr)

    def test_failed_log_query_is_capture_failed_not_zero(self):
        result, out = self.run_script(self.bundle(), LOG_EXIT="1")
        self.assertEqual(result.returncode, 1)
        rows = (out / "summary.txt").read_text().splitlines()[1:]
        self.assertTrue(all("capture-failed" in row for row in rows))
        self.assertIn("VERIFY FAILED", result.stderr)

    def test_failed_mode_fails_the_run(self):
        result, out = self.run_script(self.bundle(), FAIL_MODE="--check-reading")
        self.assertEqual(result.returncode, 1)
        rows = {row.split()[0]: row.split()[1] for row in (out / "summary.txt").read_text().splitlines()[1:]}
        self.assertEqual(rows["--check-reading"], "1")
        self.assertEqual(rows["--check-core"], "0")

    def test_output_directory_must_be_new_or_empty(self):
        used = self.temp / "used"; used.mkdir(); (used / "summary.txt").mkdir()
        result, _ = self.run_script(self.bundle(), out=used)
        self.assertEqual(result.returncode, 2); self.assertIn("not empty", result.stderr); self.assertEqual(self.modes_run(), [])


if __name__ == "__main__":
    unittest.main()
