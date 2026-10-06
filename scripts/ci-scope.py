#!/usr/bin/env python3
"""Select the native CI jobs: the merge queue and manual runs carry them, a pull request
push runs them only when asked, and a push of a merge the queue made never repeats them."""
import argparse
import re
import subprocess

NATIVE_LABEL = "ci:native"
QUEUE_MERGE = re.compile(r"\AMerge pull request #\d+ from \S+")


def native_required(base, head, event="pull_request", labels=(), head_message=""):
    """Whether the five macOS jobs run for this event.

    pull_request: not by default. The merge queue tests every group with current
    main before it lands, so a push run would test the same code twice on the five
    shared macOS runners. The label ci:native asks for a native run on the PR itself.
    merge_group: native unless the group's complete diff is documentation or site
    content that the always-run Site job validates.
    push: a merge the queue made (GitHub's "Merge pull request #N from …") was
    validated by that group's run and skips native; any other push to main, such as
    an admin bypass or a rewrite, is classified by its diff like a merge group.
    workflow_dispatch and unknown events: native, always.
    """
    if event == "pull_request":
        return NATIVE_LABEL in {label.strip() for label in labels}
    if event not in {"merge_group", "push"}:
        return True
    if event == "push" and QUEUE_MERGE.match(head_message or ""):
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
    # These paths are documentation or are validated by the always-run Site job.
    # Do not exempt Markdown globally: Resources and BrowserExtension are packaged.
    exact = {b"AGENTS.md", b"README.md", b"CONTRIBUTING.md", b"SECURITY.md",
             b"CODE_OF_CONDUCT.md", b"LICENSE", b"docs/surfaces.json"}
    return not changed or any(
        path not in exact and not path.startswith(b"site/")
        and not (path.startswith(b"docs/") and path.endswith(b".md"))
        for path in changed
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="")
    parser.add_argument("--event", default="pull_request")
    parser.add_argument("--labels", default="", help="comma-separated pull request labels")
    parser.add_argument("--head-message", default="", help="the pushed head commit's message")
    args = parser.parse_args()
    labels = [label for label in args.labels.split(",") if label.strip()]
    print("native=" + str(native_required(args.base, args.head, args.event, labels, args.head_message)).lower())
