# Independent desktop audit — 1 October 2026

An independent source and synthetic audit of the combined desktop/pill candidate, centred on the Persona webcam change. [Issue #134](https://github.com/EthDawg/workbench/issues/134) remains the acceptance record and GitHub remains the work queue; this file records coverage and evidence only.

## Revisions and evidence levels

- **Webcam change reviewed:** `4b9a51b` against its parent `26cbe4f`, then with follow-ups `5d1196d` and `147c63a`.
- **Audited candidate:** `f1eadca` on `codex/native-completion` (local to the integration owner; absent from `main` `b06fbaa`). It advanced during the audit, and every change was read before results were carried forward:
  - `d002b07`: guarded-paste receipt, bounded AX reads, clamp-before-move drag, persistent locked Persona handle.
  - `f45afab`: locked-movement hint, and a workspace-only rewording for a missing selected camera.
  - `d2a4235`: hidden or failed camera visits stay on Home's current work.
  All results below hold at `d2a4235`.
- **Fixes:** `f091bc0`, `e409652` and `d27a474` on `claude/audit-fixes`, based on `d2a4235`. Local and unpushed.
  - `f45afab`'s rewording covers only the workspace line; `f091bc0` also corrects the notice and menu text and stops the needless permission request and capture.
  - `d27a474` words the named failure so `f45afab`'s check passes too.
- **Evidence levels:** S = source trace; A = automated/synthetic execution; N = installed native execution.
- **Native (N) is blocked for this candidate.**
  - When the audit started, installed Preview was build `20260930130126` from `26cbe4f`, which predates the webcam; it was not running.
  - Mid-audit, the owner installed build `20260930224334` from `f45afab`. That build has the webcam but none of these fixes, and the owner was signing another build.
  - The integration owner holds the installed-Preview and UI slot.
  - The first native Start camera would raise a macOS camera permission request.
- **Hardware at audit time:** MacBook Air camera and a Continuity iPhone camera, lid open, one display, macOS 26.5.1 (25F80).
- **Delegation:** two read-only workers traced Dictate/Read/Meetings and Snap/Snap & Talk/Library. Every finding kept below was re-traced by the auditor.

## Findings

| # | Priority | Finding | Evidence | Status |
| --- | --- | --- | --- | --- |
| 1 | P2 | A meeting with no recognised speech is saved as a failure but never committed. It stays an "Unfinished recording" whose Retry repeats the failure, and has no Discard or Reveal. Each retry rewrites its manifest, so it stays newest and older kept recordings can no longer be retried from the app (`MeetingRecovery.swift:151-155`, `MeetingModels.swift:197`, `MeetingModel.swift:313`, `MeetingWorkspaceView.swift:125-131`). On `main` since `52bfbbb`. | S | **Fixed** `1844c50` on `claude/window-verbs`: a no-speech or too-short session is settled and shown once with Show in Finder and Move to Trash; Transcribe acts on its own row. The new check fails on the old rule. |
| 2 | P2 | Pause did not pause a reading while a meeting was busy. The meeting can start during playback (its admission checks `rendering`), and `listen()` then refused every door, so the reading kept playing into the meeting (`AppModel.swift:1179`). | S, A | **Fixed** `e409652`. The regression fails on the old `listen()`. |
| 3 | P2 | History's Hand off could package the open Snap & Talk session while it was transcribing or held an unsaved narration edit, contrary to workbench.md "Hand off waits…" (`HistorySelectionControls.swift:423,516,548`). | S, A | **Fixed** `e409652`. The helper regression fails when the helper never waits. The SwiftUI sheet wiring is source-reviewed only. |
| 4 | P3 | With the camera live, the End presentation overlays shortcut (custom assignment only) left the camera running and discarded the card the camera replaced (`AppCoordinator.swift:297`). | S, A | **Fixed** `f091bc0`, through `AppCoordinator.handleHotkey`. |
| 5 | P3 | After the chosen camera disappeared while hidden or failed, Show camera again and Try again asked for access, opened the missing ID and reported "No camera is available" beside a list offering another camera (`PersonaCamera.swift` `start`). | S, A | **Fixed** `f091bc0` and `d27a474`: the missing camera is named, and nothing is asked for or opened. |
| 6 | P3 | Every labelled reading Cancel does nothing while Save audio exports (`rendering` is true, the generation flag is false; `AppModel.swift:208`). | S, A | **Fixed** `7db81cf` on `claude/voice-p3-fixes`: one Cancel ends the export and removes a half-written file. The harness fails on the old guard. |
| 7 | P3 | A start refusal from the Dictate page mic, and History's Open while Dictate is busy, report only to Dictate's attention or recovery. The page the person is on shows nothing (`AppModel.swift:552,1022`, `Views.swift:295`). New in the candidate. | S, A | **Fixed** `6f4f9e3` on `claude/voice-p3-fixes`: each refusal is said on the page where it was clicked. The harness fails on the old code. |
| 8 | P3 | A Snap draft kept after Close disables Snap's Organise/Add to Snap & Talk/Archive without a reason. History's Edit… says "Save or discard the current Snap first" without the Review unfinished Snap that `snap.md` requires (`SnapModel.swift:120,403,501`, `SnapWorkspaceView.swift:185`). New in the candidate. | S | Open, Snap owner |
| 9 | Hypothesis | The camera refuses any device another app is using. macOS normally shares cameras, so this may block the bubble during a Zoom or Teams call, its main use. | S | Native check: start the bubble while Photo Booth or a call shows the camera. |
| 10 | Hypothesis | ⌘H (Hide Workbench) may not pause original-recording review, because pausing relies on window orderOut/close/miniaturize. | S | Native check: press ⌘H during review playback. |
| 11 | Hypothesis | `ToolbarDrag.bounded` clamps to the bounding box of overlapping displays, which includes dead space beside unequal displays. | S | Two-display drag check |
| 12 | Usability | The persistent locked move handle (`d002b07`) is visible in a whole-display share. `personas.md` line 84 still says handles leave with the pointer, while the new line 132 says one stays. | S | Decide and align the doc |

Recorded, not defects:
- Save & Copy of a reopened Snap returns to the capture's original app, as `snap.md` states.
- Resume after a text or voice change remakes audio from the start (usability).
- Meetings Stop/Cancel wording differs across surfaces (usability, on `main`).
- The ProfileCamera session changes `AVCaptureVideoPreviewLayer.session` on its capture queue. That is a threading risk worth watching in the native console, not a reproduced defect.

## Webcam coverage (S unless noted; A = `--persona-camera-only`, 14 tests, 210 assertions)

- **Pass:**
  - Choosing Camera starts nothing; Start is the only door (A).
  - Artwork stays up until the first frame (A).
  - Mirrored, cropped circle (S).
  - Move, resize and lock through the artwork window, with its own temporary placement (A).
  - Hide releases the camera and keeps its place; Show again uses the prepared camera (A).
  - End, Quit and sleep release the camera; sleep cancels permission and startup (A).
  - Late permission replies, frames, deadlines and old menu items are dropped by request and visit tokens (A).
  - Denied, restricted, busy, stalled, timed-out and disconnected cameras have contextual recovery with no silent fallback (A). The missing-camera case is now fixed.
  - A prepared set and the camera never share the slot, in either order (A).
  - Saved artwork, groups, the selection and the replaced card are preserved (A).
  - No microphone use, recording, photo save or network use (A, S).
  - Toolbar, panel and Home use the same camera projection, and stale Cancel and Hide are rejected. This is source-traced here; `WorkbenchControlChecks` covers it but was not rerun.
- **Not tested (N):** real permission prompt, first real frame, mirroring on screen, native drag/resize/lock and click-through, device disconnect, Continuity Camera, Present holding the same external camera, sleep/wake, receiver view.

## Baseline accounting at `d2a4235` (S unless noted)

**20 desktop scenarios:**
- Home: pass.
- Dictate preparation: finding 7.
- Dictate continuation: finding 7, otherwise pass.
- Meeting preparation, recording and processing: pass.
- Meeting review: pass, with hypothesis 10.
- Meeting recovery and Retained meeting: fail, finding 1.
- Read import: pass.
- Active reading: finding 2 fixed (A); finding 6 open.
- Snap preparation: pass.
- Snap review: finding 8.
- Snap & Talk continuation: pass.
- Snap & Talk recovery: finding 3 fixed (A).
- Draw and Timer, Present and Library reuse: pass at controller and model level.
- Persona: findings 4 and 5 fixed (A).
- Independent work: finding 2 fixed; finding 6 open.

**31 pill groups:**
- Pass: 2–5, 7–9, 11–14, 16, 18–22, 25 and 27.
- Not tested: 1 (switch tool) was not re-traced here; the owner's `ToolbarCore` tests cover it.
- 6: finding 2 fixed; finding 6 open.
- 10 passes at controller level; the Tools menu contents were not traced.
- Not tested: 15 is unchanged from `main`.
- 17: the Sublime prompt reason was fixed in `d002b07`; the external target was not traced.
- 23: finding 4 fixed.
- Not tested: 24 is unchanged in the candidate.
- 26: finding 1.
- 28 (drag) was rechecked at `d002b07`, with hypothesis 11.
- Not tested: 29–31 are unchanged since the 30 September receipt.

**Reopened #134 gates:**
- Sublime paste (`d002b07`): one paste, a quiet "Sent to" receipt, bounded AX reads, a scroll no longer invalidates, and Saved Prompts give the correct reason (S). The installed Sublime, Claude and ChatGPT receiver checks are not tested.
- Persona movement: handle hit area plus the persistent locked handle (S); native not tested.
- Pill placement: clamp before move, release clamps (S); native not tested.

## Checks run on `d27a474` (on `d2a4235`)

- `scripts/test-stage.sh --persona-camera-only`: 14 tests, 210 assertions, 0 failures. With the fixes reverted, the two new regressions fail 13 assertions.
- `scripts/test-reading-playback.py`: 145 checks. Its new meeting check fails on the old `listen()`.
- `LocalVoice --check-readback`: all suites OK, order checks 44. A never-waiting helper fails its new assertion.
- `scripts/check-surfaces.py`: 532 entries OK.
- `swift build`: passed.
- Not run: the full suite, galleries and `--check-floating-toolbar`. They open windows, need the owner's slot, or leak UUID preference plists (#128).
- `--check-readback` itself leaked 16 plists into `~/Library/Preferences` per run. They were removed after `cfprefsd` settled, which takes about 15 seconds.

## Native retest handoff (owner's slot, after installing a build containing `d27a474`)

1. Start the camera, then allow, deny and restrict access; confirm the artwork stays up until the first frame, the bubble is mirrored, and it moves, resizes, locks and passes clicks through.
2. Hide, Show again, End and Quit, each with the camera light observed. Sleep and wake.
3. Unplug the external or Continuity camera while the bubble is hidden, then choose Show again.
4. Start the bubble while Photo Booth or a call uses the camera (hypothesis 9).
5. Play a reading, start a meeting, then Pause from the pill.
6. Leave a Snap & Talk narration transcribing, then History → Hand off → Use the open session.
7. The Sublime, Claude and ChatGPT dictation receiver checks already in #134.
