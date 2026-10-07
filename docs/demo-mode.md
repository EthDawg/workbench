# Demo mode: Preview 1.4

**Superseded · 6 October 2026.** This record of the 9 and 10 September device stage is history. [Phone presenting](phone-presenting.md) now owns how Present finds, shows and explains the phone: the Present page shows it before Present is pressed, every surface shows one status with one next step, and one help sheet replaces the route guide. The desktop wallpaper apply described below has no door in the app; Restore desktop remains for recovery records written by earlier versions. The [rebuild ledger](research/2026-10-06-present-rebuild.md) records what was removed and why.

## Presenter polish checked on 10 September 2026

The editor now keeps the scene, size and branding together. Detailed layout
controls sit under **Adjust layout**; secondary outputs sit under **More**.
**Maximise** raises the size limit from 96% to 100% of the stage height without
clipping the outer border. Existing scene sizes are preserved. Logo import
accepts WebP and other supported raster formats, and **Paste logo** accepts
copied image data or a Finder image file. Imported artwork becomes a local PNG;
only completely transparent outer padding is removed.

Validation: `zsh scripts/test.zsh --scenes-only` passed 25 tests and 739
assertions, including real WebP decoding, alpha, orientation, clipboard data,
library persistence, frame edges, exported pixels and live-layer geometry.
The accompanying 11 Python release/install tests passed. Universal Preview
builds passed for Apple Silicon and Intel; the App Store configuration compiled.

Native Preview checks covered the actual downloaded `Rippling.webp`, Finder
copy/paste, saved-logo previews, a full-height stage, Escape returning to the
editor, PNG export, and renaming under an active search before Start/Export.
The final editor keeps the title and logo controls visible at its initial
window size. Control–Option–P opened it successfully with Preview running alone.
Temporary test catalogue entries were removed, and all six original scenes and
three original saved logos matched the pre-test records. The installed binary
and metadata were checked against the signed Preview archive. A pre-change
rollback archive is retained in `build/Before-presenter-polish-20260910.zip`.

The saved phone source was disconnected during this pass, so physical live
capture and cable recovery were not retested. Existing hardware acceptance
limits below still apply. Browser orchestration, team synchronization and X-Ray
remain concepts described in [presenter-direction.md](presenter-direction.md).

## Earlier device-stage validation

Installed Preview and native QA handoff, 9 September 2026. The user authorised
foreground testing after development. The connected iPhone path now has native
evidence; the remaining hardware and wallpaper edge cases are listed below.

## Product flow

1. Choose a saved customer scene or one of the eight existing starter backdrops.
2. Reuse a saved logo or create a simple text wordmark. Adjust the device shape
   only when needed; save a preferred shape for future scenes.
3. Start demo. StageMark hides its editor and opens a native full-screen stage.
   Its public AppKit window gets a full-screen Space; it does not create or
   manipulate ordinary desktops through private APIs.
4. Connect an unlocked, trusted iPhone or iPad by USB. A sole screen source can
   be selected automatically; ambiguous sources require a choice. The selected
   device is remembered. Source switching, disconnect/replug, runtime errors,
   wake and explicit Reconnect all preserve that identity.
5. End stops capture, releases the idle-sleep assertion, closes the stage and
   returns to the editor. Escape closes open controls first; when controls are
   closed it ends the presentation. The stage never changes wallpaper.

The phone/chevron tile starts collapsed at the right edge centre. Click or
Command-Slash opens Source / Reconnect / Position / End controls. Hover does not
reveal them. Drag toward an edge centre or corner to snap, or use Position.
Command-R reconnects even while controls are collapsed. Only video is connected; there is no recording
output, audio connection, upload or remote control. A stalled feed is hidden
after five seconds without new frames, with recovery controls shown. A locked
device may still emit valid black frames, so there is no claim to detect every
lock or freeze automatically. Capture runs on a serial background queue; the
GPU preview layer displays frames directly, with low-frequency health and size
updates to SwiftUI. Failed connection attempts use bounded backoff.

The active demo prevents idle system/display sleep, not an explicit lock or
security policy. End, close, fullscreen exit and teardown release the assertion.
This cannot keep the connected phone itself unlocked.

## Composition and saved data

The editor, PNG export and live stage share one device geometry. Screen aspect,
border thickness and inner corner radius determine the outer border; no fake
notch or Dynamic Island is drawn. Match device proportions uses live source dimensions;
disabling it retains the saved geometry and letterboxes as needed. Scene layers
are backdrop, optional hand, frame/live viewport and logo, in that order.

Hands are optional, genuine-alpha hand-only PNGs, kept at their original aspect
ratio. Size, position, flip and gentle tonal controls are supported. Raster hands
do not anatomically reshape to every device width; substantially different shapes
may need realignment or a different cutout. No hand image is included in this
release. The user's reference pictures are not bundled assets.

Each image is copied locally. `scenes.json` remains the source of customer layouts.
Optional viewport/hand fields preserve old archive decoding. `my-device.json`
stores the reusable device shape. `saved-logos.json` indexes locally retained logo
files: existing scene logos are adopted once, byte-identical imports deduplicate,
and removing a library entry never removes an existing scene's artwork.
`starter-preferences.json` holds only starter order, aliases and visibility.
Restore defaults cannot reset customer scenes. Corrupt catalog files are preserved
and blocked from writes. No source PNG is altered by gallery organization.

