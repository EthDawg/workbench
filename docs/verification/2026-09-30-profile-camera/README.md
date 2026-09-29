# Profile camera repair · 30 September 2026

## Result and delivery

The repair replaces the separate ImageKit picture taker with an AVFoundation preview inside the existing profile sheet. Camera access remains explicit. Cancel and Choose photo stay available; the shutter waits for a real frame. A ten-second startup deadline and five-second frame/photo deadlines prevent an indefinite wait. Permission denial, restriction, missing devices and interrupted capture have their own recovery messages.

The camera connects video only. It keeps one frame in memory, stops before handing a photo to the existing appearance editor, and writes nothing until Use photo. A camera selection lasts for the visit; disconnect never silently switches sources. Request and deadline identities reject callbacks belonging to cancelled or older attempts.

Source branch: `codex/profile-camera`, based on PR #229 at `af19a8b32ac288595c96d0adbb7834d196162a14`. This record and its code belong to the same repair commit.

The integration chat owns the combined regression run, changes to PR #229, and the single signed Preview installation. This repair chat did not install, merge, notarize, publish or deploy. Shared Preview UI is free: the reproduction ended with Escape and left Home open.

## Installed reproduction

Copy build details identified the existing app as:

- Workbench Preview 2.3.1, build `20260929121540`.
- Source `bca3ecf1d7bbc0152f88c0dfb5083835189f8c85`; local development, modified source: no.
- macOS 26.5.1, build `25F80`.

Home → Your profile → Take photo reproduced the reported failure. No camera appeared; Done, Take photo, Choose photo, Edit appearance and Open Me in Persona were disabled, with Waiting for your photo still shown on a later inspection. Escape dismissed the profile and returned to Home. No saved profile was changed.

The old source called `IKPictureTaker.beginSheet` from an already presented profile and waited without a deadline. The exact internal ImageKit failure was not established; there were no matching camera/sheet errors in the bounded system-log query. The repair removes that failing presentation path rather than depending on its hidden state. Apple documents that [ordinary sheets may queue](https://developer.apple.com/documentation/appkit/nswindow/sheets) and that [capture startup belongs on a serial queue](https://developer.apple.com/documentation/avfoundation/avcapturesession).

## Checks actually run

| Check | Result |
| --- | --- |
| `WORKBENCH_LAYOUT_EVIDENCE=/private/tmp/workbench-profile-camera-renders bash scripts/test-stage.sh --profile-camera-only` | 12 tests, 124 assertions, no failures; complete StageKit compile, synthetic camera callbacks, actual frame conversion and profile hosting |
| `.build/WorkbenchStageTests --persona-creation-only` | 14 tests, 196 assertions, no failures; one optional editor render skipped |
| `.build/WorkbenchStageTests --persona-appearance-only` | 15 tests, 269 assertions, no failures; one optional appearance render skipped |
| `python3 scripts/check-surfaces.py` | 441 registered entries pass |
| `node --test site/tests/*.test.mjs` | 19 tests pass |
| `plutil -lint scripts/Info.plist` and `git diff --check` | Pass |

The camera tests cover permission cancellation and late approval, denied/restricted access, startup timeout and retry, stale frames and deadlines, double shutter, late photos after Cancel, source changes, disconnect, photo failure, pixel size/orientation, and switching the actual profile view between its content and camera without creating another sheet. Existing profile tests verify identity, group and original-artwork preservation, plus failed saves.

The backend’s Continuity Camera device-type declaration matches the macOS SDK’s `AVCaptureDevice.h` requirement. It adds no separate permission. Physical built-in, USB and Continuity cameras are not certified by the synthetic checks.

## Synthetic views

Twelve light/dark state renders were generated. The six representative views below contain no live camera image or private data. The live-state image deliberately has a black preview: it demonstrates controls and layout, not a working camera feed. All tested sheets fit within 470 × 580 points.

| State | View |
| --- | --- |
| Permission, light | [View](camera-permission-light.png) |
| Starting, dark | [View](camera-starting-dark.png) |
| Live controls, dark | [View](camera-live-dark.png) |
| Access denied, light | [View](camera-denied-light.png) |
| No camera, dark | [View](camera-unavailable-dark.png) |
| Timeout, light | [View](camera-timeout-light.png) |

## Remaining installed acceptance

After the combined signed install, verify Copy build details and test Take photo with an available camera, capture → appearance preview → Cancel, a deliberate Use photo save using synthetic artwork where practical, Escape, Choose photo recovery, camera access off, and disconnect/retry. Confirm the camera indicator ends and independent jobs remain intact. Check mirrored preview/photo agreement on the available hardware. Additional cameras, VoiceOver and receiver behavior remain unverified.
