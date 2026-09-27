# Capability Preview integration, 27 September 2026

This candidate addresses [issue #112](https://github.com/EthDawg/workbench/issues/112). It combines explicit meeting transcription, durable capture history and selections, standalone Snap and Persona surfaces, and optional subscription handoffs. Public Workbench 2.2.0 and its update feed are unchanged.

## Behavior and ownership

- Meeting detection starts off. An offer opens a review; it never begins recording. A person selects the Mac app and whether to include the microphone. Original audio and an interrupted draft remain recoverable. Retrying transcription updates the same capture identity.
- Transcript History retains older captures and keeps purpose, person, company and tags beside the original words. Named selections contain stable references. Editing an active selection does not silently replace a saved selection; Update is explicit.
- Snap owns its original images, editable crop and annotations. Shared selections and handoffs use the visible rendered crop. Snap & Talk can compose selected images with narration while retaining its existing portable session and skill contract.
- Persona owns reusable overlays; Present owns its compact control surface. These remain independently usable from voice capture.
- Connected handoffs are optional and use an installed, signed-in official CLI. The reviewed selection is frozen before dispatch, results and provider receipts persist, and Stop waits for the local child process to end. Unknown interrupted outcomes require an explicit retry. Copy instructions remains available.
- Suggested transcript details require review and explicit application. The proposal parser requires the complete typed response; malformed output cannot clear existing details. Reviewed changes retain the result receipt and recording limitations.

## Evidence already obtained

The combined release build passed. The repository suite passed 194 Swift package tests and 64 browser tests, plus the earlier Python and CLI checks, before reaching five Stage assertions blocked by the running Stable app's ownership of global shortcuts. Those five checks must be rerun with Stable closed; this is not a full-suite pass.

Focused checks passed for transcript handoff (129 contract and 11 runner checks), Readback packs (32), shared history (83), integrated handoff jobs (35), Snap (66), and meeting capture/recovery (72). The meeting checks include a synthetic recording longer than 30 minutes; no live audio devices were used.

The provider implementation passed 224 pure checks, 18 adapter checks, 13 process checks and 13 macOS sandbox checks. A descendant holding an inherited pipe was stopped in approximately 0.38 seconds. Real synthetic subscription requests returned the expected exact response and session receipt through both Codex and Claude Code. Credential files remained read-only. Codex uses its documented final-message file; progress text, missing replies and stale files cannot become the saved result. An independent nine-case check also verified the final-file boundary.

One real Codex task received 45 synthetic images through the shared handoff model. Independent checks matched every source's random visual marker, theme and statement to a separate answer key, verified every linked PNG against its original bytes, and reproduced the saved input digest. The answer-key CSV and marker text were absent from the non-image task inputs. This establishes image coverage and immutable source references for that fixture; it does not establish native selection or exclusion UI acceptance.

A real structured suggestion task returned the two explicitly named synthetic identities and a valid meeting purpose. Existing details stayed unchanged until explicit review. Reviewed details reopened with provenance and the original recording limitations, without changing either original or cleaned transcript wording. The strict parser refused an earlier overlong tag; the final prompt keeps capture warnings in their separate field and states the tag length limit.

## Remaining acceptance

At this checkpoint the Mac was locked. The new candidate had not been installed or verified with Copy build details. Native capture, editor scrolling and keyboard focus, mixed-selection review, excluded-image review, and installed lifecycle checks remain pending. Live remote-app audio, microphone balance, headphones and a routed phone call require actual receiver testing before those paths can be claimed.

Codex image tasks and Claude text tasks are verified. A bounded native Claude image route is being checked before the signed candidate is frozen; the UI currently explains the text-only limit and keeps the manual image handoff available.

Use the existing signed [Preview update workflow](../updating.md). Keep installed acceptance, merge and public release as separate states.
