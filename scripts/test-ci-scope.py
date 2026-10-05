#!/usr/bin/env python3
"""Exercise the classifier against real Git changes, including renames/deletions."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

spec = importlib.util.spec_from_file_location("ci_scope", Path(__file__).with_name("ci-scope.py"))
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)
WORKFLOW = (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text()


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
        for path in ("Sources/New.swift", "scripts/build.sh", ".github/workflows/ci.yml",
                     "Package.swift", "Package.resolved", "docs/releases/tool.py",
                     "Resources/SKILL.md", "BrowserExtension/README.md", "unknown.md"):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path)
                self.assertTrue(scope.native_required(self.base, self.commit()))

    def test_documentation_and_site_changes_for_each_event(self):
        for path in ("README.md", "AGENTS.md", "CONTRIBUTING.md", "SECURITY.md",
                     "CODE_OF_CONDUCT.md", "LICENSE", "docs/updating.md",
                     "docs/research/nested/note.md", "docs/surfaces.json",
                     "site/build.mjs", "site/handbook/contract.json", "site/assets/card.png"):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path)
                head = self.commit()
                for event in ("pull_request", "merge_group", "push"):
                    self.assertFalse(scope.native_required(self.base, head, event))

    def test_mixed_documentation_and_native(self):
        self.write("docs/updating.md")
        self.write("Sources/New.swift")
        head = self.commit()
        for event in ("pull_request", "merge_group", "push"):
            self.assertTrue(scope.native_required(self.base, head, event))

    def test_complete_merge_group_includes_earlier_native_change(self):
        self.write("Sources/EarlierPR.swift")
        self.commit()
        self.write("docs/later-pr.md")
        self.assertTrue(scope.native_required(self.base, self.commit(), "merge_group"))

    def test_push_rewrite_checks_removed_native_change(self):
        self.write("Sources/Removed.swift")
        before = self.commit()
        self.git("reset", "--hard", self.base)
        self.write("docs/rewrite.md")
        after = self.commit()
        # The PR-only comparison sees docs; a main rewrite also removes native code.
        self.assertFalse(scope.native_required(before, after, "pull_request"))
        self.assertTrue(scope.native_required(before, after, "push"))

    def test_manual_and_unknown_events_require_native(self):
        self.write("docs/updating.md")
        head = self.commit()
        for event in ("workflow_dispatch", "schedule", "", "unknown"):
            self.assertTrue(scope.native_required(self.base, head, event))

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

    def test_documentation_move_to_native(self):
        Path("docs/distribution.md").rename("Sources/Instructions.md")
        self.assertTrue(scope.native_required(self.base, self.commit()))

    def test_documentation_rename_with_spaces_and_newline(self):
        Path("docs/distribution.md").rename("docs/renamed note\nsecond line.md")
        self.assertFalse(scope.native_required(self.base, self.commit()))

    def test_empty_diff(self):
        for event in ("pull_request", "merge_group", "push"):
            self.assertTrue(scope.native_required(self.base, self.base, event))

    def test_missing_or_invalid_history(self):
        for base in ("", "--output=bad", "0" * 40):
            with self.subTest(base=base):
                for event in ("pull_request", "merge_group", "push"):
                    self.assertTrue(scope.native_required(base, self.base, event))
                    self.assertTrue(scope.native_required(self.base, base, event))


class GateTests(unittest.TestCase):
    """Execute the actual aggregate job's shell with synthetic GitHub outcomes."""

    def gate(self, required="true", results=None, scope_result="success", site="success"):
        job = WORKFLOW.split("  build-and-test:\n", 1)[1]
        script = textwrap.dedent(job.split("        run: |\n", 1)[1])
        env = dict(os.environ, SCOPE_RESULT=scope_result, SITE_RESULT=site,
                   NATIVE_REQUIRED=required,
                   NATIVE_RESULTS=" ".join(["success"] * 5 if results is None else results))
        return subprocess.run(["bash", "-e", "-c", script], env=env,
                              capture_output=True).returncode == 0

    def test_all_selected_jobs_pass(self):
        self.assertTrue(self.gate())
        self.assertTrue(self.gate("false", ["skipped"] * 5))

    def test_scope_and_site_are_required(self):
        for result in ("failure", "cancelled", "skipped", ""):
            self.assertFalse(self.gate(scope_result=result))
            self.assertFalse(self.gate(site=result))
            self.assertFalse(self.gate("false", ["skipped"] * 5, site=result))

    def test_native_failure_cannot_turn_green(self):
        for index in range(5):
            for result in ("failure", "cancelled", "skipped"):
                results = ["success"] * 5
                results[index] = result
                self.assertFalse(self.gate(results=results))
        self.assertFalse(self.gate("false", ["success"] * 5))
        self.assertFalse(self.gate(required=""))
        self.assertFalse(self.gate(required="unknown"))
        for results in ([], ["success"] * 4, ["success"] * 6):
            self.assertFalse(self.gate(results=results))


if __name__ == "__main__":
    unittest.main()
