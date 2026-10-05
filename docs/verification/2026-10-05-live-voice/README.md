# Live voice experience — 5 October 2026

Branch: `codex/live-voice-engine`; PR #246. These images use synthetic content and production SwiftUI/AppKit views. They are source-rendering evidence, not screenshots of an accepted installed call. The final source revision and signed Preview installation receipt are recorded in the PR.

- [Meeting ready, light](meeting-ready-light.png): source and one Start; setup options remain secondary.
- [Meeting completed, dark](meeting-completed-dark.png): real synthetic recording commit, exact saved transcript and next actions visible together.
- [Live transcript, light](transcript-listening-light.png): separate source turns and revisable words.
- [Reconnecting, dark](transcript-reconnecting-dark.png): the same session remains visible while audio recovers.

Validation: 341 Swift tests, two skips, zero failures; 206 meeting lifecycle checks plus 34 recording-removal checks; 21 live-window checks; 14 voice-experience checks; 27 exact-field delivery checks; 184 persistence checks; 19 clean-draft checks. Core app checks and 559-entry surface registry passed, as did the registry checker's 57 tests. The desktop gallery produced 158 renders, 162 entries and zero flags; the shared transcript gallery rendered five phases in both appearances. Toolbar workers additionally checked 388 synthetic light/dark fixtures.

Reproduce the native images using `WORKBENCH_DESKTOP_GALLERY_ONLY=1 .build/debug/LocalVoice --render-surfaces .build/live-voice-desktop-final` and `.build/debug/LocalVoice --render-live-voice .build/live-voice-transcripts-final`. The full test script was not clean: the earlier run stopped at five exclusive-shortcut assertions while production Workbench owned those shortcuts.

Outstanding installed acceptance: exact external text-field compatibility, relayed iPhone call capture, Mac/headphone changes, real call-end metadata and long-session performance. A private native NSTextView fixture does not prove cross-app Accessibility behavior. “You” and “Others” identify input channels, not individual speakers. The prototype shown in conversation is illustrative and is not acceptance evidence.
