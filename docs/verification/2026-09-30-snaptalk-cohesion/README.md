# Desktop workflow completion — 30 September 2026

Source: `cbae06ad4ae02f2122912530661126e7354a7e02` on `codex/desktop-cohesion`, following baseline `57fa1ef`. This records source checks and synthetic native renders. The integration owner alone builds, installs and accepts the combined Preview. No archive was rebuilt or installed for this revision; the earlier `20260930091428` archive does not contain these changes.

## Implemented

- **Snap & Talk:** one current session, fixed capture/Stop controls, ordered thumbnails and one selected screenshot/narration. Sessions, settings, ordering and Recently Deleted open separately. Selection follows the section UUID through navigation, ordering and background publication.
- **Narration save failures:** preserve the candidate before I/O and through later publication. Retry, Copy text and confirmed discard remain available. Session changes, handoff and normal Quit wait for unresolved edits. Original screenshots, audio and transcription stay intact.
- **History to Dictate:** a distinct draft and its original require explicit Replace draft; Keep current leaves them unchanged. An active capture blocks replacement, including one started after the decision opened.
- **Unfinished delivery:** Dictate keeps the existing result's Review, permitted Copy again and Dismiss controls after the temporary cue expires. Quick Controls and Home Review use its exact transcript ID. Uncertain paste never offers another automatic insertion.
- **Read:** Import text accepts one bounded local UTF-8 plain-text file through the existing Keep/Replace owner. Cancel, invalid input and an explicit Save audio leave the current reading intact. Import starts no playback or provider call.
- **Shared study:** all 20 Desktop starting scenarios are accounted for in the [scenario map](../../experience/README.md). Portable sessions return through Sessions, including the History door being integrated separately. Library images remain file resources. Dismissing a Read failure leaves Listen available.

## Verification

| Check | Result |
| --- | --- |
| `swift build --disable-sandbox` | Passed |
| Desktop-only native gallery | 150 renders, 142 entries, 0 flags; light/dark, default/minimum sizes |
| `LocalVoice --check-readback` | 73 storage, 11 admission, 41 capture-choice, 19 availability, 18 recovery, 32 pack and 41 ordering/save checks passed |
| `test-capture-persistence.py` | 160 checks; exact AppModel methods, isolated records, no real microphone or clipboard |
| `test-read-selection-service.py` | 42 model, 8 metadata and 6 import-door checks passed |
| Surface registry / extractor | 458 entries; 57 tests passed |
| Portable Desktop study | 20 scenarios × 3 widths (1024, 736, 320); 60 layouts, no clipping or browser errors |
| `git diff --check` | Passed |

The native gallery constructs actual SwiftUI/AppKit hosts with isolated temporary state. It uses valid synthetic PNG/WAV sections and frozen recording presentation; it does not open a microphone, capture the screen or launch the installed Preview. The 39-section checks verify the fixed capture row stays in place as the selected section changes, and that selection survives rendering and sheet dismissal. Settings, Sessions and Recently Deleted are real attached sheets; Return activates Done. Default content size is 1180 × 800 points; minimum is 1050 × 730 points.

Save-failure checks inject text and manifest write errors, remove/restore the synthetic manifest, and publish another metadata update through the real ordering path. They compare retained edits and original media bytes. This is not a claim that every asynchronous completion or hardware failure was exercised.

History checks use the actual AppModel and persisted StateStore in the native gallery. They preserve an edited draft, its original and selection; test Keep/Replace and both live-capture guards; and reopen the saved store. Delivery tests additionally restore an unresolved result, review its exact saved UUID without replacing the current draft, and verify that changed draft recovery never copies replacement words.

Read tests cover cancelled input, exact UTF-8 content, empty/whitespace/invalid/NUL input, character and byte limits, a directory, active playback, both decisions, Save audio admission and unchanged source bytes. Native file-panel interaction and physical audio output remain in combined installed acceptance.

Browser checks use the exported iframe, state adapter and scenario URL bridge. They exercise Stop, section selection and narration retention, Settings acknowledgement/dismissal, the History Sessions door, Read import Keep/Replace while playing and failure dismissal. All content is synthetic.

## Native renders

- [39 sections, default width](review-default-light.png)
- [39 sections, minimum width](review-narrow-light.png)
- [39 sections, minimum width, dark](review-narrow-dark.png)
- [Narrating with fixed Stop and save](recording-narrow-light.png)
- [Session settings](settings-narrow-light.png)
- [Sessions](sessions-narrow-light.png)
- [Transcription recovery](recovery-narrow-light.png)
- [Unavailable folder](unavailable-narrow-light.png)
- [Unsaved narration](unsaved-narrow-light.png)

## Integration boundary

The shared Preview remains owned by **Complete watchdog ship tasks**. Its owner reviewed the 39-section default/minimum native host renders and will verify installed scrolling, selection and save/recovery on the final combined build. Meeting recording playback/reveal, retained Snap editor state, Library image adapters, the History Sessions callback and the floating toolbar are integrated in their assigned worktrees. This branch supplies `ReadbackView.initialSheet: .sessions` for the History door.

The final receipt must identify Copy build details for the replacement Preview and separately record native permissions, physical capture/audio/receivers, independent jobs, keyboard and accessibility checks. Source tests, the synthetic study and these images do not establish installed or released acceptance.
