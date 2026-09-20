#!/usr/bin/env python3
"""Static contract checks for the native selected-text Service declaration."""
from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[1]
info = plistlib.loads((ROOT / "scripts/Info.plist").read_bytes())
services = [item for item in info.get("NSServices", []) if item.get("NSMessage") == "readSelection"]
assert len(services) == 1, "expected exactly one readSelection Service"
service = services[0]
assert service.get("NSMenuItem", {}).get("default") == "Read Selection in Workbench"
assert service.get("NSPortName") == "Workbench"
assert service.get("NSSendTypes") == ["public.utf8-plain-text"]
assert "NSReturnTypes" not in service, "the Service must not replace text in the requesting app"
assert service.get("NSRequiredContext") == {}
assert service.get("NSRestricted") is False
assert "selected text" in service.get("NSServiceDescription", "").lower()
print("READ_SELECTION_METADATA_OK: 8 checks passed")