Legacy wallpaper apply/restore remains available. Recovery entries are separate
picture chains rather than a single slot per physical monitor. Applying in a new
Space preserves the former Space's chain; restoring the current picture retains
unmatched chains. macOS readback must confirm a change before it is reported as
successful. Users revisit other affected Spaces themselves; manual wallpaper
changes are not overwritten. Dynamic wallpaper schedules are outside this scope.

## Why this approach

Automating QuickTime device menus, window placement and arbitrary Spaces would
add fragile third-party UI dependencies to the core path. A native full-screen
window and an AVFoundation preview keep the scene and video geometry together.
QuickTime remains a manual fallback, not an automation claimed by this build.

Apple references consulted on 9 September 2026:

- [Native full-screen window lifecycle](https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/FullScreenApp/FullScreenApp.html)
- [QuickTime's documented device-recording workflow](https://support.apple.com/en-au/guide/quicktime-player/qtp356b55534/mac)
- [CoreMediaIO screen-device exposure](https://developer.apple.com/documentation/coremediaio/kcmiohardwarepropertyallowscreencapturedevices)
- [AVFoundation capture setup](https://developer.apple.com/documentation/avfoundation/capture-setup)
- [Capture devices](https://developer.apple.com/documentation/avfoundation/avcapturedevice)

The SharePad author's [design notes](https://github.com/jonyardley/SharePad/blob/main/DESIGN.md)
helped identify USB-screen discovery and sandbox risks. No implementation code
was copied. The direct build uses Apple's public frameworks and a camera
entitlement under hardened runtime. First-use camera authorization is expected;
the absence of an unintended microphone prompt requires hardware verification.

Live capture and desktop switching are hidden in the App Store edition until
its sandbox path is accepted on hardware. Scene editing/export compile with
`APP_STORE`. Android needs a compatible external video source; direct Android
USB mirroring, AirPlay and device control are not implemented. Intel compilation
is verified; physical Intel hardware remains untested.

## Verified build and native acceptance

- `zsh scripts/test.zsh --scenes-only`: 19 tests, 504 assertions, zero failures;
  plus 11 release/updater tests. The background suite uses isolated fixtures.
- `swift build --scratch-path .build/scene-store-check --disable-sandbox -Xswiftc -DAPP_STORE`:
  successful conditional Store compilation after the native QA fixes.
- Final Preview **1.4.0 build 20260909121035** is installed in
  `~/Applications/Workbench StageMark Preview.app`. Its executable matches the
  signed `build/Workbench StageMark Preview.zip` exactly. The extracted package
  passed strict signature verification with normal macOS signing access,
  Preview identity, camera entitlement, arm64/x86_64 and all eight PNG hashes.
- ZIP: 21,866,963 bytes; SHA-256
  `0db444b404295e3140198db701488504c9f9c40ac80c831e82d4ce95b1a78187`.

Native checks passed on this Mac:

1. The connected iPhone appeared directly in the full-screen stage, with readable,
   non-mirrored video, one device border, matching corners and no synthetic island.
   A text logo displayed independently above the scene.
2. Repeated Start/Escape returned to the editor. Source selection showed the
   remembered iPhone. Both the Reconnect button and Command-R rebuilt the feed
   and returned to live video.
3. `pmset -g assertions` showed StageMark's idle display/system assertions during
   the stage and none after Escape. No wallpaper apply/restore operation was run
   in this native session; the existing recovery journal stayed unchanged.
4. Previously imported logos were adopted, reused and retained after app updates.
   A temporary native text logo was created, exported and removed from the library
   while its temporary scene kept the image.
5. The native export panel produced a 2940 × 1912 PNG in the local QA directory.
6. Starter rename, reorder and hide were verified by UI and saved-file readback.
   Restore defaults returned the original eight choices. Customer-scene reorder
   and removal also worked. Tablet and landscape frame presets rendered correctly.
7. The production copy was quit, without uninstalling or replacing it. After
   restarting Preview, the conflict notice disappeared and Control-Option-P opened
   the scene editor. Preview was left open and foreground control handed back.

All four original customer IDs and their order remain. Saved boards and the
legacy wallpaper recovery journal are semantically unchanged. Temporary QA scene
and logo entries are removed; starter preferences are back at defaults. The latest
BaptistCare frame placement from the shared-control interval was retained. A full
pre-session Preview-data snapshot and the earlier 1.3 ZIP remain locally under
`.build/native-demo-qa-20260909/`. No production binary or data was edited.

Detailed local evidence: `.build/native-demo-qa-20260909/native-qa-result.json`.
The native menu automation occasionally timed out; a one-second process sample
showed normal AppKit menu event tracking, not an app deadlock. Escape dismissed
that menu and testing continued. Live phone screenshots were not committed.

## Remaining checks

- Physical cable unplug/replug, device lock/unlock and wake recovery. Programmatic
  reconnect and model identity/stale-frame cases passed; they are not substitutes
  for these hardware scenarios.
- Actual iPad capture/rotation, competing video apps and multiple source devices.
- Permission-denied flow and an explicit audit for unintended microphone prompts.
- Apply phone/tablet wallpapers in two Spaces on one monitor, relaunch and restore
  each from its own Space; preserve a later manual wallpaper. Model recovery tests
  passed, but this exact native multi-Space sequence is still pending.
- The user's future hand cutouts, physical Intel hardware and App Store sandbox
  capture acceptance.

Keep this in Preview while those edge cases are assessed. There is no automatic
production promotion, public release, notarisation submission or Store upload.
