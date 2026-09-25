# Optional ServiceNow Snap & Talk skill pack · 25 September 2026

This native Mac increment adapts Matt's branding contribution (`2172ab0`) into an optional pack. The neutral skill remains the initial default and retains the existing `template.pptx` route. At native-pack commit `aa13521`, all eleven ServiceNow payload files were moved byte-for-byte into `Sources/LocalVoice/Resources/build-snap-and-talk-deck/packs/servicenow-employee-experience/1.0.0/`; no supplied assets, helper contracts or font references were removed. A coordinated rendering follow-up clarifies the pack skill's deliberate Arial default, optional verified brand-font mode and visible-copy fit requirement; original branding assets remain intact.

## App flow and ownership

Snap & Talk has a **New session style** picker and **Install ServiceNow pack** action. Installation copies the complete bundled pack into the edition's existing application-support owner, under `SnapTalkSkillPacks`, and selects ServiceNow for future sessions. The selection uses the model's injected preferences and survives reopening. The app neither installs Python dependencies nor executes scripts, registers skills with another application, uploads data or submits an agent prompt.

Every new session receives a private copy of its selected skill payload. `skill-pack.json` is its sole durable pack-provenance record: format version, pack ID, pack version and display name. `session.json` retains its existing schema; the model's pack property is derived from the companion when loading. Consequently an older Workbench version can edit and save the session without erasing pack identity. Opening old or customised sessions never adds, replaces or migrates their skills.

Installed-pack checks validate the complete file list and recorded SHA-256 digests. An explicit reinstall repairs or replaces only the app-owned installed copy. Removing that copy preserves every existing session. If ServiceNow remains explicitly selected but its pack is missing or invalid, new-session creation explains how to reinstall or choose Neutral and stops before creating files. Neutral resource resolution does not depend on any ServiceNow asset. Existing Hand off uses the session's own `SKILL.md` and complete payload; the user still grants the chosen agent folder access and submits the prompt.

## Verification

- Full Mac debug `LocalVoice` build passed. A cloned dependency cache was reused; its path-specific module cache was rebuilt. No dependency versions changed.
- The full debug executable's `--check-readback` passed **178 checks**: 73 storage/contract, 11 admission, 19 availability, 18 recovery, 32 pack and 25 ordering checks.
- Pack checks use disposable preferences and folders. They cover neutral defaults, one-action installation and persistent selection, all eleven private snapshot files, pack ID/version, complete preservation across reinstall/style changes/removal, explicit unavailable-pack refusal, intact capture order and edited notes, changed installed-payload detection and repair, the original Codable manifest writer editing a new branded session, and unchanged legacy/custom sessions without provenance.
- The debug executable's `--check-readback-resources` passed with neutral-only resource requirements.
- `scripts/test-readback-resources.py` passed **11 actual-store process checks** across CLI, production and Preview bundle layouts, relocation, incomplete optional assets and missing neutral resources. A missing ServiceNow asset still permits neutral creation; incomplete packs fail before installation.
- The existing **8 synthetic deck-helper tests** passed from the relocated pack using the bundled workspace Python runtime. No dependencies were installed by this work. A byte comparison confirmed the eleven payload files match Matt's contribution and the neutral skill matches `main` at `c413668`.
- `git diff --check` passed.

This is source, resource and synthetic model evidence. No app was signed, installed, opened through LaunchServices or published by this task. Native control layout/VoiceOver acceptance and final released-package acceptance belong to integration. Deck rendering and any narrowly demonstrated helper/layout fixes are recorded by the separate rendering review; these test results do not assert ServiceNow-font fidelity or visual approval.

## Integrated rendering checks

The rendering follow-up preserves Matt’s five artwork files and original commit ancestry. It corrects the overlapping cover title/subtitle geometry, adds a conservative pre-output text-fit check and deliberately encodes Arial for portable output. Explicit brand-font mode keeps the original ServiceNow typeface names. The updated helper suite passes 11 tests, including wide-glyph overflow rejection, long worded copy and font mode.

All ten final synthetic slides were rendered with the bundled LibreOffice runtime and inspected by both the rendering worker and integration owner: three representative 16:9, 4:3 and portrait captures, plus seven slides with maximum supported worded copy and optional cover/divider/summary/closing. Screenshots retain all four corners, proportions and original bytes; capture order and complete edited notes match. No clipping, footer collision or text overlap was visible. The renderer used Liberation Sans for the deliberately encoded Arial. Native PowerPoint and ServiceNow-font fidelity are not asserted.

The guide now documents the one-click employee installation and existing Hand off flow. Final package gates also execute the real pack store/model checks in temporary preferences and session folders, so a package cannot pass solely because neutral resources were included.
