# Persona voice ring · 28 September 2026

**React to my voice** rings the shown persona with bars that move as the presenter speaks: the "headshot/voice-framing overlay" in [issue #112](https://github.com/EthDawg/workbench/issues/112), and Persona's voice framing option in the [Grammar](../workbench.md#grammar). The behaviour is described in [the persona contract](../personas.md#react-to-my-voice). Images and the native receipt are in [persona-voice-ring-2026-09-28](persona-voice-ring-2026-09-28/); all artwork is synthetic.

## Source checks

- `scripts/test-stage.sh --persona-voice-only`: 11 tests, 104 assertions, zero failures. They cover the microphone running only while the ring is on and its persona shows, for one card and for a prepared set; the ring following the selected overlay; stopping on hide, Hide all, End, Quit, turning it off, a refused permission and a lost device; permission asked when it is turned on; the analyzer on synthetic speech at built-in, quiet and headset levels (speech median above 0.55, breaths below 0.12); room noise and a fan switched on staying below 0.08; bands following pitch; outline fitting for a round badge (circle within 2%), a card (corner radius within 2.5%), a photo and a cut-out; colour from the artwork; and placement that keeps the artwork's size and the ring on screen.
- `--scenes-only` 128 tests / 3,019 assertions, `--persona-workspace-only` 6 / 246, `--persona-controls-only` 5 / 80 and `--persona-quick-only` 5 / 87, all with zero failures.
- `scripts/check-surfaces.py`: 327 entries. The one new entry is an Option of Persona.
- Site: 19 contract tests and the production site build.
- The voice checks write no preference files ([#128](https://github.com/EthDawg/workbench/issues/128)).

## Native check on this Mac

Signed Workbench Preview 2.2.0 (20260927235614) from source `413a397`, Developer ID team GHVAAH9P5Z, run from a scratch folder with `open -n -a "Workbench Preview.app" --args --check-persona-voice-native FOLDER --speak`, so the Preview's own microphone permission applied. The installed Preview was not replaced. MacBook Air built-in microphone, macOS 26.5.1, speakers at 19% volume, synthetic badge.

| Check | Result |
| --- | --- |
| Showing a persona with the ring off | Microphone stays closed |
| Turning the ring on | macOS reports the microphone in use after 1.3 ms; first frames after 105 ms |
| Frames | About 100 ms microphone buffers (10.5 a second, 4.7 frames each), played back at the display's rate |
| The room, 4 s | Level median 0, 90th percentile 0.02 |
| A synthetic sentence through the speakers | Median 0.50, 90th percentile 0.86, 82% of frames above 0.25 |
| 2 s after the sentence | Median 0, maximum 0.02 |
| Dictate and Snap & Talk narration capture settings beside the ring | 3.1 s recorded (peak −42 dBFS); the ring kept 5–6 deliveries every half second and continued after |
| Meeting capture's microphone engine beside the ring | 30 buffers in 3.1 s; the ring kept 5–6 per half second and continued after |
| Ring turned on during a recording | Ring heard within 107 ms; the recording continued |
| Engine restarts caused by the other recordings | 0 |
| Microphone closed after hide, turning off, the persona key and Quit | 2.5, 0.6, 0.5 and 0.5 ms |

Dictate and Snap & Talk narration both record with a 16 kHz PCM `AVAudioRecorder`; meeting capture's microphone is a second `AVAudioEngine` with a 4,096-frame tap. The check used those exact settings in the same process. Workbench's meeting detector skips its own process (`MeetingDetection.swift`), so the ring cannot raise a call offer.

## Not yet verified

- A real voice at the desk; the speech here was synthetic, through the speakers.
- A Bluetooth headset (switching to its microphone), external displays and VoiceOver.
- A meeting receiver's view of a shared screen in Teams or Zoom.
- The real Dictate, meeting and narration flows in an installed Preview; the check reproduced their capture settings rather than driving their windows.

## Quiet outline and response · #158

[#158](https://github.com/EthDawg/workbench/issues/158) replaced the bars with a quiet, still outline that brightens and thickens a little while the presenter speaks, and set two targets: visible within 150 ms of the first speech frame Workbench receives, and back to rest within 500 ms of the last. The time macOS takes to deliver a buffer is measured separately.

### What was wrong

`say` sentences mixed with a synthetic room ran through the unchanged analyser and ring (source `00be555`), in 100 ms deliveries with a 60 Hz display:

| Case | Before | After |
| --- | --- | --- |
| Turned on mid-sentence | Floor learned at −39 dBFS against a −62 room, then held 12–23 dB high for the whole 16 s; the response ran at about half strength | Floor stays within 2 dB of the room |
| Turned on mid-sentence, soft voice | Onset 467 ms; levels 0–0.4 for about 5 s | Onset 33 ms |
| 16 s of continuous speech | Floor climbed 15 dB, from −63 to −47 dBFS | Floor within 2 dB of the room |
| Return to rest | 333–600 ms | At most 400 ms |
| A fan switched on | About 4 s of false response | None |

The hypothesis in #158 holds: the estimator learned speech as room noise, through the first-eight-frame adaptation when speech was already under way and through the three-second rolling minimum during unbroken speech. The ring also replayed each delivery at the pace it was heard and eased down over 170 ms, which put return to rest past 500 ms.

### The new metering

A voice is recognised by its pitch: the analyser measures how clearly the last 40 ms repeats at a speaking pitch (70–400 Hz, looked for in the 150 Hz–4 kHz band). A frame counts at 0.7, or 0.5 once speech is under way, when it is also 6 dB above the room. A word that opens on "s" counts from its hiss, which must sit 12 dB above a room already heard and mostly above 4 kHz. Speech is held for 0.18 s through the gaps between words. The room is learned only from steady sound: a quieter room at once, steady unvoiced sound in about a quarter second, a steady tone within a second, anything else at most 0.25 dB a second. Loudness is measured against the presenter's usual level, the loudest fifth of voiced frames, settled over the first half second. The outline takes each delivery at once, lights within one display frame, and fades with a 40 ms time constant.

### Offline harness

`PersonaVoiceLatencyTests` feeds deterministic speech-like sound (formant vowels with a moving pitch, and "s", "sh" and "f" onsets) through the real analyser and outline state with a simulated clock: 100 ms deliveries, a 60 Hz display, five alignments against the buffers. Every case runs in `scripts/test-stage.sh --persona-voice-only` and in CI.

| Case | Onset, worst | Back to rest, worst |
| --- | --- | --- |
| Speech already under way when turned on (device zeros, then mid-sentence) | 17 ms | 300 ms |
| A first word opening on "s" | 117 ms | 400 ms |
| Usual voice, 48 kHz built-in | 117 ms | 400 ms |
| Soft voice, 16 dB above the room | 117 ms | 300 ms |
| Loud headset | 117 ms | 400 ms |
| 44.1 kHz interface | 117 ms | 383 ms |
| 16 kHz Bluetooth headset | 117 ms (133 ms from the vowel of an "sh" or "f" word) | 400 ms |
| 12 s without a pause, usual and soft | 117 ms, lit throughout including the last 3 s; floor within 4 dB of the room | 383 ms |

Words that open on "sh" or "f" light at their vowel, within 133 ms of it and 217 ms of the hiss. Silence, a fan and a loud fan from the moment the outline turns on, steady hiss, 50 and 60 Hz mains hum, typing, and a fan or hiss switched on lit it on no display frame. A phrase raised by 9 dB read as loud throughout; usual speech never did.

With `WORKBENCH_VOICE_SAY=1` the same harness also measures 32 sentences from four Mac voices, written by `say -o` to a temporary folder and never played. At usual and soft levels: onset median 17 ms, 95th percentile 117 ms, worst 217 ms (sentences opening on "sh", "f" or "h"); from the first voiced frame, worst 17 ms usual and 117 ms soft; back to rest median 283 ms, worst 400 ms.

Held vowels and periodic sound that is not speech, from review: a vowel held 1 s or 1.5 s mid-sentence first lifted the room 13–14 dB and dimmed the outline (lit for 86–95% of the sentence). Steady voiced sound may now lift the room no closer than 12 dB below the presenter's usual level; the outline stays lit through vowels held 0.6, 1 and 1.5 s, returning to rest within 300 ms after. Any periodic sound in the voice band reads as voiced, so it lights the outline while it sounds: a chime for 0.87 s, a 0.2 s beep for 0.48 s, a 2.4 s tune for 2.28 s, each settling within half a second after. A held C major chord does not repeat at a speaking pitch and never lit it. Call audio through the speakers is a voice to the analyser; headphones keep it out.

Known limits: a steady 120 Hz tone present when the outline turns on shows for about 0.7 s before it is learned (mains hum at 50 or 60 Hz does not), and once a voice has been heard a steady tone as loud as it keeps the outline lit while it sounds; a loud hiss concentrated above 4 kHz reads as an "s"; whispered speech lights only at its "s" sounds.

### Native measurement

`--check-persona-voice-native FOLDER --speak` now records every frame's arrival (`frames`) and every visible change (`shown`) on one clock, and reports `latency.normal`, `latency.soft`, `latency.continuous` and `latency.immediate` with `onsetMs`, `releaseMs` and the share of speech the outline stayed lit, against the 150 ms and 500 ms targets. `inputLatency` reports the buffer length and macOS's hand-over separately. It has not been run on this change yet; its receipt belongs here when it is.
