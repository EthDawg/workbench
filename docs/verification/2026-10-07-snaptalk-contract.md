# Snap & Talk permission lifecycle and contained deck contract

Source checked **7 October 2026**: `6806e74371686a3c08ad23cc8b22dc282f1cb980`, based on accepted Meetings integration `d1943eeb74cc23aa273ad040757cdcba48b3f3f2` plus the isolated Meetings wording commit `7656fc8`. This is the bounded Foundation D source correction under [#63](https://github.com/Ship-Work/workbench/issues/63), not ST1 native or host acceptance.

## Change and preservation

The existing `ReadbackModel` owns one outstanding macOS capture-access request and its originating visit. Duplicate requests wait for that slot to settle. Cancel, page departure, close/reopen, session replacement, shutdown and newer passive checks invalidate permission feedback; a late result starts no capture or recognition. The uninterruptible OS prompt may still complete. The next passive check can observe its actual permission, and current completions reread both actual statuses. J's passive setup and Stop-first admission remain in place.

New neutral sessions freeze **1.1.0** in the existing skill receipt. Their skill, README and copied handoff instructions agree: look for an optional template only inside the session, ask before using it, otherwise make a plain deck; write a uniquely named new deck under `outputs/` and leave existing files unchanged. The skill asks for exact edited narration in notes, grounded visible copy, source revision hashes, explicit skipped sections, rendered verification and an honest output path/file return. No files are automatically uploaded, executed or imported into Workbench. Frozen neutral 1.0.0, legacy, private and customised sessions retain their original bytes and instructions; old exported recipes are not silently repaired. Session format remains 1, with no new manifest field or receipt store.

## Source checks actually run

- `swift build -c release --product LocalVoice`: final passing build **108.95 s** (first checkpoint build **117.79 s**).
- `LocalVoice --check-readback`: **117** store/prompt checks, **23** admission/delivery checks, **41** capture-choice checks, **66** held-permission checks, **19** availability checks, **18** recovery checks, **33** pack checks and **44** ordering checks.
- `LocalVoice --check-readback-pack`: **33** frozen-pack checks plus **43** Pack owner checks. The neutral-version regression retains exact old/custom skill, README, receipt, manifest and template bytes while creating a new 1.1.0 session.
- `LocalVoice --check-readback-resources`: actual resource resolver, exact payload bytes and reopened manifest passed. `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-readback-resources.py`: **9** synthetic CLI/app/relocated/missing-resource process checks passed.
- `python3 scripts/check-surfaces.py`: **629** entries passed unchanged; no control was added or renamed. `git diff --check` passed.
- `WORKBENCH_SNAPTALK_GALLERY_ONLY=1 LocalVoice --render-surfaces …`: **10** production-view renders, **0** flags, both themes, including minimum **1050 × 730** workspace, saved-section review, Settings, access off and a held access request. The selector reuses the existing gallery and synthetic session owner.

The held-reply cases cover current grant, denial, screen revocation during the wait, cancellation, task cancellation, close, switch, same-session reopening, shutdown, explicit Check and Settings return. They assert duplicate suppression, no late permission/notice publication into a newer visit, no capture or transcription, unchanged session bytes, and usable passive recheck afterward. The production manual handoff action also runs with both permissions off and still copies the new session's actual contract.

**Negative control:** removed only the generation/cancellation guard immediately after the microphone await, compiled that mutation (**110.31 s**), and ran the same production-owner checks. It exited 1 at `READBACK_CAPTURE_ACCESS_CHECK_FAILED: cancel: held old reply cannot publish into a later visit`. The exact passing source and executable were then restored and verified against their saved SHA-256 values; all eight Readback groups above passed again. No mutation remains in the committed source.

Local evidence uses `.build/snaptalk-contract-{final-build,final-checks,restored-checks,resources,surfaces,gallery-final,negative-build,negative-checks}.log`, `.build/snaptalk-contract-negative.patch`, `.build/snaptalk-contract-good.sha256`, and `.build/snaptalk-contract-gallery-final/manifest.json`. Checks use temporary synthetic stores and absolute temporary preference domains, with injected permission, capture, recognition, clipboard and host boundaries. No installed app, TCC setting, real recording/model/cache, user session or assistant provider was changed.

## Render review and remaining gates

[Waiting for the macOS access reply](2026-10-07-snaptalk-contract/access-pending-light.png) · [Saved work with capture access off](2026-10-07-snaptalk-contract/access-off-dark.png).

At the constrained window size, the pending explanation and disabled duplicate Request control remain readable; saved images, editable narration, Add from Snap History and Hand off remain available. These images are isolated source renders, not native permission-prompt acceptance.

**Still unverified:** signed-candidate permission/settings-return behavior and ST1 through an actual file-producing host: five synthetic sections, reorder and corrected narration, deliberate skip of an unfinished section, chosen-template and no-template paths, actual attachment/local-folder access, unchanged originals/template, unique usable file return, rendered deck readability and verbatim notes. The skill is an instruction contract, not an enforcing sandbox or a PPTX validator. This source change establishes neither host execution nor voluntary reuse/product demand; the existing [creation research](../research/creation-handoff-2026-10.md) retains those separate gates.
