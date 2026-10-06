#!/bin/bash
# Runs one probe mode under a log stream and counts AXCommon faults from the probe process.
set -u
S=$(cd "$(dirname "$0")" && pwd)
BIN="$S/axprobe"
MODE="$1"
OUT="$S/stream-$MODE.txt"
log stream --style compact --predicate 'subsystem == "com.apple.Accessibility" AND process == "axprobe"' > "$OUT" 2>&1 &
LOGPID=$!
sleep 2.5
"$BIN" "$MODE" > "$S/out-$MODE.txt" 2>&1
sleep 2
kill $LOGPID 2>/dev/null; wait $LOGPID 2>/dev/null
FAULTS=$(grep -c "unsafeForcedSync" "$OUT")
printf '%-24s faults=%s  %s\n' "$MODE" "$FAULTS" "$(tail -1 "$S/out-$MODE.txt")"
