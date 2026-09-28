#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d /private/tmp/workbench-snap-check.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$PROJECT_DIR" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
project, checks = map(Path, sys.argv[1:])
sys.dont_write_bytecode = True
sys.path.insert(0, str(project / "scripts"))
from swift_extract import SwiftFile
source = SwiftFile(project / "Sources/LocalVoice/ReadbackModel.swift")
types = source.extract(["ReadbackSectionStatus", "ReadbackSection", "ReadbackManifest", "ReadbackError", "ReadbackHandoffBrief"])
store = source.extract(["ReadbackStore"])
(checks / "ReadbackStore.swift").write_text("import Foundation\n" + types + "\n" + store)
PY
swiftc -swift-version 5 -module-cache-path "$CHECK_DIR/ModuleCache" \
  "$PROJECT_DIR/Sources/LocalVoice/SnapStore.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/SnapAnalysis.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/SnapScreenshots.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/SnapScreenshotLocation.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/SnapRendering.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/SnapOrganization.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/SnapHandoff.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/SnapCapture.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/SnapModel.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/NoticeLifetime.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/SnapReadback.swift" \
  "$PROJECT_DIR/Sources/LocalVoice/ReadbackResources.swift" \
  "$CHECK_DIR/ReadbackStore.swift" \
  "$PROJECT_DIR/Tests/SnapChecks/AppShellStubs.swift" \
  "$PROJECT_DIR/Tests/SnapChecks/main.swift" -o "$CHECK_DIR/snap-checks"
"$CHECK_DIR/snap-checks"
