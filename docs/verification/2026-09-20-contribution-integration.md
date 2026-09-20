# Contribution integration, 20 September 2026

## Scope and provenance

Integration preserves the original commit histories from PRs #32, #33, #34, #35, #36, #39 and Matt's #40–48. The branch is `integrate/september-contributions`. Public Preview 3 remains unchanged. Issue #17 has no submitted implementation and is outside this candidate.

The integration resolves shared-source conflicts in persona failure handling, native test dispatch, Quick Look and Chrome library ownership, reading cancellation and voice selection, and shared shortcut registration. Chrome Switch to retains internal shortcut ID 4; Snap & Talk uses ID 5, with separate persisted preference fields. Focused tests cover preservation through encode/decode.

## Validation

The combined Mac source at `86a1dc7` passed `bash scripts/test.sh`: 105 Swift package tests, 127 StageKit tests with 2,672 assertions, 72 Snap & Talk checks, 64 browser-extension tests, provider/refinement transport tests, bounded Speko catalogue transport tests, and the release/persistence regression checks. Website tests (8) and the static site build passed. The Mac CI job also passed on that revision.

Native checks on this Mac passed timer placement (11 assertions) and Screenshot recovery/preserved ink (20 assertions). These use synthetic state and injected Screenshot launch outcomes; they do not prove a real screen capture or a physical display reconnection.

The Developer ID signed Preview built from that revision passed its core and Chrome protocol checks, a synthetic Mac-voice-to-local-recognition round trip, M4A export/retranscription, and native Quick Look for text, PNG and PDF. Quick Look's Escape and Home hide/close/minimize paths each released access while preserving source bytes and selection. The input check exposed an obsolete four-shortcut expectation; the integration updates it to require exactly IDs 1–5.

The initial combined CI run passed all three jobs: Mac, iPhone and iPad ([run 35490992876](https://github.com/EthDawg/workbench/actions/runs/35490992876)). A local iPhone run nevertheless reproduced rapid text insertion moving inside the old draft after cleanup. Commit `41687ce` restores the native state binding and retires Undo after the text change, with a guard against stale Undo. The four unchanged focused cleanup/input UI tests passed on both iPhone and iPad, including bulk insertion, returning to identical text, save/reopen and preserved Original. The updated input check also passed exclusive registration, conflict reporting and release for all five Mac shortcuts.

Commit `629748e` closes a further cross-feature admission gap: Dictate is blocked during Snap & Talk screenshot capture, and narration/redo recheck admission before recording or replacing files. The 72 session-store checks and 11 new actual-model admission checks passed with isolated preferences and injected captures. Early/late refusal and a session closing during capture preserve the complete synthetic session byte for byte. No microphone or screen permission was requested by these fixtures.

## Review findings addressed

| PR | Correction and evidence |
| --- | --- |
| #40 | Validate exact section directories, reject symlinks, reload the manifest after capture, and restore prior narration on cancelled rerecord. 72 synthetic session checks. |
| #41 | Disambiguate same-formatted-time history labels without speaking transcript content. Same-time and subsecond fixtures. |
| #43 | Clear failed-export feedback after a successful write. Persistence/export checks. |
| #45 | Remove the bypassing shortcut claim; reveal a failed launch while preserving ink. 20 native assertions. |
| #46 | Enforce 2 MiB during receipt and stop at 20 pages. Production transport exercised with synthetic URLProtocol fixtures, including cancellation and redirect refusal. |
| #47 | Close Quick Look when Home hides, closes or minimizes. Three packaged native previews plus all owner lifecycle paths. |
| #48 | Apply timer snapping after drag release and record its capability/acceptance in the canonical handbook contract. 19 pure and 11 native placement assertions. |

The integration also separates Chrome's shortcut ID 4 from Snap & Talk's ID 5 and tests independent preference persistence. Bounded workers supplied the session-storage, Speko-transport and native-lifecycle fixes; the integrator reviewed and reran the combined checks above.

## Installed candidate and rollback

The initial signed candidate used Preview identity `com.ethdawg.workbench.preview`, version 2.0.0 and the existing Production iCloud profile. Installation preserved all 70 recorded saved-data files byte for byte. A private data backup and the previous signed app archive were retained. This is a local testing build, not a notarized public download. Signing/profile checks do not establish an actual two-device iCloud transfer.

The maintainer retains local package receipts with the exact source commit, bundle version/build, archive SHA-256, signature/profile checks and rollback. The final combined CI and packaged acceptance are recorded on [integration PR #49](https://github.com/EthDawg/workbench/pull/49). Earlier PR descriptions remain historical evidence, not proof that the combined candidate passes.

## Remaining physical acceptance

Use the [candidate checklist](../releases/2026-09-20-integration-preview.md). A fresh Mac, real microphone/screen permissions, actual Speko synthesis, physical phone and display reconnection, VoiceOver, and receiving meeting views require explicit acceptance. Synthetic fixtures contain no customer content and do not change the user's desktop picture or production data.
