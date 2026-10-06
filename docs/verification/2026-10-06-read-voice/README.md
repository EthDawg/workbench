# Read voice catalogue — 6 October 2026

Branch `claude/read-voice-errors` on main `5f209cab85fad6fef5c8337ff2a076bdeffbcd35`; refs #7 and #140. The images are offscreen renders of the production Read views from `.build/release/LocalVoice --render-reading-fixture`, with synthetic text and a synthetic catalogue (Karen compact as the only Australian voice, so the hint shows). They are source evidence, not screenshots of the installed app.

- [Voice & pace, light](voice-hint-light.png): the picker lists installed voices by identifier, and the free-upgrade hint names Matilda (Premium) for en-AU.
- [Read mid-reading, light](reading-mid-light.png) and [dark](reading-mid-dark.png): the voice line under the reading is unchanged.

## What was found

The installed app's 398 `AFLocalization outputVoiceDescriptorForOutputLanguageCode:voiceName:` errors on 6 October came from one place: `MacVoiceCatalog.installed()` asking `NSSpeechSynthesizer` about every voice `say` lists (185 on this Mac), on every launch and on every return to the app. A standalone probe under `log stream` attributed every line: 10 inside `NSSpeechSynthesizer.availableVoices` (once per process) and 6 inside `attributes(forVoice:)` for each of the Siri-era voices that only `say` keeps (`com.apple.voice.Aman`, `Aman.premium`, `Aru`, `Ona`, `Tara`), which AppKit looks up by language and name and cannot find. `AVSpeechSynthesisVoice.speechVoices()`, `AVSpeechSynthesisVoice(identifier:)` for installed and uninstalled identifiers, `AVSpeechSynthesisVoice(language:)` and a full `AVSpeechSynthesizer.write` of an utterance logged nothing. That matches the log: 40 lines on the main thread at each launch (10 + 5 × 6) and 30 on a background thread after each activation (the enumeration is cached, the five lookups repeat).

The same background refresh ran AppKit off the main thread from a Swift concurrency context, which logged 741 `AXCommon` "unsafeForcedSync" faults per refresh (4,575 on 6 October) and took 7.7 s against 0.8 s on the main thread in the probe.

User impact, proven: launch spent 0.8 to 1.8 s on the main thread in that scan (measured in the probe while and while not building); every activation burned a background core for seconds. Not a Read failure: the reading voice is constructed from its installed identifier and rendered without any lookup, so Read did not fall back, delay, stutter or fail because of these lines. Ethan's saved choice is a name an earlier build saved (`Daniel`), which resolves without the `say` list. This Mac has one Australian voice (Karen, super-compact) and no Enhanced or Premium English voice at all, so Read sounds compact until Matilda (Premium) is added; the hint already says so.

Other lines in the same minutes are not Read: `com.apple.coreml E5RT` and `com.apple.ane Unknown aneSubType` appear once per launch right after the recognition model's `MMapped` loads; the 8 CoreAudio lines (`AudioObjectGetPropertyData: no object with given ID`, `HALC_ShellDevice::CreateIOContextDescription`) sit beside `HAL notification: default input device changed` on 5 and 6 October, at other times than the bursts.

## What changed

The catalogue is built from `AVSpeechSynthesisVoice` identifiers only, on the main thread (about 80 ms measured warm), at launch, on `availableVoicesDidChangeNotification` and on return to the app. The `say` list is read once per process, on the main thread, and only when the saved choice resolves to nothing else (an older `say` name with no match, or a voice only `say` can speak); the names `say` listed for installed voices ("Eddy (English (UK))", "Daniel (Enhanced)") now resolve by parsing them, checked against all 137 shared names on macOS 26.5.1. A saved say-only choice such as Aman still works and still lists the say-only voices. Novelty, default and hint rules are unchanged.

Classification: Quality inside Read. No entry point was added or renamed; `python3 scripts/check-surfaces.py` prints `Surface registry OK: 561 entries.` The one visible difference is that the Voice picker no longer lists the five Siri-era voices only `say` can speak (Indian English, no word timing) unless a saved choice is one of them.

## Counts

Same reproduction before and after, debug build, `log stream --process LocalVoice --predicate 'subsystem == "com.apple.siri" OR subsystem == "com.apple.coreml" OR subsystem == "com.apple.ane" OR subsystem == "com.apple.coreaudio" OR subsystem == "com.apple.Accessibility"'`:

| mode | before: siri errors / AX faults | after (debug) | after (release) |
| --- | --- | --- | --- |
| `--check-reading` | 0 / 0 | 0 / 1 | 0 / 1 |
| `--check-reading-render` | 48 / 933 | 0 / 8 | 0 / 8 |
| `--check-neural-voice` | 0 / 0 | 0 / 0 | 0 / 0 |
| `--measure-reading-latency` (Karen) | 0 / 3 | 0 / 3 | 0 / 6 (two voices) |

The remaining AX faults are one per `AVSpeechSynthesisVoice` call made from an async check function (the checks run inside `MainActor.run`); the app's own refresh runs from `init` and Combine sinks on the plain main run loop, where the installed log shows none on the launch thread. Results: READING_CHECKS_OK 104 (was 99), READING_RENDER_OK three voices and READING_STREAM_OK 25 render checks (was 24), NEURAL_VOICE_CHECKS_OK 27; Karen first audio 0.087 s median, Daniel 0.113 s (release).

## Not verified

Installed-app behaviour (launch time, activation, the Voice picker in the signed build) is owed to the lead; `availableVoicesDidChangeNotification` firing when a voice is added in System Settings was not exercised (no system voice was installed or removed); the `say`-only path with a real saved say-only choice was exercised only through the synthetic resolution checks and the standalone probes, not in the app.
