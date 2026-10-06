# Accessibility bridge: the AXCommon fault flood, 6 October 2026

Source: branch `claude/ax-structured-sync` with `claude/read-voice-errors` (#269) merged in, from `main` 5f209cab. Nothing visible changed, so there are no renders; this folder records the measurement that grounds the two fixes and the bridge's own reruns. macOS 26.5.1 (25F80), the development Mac.

The split, after review: the flood is the voice listing, and #269 fixes it inside `MacVoiceCatalog` (the catalogue from `AVSpeechSynthesisVoice` identifiers alone, the `NSSpeechSynthesizer` scan only when a saved choice needs it, refreshes on a GCD utility queue; `docs/verification/2026-10-06-read-voice/`). `AccessibilityBridge` is the one door for `AXUIElement*` and `AXObserver*` calls, which never fault (the table below), so it runs each call in place on the calling thread, with no queue, no wait and no process-wide timeout. This branch also closes the two task-context voice calls #269 left: the catalogue keeps the voice objects each listing hands it, and `MacVoiceCatalog.voice(identifier:)` serves them to `MacSpeechRenderer.start` and the voice preview, so a Listen looks nothing up from its task; the checks list on a GCD utility queue. `scripts/check-accessibility-bridge.py` keeps element calls in the bridge and voice listings in `ReadingVoices.swift`, and fails a listing, a catalogue call or `AVSpeechSynthesisVoice(identifier:)` inside a `Task` closure in any file, the flood's own shape.

## What the installed app logged

`log show --last 7d --predicate 'process BEGINSWITH "Workbench" AND messageType IN {16,17}'`, 29 September to 6 October: 126,307 lines of `[com.apple.Accessibility:AXCommon] Potential Structural Swift Concurrency Issue: unsafeForcedSync called from Swift Concurrent context.` Grouped by process and thread, 150 bursts are exactly 741 lines and 8 are exactly 1,482, each about 100 ms long on a background thread, each in the same second as Siri's `AFLocalization outputVoiceDescriptorForOutputLanguageCode` lines. That is one listing of the Mac voices (`MacVoiceCatalog.installed`, run in `Task.detached` whenever Workbench comes to the front, and at launch): 180 `AVSpeechSynthesisVoice`s plus 185 `NSSpeechSynthesizer` voices read for name and locale. The remaining 3,295 lines are partial listings and a handful of single faults from `AVSpeechSynthesisVoice(identifier:)` in Listen and voice previews.

## Which contexts fault

`axprobe.swift` (built with `xcrun swiftc -O`) runs one call in one context per invocation; `run.sh MODE` captures `log stream --predicate 'subsystem == "com.apple.Accessibility"'` around it and counts the faults. Each row was run once.

| Call | Plain main frame | `Task { @MainActor }` | `Task.detached` | Serial queue (`async` + wait, from a task) | `queue.sync` from a task |
| --- | --- | --- | --- | --- | --- |
| `AXUIElementCopyAttributeValue` on Finder's and this process's application element (real IPC, results 0 and notImplemented) | 0 | 0 | 0 | 0 | 0 |
| `AVSpeechSynthesisVoice.speechVoices()` | 0 | 1 | 1 | 0 | 1 |
| `AVSpeechSynthesisVoice(identifier:)` | – | – | 1 | 0 | – |
| `NSSpeechSynthesizer.availableVoices` + `attributes(forVoice:)` for 185 voices | – | – | 926 | 0 | – |
| `AVSpeechSynthesizer.write` rendering 216 buffers | 0 | 1 (the voice lookup) | 1 | 0 | – |
| `AXIsProcessTrusted()` | 0 | – | 0 | – | – |

So on this macOS the fault belongs to the speech-voice side of the Accessibility framework, not to AXUIElement IPC, and `dispatch_sync` does not help because it runs the block on the task's own thread. That is why the bridge runs element calls in place and the voice fix lives with the catalogue (#269).

## Production reproduction

`.build/debug/LocalVoice` under the same capture (`--process LocalVoice`, `subsystem == "com.apple.Accessibility"`), base `main` before either fix, then this branch at two points: with #269 merged and the bridge inline (the review's measurement), and at its head, with the listed voice objects served to readings and the checks listing on a GCD queue. Each cell was run once, in table order, on that source.

| Mode | `main` before | #269 merged, bridge inline | Head (debug) | Head (release) |
| --- | --- | --- | --- | --- |
| `--check-live-dictation-delivery` | 0 (synthetic AX only) | 0 (27 field checks) | 0 (35 field checks, with #265's boundary fit merged) | – |
| `--check-floating-toolbar` (TextDeliveryChecks, PromptPickerChecks) | 0 (synthetic AX only) | 0 (`TEXT_DELIVERY_CHECKS_OK: 64`, `PROMPT_PICKER_CHECKS_OK: 38`) | 0 (`TEXT_DELIVERY_CHECKS_OK: 74`, `PROMPT_PICKER_CHECKS_OK: 38`) | – |
| `--check-core` (includes AccessibilityBridgeChecks) | 0 | 2: `ReadingChecks.run` listed the catalogue twice (`MacVoiceCatalog.installed`) from the `MainActor.run` task; `ACCESSIBILITY_BRIDGE_CHECKS_OK: 12 checks` logged none | 0 (`ACCESSIBILITY_BRIDGE_CHECKS_OK: 10 checks`, `READING_CHECKS_OK: 107`) | 0 (`ACCESSIBILITY_BRIDGE_CHECKS_OK: 10 checks`, `READING_CHECKS_OK: 107`) |
| `--check-reading` | 0 (no voice listing on `main`'s checks) | 2: the same two listings (`READING_CHECKS_OK: 106`) | 0 (`READING_CHECKS_OK: 107`) | – |
| `--check-reading-render` | 931 | 8: one listing (`runRender`), the three `AVSpeechSynthesisVoice(identifier:)` lookups of its guard and one lookup per `MacSpeechRenderer.start` from the async check (four) (`READING_RENDER_OK` Daniel, Karen, Samantha; `READING_STREAM_OK` 25) | 0 (`READING_RENDER_OK` Samantha, Karen, Daniel; `READING_STREAM_OK` 25) | 0 (`READING_RENDER_OK` Samantha, Karen, Daniel; `READING_STREAM_OK` 25) |

The Siri `AFLocalization` lines did not appear in any run (0 in every cell), which is #269's `say`-list rule at work. The two and the eight in the middle column were the checks' own task-context voice calls, and the same `MacSpeechRenderer.start` lookup ran once per Listen in the app; the head column is after `MacVoiceCatalog.voice(identifier:)` and the checks' `offMain` helper, and `ReadingChecks` holds that `voice(identifier:)` returns the listed object itself after a listing (the 107th check).

Not verified here: the installed app's own count after this change, which needs a Preview build and a day of use.
