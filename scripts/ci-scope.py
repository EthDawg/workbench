#!/usr/bin/env python3
"""Skip native CI only for known documentation/site changes. Default to full CI."""
import argparse
import re
import subprocess


def native_required(base, head, event="pull_request"):
    if event not in {"pull_request", "merge_group", "push"}:
        return True
    if not all(re.fullmatch(r"[0-9a-f]{40}", ref or "") for ref in (base, head)):
        return True
    try:
        # Disable rename detection so BOTH paths of a move are checked.
        changed = subprocess.check_output([
            "git", "diff", "--no-renames", "--name-only", "-z",
            f"{base}{'...' if event == 'pull_request' else '..'}{head}", "--",
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
    args = parser.parse_args()
    print("native=" + str(native_required(args.base, args.head, args.event)).lower())
