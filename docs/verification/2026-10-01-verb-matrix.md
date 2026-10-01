# Verb matrix — 1 October 2026

Where every verb can be found, started, controlled, recovered and finished, on every surface, for the 1 October candidate. It exists so the same requests stop coming back: each one is listed with where it now stands and who closes what is left. [Issue #134](https://github.com/EthDawg/workbench/issues/134) remains the acceptance record and GitHub the work queue.

## Revisions, owners and evidence

- **Candidate:** `d2a4235` (PR #232, installed as Preview `20260930225621`), plus the audit fixes on `claude/audit-fixes` (`d43369c`), plus this window pass on `claude/window-verbs`.
- **Owners on 1 October:**
  - Desktop window and this matrix: the "Verbs and experience ready to ship" session.
  - Floating toolbar and menu-bar panel for Snap, Snap & Talk, Draw and Present, plus launch readiness: "Workbench app launch readiness".
  - Persona and camera, Timer on every surface, Settings › Models, and Claude-side integration: "Codex preview code review and menu smoothing".
  - Preview installs: the Codex integration owner only.
- **Evidence levels:** S = source trace, R = registry (`docs/surfaces.json`, checked by `scripts/check-surfaces.py`), G = surface gallery render, A = automated check, N = installed native use. Nothing below claims N unless it says so.

## What keeps being asked, and where it stands

| Ask (first, then repeated) | Where it stands in the candidate | Evidence | Left, and who |
| --- | --- | --- | --- |
| Remove the pill's "…" (30 Sep, again 30 Sep 11:01: "still there") | Gone. Each tool keeps one contextual accessory; live work owns its own actions (`4355a71`, `47fc7b7`). | S, G (`toolbar-present-revealed`) | Ethan's eyes on the installed build. Toolbar owner. |
| Pill: no blur at rest, grow from the centre, steady tooltips, snap to edges, horizontal at top and bottom, vertical at the sides (29 Sep) | In (`bd6d2ba`, `4d485a4`, `9d78bad`). The drag clamp moves the pill once per event (`d002b07`). | S, G | Physical drag to every edge, on one and two displays (N). Toolbar owner. |
| The pill can be dropped off the screen; Persona can't be dragged (30 Sep 20:46) | Clamp before move (`d002b07`); a locked Persona keeps one move handle. | S, A | Physical drag (N). The handle shows in a full-display share (audit row 12). Persona owner. |
| Live webcam as a persona (30 Sep), reachable from the pill (1 Oct) | Webcam bubble in (`4b9a51b`); the missing-camera and End fixes in `f091bc0`. | S, A | Camera from the expanded pill. Persona owner. |
| Auto-paste fails in Sublime, Claude and ChatGPT (30 Sep) | Guarded paste with bounded AX reads and a quiet "Sent to" receipt (`1116a08`, `d002b07`). | S, A | Ethan's own ⌥V test in those three apps (N). Nobody else can type into them. |
| Dictate page and its options feel disorganised (30 Sep 07:57) | Page is microphone, transcript, Copy text and More. Options are one sheet with one label column: Delivery, Text style, Shortcut, Activation, Dictionary, Shortcuts app. Paste automatically says what happens before Accessibility is approved. | S, G (`page-dictate-state-options-focused`) | None. |
| Transcribe a meeting or call is hard to find (30 Sep 07:57) | Meetings is a sidebar page, a Home card and a Window menu door. Detect Meetings & Calls now lives on Meetings, not in Settings. | S, R, G | A real call with headphones has never been confirmed (N). |
| Home's retry banner can't be cleared (30 Sep 07:52) | Removed from Home (`be49223`); History keeps the transcripts. | S, G | None. |
| Collapsed sidebar needs tooltips; Voice, Screen and Saved headers; Home padding; smooth collapse (30 Sep) | In (`SidebarHintTarget`, `sidebarGroups`, `f1eadca`). | S, G (`page-home-hint-*`, `page-home-collapsed-*`) | None. |
| Snap hover should offer Region, Window and Screen (29 Sep) | In (`76a01ee`). | S, R | None. |
| One image workspace for viewing and editing (29 Sep) | In (`72ee015`, `aa0e626`). | S, G (`page-snap-workspace-*`) | None. |
| Take photo hangs (29 Sep) | Fixed (`4f2909d`). | S, A | None. |
| Timer feels like an afterthought (1 Oct) | Panel row, live strip, toolbar live controls and Break timer shortcut exist; no page by contract ("Timer remains within Draw and the quick controls"). | S, R | Consistency across surfaces. Timer owner. |
| Local model download visibility dropped (1 Oct) | Parakeet and Ollama setup rows survive in Settings › Models. Meetings and Home now have a Models… door. | S, R | Download progress and failure reasons. Models owner. |

## Where each verb is found and started

From the registry (R); default shortcuts from `VoicePreferences` and StageKit `Settings` (S). "—" means no entry on that surface.

| Verb | Home | Sidebar page | Window menu | Menu-bar panel | Floating toolbar | Default shortcut |
| --- | --- | --- | --- | --- | --- | --- |
| Dictate | Start here card | Dictate | Dictate | row | mode | ⌥V |
| Meetings (Dictate's workflow) | Start here card | Meetings | Meetings… | status row while recording or transcribing | Stop & transcribe while recording; Open Meetings… while busy or kept | — (an offer when Detect is on) |
| Read | — | Read | Read | row | mode | off, assignable |
| Snap | Start here card | Snap | Snap | row | mode, with Region, Window and Screen | off, assignable |
| Snap & Talk | Start here card | Snap & Talk | Snap & Talk | row | mode | ⌥C |
| Draw | — | Draw | Draw, plus the Draw tools menu | row | mode | ⌥D pen, ⌥A arrow, ⌥S box, ⌥Z undo, ⌥X clear |
| Present | — | Present | Present, plus Switch to… | row | mode | ⌥Q |
| Persona | Me profile | Persona | Persona | row | mode | ⌥F show or hide, ⌥R next |
| Timer | live strip only | — (inside Draw and quick controls) | — | row | live controls | off, Break timer assignable |

This pass added Dictate, Read, Snap, Draw and Present to the Window menu, so it now lists every sidebar page in the sidebar's order. Read, Snap and Timer shortcuts are opt-in on purpose: defaults cover only the presenter essentials.

## What this pass closed on the window

- **Meetings, audit row 1 (P2).** A recording that heard no speech, or was too short to hold any, is settled: shown once with its audio kept, Show in Finder and Move to Trash, and never offered for retry. It no longer stays "Unfinished" forever or hides older kept recordings. Each recording kept for later has its own Transcribe, Show in Finder and Move to Trash, and Transcribe acts on that row. Stop & keep for later is no longer shown as an error. (A: `--check-meetings`, the new check fails on the old rule; G: `page-meeting-state-kept`.)
- **Same action, same words.** A meeting's Stop is "Stop & transcribe" on the page, the panel and the toolbar. Its processing Cancel, which kept the audio, is "Stop processing". Dictate's in-recording Discard is "Cancel", the Grammar's word. Home's "Speech settings" is "Models…". (R, A: `ToolbarNextActionTests`.)
- **Read** shows the voice's quality and the free better-voices hint on the page, as the contract promises. Its one Cancel now also ends Save audio's export and removes a half-written file (audit row 6). (S, A: `test-reading-playback.py` 150, `--check-reading-cancellation`)
- **Refusals show where you acted** (audit row 7). A Dictate start the page's mic can't make is said in Dictate's banner. History's Open while Dictate is busy is said on History. (A: `test-capture-persistence.py` 172)
- **Settings › General** groups Keep open and Position under the Floating toolbar switch and uses switches throughout. (G)

## Native checks still owed

Each needs a person or the QA controller on the installed build:

1. ⌥V in Sublime, Claude and ChatGPT, twice each. Replace selected text, and change app during capture.
2. Drag the pill and a locked Persona to every edge, on one display and on two unequal displays.
3. Transcribe a real call with headphones, and a recording with nothing said.
4. Start the camera bubble while Zoom or Photo Booth is using the camera (audit hypothesis 9).
5. ⌘H during recording review (audit hypothesis 10).
6. A VoiceOver pass of the toolbar, panel and Meetings.

## Follow-ups for #134

- Read's panel row has no options, unlike every other row; the proposal is the voice with its quality, the better-voices hint, then Open Read….
- Dictate and Snap & Talk narration name their engine but have no Models… door.
- Home's Start here covers four of nine verbs. Read, Draw, Present and Persona start from their pages, the panel and the toolbar. Decide whether Home should offer them.
