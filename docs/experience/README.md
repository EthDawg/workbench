# Workbench experience studies

Open [the shared entry](index.html), then choose Desktop or Floating pill. Each study has named, resettable scenarios. Its URL identifies the starting scenario, so a reviewer can repeat the same journey.

These are local interaction models using synthetic data. They run no microphone, provider, clipboard, native capture, installer or external handoff. The product contract remains [workbench.md](../workbench.md); agreed work remains in the repository's issues and PRs.

## What is implemented

The desktop candidate implements grouped navigation, visible Meetings, safe Home workspace doors, focused Dictate and Read pages, their settings sheets, exact meeting-result review, and the focused Snap & Talk session workspace. [Initial candidate evidence](../verification/2026-09-30-desktop-cohesion/README.md) and the [Snap & Talk completion record](../verification/2026-09-30-snaptalk-cohesion/README.md) separate source checks, native renders and installed acceptance.

The desktop study also depicts existing Snap, Draw, Present, Persona, History and Library journeys in a simplified form. It models representative states and controls; it does not reproduce every native menu, permission flow, provider option or visual detail. Changing the study does not change the app.

The **Floating pill is being implemented and verified by its separate owner**. The imported study remains synthetic. Its removal of overflow controls and proposed homes for Keep open, live presentation adjustments and live Persona-copy controls are not part of this desktop branch and require the combined integration receipt. The native quiet-feedback work is separately recorded in [#230's evidence](../verification/2026-09-30-quiet-toolbar/README.md). The pill's Timer detail view maps to the existing Draw/Timer controls and menu; there is no separate desktop Timer destination or eighth toolbar mode.

## Desktop scenarios and owners

| Scenario | Native owner and implemented route | Final acceptance to record |
| --- | --- | --- |
| [Home](desktop.html#home) | `WorkbenchHome`: grouped sidebar, four safe workspace doors, current work and five recent results | Confirm spacing and navigation on combined Preview |
| [Dictate preparation](desktop.html#dictate-ready) | `ContentView` / `AppModel`: focused editor, one settings sheet, explicit capture | Settings doors, Done/Escape, original and draft retained |
| [Dictate continuation](desktop.html#dictate-continue) | `AppModel`: stop/cancel and retained capture; unfinished delivery has durable review/copy/dismiss controls | Capture and real receiver checks; History Open Keep/Replace decision |
| [Meeting preparation](desktop.html#meeting-ready) | `MeetingModel`: app audio or microphone-only; explicit Start | Native source choice and microphone-only admission |
| [Meeting recording](desktop.html#meeting-recording) | `MeetingModel` and independent StageKit timer | Stop/transcribe, Stop/keep, independent timer |
| [Meeting processing](desktop.html#meeting-processing) | `MeetingModel`: cancellable processing with retained recording | Final Preview processing/retry and retained audio |
| [Meeting review](desktop.html#meeting-review) | Exact committed `HistoryDoor`; recording playback/reveal being integrated by the ship owner | Combined History recording sheet and text export |
| [Meeting recovery](desktop.html#meeting-recovery) | `MeetingModel` / `MeetingStore` retry retained tracks | Real failed/cancelled path; no unrelated draft replacement |
| [Read import](desktop.html#read-import) | Bounded native UTF-8 file picker and `AppModel` import admission: Keep current or Replace reading, no automatic playback | Cancel/invalid/oversized input, active reading, both decisions and explicit Save audio guard tested |
| [Active reading](desktop.html#read-active) | `AppModel`: playback, pause/resume/seek, Save audio and cancellation | Voice & pace, audio output and sample-file save |
| [Snap preparation](desktop.html#snap-ready) | `SnapModel`: Region/Window/Screen, import, explicit capture | Cancel selection leaves no result |
| [Snap review](desktop.html#snap-review) | Shared image workspace: original, edit and Save & Copy | Explicit close/discard semantics being integrated by ship owner |
| [Snap & Talk continuation](desktop.html#snap-talk-continue) | `ReadbackModel` / `ReadbackView`: Sessions, fixed capture/Stop, selected section, Hand off | 39-section layout at minimum/default sizes, all capture sources, navigation preserves review |
| [Snap & Talk recovery](desktop.html#snap-talk-recovery) | Section owns retained audio/retry; failed narration saves retain the edit with retry/copy/discard | Failed save, background publication, close/reopen and exact original media preservation |
| [Draw and Timer](desktop.html#draw-timer) | StageKit drawing and timer owners | Drawing tools, countdown and independent stop; pill routes integrated separately |
| [Present](desktop.html#present-active) | StageKit scene and presentation owners | Device/reconnect, live controls, end one presentation; pill routes integrated separately |
| [Persona](desktop.html#persona-ready) | StageKit Persona owner: selected and shown are separate | Browse, show/hide, live-copy controls; pill routes integrated separately |
| [Retained meeting](desktop.html#meeting-retained) | Existing meeting recovery records | Relaunch/retry preserves the recording |
| [Independent work](desktop.html#independent-work) | Existing activity owners projected by Home | Navigation and Stop affect only the named operation |
| [Library reuse](desktop.html#library-reuse) | Existing resource owners, shared image preview and Read import admission | Select/reuse, Keep/Replace, original resource and current work preserved |

These rows account for all accepted study scenarios. The source tests and native renders below prove only their named checks. The ship owner records final combined installed acceptance against the exact replacement build. The baseline installed `57fa1ef` receipt does not cover this revision. Snap & Talk sessions remain portable folders reached through Sessions; their captured images enter Snap History. A manual assistant handoff does not automatically create a finished deck or a History result.

The desktop has 20 starting scenarios. The selector's State control can explore additional moments within each workspace. Reset scenario restores its synthetic starting data, including drafts, jobs and results. No state is copied between Desktop and Pill.

## Pill scenarios and action map

The [pill contract](pill-contract.json) records all 14 scenario IDs, 31 action-owner groups, checked journeys and limits. Useful starting points include [retained audio](pill.html#recovery-pending), [Meeting + Timer](pill.html#meeting-and-timer), [Present + Persona](pill.html#present-and-persona) and [hidden toolbar](pill.html#toolbar-hidden).

The imported proposal targets quiet-toolbar source `62f8ba5b9f41de7549d0877719baa89a402fdb34`, with installed-evidence correction `45276a6`. It names `MeetingModel` and the canonical Meetings page. Native pointer, VoiceOver, global shortcuts, device capture and real paste acceptance remain outside its browser evidence.

## Portable entry protocol

Both standalone files retain a sandboxed iframe and their local state adapter. They have a return link to this entry and require no app backend or build. The portable renderer loads three pinned libraries from `unpkg.com`, so its complete rendering depends on network access to that CDN. No sample content is sent to an app backend.

- Desktop URL: `desktop.html#meeting-review`. Parent message: `{type: "wb:scenario", scenario: "meeting-review"}`. Selection event: `wb:scenario-changed` with `scenario`.
- Pill URL: `pill.html#recovery-pending`. Parent message: `{type: "workbench-pill-journey", id: "recovery-pending"}`. Selection event: `workbench-pill-scenario-changed` with `id`.
- The parent accepts selection events only from its own iframe. Changing the selector updates the portable URL. Reset stays on the same scenario.
- State is local to the study. The desktop ignores its own saved-state acknowledgement so an open sheet remains open; transient sheets are not restored after a reload.

If a browser blocks local-file previews, serve this repository's `docs` directory on loopback and open `/experience/index.html`. The Markdown contract links then resolve alongside the studies. No hosting or publication is required.

## Verification and provenance

The desktop worker rechecked all 20 scenarios at 1024, 736 and 320 pixels after the Snap & Talk changes: 60 layouts, no horizontal clipping and no browser errors. Interaction checks cover fixed capture/Stop, section selection and narration preservation, Settings dismissal and saved-state acknowledgement, the History Sessions door, and Read import Keep/Replace while playing. Dismissing a reading error retains text and voice; Listen remains available while the conditional Retry action disappears. The integration owner replayed the exported study in the Codex browser, including its real state adapter and URL bridge. This caught and fixed a dialog-closing acknowledgement issue that standalone fragment checks had missed.

The pill owner checked its 14 scenarios and documented the limits in its contract. The integration owner independently replayed the portable recovery link, failed retry and Meeting + Timer path through the shared entry. These are browser checks of sample state.

The imported files preserve the final pill source hash in `sourceSHA256`; `sha256` identifies this repository's portable wrapper with its return link. Its source artifact was `workbench-live-pill.html`. The desktop source artifact was `desktop-journeys.html`, SHA-256 `d7a2d1c36bde86a6dac9dd01cb7791d493943827de349a129c04dbf11908d5f6`; its exported wrapper is maintained here as `desktop.html`.

Source renders and the signed candidate package belong in the verification record. An interactive model or passing screenshot does not establish installed acceptance.
