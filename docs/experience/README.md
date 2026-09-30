# Workbench experience studies

Open [the shared entry](index.html), then choose Desktop or Floating pill. Each study has named, resettable scenarios. Its URL identifies the starting scenario, so a reviewer can repeat the same journey.

These are local interaction models using synthetic data. They run no microphone, provider, clipboard, native capture, installer or external handoff. The product contract remains [workbench.md](../workbench.md); agreed work remains in the repository's issues and PRs.

## What is implemented

The desktop candidate implements grouped navigation, visible Meetings, safe Home workspace doors, focused Dictate and Read pages, their settings sheets, and exact meeting-result review. [Candidate evidence](../verification/2026-09-30-desktop-cohesion/README.md) separates source checks, native renders and installed acceptance.

The desktop study also depicts existing Snap, Snap & Talk, Draw, Present, Persona, History and Library journeys in a simplified form. It models representative states and controls; it does not reproduce every native menu, permission flow, provider option or visual detail. Changing the study does not change the app.

The **Floating pill remains a tested interaction proposal**. Its removal of overflow controls and proposed homes for Keep open, live presentation adjustments and live Persona-copy controls are not implemented by the desktop candidate. The native quiet-feedback work is separately recorded in [#230's evidence](../verification/2026-09-30-quiet-toolbar/README.md). The pill's Timer detail view maps to the existing Draw/Timer controls and menu; there is no separate desktop Timer destination or eighth toolbar mode.

## Desktop scenarios and owners

| Starting scenarios | Native state owner | Boundary to preserve |
| --- | --- | --- |
| [Home](desktop.html#home), [independent work](desktop.html#independent-work) | `WorkbenchHome`, existing activity owners and History's recent projection | Opening a workspace starts nothing. Current work shows actual operations; unfinished retained audio stays with its recovery owner. |
| [Dictate preparation](desktop.html#dictate-ready), [continue](desktop.html#dictate-continue) | `AppModel`, `CaptureRecoveryStore`, `ContentView`, voice preferences | Drafts survive navigation. Settings has one entry sheet; dictionary remains its own subpage. Result feedback comes from the action that completed. |
| [Meetings preparation](desktop.html#meeting-ready), [recording](desktop.html#meeting-recording), [processing](desktop.html#meeting-processing) | `MeetingModel` | Choose a valid source, then start explicitly. Microphone-only selection enables the microphone. Timer and presentation remain independent. |
| [Meeting review](desktop.html#meeting-review), [recovery](desktop.html#meeting-recovery), [retained work](desktop.html#meeting-retained) | `MeetingModel`, committed transcript ID and typed `HistoryDoor` | Review the exact saved result. Failed or cancelled removal preserves it. Unfinished audio is recoverable; successful removal clears its stale completion link. |
| [Read import](desktop.html#read-import), [active reading](desktop.html#read-active) | `AppModel` reading import, playback and export owners | Keep current preserves text and playback. Replace is explicit. Import never starts playback. Sample save and Cancel illustrate operation outcomes only. |
| [Snap preparation](desktop.html#snap-ready), [review](desktop.html#snap-review) | `SnapModel`, image workspace and Snap History | Cancel creates no result. Drafts remain reviewable, and originals stay intact. |
| [Snap & Talk continuation](desktop.html#snap-talk-continue), [recovery](desktop.html#snap-talk-recovery) | Existing Readback session and capture owner | Navigation does not reload the session. Cancelling a capture preserves earlier captures and narration. |
| [Draw and Timer](desktop.html#draw-timer), [Present](desktop.html#present-active), [Persona](desktop.html#persona-ready) | Existing StageKit annotation, timer, presentation and Persona owners | Stop, hide and end affect their named operation. Browsing assets does not replace live work. |
| [Library reuse](desktop.html#library-reuse) and History through the sidebar | Existing saved resource, transcript, Snap and handoff owners | Reuse goes through the destination's current draft/selection rules. Completed results and reusable resources retain separate purposes. |

The desktop has 20 starting scenarios. The selector's State control can explore additional moments within each workspace. Reset scenario restores its synthetic starting data, including drafts, jobs and results. No state is copied between Desktop and Pill.

## Pill scenarios and action map

The [pill contract](pill-contract.json) records all 14 scenario IDs, 31 action-owner groups, checked journeys and limits. Useful starting points include [retained audio](pill.html#recovery-pending), [Meeting + Timer](pill.html#meeting-and-timer), [Present + Persona](pill.html#present-and-persona) and [hidden toolbar](pill.html#toolbar-hidden).

The imported proposal targets quiet-toolbar source `62f8ba5b9f41de7549d0877719baa89a402fdb34`, with installed-evidence correction `45276a6`. It names `MeetingModel` and the canonical Meetings page. Native pointer, VoiceOver, global shortcuts, device capture and real paste acceptance remain outside its browser evidence.

## Portable entry protocol

Both standalone files retain a sandboxed iframe and their local state adapter. They have a return link to this entry and require no build or external service.

- Desktop URL: `desktop.html#meeting-review`. Parent message: `{type: "wb:scenario", scenario: "meeting-review"}`. Selection event: `wb:scenario-changed` with `scenario`.
- Pill URL: `pill.html#recovery-pending`. Parent message: `{type: "workbench-pill-journey", id: "recovery-pending"}`. Selection event: `workbench-pill-scenario-changed` with `id`.
- The parent accepts selection events only from its own iframe. Changing the selector updates the portable URL. Reset stays on the same scenario.
- State is local to the study. The desktop ignores its own saved-state acknowledgement so an open sheet remains open; transient sheets are not restored after a reload.

If a browser blocks local-file previews, serve this repository's `docs` directory on loopback and open `/experience/index.html`. The Markdown contract links then resolve alongside the studies. No hosting or publication is required.

## Verification and provenance

The desktop worker checked all 20 scenarios at 1024, 736 and 320 pixels and the import, reuse, recovery and sample-save decisions. The integration owner replayed the exported study in the Codex browser, including its real state adapter and URL bridge. This caught and fixed a dialog-closing acknowledgement issue that standalone fragment checks had missed.

The pill owner checked its 14 scenarios and documented the limits in its contract. The integration owner independently replayed the portable recovery link, failed retry and Meeting + Timer path through the shared entry. These are browser checks of sample state.

The imported files preserve the final pill source hash in `sourceSHA256`; `sha256` identifies this repository's portable wrapper with its return link. Its source artifact was `workbench-live-pill.html`. The desktop source artifact was `desktop-journeys.html`, SHA-256 `c7dab6229a6379402a90a92350f6c9ecde6ff468f5d94c36f80e818de70b2fa4`; its exported wrapper is maintained here as `desktop.html`.

Source renders and the signed candidate package belong in the verification record. An interactive model or passing screenshot does not establish installed acceptance.
