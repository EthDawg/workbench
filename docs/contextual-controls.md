# Compact controls during a continuous presentation

The menu bar offers Dictate, Snap & Talk, Draw, Present and Read directly. Each main action takes one click; active work replaces Start with its own Finish, Done or End action. Secondary controls add a choice or a review surface: text style/destination, capture review, drawing tools, scene selection and shortcuts. There is no icon-only selector strip or six-dot drag grip. The 344pt menu fits its content with 12pt outer padding rather than reserving a fixed 440pt height.

The floating toolbar retains the existing resting pill, hover grace, keyboard access, eight docking positions and Reduce Motion behavior. Hover is 336 × 52pt (76pt high at side docks to retain the whole resting target); expanded controls are 400 × 88pt. Its tool menu changes the controls without stopping independent work. Current configured shortcuts are visible; off/conflicted bindings are identified. The text-style menu separately controls cleanup and paste/copy destination for the next capture. Native snapshots below use a synthetic three-capture session, not private user content.

![Light controls](assets/contextual-controls/light.png)
![Dark controls](assets/contextual-controls/dark.png)

## State and ownership

| Activity | Start/change | Finish and preservation |
| --- | --- | --- |
| Device scene | Existing scene selection and presentation guard | End scene ends only the device scene |
| Drawing | Click, held or toggle shortcut; permitted during voice request, recording, transcription and cleanup | Done commits stroke/text, releases input and retains ink/boards; visible boards remain visible |
| Dictation | One microphone owner; snapshot cleanup/destination settings | Save transcript first. While drawing owns input, wait to paste or offer Copy now. Revalidate the original target after release; changed focus falls back to copy |
| Snap & Talk | Existing session and permission flow; count non-deleted captures | Finish narration keeps the session/capture count; review and handoff use existing session records |
| Reading | Existing reading operation | Pause/resume or stop remains separate |

Drawing cannot begin during final text insertion, cancellation, screen acquisition, board export, shortcut practice or shutdown. A changed hotkey registration ends only held drawing, so a missed key-up cannot leave it stuck. `finishDrawing()` is deliberately distinct from Escape/reset. The app no longer calls that reset whenever dictation changes phase. A board mouse click cannot bypass denied drawing admission.

Explicit Copy to clipboard permits capturing a thought without a Mac text field during a live scene. Automatic paste retains the existing Mac target checks and never sends text to a phone. Ordinary dictation waits for Snap & Talk's microphone/transcription queue. Quit cancels waiting insertion while retaining the saved capture.

## Build owners and acceptance

- `WorkbenchControlTool.swift` owns shared action availability, labels and context. `WorkbenchQuickPanel` and `FloatingToolbar` render it; choosing controls is not a global exclusive mode.
- `AppModel` and `DrawingDeliveryGate` own saved-transcript delivery waiting. `TextDelivery` retains original-target revalidation, clipboard fallback and insertion reporting.
- `StageKitController` exposes the narrow drawing admission and settled state callback. `AppCoordinator` retains drawing, screenshot, export and practice ownership.
- Existing capture history remains history. Durable notes with titles/categories and importing notes into a Snap & Talk handoff are not implemented by this increment.
- Local automated and native evidence is in [the acceptance record](verification/2026-09-21-contextual-controls.md). Actual microphone + phone + meeting-receiver behavior, physical multi-display movement and VoiceOver remain separate acceptance checks.
