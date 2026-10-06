#!/usr/bin/env python3
"""Select the native CI jobs: the merge queue and manual runs carry them, a pull request
push runs them only when asked, and main reuses verified successful queue runs."""
import argparse
import json
import os
import re
import subprocess
import sys

NATIVE_LABEL = "ci:native"


def verified_queue_run(head, repository):
    """Return the latest matching successful CI run; uncertainty never skips CI.

    Use the workflow-specific API, not commit messages or a same-named check.
    A bounded lookup can miss evidence, which safely costs another native run.
    Do not filter by success: a newer failed/pending rerun must prevent reuse.
    """
    if not re.fullmatch(r"[0-9a-f]{40}", head or "") or not re.fullmatch(
        r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository or ""
    ):
        return None
    endpoint = (f"repos/{repository}/actions/workflows/ci.yml/runs"
                f"?event=merge_group&head_sha={head}&per_page=100")
    try:
        result = subprocess.run(["gh", "api", endpoint], check=True,
                                capture_output=True, text=True, timeout=15)
        payload = json.loads(result.stdout)
        runs = payload.get("workflow_runs") if isinstance(payload, dict) else None
        if not isinstance(runs, list):
            return None
        matching = [run for run in runs if isinstance(run, dict)
                    and run.get("head_sha") == head
                    and run.get("event") == "merge_group"
                    and isinstance(run.get("path"), str)
                    and run["path"].split("@", 1)[0] == ".github/workflows/ci.yml"
                    and isinstance(run.get("repository"), dict)
                    and isinstance(run["repository"].get("full_name"), str)
                    and run["repository"]["full_name"].lower() == repository.lower()
                    and isinstance(run.get("head_branch"), str)
                    and run["head_branch"].startswith("gh-readonly-queue/main/")
                    and type(run.get("id")) is int and run["id"] > 0]
        latest = max(matching, key=lambda run: run["id"], default={})
        if latest.get("status") == "completed" and latest.get("conclusion") == "success":
            return latest["id"]
    except (OSError, subprocess.SubprocessError, ValueError):
        print("Queue evidence unavailable; classify the push normally.", file=sys.stderr)
    return None


def native_required(base, head, event="pull_request", labels=(), queue_verified=False):
    """Whether the five macOS jobs run for this event.

    pull_request: not by default. The merge queue tests every group with current
    main before it lands, so a push run would test the same code twice on the five
    shared macOS runners. The label ci:native asks for a native run on the PR itself.
    merge_group: native unless the group's complete diff is documentation, site
    content or the report verifier, which the always-run Site and Report check jobs
    validate.
    push: reuse a verified successful queue run for this exact commit; otherwise
    classify the diff, including administrator bypasses and rewrites.
    workflow_dispatch and unknown events: native, always.
    """
    if event == "pull_request":
        return NATIVE_LABEL in {label.strip() for label in labels}
    if event not in {"merge_group", "push"}:
        return True
    if event == "push" and queue_verified:
        return False
    if not all(re.fullmatch(r"[0-9a-f]{40}", ref or "") for ref in (base, head)):
        return True
    try:
        # Disable rename detection so BOTH paths of a move are checked.
        changed = subprocess.check_output([
            "git", "diff", "--no-renames", "--name-only", "-z", f"{base}..{head}", "--",
        ]).split(b"\0")[:-1]
    except subprocess.CalledProcessError:
        return True
    # These paths are documentation or are validated by the always-run Site and
    # Report check jobs. Do not exempt Markdown globally: Resources and
    # BrowserExtension are packaged.
    exact = {b"AGENTS.md", b"README.md", b"CONTRIBUTING.md", b"SECURITY.md",
             b"CODE_OF_CONDUCT.md", b"LICENSE", b"docs/surfaces.json"}
    prefixes = (b"site/", b"services/report-check/")
    return not changed or any(
        path not in exact and not path.startswith(prefixes)
        and not (path.startswith(b"docs/") and path.endswith(b".md"))
        for path in changed
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="")
    parser.add_argument("--event", default="pull_request")
    parser.add_argument("--labels", default="", help="comma-separated pull request labels")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    args = parser.parse_args()
    labels = [label for label in args.labels.split(",") if label.strip()]
    run_id = verified_queue_run(args.head, args.repository) if args.event == "push" else None
    if run_id:
        print(f"Reusing queue CI for {args.head}: https://github.com/{args.repository}/actions/runs/{run_id}",
              file=sys.stderr)
    else:
        print(f"Selecting checks for {args.event}; no queue result reused.", file=sys.stderr)
    print("native=" + str(native_required(args.base, args.head, args.event, labels, bool(run_id))).lower())
