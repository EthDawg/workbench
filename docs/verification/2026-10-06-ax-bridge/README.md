# Accessibility bridge: the AXCommon fault flood, 6 October 2026

Source: branch `claude/ax-structured-sync` from `main` 5f209cab. Nothing visible changed, so there are no renders; this folder records the measurement that grounds the fix and its result. macOS 26.5.1 (25F80), the development Mac.

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

So on this macOS the fault belongs to the speech-voice side of the Accessibility framework, not to AXUIElement IPC, and `dispatch_sync` does not help because it runs the block on the task's own thread. The bridge therefore hops to its queue with `async` and waits.

## Production reproduction

`.build/debug/LocalVoice` under the same capture (`process == "LocalVoice"`), before and after the bridge:

| Mode | Before | After |
| --- | --- | --- |
| `--check-live-dictation-delivery` | 0 (synthetic AX only) | 0 |
| `--check-floating-toolbar` (TextDeliveryChecks, PromptPickerChecks) | 0 (synthetic AX only) | 0 |
| `--check-reading` | 0 (no voice listing) | 0 |
| `--check-reading-render` (lists the voices, renders three) | 931 | 0 |
| `--check-core` | 0 | 0 (now includes AccessibilityBridgeChecks, 9 checks) |

Not verified here: the installed app's own count after this change, which needs a Preview build and a day of use; that is owed to the lead.
