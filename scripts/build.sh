#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
if [ "${1:-}" = "--preview" ]; then
    shift
    exec python3 scripts/release/preview.py build "$@"
fi
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/dist"
PACKAGE_DIR="$(mktemp -d "$PROJECT_DIR/.build/package.XXXXXX")"
trap 'rm -rf -- "$PACKAGE_DIR"' EXIT
if xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
    TOOLCHAIN="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
    export VOICE_INTENT_PROTOCOLS="$PROJECT_DIR/scripts/app-intents-protocols.json"
    # A unique output makes Swift re-emit the app's metadata on every package
    # build, including incremental builds; dependency products stay cached.
    export VOICE_INTENT_VALUES="$PACKAGE_DIR/Voice.swiftconstvalues"
fi
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"
APP_DIR="$PACKAGE_DIR/Workbench.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/LocalVoice" "$APP_DIR/Contents/MacOS/Workbench"
cp "$BIN_DIR/WorkbenchBrowserHost" "$APP_DIR/Contents/MacOS/WorkbenchBrowserHost"
ditto "$PROJECT_DIR/BrowserExtension" "$APP_DIR/Contents/Resources/BrowserExtension"
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    ditto "$bundle" "$APP_DIR/Contents/Resources/$(basename "$bundle")"
done
cp "$PROJECT_DIR/scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ ! -f "$PROJECT_DIR/scripts/AppIcon.icns" ]; then
    swift "$PROJECT_DIR/scripts/icon.swift" "$PACKAGE_DIR/AppIcon.iconset"
    iconutil -c icns "$PACKAGE_DIR/AppIcon.iconset" -o "$PROJECT_DIR/scripts/AppIcon.icns"
fi
cp "$PROJECT_DIR/scripts/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
ditto "$PROJECT_DIR/Resources/SceneBackdrops" "$APP_DIR/Contents/Resources/SceneBackdrops"
ditto "$PROJECT_DIR/Resources/AmbientScenes" "$APP_DIR/Contents/Resources/AmbientScenes"
ditto "$PROJECT_DIR/Resources/PersonaPortraits" "$APP_DIR/Contents/Resources/PersonaPortraits"
bash "$PROJECT_DIR/scripts/app-intents.sh" "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$PACKAGE_DIR/Workbench.zip"
mv "$PACKAGE_DIR/Workbench.zip" "$PROJECT_DIR/dist/Workbench.zip"
echo "Built: $PROJECT_DIR/dist/Workbench.zip"
