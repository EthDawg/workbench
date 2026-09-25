# Snap & Talk ServiceNow deck pack · 25 September 2026

Scope: integrate the supplied ServiceNow Employee Experience branding and local PowerPoint builder into newly created Snap & Talk sessions. Built from main `2140acb` with the resource-resolution prerequisite from PR #103 (`da8ebe2`). The contribution's commit/PR identifies the final source revision. No app installation or publication took place.

## Payload and preservation

The pack contains eleven files: the updated skill, dependency list, brand geometry, five original raster brand assets and three local Python helpers. Real-session screenshots, sample outline and personal glossary corrections from the attachment are excluded from distribution. No fonts are supplied. Branding assets are retained as supplied; screenshot rendering preserves original image bytes and all corners rather than converting to lossy JPEG or masking edges.

The native store preflights the complete explicit payload before creating a session, then copies files with mode 0600 and private directories. Existing sessions and custom skills are not rewritten. No dependency installation, helper execution or upload happens inside Workbench. New deck outputs refuse overwriting existing files.

The supplied editorial automation was adapted to the existing product contract: no automatic false-start deletion, desktop-capture rejection, screenshot substitution, resequencing or cleaned speaker notes. Covers/dividers/summary/closing are optional; the default remains one slide per eligible capture. Visible copy is concise and notes preserve edited narration exactly.

## Evidence

- Swift debug build passed with the worktree-local module caches and existing dependency cache.
- `LocalVoice --check-readback`: 145 checks passed (72 store, 11 admission, 19 availability, 18 recovery, 25 ordering). Two brittle skill-phrase assertions now verify identity and exact complete copied payload instead.
- `LocalVoice --check-readback-resources`: passed for the full debug executable. This is a CLI smoke check, not an installed app acceptance claim.
- `python3 scripts/test-readback-resources.py`: 11 process checks passed, compiling the actual store/resolver into disposable CLI, production-layout and Preview-layout fixtures. Checks include relocation, missing brand asset, missing skill/bundle, exact payload bytes, private permissions and retaining a custom skill on reopen.
- `python3 scripts/test-snap-talk-deck.py` with the pack dependencies: 8 tests passed. Synthetic sessions cover complete image bytes, aspect ratio/crop, exact multiline notes, visible copy, sequence, short/repeated/non-16:9 captures, excluded inputs, path/symlink refusal, overwrite refusal, optional extra slides and invalid formats. Added a separate CI job for these portable helpers.
- Skill-creator `quick_validate.py`: passed in an isolated YAML-enabled environment.
- Website tests: all 16 passed. `git diff --check`: passed.

## Limits

No real user session was modified. No signed package, install, merge, feed promotion or website deployment is implied. The supplied reference design and background were inspected, but generated slides were not visually rendered or checked in desktop PowerPoint in this change. The receiving agent must still render the final deck and inspect every slide, especially font substitution and longer copy. The full unrelated Mac suite was not rerun; focused checks above are the evidence for this contribution.
