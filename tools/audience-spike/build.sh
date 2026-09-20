#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
ARCH="$(uname -m)"
swiftc -swift-version 5 -warnings-as-errors -target "$ARCH-apple-macos15.2" -module-cache-path .build/module-cache \
  -parse-as-library AudienceSessionState.swift StateTests.swift -o .build/StateTests
.build/StateTests
APP=".build/Workbench Audience Spike.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -warnings-as-errors -target "$ARCH-apple-macos15.2" -module-cache-path .build/module-cache \
  -parse-as-library AudienceSessionState.swift AudienceSpike.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CoreImage -framework CoreMedia \
  -o "$APP/Contents/MacOS/WorkbenchAudienceSpike"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ethdawg.workbench.audience-spike</string>
<key>CFBundleName</key><string>Workbench Audience Spike</string>
<key>CFBundleDisplayName</key><string>Workbench Audience Spike</string>
<key>CFBundleExecutable</key><string>WorkbenchAudienceSpike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>LSMinimumSystemVersion</key><string>15.2</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Compiled only. To run explicitly: open "%s"\n' "$(pwd)/$APP"
