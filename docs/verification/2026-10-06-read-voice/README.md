# Read voice catalogue — 6 October 2026

Branch `claude/read-voice-errors` on main `5f209cab85fad6fef5c8337ff2a076bdeffbcd35`; refs #7 and #140. The images are offscreen renders of the production Read views from `.build/release/LocalVoice --render-reading-fixture`, with synthetic text and a synthetic catalogue (Karen compact as the only Australian voice, so the hint shows). They are source evidence, not screenshots of the installed app.

- [Voice & pace, light](voice-hint-light.png): the picker lists installed voices by identifier, and the free-upgrade hint names Matilda (Premium) for en-AU.
- [Read mid-reading, light](reading-mid-light.png) and [dark](reading-mid-dark.png): the voice line under the reading is unchanged.

## What was found

The installed app's 398 `AFLocalization outputVoiceDescriptorForOutputLanguageCode:voiceName:` errors on 6 October came from one place: `MacVoiceCatalog.installed()` asking `NSSpeechSynthesizer` about every voice `say` lists (186 on this Mac), on every launch and on every return to the app. A standalone probe under `log stream` (`probe say`, main thread) attributed every line: 12 inside `NSSpeechSynthesizer.availableVoices` (once per process) and 6 inside `attributes(forVoice:)` for each of the six Siri-era identifiers that only `say` keeps (`com.apple.voice.Aman`, `Aman.premium`, `Aru`, `Ona`, `Tara`, `Tara.premium`), which AppKit looks up by language and name and cannot find: 48 in all, in two runs. `AVSpeechSynthesisVoice.speechVoices()` (main thread, a GCD queue or a detached task), `AVSpeechSynthesisVoice(identifier:)` for all 180 installed identifiers and for an uninstalled one (nil), `AVSpeechSynthesisVoice(language:)` and a full `AVSpeechSynthesizer.write` of an utterance logged no `com.apple.siri` line in any run. The installed log shows the same two sources with slightly smaller shares (40 lines on the main thread at each launch, 30 on a background thread after each activation, the enumeration cached after the first).

