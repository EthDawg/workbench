#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/test_release.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/test_preview.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-photo-cloud.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-clean-draft.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-capture-persistence.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-remember-correction.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-reading-playback.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-read-selection-service.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-speko-catalog.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-library-recall.py
PYTHONDONTWRITEBYTECODE=1 python3 BrowserExtension/tests/package_test.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-library-recall.py --import-review
swift test --disable-sandbox
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
"$BIN_DIR/LocalVoice" --check-core
"$BIN_DIR/LocalVoice" --check-presenter
node --test BrowserExtension/tests/*.test.js

"$BIN_DIR/LocalVoice" --check-providers
"$BIN_DIR/LocalVoice" --check-refinement
bash scripts/test-stage.sh --ci
