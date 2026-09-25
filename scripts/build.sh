#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
if [ "${1:-}" = "--preview" ]; then
    shift
    exec python3 scripts/release/preview.py build "$@"
fi
if [ "${1:-}" != "--component-package" ]; then
    exec python3 scripts/release/preview.py build --ad-hoc "$@"
fi
shift
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/dist" "$PROJECT_DIR/.build/component"
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
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
SPARKLE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE" ] || { echo "Sparkle framework missing after dependency resolution" >&2; exit 1; }
ditto "$SPARKLE" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
cp "$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP_DIR/Contents/Resources/Sparkle-LICENSE.txt"
cp "$BIN_DIR/LocalVoice" "$APP_DIR/Contents/MacOS/Workbench"
cp "$BIN_DIR/WorkbenchBrowserHost" "$APP_DIR/Contents/MacOS/WorkbenchBrowserHost"
ditto "$PROJECT_DIR/BrowserExtension" "$APP_DIR/Contents/Resources/BrowserExtension"
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    ditto "$bundle" "$APP_DIR/Contents/Resources/$(basename "$bundle")"
done
cp "$PROJECT_DIR/scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
python3 scripts/release/build_info.py "$APP_DIR/Contents/Info.plist" production
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
"$APP_DIR/Contents/MacOS/Workbench" --check-readback-resources
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$PACKAGE_DIR/Workbench.zip"
mv "$PACKAGE_DIR/Workbench.zip" "$PROJECT_DIR/.build/component/Workbench.zip"
echo "Built internal component: $PROJECT_DIR/.build/component/Workbench.zip"
