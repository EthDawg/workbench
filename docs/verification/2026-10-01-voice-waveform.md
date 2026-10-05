# Voice waveform: Persona ring and recording trace · 1 October 2026

**React to my voice** now rings the shown persona with dots that rise into bars as the presenter speaks, and the floating toolbar's recording trace is a waveform of seven bars, tallest in the middle. Ethan chose both on 1 October 2026 from a reference image and three moving previews; the behaviour is described in [the persona contract](../personas.md#react-to-my-voice) and [the floating-toolbar contract](../floating-toolbar.md). Images and the motion clip are in [voice-waveform-2026-10-01](voice-waveform-2026-10-01/); all artwork is synthetic.

## What changed, and why it had kept failing

The 28 September decision ([#134](https://github.com/EthDawg/workbench/issues/134#issuecomment-5869651899), [#158](https://github.com/EthDawg/workbench/issues/158)) specified a still continuous outline and three fixed lobes, with "no sideways travel or autonomous oscillation". Each later pass kept to that record, so neither surface could look like an audio waveform. Acceptance then rested on stills and timing checks; nobody had watched either surface move with a voice.

Three things were also short of signal. The trace received one level twelve times a second and showed it as about a point of height. The ring averaged each 100 ms microphone buffer into one value. And neither had a shape that varies with what is said.

Now:

- **Ring.** The Persona analyser hands over 128 bands of the voice's spectrum with every 21 ms frame, each against the frame's strongest band and at the frame's energy. `VoiceSpectrum` plays a microphone buffer's frames in turn, raises each band in 15 ms and lets it fall in 180 ms. Each bar reads its own part of the range, and the range wanders around the ring and closes on itself, so there is no seam and no side that always leads. Bars stand shorter around a card's corners.
- **Trace.** `VoiceWave` follows the recorder's level and carries it outward from the middle bar over 140 ms, under a taper that makes the middle tallest.
- **Colour.** The ring's colour is the presenter's, mint to begin with, chosen with the same swatches, menu and picker as Draw's ink colour.
- **Rejected on the way** (do not return to these): a wavy continuous line (read as a wobbly border), a solid outline with bars on it, bars travelling around the ring (too distracting for an audience), and a single wrap of the range from the top (a hard seam with the strongest sounds always beside it).

## Source checks

Run at this branch's head on macOS 26.5.1, Apple M5.

- `scripts/test-stage.sh --persona-voice-only`: 28 tests, 1,902 assertions, zero failures, including the optional renders and the Mac-voice run below. New or rewritten checks cover: the ring at rest is dots only; bars rise outward and never toward the artwork; a steady sound holds its bars in place; neighbouring bars differ; the loudest ring fits the room its window makes; the range closes on itself and neighbours show neighbouring sounds; a rounded rectangle's edge is walked outward with its corners known; the chosen colour is remembered, reaches a shown ring and every overlay of a set, and never opens the microphone; the trace's bars fit 28 × 12 points, are tallest in the middle, swell from the middle outward and rest as dots; Reduce Motion holds both still.
- Mac voices through the analyser (`WORKBENCH_VOICE_SAY=1`, 160 runs each): usual speech lights the ring a median 17 ms after the first voiced frame (maximum 17 ms) and returns to rest in a median 283 ms (maximum 383 ms); soft speech 17 ms (maximum 117 ms) and 283 ms (maximum 400 ms). The 150 ms and 500 ms targets of #158 hold.
- The trace from a recorder's level read every 80 ms: lit within 33 ms of the first voiced reading, at rest within 277 ms of the last.
- `swift test`: 338 tests, 2 skipped, zero failures. Release build, the `--check-*` runs and `scripts/test-snap.sh`: passed.
- `scripts/check-surfaces.py`: 543 entries. The two new ones are Options of Persona: **Voice Colour** and its **Choose Colour…**.
- `scripts/test-stage.sh --ci`: 273 tests, 5,857 assertions, 5 failures, all in `IntegrationTests` shortcut registration (`⌥A is unavailable (code -9878)` and four that depend on it). The installed Workbench was running on this Mac and held those global shortcuts. They do not touch this change; CI has no running Workbench.
- No preference files were left behind.

## What the renders show

| File | Shows |
| --- | --- |
| [spoken-sentences.mp4](voice-waveform-2026-10-01/spoken-sentences.mp4) | Both surfaces through a spoken sentence, with its audio: a small Circle, a large Card and the trace at native size and four times |
| [speech-moments.jpg](voice-waveform-2026-10-01/speech-moments.jpg) | Eight moments of that sentence, a quarter of a second apart |
| [sheet-dark.jpg](voice-waveform-2026-10-01/sheet-dark.jpg), [sheet-light.jpg](voice-waveform-2026-10-01/sheet-light.jpg), [sheet-busy-light.jpg](voice-waveform-2026-10-01/sheet-busy-light.jpg) | Quiet, soft, usual and raised over dark, white and busy content |
| [sheet-reduce-motion-dark.jpg](voice-waveform-2026-10-01/sheet-reduce-motion-dark.jpg) | Reduce Motion: still dots and a still waveform that only brighten |
| [persona-page-colour.jpg](voice-waveform-2026-10-01/persona-page-colour.jpg) | The Persona page with React to my voice on and its colour row |

The sentence was written by the Mac's own voice with `say -o` and never played aloud. The ring's frames came from the real analyser fed 100 ms buffers, as this Mac's microphone delivers them. The trace's level is an emulation of the recorder's meter: the average power of each 80 ms over 55 dB. The four steady states in the sheets use a synthetic vowel, so their bars are more even than speech's.

## Not yet verified

- A real voice at the desk in an installed Preview, for either surface. The microphone cannot be used from this session.
- The trace against `AVAudioRecorder`'s actual meter; its ballistics may differ from the emulation.
- The colour picker and Voice Colour menu by hand, a Bluetooth headset, external displays, VoiceOver, and a meeting receiver's view of a shared screen.
- macOS 14 and 15.
