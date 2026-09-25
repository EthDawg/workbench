"""Read-only, session-contained inputs shared by the outline and deck helpers."""
import json
from pathlib import Path, PurePosixPath
from PIL import Image


def local_file(root, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError("Invalid relative session path")
    parts = relative.split("/")
    if PurePosixPath(relative).is_absolute() or any(p in ("", ".", "..") for p in parts):
        raise ValueError("Unsafe relative session path")
    current = Path(root).resolve()
    for part in parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("Symbolic links are not session inputs")
    if not current.is_file():
        raise ValueError("Missing session file: " + relative)
    return current


def captures(root):
    manifest = json.loads(local_file(root, "session.json").read_bytes())
    if manifest.get("formatVersion") != 1:
        raise ValueError("Unsupported Snap & Talk session format")
    slides, excluded, seen = [], [], set()
    for sec in manifest["sections"]:
        directory = sec.get("directory", "")
        reason = None
        if sec.get("deletedAt") or directory.startswith("trash/"):
            reason = "Deleted capture"
        elif sec.get("status") != "ready":
            reason = "Capture is not ready: " + str(sec.get("status"))
        if reason:
            excluded.append({"directory": directory, "reason": reason})
            continue
        try:
            identity = sec["id"]
            if identity in seen:
                raise ValueError("Duplicate section identity")
            seen.add(identity)
            if len(directory.split("/")) != 2 or not directory.startswith("items/"):
                raise ValueError("Capture must belong to items/<section>")
            for key in ("screenshot", "transcript"):
                if not sec[key].startswith(directory + "/"):
                    raise ValueError("Media must belong to its own section")
            screenshot = local_file(root, sec["screenshot"])
            narration = local_file(root, sec["transcript"]).read_bytes().decode("utf-8")
            with Image.open(screenshot) as image:
                width, height = image.size
                image.verify()
            flags = [] if abs(width / height - 16 / 9) < .03 else [
                f"{width}x{height}: letterbox the complete capture; do not discard it"]
            slides.append({"section_id": identity, "image": sec["screenshot"],
                           "notes": narration, "headline": "", "takeaways": [], "flags": flags})
        except (KeyError, ValueError, OSError, TypeError) as error:
            excluded.append({"directory": directory, "reason": str(error)})
    return manifest, slides, excluded


def new_output(path):
    """Exclusive creation prevents overwriting sessions, decks or symlink targets."""
    return Path(path).open("xb")
