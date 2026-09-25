# Optional ServiceNow Snap & Talk skill pack · 25 September 2026

This native Mac increment adapts Matt's branding contribution (`2172ab0`) into an optional pack. The neutral skill remains the initial default and retains the existing `template.pptx` route. At native-pack commit `aa13521`, all eleven ServiceNow payload files were moved byte-for-byte into `Sources/LocalVoice/Resources/build-snap-and-talk-deck/packs/servicenow-employee-experience/1.0.0/`; no supplied assets, helper contracts or font references were removed. A coordinated rendering follow-up clarifies the pack skill's deliberate Arial default, optional verified brand-font mode and visible-copy fit requirement; original branding assets remain intact.

## App flow and ownership

Snap & Talk has a **New session style** picker and **Install ServiceNow pack** action. Installation copies the complete bundled pack into the edition's existing application-support owner, under `SnapTalkSkillPacks`, and selects ServiceNow for future sessions. The selection uses the model's injected preferences and survives reopening. The app neither installs Python dependencies nor executes scripts, registers skills with another application, uploads data or submits an agent prompt.

Every new session receives a private copy of its selected skill payload. `skill-pack.json` is its sole durable pack-provenance record: format version, pack ID, pack version and display name. `session.json` retains its existing schema; the model's pack property is derived from the companion when loading. Consequently an older Workbench version can edit and save the session without erasing pack identity. Opening old or customised sessions never adds, replaces or migrates their skills.

Installed-pack checks validate the complete file list and recorded SHA-256 digests. An explicit reinstall repairs or replaces only the app-owned installed copy. Removing that copy preserves every existing session. If ServiceNow remains explicitly selected but its pack is missing or invalid, new-session creation explains how to reinstall or choose Neutral and stops before creating files. Neutral resource resolution does not depend on any ServiceNow asset. Existing Hand off uses the session's own `SKILL.md` and complete payload; the user still grants the chosen agent folder access and submits the prompt.

## Initial model and resource checks

- Full Mac debug `LocalVoice` build passed. A cloned dependency cache was reused; its path-specific module cache was rebuilt. No dependency versions changed.
- The full debug executable's `--check-readback` passed **178 checks**: 73 storage/contract, 11 admission, 19 availability, 18 recovery, 32 pack and 25 ordering checks.
- Pack checks use disposable preferences and folders. They cover neutral defaults, one-action installation and persistent selection, all eleven private snapshot files, pack ID/version, complete preservation across reinstall/style changes/removal, explicit unavailable-pack refusal, intact capture order and edited notes, changed installed-payload detection and repair, the original Codable manifest writer editing a new branded session, and unchanged legacy/custom sessions without provenance.
- The debug executable's `--check-readback-resources` passed with neutral-only resource requirements.
- `scripts/test-readback-resources.py` passed **11 actual-store process checks** across CLI, production and Preview bundle layouts, relocation, incomplete optional assets and missing neutral resources. A missing ServiceNow asset still permits neutral creation; incomplete packs fail before installation.
- The existing **8 synthetic deck-helper tests** passed from the relocated pack using the bundled workspace Python runtime. No dependencies were installed by this work. A byte comparison confirmed the eleven payload files match Matt's contribution and the neutral skill matches `main` at `c413668`.
- `git diff --check` passed.

These initial worker checks establish source, resource and synthetic model behavior. They did not include signing, installation, LaunchServices or publication. Integrated rendering and native acceptance are recorded separately below; no ServiceNow-font fidelity or VoiceOver coverage is implied.

## Integrated rendering checks

The rendering follow-up preserves Matt’s five artwork files and original commit ancestry. It corrects the overlapping cover title/subtitle geometry, adds a conservative pre-output text-fit check and deliberately encodes Arial for portable output. Explicit brand-font mode keeps the original ServiceNow typeface names. The updated helper suite passes 11 tests, including wide-glyph overflow rejection, long worded copy and font mode.

All ten final synthetic slides were rendered with the bundled LibreOffice runtime and inspected by both the rendering worker and integration owner: three representative 16:9, 4:3 and portrait captures, plus seven slides with maximum supported worded copy and optional cover/divider/summary/closing. Screenshots retain all four corners, proportions and original bytes; capture order and complete edited notes match. No clipping, footer collision or text overlap was visible. The renderer used Liberation Sans for the deliberately encoded Arial. Native PowerPoint and ServiceNow-font fidelity are not asserted.

The guide now documents the one-click employee installation and existing Hand off flow. Final package gates also execute the real pack store/model checks in temporary preferences and session folders, so a package cannot pass solely because neutral resources were included.

## Integrated native and release acceptance

Signed Preview `2.1.0 (20260925062649)`, clean source `83fe3c07cb48073ae87a49667f9b13445d5bbc2a`, passed native Neutral creation, one-click ServiceNow installation, complete eleven-file branded session creation, relaunch persistence, removal/reinstall recovery and the existing Codex Hand off flow. Each session retained its own files throughout. The handoff copied a prompt and opened the selected agent; no prompt was submitted and no session was uploaded. Original Recents and all four original core saved records were preserved after removing only the synthetic test entries.

The combined signed Preview `2.1.0 (20260925064621)`, clean source `e09b5bd2d11b88a07354f26e87f345fb593dc869`, also passed native shortcut migration, rejected Command-Q as a global assignment, and preserved ordinary TextEdit Save/Close/Quit and Workbench Quit. The release-only input fixture correction in #107 passed from the actual packaged executable.

Production package `2.1.0 (20260925071655)` is built from clean merged source `b0ec3daa90fbe0924ba107f33a3a89641e335a66`. The full release suite passed: 177 Swift tests, 157 StageKit tests / 3,091 assertions, 30 cross-module migration checks, packaged input registration, synthetic speech round-trip, Snap & Talk checks and native reading-service checks. Apple notarization, stapling, Gatekeeper, final ZIP re-extraction, actual session creation and all 32 pack checks passed. SHA-256: `18090fa32bee5c240a352c94093a7c881bea133f8f9f617a2cb62ba4618a8276`.

The [2.1.0 release notes](https://github.com/EthDawg/workbench/releases/tag/v2.1.0) record acceptance of that exact installed production package and the public update cycle. The signed feed and website record promote the same archive. Fresh-Mac, older-macOS, hardware/meeting-receiver and native PowerPoint checks remain outside this evidence.
