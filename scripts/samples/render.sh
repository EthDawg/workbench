#!/bin/bash
# Rebuild the sample deck that ships in Resources/Samples after editing deck.html, deck.css,
# manifest.json, provenance.json or anything in screens/.
#   bash scripts/samples/render.sh             rebuild from the committed screens
#   bash scripts/samples/render.sh --screens DESKTOP SAMPLE
#       first refresh screens/ from two surface-gallery runs:
#       DESKTOP: WORKBENCH_DESKTOP_GALLERY_ONLY=1 .build/debug/LocalVoice --render-surfaces DESKTOP
#       SAMPLE:  WORKBENCH_SAMPLE_SCREENS_GALLERY_ONLY=1 .build/debug/LocalVoice --render-surfaces SAMPLE
#       (the sample run draws a four-screen Snap & Talk walkthrough and Dictate with automatic paste)
# Headless Chrome draws each 1920×1080 slide at twice the pixel density, sips makes the
# 1600×900 JPEGs, and Chrome prints the same page as a six-page 16:9 PDF with real text.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
OUT="$(cd ../.. && pwd)/Resources/Samples"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PDF_NAME="Workbench sample deck.pdf"
SLIDES=6

if [[ "${1:-}" == "--screens" ]]; then
  DESKTOP="${2:?usage: render.sh --screens DESKTOP_GALLERY SAMPLE_GALLERY}"; SAMPLE="${3:?usage: render.sh --screens DESKTOP_GALLERY SAMPLE_GALLERY}"
  for pair in "dictate:$SAMPLE/sample-dictate-light" "meetings:$DESKTOP/page-meeting-state-completed-light" \
              "snap-and-talk:$SAMPLE/sample-snap-and-talk-light" "draw:$DESKTOP/page-annotate-default-light" \
              "history:$DESKTOP/page-history-default-light"; do
    src="${pair#*:}.png"
    [[ -f "$src" ]] || { echo "missing $src: run the surface gallery first" >&2; exit 1; }
    sips -Z 1600 "$src" --out "screens/${pair%%:*}.png" >/dev/null
  done
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run headless Chrome and give up after 30 seconds. (A throwaway --user-data-dir makes Chrome
# start its updater and linger after writing the file, so leave the profile alone.)
chrome() {
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --disable-component-update --disable-background-networking "$@" >"$WORK/chrome.log" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= 300 )); then kill -9 "$pid" 2>/dev/null; echo "Chrome timed out: $*" >&2; return 1; fi
    sleep 0.1; waited=$((waited + 1))
  done
  wait "$pid"
}

size() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{printf "%s×%s", w, h}'; }

python3 -m json.tool manifest.json >/dev/null
python3 -m json.tool provenance.json >/dev/null

# Pass 1: the walls and window shadows, which stay soft as JPEGs instead of bloating the PDF.
mkdir -p backdrops
for name in wide low cover; do
  chrome --window-size=1920,1080 --force-device-scale-factor=1 --screenshot="$WORK/$name.png" "file://$HERE/backdrop.html#$name"
  sips -s format jpeg -s formatOptions 90 "$WORK/$name.png" --out "backdrops/$name.jpg" >/dev/null
  echo "scripts/samples/backdrops/$name.jpg $(size "backdrops/$name.jpg")"
done

# Pass 2: the slides and the PDF.
mkdir -p "$OUT"
rm -f "$OUT"/slide-*.jpg "$OUT/$PDF_NAME" "$OUT/manifest.json" "$OUT/provenance.json"

for n in $(seq 1 "$SLIDES"); do
  png="$WORK/slide-$n.png"
  chrome --window-size=1920,1080 --force-device-scale-factor=2 --screenshot="$png" "file://$HERE/deck.html#s$n"
  sips -Z 1600 "$png" >/dev/null
  sips -s format jpeg -s formatOptions 82 "$png" --out "$OUT/slide-$n.jpg" >/dev/null
  echo "Resources/Samples/slide-$n.jpg $(size "$OUT/slide-$n.jpg")"
done

chrome --no-pdf-header-footer --print-to-pdf="$OUT/$PDF_NAME" "file://$HERE/deck.html"
pages=$(python3 - "$OUT/$PDF_NAME" <<'PY'
import re, sys
data = open(sys.argv[1], "rb").read()
print(len(re.findall(rb"/Type\s*/Page(?![s\w])", data)))
PY
)
box=$(python3 - "$OUT/$PDF_NAME" <<'PY'
import re, sys
m = re.search(rb"/MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)", open(sys.argv[1], "rb").read())
print(f"{float(m[3]):g}×{float(m[4]):g} pt" if m else "unknown size")
PY
)
echo "Resources/Samples/$PDF_NAME $pages pages, $box"
[[ "$pages" == "$SLIDES" ]] || { echo "expected $SLIDES PDF pages, got $pages" >&2; exit 1; }

cp manifest.json provenance.json "$OUT/"
echo "Resources/Samples/manifest.json, provenance.json"
du -sh "$OUT" | awk '{print "Resources/Samples total " $1}'
