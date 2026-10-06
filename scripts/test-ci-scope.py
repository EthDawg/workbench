#!/usr/bin/env python3
"""Exercise the classifier against real Git changes, including renames/deletions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

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
        self.assertFalse(scope.native_required(self.base, self.commit(), "merge_group"))

    def test_unknown_paths_require_native(self):
        for path in ("Sources/New.swift", "scripts/build.sh", ".github/workflows/ci.yml",
                     "Package.swift", "Package.resolved", "docs/releases/tool.py",
                     "Resources/SKILL.md", "BrowserExtension/README.md", "unknown.md"):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path)
                self.assertTrue(scope.native_required(self.base, self.commit(), "merge_group"))

    def test_pull_request_defers_native_to_the_queue(self):
        # The queue runs the five macOS jobs for every group; a push run would repeat them.
        self.write("Sources/New.swift")
        head = self.commit()
        self.assertFalse(scope.native_required(self.base, head, "pull_request"))
        self.assertFalse(scope.native_required(self.base, head, "pull_request", ["bug", "design system"]))
        self.assertTrue(scope.native_required(self.base, head, "pull_request", ["ci:native"]))
        self.assertTrue(scope.native_required(self.base, head, "pull_request", ["bug", " ci:native "]))
        self.assertFalse(scope.native_required(self.base, head, "pull_request", ["ci:nativeish"]))

    def test_only_verified_push_reuses_queue(self):
        self.write("Sources/New.swift")
        head = self.commit()
        self.assertFalse(scope.native_required(self.base, head, "push", queue_verified=True))
        self.assertTrue(scope.native_required(self.base, head, "push"))
        for event in ("merge_group", "workflow_dispatch", "unknown"):
            self.assertTrue(scope.native_required(self.base, head, event, queue_verified=True))

    def test_merge_message_is_not_evidence(self):
        self.write("Sources/New.swift")
        self.commit()
        self.git("commit", "--amend", "-qm", "Merge pull request #1 from owner/branch")
        self.assertTrue(scope.native_required(self.base, self.git("rev-parse", "HEAD"), "push"))

    def test_cli_queue_evidence_and_fallback(self):
        # Exercise the real entry point and gh boundary, without network or credentials.
        self.write("Sources/New.swift")
        head = self.commit()
        gh = Path(self.temp.name) / "gh"
        gh.write_text('#!/bin/sh\nprintf "%s" "$CI_TEST_RESPONSE"\n')
        gh.chmod(0o755)
        env = dict(os.environ, PATH=self.temp.name + os.pathsep + os.environ["PATH"])
        evidence = {"workflow_runs": [{"id": 123, "head_sha": head,
                    "event": "merge_group", "path": ".github/workflows/ci.yml",
                    "status": "completed", "conclusion": "success",
                    "head_branch": "gh-readonly-queue/main/pr-1-abc",
                    "repository": {"full_name": "example/workbench"}}]}
        script = str(Path(scope.__file__).resolve())
        for payload, expected in ((json.dumps(evidence), "native=false"),
                                  ("invalid json", "native=true"),
                                  ('{"workflow_runs": []}', "native=true")):
            env["CI_TEST_RESPONSE"] = payload
            result = subprocess.run([sys.executable, script, "--event", "push",
                "--base", self.base, "--head", head, "--repository", "example/workbench"],
                env=env, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), expected)

        # A receipt must never suppress a queue or manual run, nor trigger an API
        # call on the PR path (including read-only fork tokens).
        gh.write_text('#!/bin/sh\ntouch "$CI_TEST_CALLED"\nexit 1\n')
        called = Path(self.temp.name) / "called"
        env["CI_TEST_CALLED"] = str(called)
        for event, labels, expected in (("pull_request", "", "false"),
                                      ("pull_request", "ci:native", "true"),
                                      ("merge_group", "", "true"),
                                      ("workflow_dispatch", "", "true")):
            result = subprocess.run([sys.executable, script, "--event", event,
                "--base", self.base, "--head", head, "--labels", labels,
                "--repository", "example/workbench"], env=env,
                capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), "native=" + expected)
            self.assertFalse(called.exists())

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

    def test_report_verifier_changes_run_report_check_not_native(self):
        # services/report-check is validated by the always-run Report check job.
        for path in ("services/report-check/api/v1/verify.ts", "services/report-check/package-lock.json",
                     "services/report-check/ops/report_ops.py", "services/report-check/vercel.json"):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path)
                head = self.commit()
                for event in ("pull_request", "merge_group", "push"):
                    self.assertFalse(scope.native_required(self.base, head, event))

    def test_other_services_and_lookalike_paths_require_native(self):
        for path in ("services/report-intake/src/index.ts", "services/report-check.md",
                     "services/report-checker/x.ts", "services/README.md"):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path)
                self.assertTrue(scope.native_required(self.base, self.commit(), "merge_group"))

    def test_report_verifier_with_native_change_requires_native(self):
        self.write("services/report-check/api/v1/verify.ts")
        self.write("Sources/New.swift")
        head = self.commit()
        for event in ("merge_group", "push"):
            self.assertTrue(scope.native_required(self.base, head, event))

    def test_report_verifier_moved_into_native_requires_native(self):
        self.write("services/report-check/api/v1/verify.ts")
        middle = self.commit()
        Path("services/report-check/api/v1/verify.ts").rename("Sources/verify.ts")
        self.assertTrue(scope.native_required(middle, self.commit(), "merge_group"))

    def test_mixed_documentation_and_native(self):
        self.write("docs/updating.md")
        self.write("Sources/New.swift")
        head = self.commit()
        for event in ("merge_group", "push"):
            self.assertTrue(scope.native_required(self.base, head, event))
        self.assertFalse(scope.native_required(self.base, head, "pull_request"))

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
        # A main rewrite also removes native code; a pull request leaves that to the queue.
        self.assertFalse(scope.native_required(before, after, "pull_request"))
        self.assertTrue(scope.native_required(before, after, "push"))

    def test_manual_and_unknown_events_require_native(self):
        self.write("docs/updating.md")
        head = self.commit()
        for event in ("workflow_dispatch", "schedule", "", "unknown"):
            self.assertTrue(scope.native_required(self.base, head, event))

    def test_native_deletion(self):
        Path("Sources/App.swift").unlink()
        self.assertTrue(scope.native_required(self.base, self.commit(), "merge_group"))

    def test_native_renamed_to_release_note(self):
        Path("docs/releases").mkdir()
        Path("Sources/App.swift").rename("docs/releases/moved.md")
        self.assertTrue(scope.native_required(self.base, self.commit(), "merge_group"))

    def test_release_note_deletion(self):
        Path("docs/distribution.md").unlink()
        self.assertFalse(scope.native_required(self.base, self.commit(), "merge_group"))

    def test_documentation_move_to_native(self):
        Path("docs/distribution.md").rename("Sources/Instructions.md")
        self.assertTrue(scope.native_required(self.base, self.commit(), "merge_group"))

    def test_documentation_rename_with_spaces_and_newline(self):
        Path("docs/distribution.md").rename("docs/renamed note\nsecond line.md")
        self.assertFalse(scope.native_required(self.base, self.commit(), "merge_group"))

    def test_empty_diff(self):
        for event in ("merge_group", "push"):
            self.assertTrue(scope.native_required(self.base, self.base, event))
        self.assertFalse(scope.native_required(self.base, self.base, "pull_request"))

    def test_missing_or_invalid_history(self):
        for base in ("", "--output=bad", "0" * 40):
            with self.subTest(base=base):
                for event in ("merge_group", "push"):
                    self.assertTrue(scope.native_required(base, self.base, event))
                    self.assertTrue(scope.native_required(self.base, base, event))
                self.assertFalse(scope.native_required(base, self.base, "pull_request"))


class QueueEvidenceTests(unittest.TestCase):
    head = "a" * 40
    repository = "example/workbench"

    def run_record(self, **changes):
        return dict({"id": 123, "head_sha": self.head, "event": "merge_group",
                     "path": ".github/workflows/ci.yml", "status": "completed",
                     "conclusion": "success", "repository": {"full_name": self.repository},
                     "head_branch": "gh-readonly-queue/main/pr-1-abc"}, **changes)

    def verify(self, payload):
        response = subprocess.CompletedProcess([], 0, json.dumps(payload), "")
        with patch.object(scope.subprocess, "run", return_value=response) as call:
            result = scope.verified_queue_run(self.head, self.repository)
            self.assertEqual(call.call_args.args[0], ["gh", "api",
                f"repos/{self.repository}/actions/workflows/ci.yml/runs"
                f"?event=merge_group&head_sha={self.head}&per_page=100"])
            self.assertEqual(call.call_args.kwargs["timeout"], 15)
            return result

    def test_exact_successful_queue_run(self):
        self.assertEqual(self.verify({"workflow_runs": [self.run_record()]}), 123)
        self.assertEqual(self.verify({"workflow_runs": [self.run_record(
            path=".github/workflows/ci.yml@refs/heads/main")]}), 123)

    def test_wrong_or_incomplete_evidence(self):
        for changes in ({"head_sha": "b" * 40}, {"event": "pull_request"},
                        {"path": ".github/workflows/other.yml"},
                        {"repository": {"full_name": "other/workbench"}},
                        {"repository": None}, {"repository": {"full_name": None}},
                        {"repository": {"full_name": 123}}, {"path": None}, {"head_branch": "gh-readonly-queue/other/pr-1"},
                        {"status": "in_progress"}, {"conclusion": "failure"},
                        {"conclusion": "cancelled"}, {"conclusion": "skipped"},
                        {"conclusion": None}, {"id": None}):
            with self.subTest(changes=changes):
                self.assertIsNone(self.verify({"workflow_runs": [self.run_record(**changes)]}))
        for payload in ({}, [], {"workflow_runs": None}, {"workflow_runs": []},
                        {"workflow_runs": [None, "invalid", {}]}):
            self.assertIsNone(self.verify(payload))

    def test_newer_unsuccessful_run_prevents_reuse(self):
        old = self.run_record()
        for status, conclusion in (("completed", "failure"), ("queued", None),
                                   ("completed", "cancelled")):
            new = self.run_record(id=124, status=status, conclusion=conclusion)
            for runs in ([old, new], [new, old]):
                self.assertIsNone(self.verify({"workflow_runs": runs}))

    def test_api_failures_fall_back(self):
        for error in (FileNotFoundError(), subprocess.CalledProcessError(1, "gh"),
                      subprocess.TimeoutExpired("gh", 15)):
            with patch.object(scope.subprocess, "run", side_effect=error):
                self.assertIsNone(scope.verified_queue_run(self.head, self.repository))
        with patch.object(scope.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 0, "not json", "")):
            self.assertIsNone(scope.verified_queue_run(self.head, self.repository))

    def test_invalid_identity_never_calls_api(self):
        with patch.object(scope.subprocess, "run") as call:
            for head, repo in (("", self.repository), ("--bad", self.repository),
                               (self.head, ""), (self.head, "owner/repo?redirect=bad")):
                self.assertIsNone(scope.verified_queue_run(head, repo))
            call.assert_not_called()


class GateTests(unittest.TestCase):
    """Execute the actual aggregate job's shell with synthetic GitHub outcomes."""

    def gate(self, required="true", results=None, scope_result="success", site="success",
             report_check="success"):
        job = WORKFLOW.split("  build-and-test:\n", 1)[1]
        script = textwrap.dedent(job.split("        run: |\n", 1)[1])
        env = dict(os.environ, SCOPE_RESULT=scope_result, SITE_RESULT=site,
                   REPORT_CHECK_RESULT=report_check, NATIVE_REQUIRED=required,
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

    def test_report_check_is_required(self):
        for result in ("failure", "cancelled", "skipped", ""):
            self.assertFalse(self.gate(report_check=result))
            self.assertFalse(self.gate("false", ["skipped"] * 5, report_check=result))

    def test_gate_waits_for_report_check(self):
        job = WORKFLOW.split("  build-and-test:\n", 1)[1]
        needs = job.split("needs: [", 1)[1].split("]", 1)[0]
        self.assertIn("report-check", [item.strip() for item in needs.split(",")])
        self.assertIn("REPORT_CHECK_RESULT: ${{ needs.report-check.result }}", job)

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
