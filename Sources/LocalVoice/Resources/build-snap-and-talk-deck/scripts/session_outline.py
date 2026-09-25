#!/usr/bin/env python3
"""Usage: python3 session_outline.py SESSION NEW_OUTLINE.json"""
import json
import sys
from session_io import captures, new_output


def main(session_dir, out_path):
    manifest, slides, excluded = captures(session_dir)
    outline = {
        "title": {"lead": manifest.get("title", ""), "rest": ""},
        "cover": False, "dividers": False, "closing": False,
        "chapters": [{"name": "Walkthrough", "slides": slides}],
        "excluded": excluded,
    }
    with new_output(out_path) as output:
        output.write(json.dumps(outline, indent=2, ensure_ascii=False).encode("utf-8"))
    print(f"{len(slides)} captures kept, {len(excluded)} excluded -> {out_path}")
    for entry in excluded:
        print("Excluded:", entry["directory"], "-", entry["reason"])


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