The activation refresh ran that AppKit scan from a `Task.detached`, which logs one `AXCommon` "unsafeForcedSync" fault per voice: 931 per refresh in the probe (`probe say-detached`), 11,985 in the 6 October sample. Off the main thread the scan took 0.43–0.52 s against 0.39–0.51 s on it on this Mac with a build running in parallel (the first pass of this work measured up to 1.8 s on the main thread and 7.7 s detached while two builds ran; those were load, not the scan's own cost).

User impact, proven: launch and activation cost only, 0.4–0.5 s of main thread per launch on an idle Mac and a background thread for as long after each activation. Not a Read failure: the reading voice is constructed from its installed identifier and rendered without any lookup, so Read did not fall back, delay, stutter or fail because of these lines. Ethan's saved choice is a name an earlier build saved (`Daniel`), which resolves without the `say` list. This Mac has one Australian voice (Karen, super-compact) and no Enhanced or Premium English voice at all, so Read sounds compact until Matilda (Premium) is added; the hint already says so.

Other lines in the same minutes are not Read: `com.apple.coreml E5RT` and `com.apple.ane Unknown aneSubType` appear once per launch right after the recognition model's `MMapped` loads; the 8 CoreAudio lines (`AudioObjectGetPropertyData: no object with given ID`, `HALC_ShellDevice::CreateIOContextDescription`) sit beside `HAL notification: default input device changed` on 5 and 6 October, at other times than the bursts.

## What changed

The catalogue is built from `AVSpeechSynthesisVoice` identifiers only (`MacVoiceCatalog.listed`, 77–81 ms cold and 35–40 ms warm in the probe). Launch reads it on the main thread and waits; `availableVoicesDidChangeNotification` and returning to the app read it on a GCD utility queue, where the probe logs 0 Accessibility faults (a Swift task's thread logs 1 per call), and apply the picker order on the main thread (`catalogue`). The `say` list is read once per process, on the main thread, and only when the saved choice resolves to nothing else: an older `say` name with no match, or a voice only `say` can speak. An identifier with a language segment (`com.apple.voice.premium.en-AU.Matilda` after the download is removed) is reported missing without the list, which cannot have it; only the Siri-era identifiers `say` alone keeps have no language segment. The names `say` listed for installed voices ("Eddy (English (UK))", "Daniel (Enhanced)") resolve by parsing them, checked against all 137 shared names on macOS 26.5.1. A saved say-only choice such as Aman still works and still lists the say-only voices. Novelty, default and hint rules are unchanged.

Classification: Quality inside Read. No entry point was added or renamed; `python3 scripts/check-surfaces.py` prints `Surface registry OK: 561 entries.` The one visible difference is that the Voice picker no longer lists the five Siri-era voices only `say` can speak (Indian English, no word timing) unless a saved choice is one of them.

Merging with #264 (`claude/ax-structured-sync`): that branch routes the same three framework calls through `AccessibilityBridge` inside `installed()`, so the two conflict in `ReadingVoices.swift`. The resolution keeps this branch's shape and swaps the calls: `AVSpeechSynthesisVoice.speechVoices()` in `listed` becomes `AccessibilityBridge.speechVoices()` (`traits` for `voiceTraits`), the two `NSSpeechSynthesizer` calls in `sayVoices()` become one `AccessibilityBridge.sayVoices()`, and `AVSpeechSynthesisVoice(identifier:)` in the render check becomes `AccessibilityBridge.speechVoice(identifier:)`. Keeping #264's body of `installed()` would reinstate the scan on every refresh.

## Counts

Same reproduction before and after, `log stream --process LocalVoice --predicate 'subsystem == "com.apple.siri" OR subsystem == "com.apple.coreml" OR subsystem == "com.apple.ane" OR subsystem == "com.apple.coreaudio" OR subsystem == "com.apple.Accessibility"'`; "before" is main, "after" the second commit:

| mode | before: siri errors / AX faults | after (debug) | after (release) |
| --- | --- | --- | --- |
| `--check-reading` | 0 / 0 | 0 / 2 | 0 / 2 |
| `--check-reading-render` | 48 / 933 | 0 / 8 | 0 / 8 |
| `--check-neural-voice` | 0 / 0 | 0 / 0 | 0 / 0 |
| `--measure-reading-latency` (Karen, Daniel) | 0 / 3 | 0 / 6 | 0 / 6 |

The remaining AX faults are one per `AVSpeechSynthesisVoice` call made from the check's own task thread (the checks run inside `MainActor.run`, and `--check-reading` makes two such calls); the new listing on the utility queue logs none, and the app's refreshes run from `init`, Combine sinks on the main run loop and that queue, where the installed log shows none on the launch thread. No run logged `AudioObjectGetPropertyData: no object with given ID` or `HALC_ShellDevice`; the error-level CoreAudio lines in the render and latency runs are AUCrashHandler/auext XPC invalidation at teardown. Results: READING_CHECKS_OK 106 (99 on main), READING_RENDER_OK three voices and READING_STREAM_OK 25 render checks (was 24), NEURAL_VOICE_CHECKS_OK 27; Karen first audio 0.088 s median, Daniel 0.114 s (debug); Karen 0.088 s, Daniel 0.106 s (release).

Standalone probes (`swiftc -O`, under the same predicate, two runs each): the `NSSpeechSynthesizer` scan of 186 voices on the main thread 0.39–0.51 s, 48 siri lines, 0 AX faults; from `Task.detached` 0.43–0.52 s, 48 siri lines, 931 AX faults; `AVSpeechSynthesisVoice.speechVoices()` 77 ms cold and 35–40 ms warm on the main thread, 81 ms on `DispatchQueue.global(qos: .utility)` with 0 faults, 82 ms from `Task.detached` with 1 fault; 180 of 180 listed identifiers construct in 64 ms with no log line; an uninstalled identifier returns nil.

## Not verified

Installed-app behaviour (launch time, activation, the Voice picker in the signed build) is owed to the lead; `availableVoicesDidChangeNotification` firing when a voice is added in System Settings was not exercised (no system voice was installed or removed); the `say`-only path with a real saved say-only choice was exercised only through the synthetic resolution checks and the standalone probes, not in the app; the #264 merge resolution above was not compiled, since it needs both branches in one tree.
