#!/bin/bash
# Purpose: verify a signed scratch Workbench Preview build (bash scripts/build.sh --preview,
# unpacked anywhere) before anyone installs it, by running the packaged binary's own
# --check-* modes while the unified log is captured for that process.
#
# Usage: bash scripts/verify-preview.sh "<path to Workbench Preview.app>" <new output dir>
#
# The output directory must be new or empty: every receipt is written fresh, and a receipt
# that cannot be written fails the run. Before anything runs, the bundle must pass the
# release tooling's own Preview validation (scripts/release/preview.py validate_bundle: the
# exact Preview identifier, executable and channel, absence of the retired Read Service, a strict deep
# codesign verification and a Developer ID signature), carry its version, build, source
# revision and clean-source flag (retained in <output dir>/build.json), and the executable
# it launches must live inside that bundle. A Stable bundle, an ad-hoc build, a tampered
# bundle or one without that metadata stops the script before any mode runs.
#
# Output: one row per check mode in <output dir>/summary.txt with four columns:
#   exit     the mode's own exit code (0 is a pass)
#   axsync   Accessibility "unsafeForcedSync called from Swift Concurrent context" faults
#   siri     Siri AFLocalization voice-descriptor errors
#   runtime  AppKit and SwiftUI runtime-issue faults (invalid geometry, publishing changes,
#            accessing State outside a view)
# A count is a number only when the log query itself succeeded; a failed query prints
# "capture-failed" in every count column, keeps the query's stderr beside the mode's output,
# and fails the script, so unavailable evidence is never read as a clean pass. The script
# exits non-zero when any mode failed, any capture failed, or any receipt is missing.
# Each mode's stdout, stderr and matching log lines are kept beside it in <output dir>.
# The log window opens at the mode's start in local time (log show reads a zone-less date as
# local time) and is filtered to the mode's own process id, so an installed edition running at
# the same time is not counted. VERIFY_PREVIEW_SETTLE (seconds, default 2) is the pause that
# lets the log catch up after each mode; the focused test sets it to 0.
#
# MODES lists the check modes the binary has on main. When a PR adds a mode, add it here
# once that PR is merged; a mode the binary does not know prints exit 1 and no log counts.
# Read is retired (#284, #295); preservation and inactive admission are covered
# by --check-read-retirement, without loading a TTS provider or voice catalogue.
#
# It never installs or replaces an app, needs no microphone or screen access, and never
# reads or writes the installed editions' saved data or preferences. It opens no visible or
# interactive window; a check mode may host an invisible, non-interactive view (the
# refinement checks create an invisible Models window). This is source evidence from the
# packaged binary, not installed native acceptance (docs/updating.md).
# See docs/release-lead.md, section 6.
set -u
APP="$1"; OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
SETTLE="${VERIFY_PREVIEW_SETTLE:-2}"
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
  echo "refused: output directory $OUT exists and is not empty; give a new one" >&2; exit 2
fi
mkdir -p "$OUT" || { echo "refused: cannot create $OUT" >&2; exit 2; }
# Reuse the release tooling's Preview validation before launching anything, and keep the
# bundle's identity with the receipts.
python3 - "$APP" "$HERE/release/preview.py" "$OUT/build.json" <<'PY' || { echo "bundle validation failed; nothing was run" >&2; exit 2; }
import importlib.util, json, pathlib, plistlib, re, sys
app = pathlib.Path(sys.argv[1]).resolve()
sys.path.insert(0, str(pathlib.Path(sys.argv[2]).resolve().parent))  # preview.py imports its siblings
spec = importlib.util.spec_from_file_location("preview", sys.argv[2])
preview = importlib.util.module_from_spec(spec); spec.loader.exec_module(preview)
config = preview.configuration(production=False)
try:
    signature = preview.validate_bundle(app, config)
except Exception as error:
    print(f"refused: {error}"); sys.exit(1)
executable = (app / "Contents/MacOS" / config["executable"]).resolve()
if app not in executable.parents or not executable.is_file():
    print("refused: the executable is not inside the bundle"); sys.exit(1)
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
version, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
revision, dirty = info.get("WorkbenchSourceRevision"), info.get("WorkbenchSourceDirty")
if not (isinstance(version, str) and version and isinstance(build, str) and re.fullmatch(r"\d{14}", build)
        and isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision) and isinstance(dirty, bool)):
    print("refused: the bundle lacks its version, build, source revision or clean-source flag"); sys.exit(1)
authority = next((line.strip() for line in signature.splitlines() if "Authority=Developer ID Application" in line), "")
receipt = {"identifier": config["identifier"], "executable": str(executable), "version": version, "build": build,
           "source_revision": revision, "source_dirty": dirty, "authority": authority}
pathlib.Path(sys.argv[3]).write_text(json.dumps(receipt, indent=2) + "\n")
print(f"validated: {config['identifier']} {version} {build} {revision[:12]} dirty={str(dirty).lower()} {authority}")
PY
[ -s "$OUT/build.json" ] || { echo "refused: build.json was not written" >&2; exit 2; }
BIN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["executable"])' "$OUT/build.json")"
MODES=(--check-core --check-read-retirement --check-live-dictation-delivery --check-insertion-boundary --check-floating-toolbar --check-refinement --check-readback --check-feedback)
PRED='(subsystem == "com.apple.Accessibility" AND eventMessage CONTAINS "unsafeForcedSync") OR (subsystem == "com.apple.siri" AND eventMessage CONTAINS "AFLocalization") OR (subsystem == "com.apple.runtime-issues")'
failed=0
write_row() { printf "%-34s %6s %15s %15s %15s\n" "$@" >> "$OUT/summary.txt" || { echo "cannot write $OUT/summary.txt" >&2; exit 2; }; printf "%-34s %6s %15s %15s %15s\n" "$@"; }
: > "$OUT/summary.txt" || { echo "cannot write $OUT/summary.txt" >&2; exit 2; }
write_row mode exit axsync siri runtime
for m in "${MODES[@]}"; do
  name=${m#--}
  start=$(date +"%Y-%m-%d %H:%M:%S")
  "$BIN" $m > "$OUT/$name.out" 2> "$OUT/$name.err" & pid=$!
  wait "$pid"; code=$?
  [ "$code" -eq 0 ] || failed=1
  sleep "$SETTLE"
  if log show --start "$start" --style compact --predicate "processID == $pid AND ($PRED)" > "$OUT/$name.log" 2> "$OUT/$name.log.err"; then
    ax=$(grep -c "unsafeForcedSync" "$OUT/$name.log"); siri=$(grep -c "AFLocalization" "$OUT/$name.log"); rt=$(grep -c "runtime-issues" "$OUT/$name.log")
  else
    ax="capture-failed"; siri="capture-failed"; rt="capture-failed"; failed=1
    echo "log query failed for $m; see $OUT/$name.log.err" >&2
  fi
  write_row "$m" "$code" "$ax" "$siri" "$rt"
done
rows=$(wc -l < "$OUT/summary.txt" | tr -d ' ')
[ "$rows" -eq $(( ${#MODES[@]} + 1 )) ] || { echo "VERIFY FAILED: summary has $rows rows, expected $(( ${#MODES[@]} + 1 ))" >&2; exit 1; }
echo; echo "OK lines:"; grep -hE "_OK|passed" "$OUT"/*.out 2>/dev/null | sed 's/^/  /' | head -60
if [ "$failed" -ne 0 ]; then echo "VERIFY FAILED: a mode exited non-zero or a log capture failed; see $OUT" >&2; exit 1; fi
echo "VERIFY OK: every mode exited 0, every log capture succeeded, receipts in $OUT"
