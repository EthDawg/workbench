# Snap & Talk folder availability · 24 September 2026

The model publishes read-only availability for recent and selected session paths. The view checks every two seconds while mounted, and activation checks again. Unavailable current sessions show recovery actions instead of stale section cards. Locate validates the selected session's identity, while Remove from Recents changes preferences only. Recording controls and independent jobs keep their existing owners. New capture reloads the manifest after its asynchronous screenshot and creates only the leaf section directory, without recreating missing parent folders.

Validation on `fix/snap-talk-missing-folders`:

- Full Mac debug build passed with the pinned FluidAudio version. The existing cached NemoTextProcessing archive was reused after verifying its SHA-256 against the package manifest; no dependency versions changed.
- `LocalVoice --check-readback`: 72 storage/contract checks, 11 admission checks, 19 new availability checks and 25 ordering checks passed (127 total).
- New checks use disposable synthetic sessions: folder move/return, missing/restored manifest, unavailable capture/handoff rejection, no parent recreation, wrong-session locate rejection, valid relinking, unchanged original manifest bytes, forgetting without deletion, persisted recents and relaunch. Directory-hinted and ordinary file URLs resolve to the same path key; the first run exposed that mismatch and the corrected rerun passed.
- Eight site tests, static site build and `git diff --check` passed.

This is source/build and automated model evidence. Physical Finder interaction, a disconnected external/network drive, cloud-provider placeholders, VoiceOver and live microphone removal/recovery have not been verified in an installed package. No signed installation, public binary or release is included. The two-second refresh is scoped to the mounted workspace, not a background filesystem index or automatic move search.

## Integration recovery checks

Review found two gaps: replacing a folder between refreshes could leave the old session visible and permit handoff to the replacement; recognition that finished while its folder was absent could remain queued indefinitely after reconnection. Current-session checks now verify the saved UUID even if no refresh observed the missing interval. Returning the matching folder reconciles interrupted work and resumes saved audio, while preserving sections still owned by a recording or recognition operation. Job identity uses a standardized path and section UUID so equivalent URL spellings cannot queue the same live job twice.

Focused verification compiled the production model and availability/recovery code with Swift 6 and ran the exact checked-in admission, availability and recovery suites in a disposable native harness: **11 admission, 19 availability and 18 recovery checks passed (48 total)**. Recognition was injected and controlled; preferences, folders and audio bytes were synthetic. The checks cover same-path UUID replacement without an observed absence, replacement bytes remaining intact, one active and one queued job completing during absence, reconnection and committed results, original audio preservation, a still-active worker reconnecting without duplication, and recognition completing after Remove from Recents. Recording ownership was checked through the reconciliation policy without opening the microphone.

This focused run does not replace the integrated app build, full regression suite or installed-package acceptance. Physical drive/cloud behaviour, microphone recovery and native recovery controls retain the limits above.
