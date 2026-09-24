# Contextual controls acceptance, 21 September 2026

Built on the compact-toolbar branch at `17fd38f`, including its docking, animation and explicit-collapse fixes. This change preserves that behavior and replaces the empty menu space with direct actions and contextual options. The separate focused StageKit contribution is committed as `8de0d66` on this branch.

Implementation: `f85fbcbdf30ef22a59f1d9c113ebbc11d7481604`. Signed local Preview build `20260921121123` was packaged from that source and installed. The existing signing identity and CloudKit provisioning profile were reused and validated; the installer retained a previous-app archive. All 98 saved application files matched their pre-install hashes before launch. The final installed-app UI inspection was blocked by the Mac lock screen; no automatic unlock was attempted after that result.

## Verified locally

- `bash scripts/test.sh`: complete Mac suite passed. Includes 107 package tests; 64 browser-extension tests; StageKit 142 tests / 2,875 assertions; provider, refinement, clipboard, keyboard, capture, reading and persistence checks.
- Capture persistence harness: 59 assertions against the exact AppModel capture methods, real temporary recovery files and injected recognition/delivery. New cases verify save before wait, retained original target, stale drawing callback rejection, one delivery/history item, Copy now and cancellation on Quit.
- Contextual controls: 23 checks for independent finish actions, microphone admission, narrower drawing admission and waiting-delivery resume/copy/cancel.
- Floating toolbar: 55 state/geometry/motion checks; final native fixture 38 checks, including content-fitted menu height, active finish actions without extra padded rows, hover/menu/drag behavior, docking, side orientation and interrupted capture transitions.
- StageKit contribution: three focused native tests / 47 assertions; included again in the complete StageKit suite. Independent guards, ink/board preservation, settled callbacks, denied board clicks and held-key re-registration were exercised.
- Website: eight tests passed. Product spec, guide and lifecycle contract updated in source.
- Production SwiftUI views rendered in disposable QA bundles in light and dark, with a synthetic three-capture session. Final inspection confirmed no six-dot idle grip, direct menu action rows, visible shortcuts/count and tighter toolbar geometry. See [the build handoff](../contextual-controls.md).

The native fixtures do not use the live microphone, user clipboard, user scene library or real phone. The running Preview was inspected as idle and quit before the full suite so it could not hold the exclusive shortcuts. Native screenshots are layout evidence, not proof of meeting-receiver output.

## Remaining acceptance

Run a real device scene with Mac dictation and held/toggle drawing, stopping voice before drawing and then changing the target field. Check original-target insertion/copy fallback and scene continuity. Repeat with Snap & Talk narration and denied permissions. Physical display changes, VoiceOver and meeting receiver output remain unverified. Grouped durable notes and their reuse in handoff are a separate increment. No public release, App Store submission or website deployment is implied by these checks.
