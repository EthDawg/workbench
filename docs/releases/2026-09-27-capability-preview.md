# Capability Preview integration, 27 September 2026

This candidate addresses [issue #112](https://github.com/EthDawg/workbench/issues/112). It combines explicit meeting transcription, durable capture history and selections, standalone Snap and Persona surfaces, and optional subscription handoffs. Public Workbench 2.2.0 and its update feed are unchanged.

## Behavior and ownership

- Meeting detection starts off. An offer opens a review; it never begins recording. A person selects the Mac app and whether to include the microphone. Original audio and an interrupted draft remain recoverable. Retrying transcription updates the same capture identity.
- Transcript History retains older captures and keeps purpose, person, company and tags beside the original words. Named selections contain stable references. Editing an active selection does not silently replace a saved selection; Update is explicit.
- Snap owns its original images, editable crop and annotations. Shared selections and handoffs use the visible rendered crop. Snap & Talk can compose selected images with narration while retaining its existing portable session and skill contract.
- A named Snap selection keeps one current review document as its members change. Synthesis can explicitly include the previous document as reference, while each task keeps immutable inputs and its original reply. A result cannot overwrite a document edited while it ran; deliberately replacing the current review retains a copy of the intervening edits. Suggested names and exclusions never change the sources automatically.
- Persona owns reusable overlays; Present owns its compact control surface. These remain independently usable from voice capture.
- Connected handoffs are optional and use an installed, signed-in official CLI. The reviewed selection is frozen before dispatch, results and provider receipts persist, and Stop waits for the local child process to end. Unknown interrupted outcomes require an explicit retry. Copy instructions remains available.
- Connection setup preserves the open handoff draft. A saved Ready job can start after a provider is connected. Archived or missing Snaps can be deliberately excluded without clearing other selected evidence; changing a saved selection still requires Update.
- Suggested transcript details require review and explicit application. The proposal parser requires the complete typed response; malformed output cannot clear existing details. Reviewed changes retain the result receipt and recording limitations.

## Evidence already obtained

The combined release build passed. The repository suite passed 194 Swift package tests and 64 browser tests, plus its preceding Python and CLI checks. Its first Stage run hit five shortcut assertions while Stable owned the global shortcuts. After quitting Stable through the normal UI, the complete Stage suite passed 162 tests and 3,337 assertions. Subsequent focused checks below cover the remaining capability checks; the new combined head still requires its CI run.

Focused checks passed for transcript handoff (129 contract and 11 runner checks), Readback packs (32), shared history (83), integrated handoff jobs (53), Snap (66), and meeting capture/recovery (72). The handoff checks exercise named-review continuity, immutable replies, inline and reference-style source links, changed-document protection and explicit replacement recovery. The meeting checks include a synthetic recording longer than 30 minutes; no live audio devices were used.

The provider implementation passed 252 pure checks, 18 adapter checks, 18 process checks and 17 macOS sandbox checks. A descendant holding an inherited pipe was stopped in approximately 0.36 seconds. The first CI run exposed an inactivity ordering defect: after a scheduling delay, queued progress could be declared inactive before being read. The correction drains bounded queued output first, while retaining the independent overall deadline and quiet-process cutoff. An independent before/after fixture reproduces the old failure and verifies the correction. A fresh combined-head CI run is still required.

Real synthetic subscription requests returned the expected exact response and session receipt through both Codex and Claude Code. Credential files remained read-only. Codex uses its documented final-message file; progress text, missing replies and stale files cannot become the saved result. An independent nine-case check also verified the final-file boundary.

One real Codex task received 45 synthetic images through the shared handoff model. Independent checks matched every source's random visual marker, theme and statement to a separate answer key, verified every linked PNG against its original bytes, and reproduced the saved input digest. The answer-key CSV and marker text were absent from the non-image task inputs. This establishes image coverage and immutable source references for that fixture; it does not establish native selection or exclusion UI acceptance.

One real Claude Code task received two synthetic PNGs through the restricted native stream-input route. Independent visual and byte checks verified the selected images, their order, printed random markers, complete response and session receipt. Answers were absent from the task text and file paths. The route limits input to 20 images, 3.75 MiB per image, 16 MiB of image bytes and 24 MiB of serialized request data. The live proof covers these two PNGs, not every format or the full batch ceiling.

A real structured suggestion task returned the two explicitly named synthetic identities and a valid meeting purpose. Existing details stayed unchanged until explicit review. Reviewed details reopened with provenance and the original recording limitations, without changing either original or cleaned transcript wording. The strict parser refused an earlier overlong tag; the final prompt keeps capture warnings in their separate field and states the tag length limit.

## Remaining acceptance

At this source checkpoint the new candidate had not been installed or verified with Copy build details. The Mac became accessible and Stable was quit normally for source verification. Native capture, editor scrolling and keyboard focus, mixed-selection review, excluded-image review, and installed lifecycle checks remain pending. The handoff review now keeps its header and actions outside one scrolling body, capped to the current screen's visible height; native focus and small-screen acceptance remain required. Live remote-app audio, microphone balance, headphones and a routed phone call require actual receiver testing before those paths can be claimed.

The review and saved-job start controls apply each provider's image limits. The complete manual handoff remains available for larger selections and file-producing skills.

Use the existing signed [Preview update workflow](../updating.md). Keep installed acceptance, merge and public release as separate states.
