#!/bin/bash
# The regression suite, in four phases that share nothing but the source:
#
#   harnesses      the surface registry, the Python harnesses and the browser extension's tests
#   package-tests  swift test
#   checks         the release build, every LocalVoice --check-* and scripts/test-snap.sh
#   stage          scripts/test-stage.sh --ci, StageKit's own runner
#
# With no argument every phase runs in that order, as one local command. CI gives
# each phase its own runner, so a pull request finishes in the time of the longest
# phase rather than the sum of all four.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

PHASES=(harnesses package-tests checks stage)
if [ "$#" -eq 0 ]; then
  RUN=("${PHASES[@]}")
else
  RUN=("$@")
  for phase in "${RUN[@]}"; do
    case " ${PHASES[*]} " in
      *" $phase "*) ;;
      *) echo "Usage: scripts/test.sh [${PHASES[*]}]  (no phase runs every phase)" >&2; exit 2 ;;
    esac
  done
fi

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
# New folders for checks that keep their stores and a receipt in one.
CHECK_FOLDERS="$(mktemp -d)"
trap 'rm -f -- "$SUITES_BEFORE"; rm -rf -- "$CHECK_FOLDERS"' EXIT
suite_plists > "$SUITES_BEFORE"

harnesses() {
  python3 scripts/check-surfaces.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-check-surfaces.py
  python3 scripts/check-accessibility-bridge.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-accessibility-bridge.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-swift-extract.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/test_release.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/test_preview.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/test_updates.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/test_adoption.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-photo-cloud.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-clean-draft.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-capture-persistence.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-capture-continuity.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-live-dictation.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-voice-preferences.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-remember-correction.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-reading-playback.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-read-selection-service.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-readback-resources.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-speko-catalog.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-library-recall.py
  PYTHONDONTWRITEBYTECODE=1 python3 BrowserExtension/tests/package_test.py
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-library-recall.py --import-review
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-library-recall.py --image-reuse
  node --test BrowserExtension/tests/*.test.js
}

package_tests() {
  swift test --disable-sandbox
}

checks() {
  swift build -c release --disable-sandbox
  BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
  "$BIN_DIR/LocalVoice" --check-core
  "$BIN_DIR/LocalVoice" --check-reading-render
  "$BIN_DIR/LocalVoice" --check-neural-voice
  "$BIN_DIR/LocalVoice" --check-shortcut-migration
  "$BIN_DIR/LocalVoice" --check-readback
  "$BIN_DIR/LocalVoice" --check-snap-capture
  "$BIN_DIR/LocalVoice" --check-presenter
  "$BIN_DIR/LocalVoice" --check-providers
  "$BIN_DIR/LocalVoice" --check-refinement
  "$BIN_DIR/LocalVoice" --check-transcript-handoff
  "$BIN_DIR/LocalVoice" --check-readback-pack
  "$BIN_DIR/LocalVoice" --check-capture-preview
  "$BIN_DIR/LocalVoice" --check-image-workspace
  "$BIN_DIR/LocalVoice" --check-history-library
  # The History journey from #137 at model level: one search, a shared selection, Hand off, a restart.
  "$BIN_DIR/LocalVoice" --check-history-journey "$CHECK_FOLDERS/history-journey"
  "$BIN_DIR/LocalVoice" --check-handoff-jobs
  "$BIN_DIR/LocalVoice" --check-subscription-cli
  "$BIN_DIR/LocalVoice" --check-meetings
  bash scripts/test-snap.sh
}

stage() {
  bash scripts/test-stage.sh --ci
}

for phase in "${RUN[@]}"; do
  echo "== scripts/test.sh: $phase"
  "${phase//-/_}"
done

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
