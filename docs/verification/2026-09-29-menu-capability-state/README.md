# Menu rows keep their own capability

Quality refinement for [#134](https://github.com/EthDawg/workbench/issues/134), based on `main` at `e698f53ddc55fbaed3b65497455fa2783e14c8f7`. This records the initial standalone evidence. [PR #214](https://github.com/EthDawg/workbench/pull/214) carries the current combined source and its fresh verification.

## Behavior

The menu is a capability index. Each row reads only its own state and dispatches the action it displayed. Drawing no longer makes every row say Stop drawing, and dictation no longer makes every row stop dictation. Present, Persona and Timer retain their independent endings. The floating toolbar keeps its existing global next-action priority.

New starts use the existing owner admission. Capture next respects audio and screen-capture admission, waiting actions stay disabled, and Show personas respects the prepared set's resume guard. Hiding a live card or set remains available. Home's existing Persona button uses the same enabled state and rechecks the rendered operation.

Rows retain their capability symbols; the existing accent marks their own live work. A button's identity follows its operation, and commit checks reject an operation that has ended or become unavailable. No new entry, preference, storage or background job was added.

## Initial checks run

On arm64 macOS 26.5.1 (25F80):

- `swift build --product LocalVoice -j 4` with `--disable-sandbox`, pinned dependencies and private scratch/cache/config/security directories: passed.
- `LocalVoice --check-floating-toolbar`: 152 control checks passed. The same command also passed 19 prompt insertion, 12 text delivery, 9 Accessibility setup and 36 prompt picker checks using injected effects and isolated pasteboards.
- `LocalVoice --render-surfaces`: 234 renders, 138 entries, zero flags. Each appearance ran in the gallery's temporary synthetic home.
- `python3 scripts/check-surfaces.py`: 406 entries passed.
- `node --test site/tests/build.test.mjs`: 3 tests passed.
- `git diff --check`: passed.

The control regressions cover combined live work, recording alongside those activities, disabled Capture next, meeting admission, processing/capture waits, prepared Persona resume admission, changed admission before commit, and obsolete Stop/Hide/End operations. They also assert that the toolbar still prioritises dictation and drawing globally.

## Reviewed renders

These are the production panel's rows with frozen synthetic StageKit facts. They verify labels, enabled appearance and layout without opening a live overlay, device scene or timer. Both appearances were visually inspected.

| State | Light | Dark |
| --- | --- | --- |
| Drawing, presenting, Persona and timer | [Render](panel-combined-live-light.png) | [Render](panel-combined-live-dark.png) |
| Dictating alongside those activities | [Render](panel-dictating-live-light.png) | [Render](panel-dictating-live-dark.png) |
| Hidden Persona set during dictation | [Render](panel-persona-hidden-busy-light.png) | [Render](panel-persona-hidden-busy-dark.png) |

## Limits and installed acceptance

This is source and synthetic render evidence. The installed Preview was not launched, quit, changed or installed. No global shortcut suite or real microphone, screen capture, device or receiver test ran. Existing stores and independent jobs retain their owners.

The stale-operation checks prove the admission guard. They do not prove a genuine held mouse-button sequence in SwiftUI. The integration owner still needs to confirm in the signed installed Preview that holding Stop, Hide or End while its operation completes, then releasing, cannot start new work. Verify the same transition from Home's Persona button, keyboard access, and that ending one live capability preserves the others. Copy build details must identify the accepted build.

## Earlier integration check

A temporary source combination of this implementation (`5aa24a8`), #211 at `c1d72fa`, and the hover correction #213 at `7e594ca` built successfully. Its focused suite passed **169 control checks plus the same 76 supporting checks**. Three extra assertions exercised delivery waiting on drawing: Dictate waits and is disabled, Draw offers Stop drawing, and the shared toolbar still offers its contextual Stop drawing. The standalone branch's 152 checks also passed after the final source adjustment.

At those inspected heads, source files merged automatically with #211. Two adjacent prose edits in `docs/workbench.md` and `site/guide/index.html` needed both paragraphs retained: this PR's own-capability menu behavior and #211's single-host voice behavior. One check introduced by #211 assumed the old menu behavior; the combined check asserted the three outcomes above. That exact resolution was used for the combined build and checks. #211's `waitingForDrawing` and timer transport facts were retained. No changes to #211 or the installed app were made by this verification.

## Current combined PR

PR #214 now includes the pill refinement from #213 (`ebd25b0`), this menu/Home refinement (`702911c`), and the landed voice/results host in main (`c3fff97`). It is the integration path for all three surfaces. The guide retains both the capability-specific menu description and the new pill identity, motion and shortcut hints. The state checks retain the contextual toolbar ending and the separate menu-row endings. No design choice remains open. Current build, surface and CI results are in the PR; the installed acceptance limits above still apply.
