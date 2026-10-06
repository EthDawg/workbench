#!/bin/bash
# Purpose: verify a signed scratch Workbench Preview build (bash scripts/build.sh --preview,
# unpacked anywhere) before anyone installs it, by running the packaged binary's own
# --check-* modes while the unified log is captured for that process.
#
# Usage: bash scripts/verify-preview.sh "<path to Workbench Preview.app>" <new output dir>
#
# Output: the build's version, build number and source revision, its signing authority, then
# one row per check mode in <output dir>/summary.txt with four columns:
#   exit     the mode's own exit code (0 is a pass)
#   axsync   Accessibility "unsafeForcedSync called from Swift Concurrent context" faults
#   siri     Siri AFLocalization voice-descriptor errors
#   runtime  AppKit and SwiftUI runtime-issue faults (invalid geometry, publishing changes,
#            accessing State outside a view)
# Each mode's stdout, stderr and matching log lines are kept beside it in <output dir>.
# The log window opens at the mode's start in local time (log show reads a zone-less date as
# local time) and is filtered to the mode's own process id, so an installed edition running at
# the same time is not counted.
#
# MODES lists the check modes the binary has on main. When a PR adds a mode (for example
# --check-insertion-boundary from PR #265), add it here once that PR is merged; a mode the
# binary does not know prints exit 1 and no log counts.
#
# It never installs or replaces an app, never opens the app's UI, needs no microphone or
# screen access, and never reads or writes the installed editions' saved data or preferences.
# See docs/release-lead.md, section 6.
set -u
APP="$1"; OUT="$2"; mkdir -p "$OUT"
BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
echo "binary: $BIN"
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' -c 'Print CFBundleVersion' -c 'Print WorkbenchSourceRevision' "$APP/Contents/Info.plist" | tr '\n' ' '; echo
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID|Identifier=" | head -2
MODES=(--check-core --check-reading --check-reading-render --check-reading-service --check-live-dictation-delivery --check-floating-toolbar --check-refinement --check-readback --check-feedback)
PRED='(subsystem == "com.apple.Accessibility" AND eventMessage CONTAINS "unsafeForcedSync") OR (subsystem == "com.apple.siri" AND eventMessage CONTAINS "AFLocalization") OR (subsystem == "com.apple.runtime-issues")'
printf "%-34s %6s %8s %6s %8s\n" mode exit axsync siri runtime | tee "$OUT/summary.txt"
for m in "${MODES[@]}"; do
  name=${m#--}
  start=$(date +"%Y-%m-%d %H:%M:%S")
  "$BIN" $m > "$OUT/$name.out" 2> "$OUT/$name.err" & pid=$!
  wait "$pid"; code=$?
  sleep 2
  log show --start "$start" --style compact --predicate "processID == $pid AND ($PRED)" 2>/dev/null > "$OUT/$name.log" || true
  ax=$(grep -c "unsafeForcedSync" "$OUT/$name.log"); siri=$(grep -c "AFLocalization" "$OUT/$name.log"); rt=$(grep -c "runtime-issues" "$OUT/$name.log")
  printf "%-34s %6s %8s %6s %8s\n" "$m" "$code" "$ax" "$siri" "$rt" | tee -a "$OUT/summary.txt"
done
echo; echo "OK lines:"; grep -hE "_OK|passed" "$OUT"/*.out | sed 's/^/  /' | head -60
