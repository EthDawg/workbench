# Foundation A1: preparation and live-control ownership

Source: `94813d5453b7242c5dfff7ee70f23ac7b65028d4`, based on the integrated G/H/AX candidate `41a6971e2535af3b06cb32e808315b897128a0ea`. This candidate does not yet include the separate manual-first handoff C slice. These are source, synthetic behavioral and production-view render results, not installed Preview acceptance.

Home now has a static heading, current work first, and compact navigation to Dictate, Meetings, Snap & Talk and Present. Navigation starts nothing. Persona opens the existing Me editor using the unchanged `persona.me.id.v1`/artwork owner; opening it requests no camera. Library owns the existing Saved Prompts picker and complete Copy with truthful clipboard failure. Present and its toolbar no longer expose general prompts. The cancellable insertion owner remains for explicitly admitted frozen targets, but Library never infers one.

Live Persona shape targets now carry the lifecycle generation. The regression ends and restarts a prepared set with the same saved copy IDs, invokes the earlier captured action, and verifies unchanged current copies and saved archive bytes. A current target still works across Hide/Show. Native toolbar buttons consume repeated Return, Space, Enter and Down; fresh keyboard and accessibility activations still dispatch once.

## Checks run

All checks used synthetic stores or fixtures. No installed app, live saved data, permission setting, provider job, network transfer or download was used.

| Command | Result |
| --- | --- |
| `swift build -c release --product LocalVoice --disable-automatic-resolution` | Passed. |
| `.build/release/LocalVoice --check-core` | Passed, including PromptPicker 45, HomeJourney 31 and WorkbenchPage 105 checks. Prompt tests exercise the production Library context/action, exact multiline UTF-8, filters/favourites, Cancel, clipboard refusal and unchanged saved prompt bytes. |
| `swift test --disable-sandbox --filter 'ToolbarCoreTests\|ToolbarKitTests'` | 218 tests executed, 2 opt-in native tests skipped. The new production-button repeat regression and other suites passed. Obsolete Prompts gallery expectations were corrected; final `swift test --disable-sandbox --filter ToolbarGalleryTests` passed all 19 tests. |
| `bash scripts/test-stage.sh --persona-appearance-only` | 15 tests, 274 assertions, zero failures; one optional appearance render skipped. |
| `.build/WorkbenchStageTests --persona-shown-only` | 10 tests, 175 assertions, zero failures; one optional render skipped. |
| `.build/WorkbenchStageTests --profile-camera-only` | 12 tests, 124 assertions, zero failures. Opening profile remains permission-free; explicit capture/cancel/save use injected camera effects. |
| `.build/WorkbenchStageTests --persona-creation-only` | 14 tests, 196 assertions, zero failures; one optional render skipped. Existing Me reference/reopen and source-preservation coverage retained. |
| `.build/WorkbenchStageTests --persona-workspace-only` | 6 tests, 249 assertions, zero failures. |
| `python3 scripts/check-surfaces.py` | 520 entries, passed. Existing scene-choice door is now scanned alongside the moved Me door. |
| `python3 scripts/test-check-surfaces.py` | 58 tests, passed. |
| `WORKBENCH_FOUNDATION_OWNERSHIP_GALLERY_ONLY=1 .build/release/LocalVoice --render-surfaces .build/foundation-ownership-gallery` | 88 light/dark renders, 144 catalogue entries, zero flags. Existing isolated gallery processes only. |

Detailed logs remain local as `.build/foundation-ownership-*.log`. The A1 gallery reuses production Home/Library/Persona/Present views, the existing profile sheet and prompt picker. Minimum-window views, current-work priority, long labels, light/dark and the existing 1.35× Home text stress fixture were inspected. Scroll content continues below its viewport as expected. The gallery also verifies that Home/History navigation preserves pending capture audio and its journal byte for byte.

## Representative renders

- [Minimum Home](2026-10-06-foundation-ownership/home-minimum.png)
- [Current work first](2026-10-06-foundation-ownership/home-current-work.png)
- [Home larger text, dark](2026-10-06-foundation-ownership/home-larger-text-dark.png)
- [Library prompt entry](2026-10-06-foundation-ownership/library-minimum.png)
- [Persona Me entry](2026-10-06-foundation-ownership/persona-minimum.png)
- [Existing Me editor](2026-10-06-foundation-ownership/me-editor.png)
- [Present without general prompts](2026-10-06-foundation-ownership/present-minimum.png)
- [Prompt picker with long labels and larger text](2026-10-06-foundation-ownership/prompts-larger-text-dark.png)

## Limits and integration

Actual held-key/menu dismissal timing, VoiceOver, native picker focus return, Me sheet focus, and navigation while independent work runs still require the integrated signed Preview. Programmatic key/accessibility activation and renders do not establish those native results. Camera hardware and phone/receiver behavior were not exercised. Resources/Packs hierarchy and conditional legacy recovery remain the separately assigned A2/E work; the remaining From iPhone section in these source-candidate renders is not a clean-app acceptance claim. Parent integration must reconcile current main and C before installing the final candidate.
