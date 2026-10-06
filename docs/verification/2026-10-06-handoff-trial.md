# Handoff trial · 6 October 2026

This sanitized record preserves the result of a synthetic engineering trial and a native Preview inspection. It supports the [creation/handoff decisions](../research/creation-handoff-2026-10.md); it is not a user study, provider comparison or claim of arbitrary-file support.

## Protocol and result

Four fresh native Codex workers received one task and one route each, with the same inherited model/tools. Each produced a first result and one correction. One reviewer graded eight anonymized outputs against a predeclared rubric; structural references could reveal the route, so this was not fully blinded. The parent independently checked a disputed image finding and source integrity. Workers did not browse, use the desktop, contact external providers or inspect another run.

| Task | Shared evidence | Same correction applied to both routes |
| --- | --- | --- |
| Narrated walkthrough → decision brief | Three screenshots, paired narration and source index | Update delivery counts and one owner/date, retaining unrelated commitments. |
| Presentation/rehearsal → critique | Four-slide editable PPTX, slide PNGs, notes/text, synthetic transcript and source index | Correct a response-time observation to 25%; remove an unsupported productivity/causality claim. |

The direct route received ordinary files; the portable route received byte-identical evidence plus a manually assembled current-format session and skill. Both already had prepared derivatives and source mapping. No actual audio/video was supplied, and synthetic timestamps were passage anchors rather than measured speaking times. The package construction does not demonstrate an app importer.

| Route | Walkthrough first / revised | Presentation first / revised |
| --- | --- | --- |
| Ordinary files | 100 / 100 | 100 / 100 |
| Portable session | 100 / 100 | 100 / 84 |

These are rubric scores, not accuracy percentages. The predeclared portable-route threshold was a ten-point mean improvement with no hard failures or correction regression. It was not met. Because the direct scores reached the ceiling, the rubric could not detect a positive advantage; this result cannot reject a benefit in preparation or reuse.

All corrections propagated. One portable revision falsely said slide 2 lacked a title, although the image plainly contained it. That is a material error in one run, not evidence that packaging caused it. An initial review also penalized a statement supported by omitted request metadata; supplying that evidence corrected its score. The original and corrected grading records were retained.

All **38** output source links resolved, **79** input/correction files matched the integrity snapshot, and all eight outputs were retained. The trial used synthetic content. Raw fixtures, output wording, protocol, original/corrected scores and integrity receipts remain in the local ignored evidence folder `.build/handoff-comparison-20261006`; they are not published here and are not available to a fresh clone.

## Native evidence and the repair it exposed

The baseline app's native Copy build details reported **Preview 2.4.1, build 20261006020537**, clean source `76e49ac54126c9c5dbf8db33ce722364ebf3c978`, macOS **26.5.1 (25F80)**. Relevant handoff files matched the then-current main source. A three-section synthetic session preserved image/narration pairs in review. Copy instructions created a Ready job without running a provider; its three frozen images matched the fixtures. Existing user work was restored and the synthetic job retained outside live History after quitting.

The copied prompt requested documents in `outputs/` but used `inputs/` source links. From those documents the links point to a nonexistent `outputs/inputs/`. [PR #272](https://github.com/Ship-Work/workbench/pull/272) repaired manual guidance to `../inputs/` and documented the nested-output case. Connected root-level `result.md` retains its existing links. Frozen records and originals are unchanged.

Source commit `d2677d8c565aa9aa01c50e29376ef8e109a77395` passed a release build, **164** handoff checks, **129** transcript-handoff checks, **11** runner checks and the **563**-entry surface registry. Independent review found no actionable issue. All eight [PR checks](https://github.com/Ship-Work/workbench/actions/runs/37411186112) and all eight [merge-group checks](https://github.com/Ship-Work/workbench/actions/runs/37414274872) passed. The repair merged at `c7947a51080ee36255efadbf8dca152c41ded638`.

The shared integration owner installed signed **Preview 2.4.1, build 20261006051135** from that clean source. The parent independently verified bundle metadata and full code signature using normal macOS security services; a restricted-environment signature check had failed and both outcomes were retained. Installed handoff checks passed **164**. **Native Copy build details and repaired Copy instructions acceptance remain pending because the Mac was locked.** The earlier native observation establishes baseline behavior only. No public package/feed was promoted.

After unlock, the integration owner should verify the running build, copy instructions from the synthetic session, resolve its relative source links and nested-path example against frozen files, restore original work and retain only the synthetic evidence. Do not start a provider merely to verify copied instructions. Broader [issue #63](https://github.com/Ship-Work/workbench/issues/63) remains open for template/output/host acceptance.

## What would improve the evidence

Start with a real person's unprepared material and a creation request. Compare the ordinary assistant route with capture-and-explain, including gathering, attachment, review and one correction. Observe preparation effort, repeated explanation, source confusion and voluntary reuse. Do not prepare both routes' source maps in advance. Actual vocal-delivery feedback additionally requires audio/video and clear separation of observed, heard and inferred evidence.

This trial did not test human preparation time, voluntary reuse, Claude/ChatGPT UI interaction, physical capture, provider execution, arbitrary inputs, rich artifact return or a signed old-to-new app update.
