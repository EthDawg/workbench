# Snap & Talk folder availability · 24 September 2026

The model publishes read-only availability for recent and selected session paths. The view checks every two seconds while mounted, and activation checks again. Unavailable current sessions show recovery actions instead of stale section cards. Locate validates the selected session's identity, while Remove from Recents changes preferences only. Recording controls and independent jobs keep their existing owners. New capture reloads the manifest after its asynchronous screenshot and creates only the leaf section directory, without recreating missing parent folders.

Validation on `fix/snap-talk-missing-folders`:

- Full Mac debug build passed with the pinned FluidAudio version. The existing cached NemoTextProcessing archive was reused after verifying its SHA-256 against the package manifest; no dependency versions changed.
- `LocalVoice --check-readback`: 72 storage/contract checks, 11 admission checks, 19 new availability checks and 25 ordering checks passed (127 total).
- New checks use disposable synthetic sessions: folder move/return, missing/restored manifest, unavailable capture/handoff rejection, no parent recreation, wrong-session locate rejection, valid relinking, unchanged original manifest bytes, forgetting without deletion, persisted recents and relaunch. Directory-hinted and ordinary file URLs resolve to the same path key; the first run exposed that mismatch and the corrected rerun passed.
- Eight site tests, static site build and `git diff --check` passed.

This is source/build and automated model evidence. Physical Finder interaction, a disconnected external/network drive, cloud-provider placeholders, VoiceOver and live microphone removal/recovery have not been verified in an installed package. No signed installation, public binary or release is included. The two-second refresh is scoped to the mounted workspace, not a background filesystem index or automatic move search.
