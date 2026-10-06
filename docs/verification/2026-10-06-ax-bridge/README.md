# Accessibility bridge: the AXCommon fault flood, 6 October 2026

Source: branch `claude/ax-structured-sync` with `claude/read-voice-errors` (#269) merged in, from `main` 5f209cab. Nothing visible changed, so there are no renders; this folder records the measurement that grounds the two fixes and the bridge's own reruns. macOS 26.5.1 (25F80), the development Mac.

The split, after review: the flood is the voice listing, and #269 fixes it inside `MacVoiceCatalog` (the catalogue from `AVSpeechSynthesisVoice` identifiers alone, the `NSSpeechSynthesizer` scan only when a saved choice needs it, refreshes on a GCD utility queue; `docs/verification/2026-10-06-read-voice/`). `AccessibilityBridge` is the one door for `AXUIElement*` and `AXObserver*` calls, which never fault (the table below), so it runs each call in place on the calling thread, with no queue, no wait and no process-wide timeout; `scripts/check-accessibility-bridge.py` keeps element calls there and voice listings in `ReadingVoices.swift`, outside `Task` closures.

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

`.build/debug/LocalVoice` under the same capture (`--process LocalVoice`, `subsystem == "com.apple.Accessibility"`), base `main` before either fix, then this branch with #269 merged and the bridge inline. The measured faults on this branch are all speech-voice calls made from Swift task contexts in #269's checks and in `MacSpeechRenderer.start`, which the table attributes; none is an element call.

| Mode | `main` before | This branch (bridge inline, #269 merged) |
| --- | --- | --- |
| `--check-live-dictation-delivery` | 0 (synthetic AX only) | 0 (27 field checks) |
| `--check-floating-toolbar` (TextDeliveryChecks, PromptPickerChecks) | 0 (synthetic AX only) | 0 (`TEXT_DELIVERY_CHECKS_OK: 64`, `PROMPT_PICKER_CHECKS_OK: 38`) |
| `--check-core` (now includes AccessibilityBridgeChecks) | 0 | 2: `ReadingChecks.run` lists the catalogue twice (`MacVoiceCatalog.installed`, lines 157 and 160) from the `MainActor.run` task; `ACCESSIBILITY_BRIDGE_CHECKS_OK: 12 checks` logged none |
| `--check-reading` | 0 (no voice listing on `main`'s checks) | 2: the same two listings (`READING_CHECKS_OK: 106`) |
| `--check-reading-render` | 931 | 8: one listing (`runRender`, line 441), the three `AVSpeechSynthesisVoice(identifier:)` lookups of its guard (line 449) and one lookup per `MacSpeechRenderer.start` from the async check (four) (`READING_RENDER_OK` Daniel, Karen, Samantha; `READING_STREAM_OK` 25) |

Each row was run once, in this order, on the final source. The Siri `AFLocalization` lines did not appear in any run (0 in all five), which is #269's `say`-list rule at work. The eight and the two are the checks' own task-context voice calls, which the bridge no longer wraps by the lead's decision that the voice side belongs to the catalogue; they are listed for the lead in the pull request's Not verified.

Not verified here: the installed app's own count after this change, which needs a Preview build and a day of use.
