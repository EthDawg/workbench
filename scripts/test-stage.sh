#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/stage-module-cache
# Keep the framework-free legacy runner, but build its shared stores as actual
# modules so integration tests exercise the same public boundaries as the app.
STAGE_MODULES="$(pwd)/.build/stage-test-modules"
mkdir -p "$STAGE_MODULES"
for module in PhotoHandoffKit SceneSyncKit VoiceAppearance; do
  swiftc -swift-version 5 -parse-as-library -emit-library -emit-module -module-name "$module" \
    -module-cache-path .build/stage-module-cache Sources/"$module"/*.swift \
    -emit-module-path "$STAGE_MODULES/$module.swiftmodule" -o "$STAGE_MODULES/lib$module.dylib"
done
swiftc -swift-version 5 -module-name WorkbenchStageTests -module-cache-path .build/stage-module-cache \
  -I "$STAGE_MODULES" -L "$STAGE_MODULES" -lPhotoHandoffKit -lSceneSyncKit -lVoiceAppearance \
  -Xlinker -rpath -Xlinker "$STAGE_MODULES" -framework Carbon \
  Sources/StageKit/*.swift Tests/StageKitLegacy/*.swift -o .build/WorkbenchStageTests
WORKBENCH_TEST_LOG="$(mktemp)"
trap 'rm -f -- "$WORKBENCH_TEST_LOG"' EXIT
.build/WorkbenchStageTests "$@" | tee "$WORKBENCH_TEST_LOG"
/usr/bin/grep -Eq '^[0-9]+ tests · [0-9]+ assertions · 0 failures$' "$WORKBENCH_TEST_LOG"
