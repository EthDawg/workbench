#!/bin/bash
# Re-render the share cards after editing share/*.html or share/card.css.
# Headless Chrome draws each card at 1200×630 points, twice the pixel density.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
for name in workbench team-pack; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1200,630 --force-device-scale-factor=2 \
    --virtual-time-budget=4000 --screenshot="../assets/share/$name.png" "file://$PWD/$name.html" >/dev/null 2>&1
  echo "assets/share/$name.png $(sips -g pixelWidth -g pixelHeight "../assets/share/$name.png" | awk '/pixel/{printf "%s ", $2}')"
done
