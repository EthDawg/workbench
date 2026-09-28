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
