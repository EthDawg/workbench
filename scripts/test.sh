#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
# A settings suite in a test or check is an absolute path in a temporary folder.
# A named suite lands in the real ~/Library/Preferences, even under a temporary
# HOME, so the run notes the UUID-named plists there now and fails at the end if
# it added any (#128).
PREFERENCES="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')/Library/Preferences"
suite_plists() {
  ls -1 "$PREFERENCES" 2>/dev/null \
    | /usr/bin/grep -E '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}.*\.plist$' | LC_ALL=C sort || true
}
SUITES_BEFORE="$(mktemp)"
trap 'rm -f -- "$SUITES_BEFORE"' EXIT
suite_plists > "$SUITES_BEFORE"
python3 scripts/check-surfaces.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-check-surfaces.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-swift-extract.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/test_release.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/test_preview.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/test_updates.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-photo-cloud.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-clean-draft.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-capture-persistence.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-capture-continuity.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-live-dictation.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-remember-correction.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-reading-playback.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-read-selection-service.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-readback-resources.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-speko-catalog.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-library-recall.py
PYTHONDONTWRITEBYTECODE=1 python3 BrowserExtension/tests/package_test.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-library-recall.py --import-review
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-library-recall.py --image-reuse
swift test --disable-sandbox
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
"$BIN_DIR/LocalVoice" --check-core
"$BIN_DIR/LocalVoice" --check-reading-render
"$BIN_DIR/LocalVoice" --check-neural-voice
"$BIN_DIR/LocalVoice" --check-shortcut-migration
"$BIN_DIR/LocalVoice" --check-readback
"$BIN_DIR/LocalVoice" --check-snap-capture
"$BIN_DIR/LocalVoice" --check-presenter
node --test BrowserExtension/tests/*.test.js

"$BIN_DIR/LocalVoice" --check-providers
"$BIN_DIR/LocalVoice" --check-refinement
bash scripts/test-stage.sh --ci

"$BIN_DIR/LocalVoice" --check-transcript-handoff
"$BIN_DIR/LocalVoice" --check-readback-pack
"$BIN_DIR/LocalVoice" --check-capture-preview
"$BIN_DIR/LocalVoice" --check-image-workspace
"$BIN_DIR/LocalVoice" --check-history-library
"$BIN_DIR/LocalVoice" --check-handoff-jobs
"$BIN_DIR/LocalVoice" --check-subscription-cli
"$BIN_DIR/LocalVoice" --check-meetings
bash scripts/test-snap.sh

# cfprefsd writes a suite's plist about 10 s after its process exits.
sleep 20
LEFT_BEHIND="$(suite_plists | LC_ALL=C comm -13 "$SUITES_BEFORE" -)"
if [ -n "$LEFT_BEHIND" ]; then
  echo "This run left $(echo "$LEFT_BEHIND" | wc -l | tr -d ' ') settings suites in $PREFERENCES." >&2
  echo "Give each UserDefaults(suiteName:) an absolute path in a temporary folder (#128):" >&2
  echo "$LEFT_BEHIND" | sed 's/^/  /' >&2
  exit 1
fi
echo "No settings suites left in $PREFERENCES."
