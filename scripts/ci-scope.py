#!/usr/bin/env python3
"""Only release-metadata-only PRs may omit the native build. Default to full CI."""
import argparse
import re
import subprocess


def native_required(base, head):
    if not all(re.fullmatch(r"[0-9a-f]{40}", ref or "") for ref in (base, head)):
        return True
    try:
        # Disable rename detection so BOTH paths of a move are checked.
        changed = subprocess.check_output([
            "git", "diff", "--no-renames", "--name-only", "-z",
            f"{base}...{head}", "--",
        ]).split(b"\0")[:-1]
    except subprocess.CalledProcessError:
        return True
    exact = {b"docs/distribution.md", b"site/updates/production.json",
             b"site/updates/production.xml"}
    return not changed or any(
        path not in exact and not re.fullmatch(rb"docs/releases/[^/]+\.md", path)
        for path in changed
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="")
    args = parser.parse_args()
    print("native=" + str(native_required(args.base, args.head)).lower())
