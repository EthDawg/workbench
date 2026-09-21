# Menu and dictation repair, 22 September 2026

The earlier Preview could retain an audio-only failure in its one-slot recovery journal, refuse every new recording, and offer only another attempt at the same audio. The native application menu also lacked annotation controls. This repair keeps failed audio without trapping new capture and restores compact native controls.

## Verified

- Full Mac suite: 107 package tests, 64 browser tests, StageKit 146 tests / 2,961 assertions. Provider, capture, keyboard, reading and persistence checks passed.
- Exact AppModel capture harness: 71 checks. New cases cover lossless archive/new capture, unchanged draft, external metadata changes, missing WAV after a journal-only crash, archive destination collision, invalid import and import of the current recovery itself. Unsaved recognized text still requires save-only retry.
- Final native menu/toolbar fixture: 38 checks. Quick menu 288pt wide; hover 244 × 52pt; expanded 304 × 88pt. Light/dark renders use synthetic content. All recording and narration drag grips are hidden.
- Installed Preview build 20260921220127 from implementation 4ce4747: top Annotate menu opened, Arrow started directly, Finish Drawing released input, and the quick menu’s Tools action opened the same native drawing menu.
- In that installed app, the configured dictation shortcut started a fresh microphone capture despite the original failed recovery. The original WAV was found under SavedRecordings with an identical SHA-256 digest. Stop returned to idle; silent input did not strand the next attempt.
- Installed app Import audio transcribed a 5.42-second synthetic recording exactly: “Workbench keeps the presentation running. Please bring the blue notebook to the meeting tomorrow morning.” The existing working draft was restored after the test. A synthetic capture remains in history as verification evidence.
- The installed local speech engine also passed its built-in speech round-trip and M4A recognition checks with synthetic speech.

## Microphone finding and limits

The Mac’s default input was its built-in microphone while its lid was closed. Apple’s hardware disconnect disables that microphone in this state. The microphone checks therefore received silence; they do not establish successful live spoken capture. Open the lid or choose an external input, then repeat the short speech check. No microphone permission, input-device selection or system protection was changed. [Apple’s hardware documentation](https://support.apple.com/guide/security/secbbd20b00b/web).

Existing signing identity and the CloudKit profile were retained. A private saved-data backup and previous-app archive were kept. The old Preview quit normally after reconnecting the desktop control service; the rejected force-quit fallback was never performed. No public binary release, App Store submission or merge occurred. A real phone/meeting receiver, physical multi-display movement and VoiceOver remain separate acceptance checks.
