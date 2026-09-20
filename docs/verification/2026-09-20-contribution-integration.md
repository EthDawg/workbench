# Contribution integration, 20 September 2026

## Scope and provenance

Integration preserves the original commit histories from PRs #32, #33, #34, #35, #36, #39 and Matt's #40–48. The branch is `integrate/september-contributions`. Public Preview 3 remains unchanged. Issue #17 has no submitted implementation and is outside this candidate.

The integration resolves shared-source conflicts in persona failure handling, native test dispatch, Quick Look and Chrome library ownership, reading cancellation and voice selection, and shared shortcut registration. Chrome Switch to retains internal shortcut ID 4; Snap & Talk uses ID 5, with separate persisted preference fields. Focused tests cover preservation through encode/decode.

## Validation

Validation is in progress. Final checked source, automated results, packaged identity and native acceptance will be recorded here before delivery. Earlier PR descriptions remain historical evidence, not proof that the combined candidate passes.

## Remaining physical acceptance

Use the [candidate checklist](../releases/2026-09-20-integration-preview.md). A fresh Mac, real microphone/screen permissions, actual Speko synthesis, physical phone and display reconnection, VoiceOver, and receiving meeting views require explicit acceptance. Synthetic fixtures contain no customer content and do not change the user's desktop picture or production data.
