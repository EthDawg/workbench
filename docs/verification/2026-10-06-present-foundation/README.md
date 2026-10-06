# Present: your phone on a clean stage — 6 October 2026

Branch `claude/present-foundation` from `main` 7989426b41f84afaf8e38bf57ae4b2a68935aacb; the PR names the head revision. Refs #276 (the design record and ledger) and #7 (the batch claim). Every image is a source render of production SwiftUI/AppKit views with synthetic state: the Present page and the stage content from `WORKBENCH_LAYOUT_EVIDENCE=<folder> .build/WorkbenchStageTests --persona-workspace-only` with `PhoneLinkMonitor.fixture` pinned per state, in an isolated scene root with one synthetic customer scene and persona. No capture session runs offscreen (the page's canvas reports visibility only from a window whose occlusion state is visible), no permission is asked, and none of these is a screenshot of an installed build.

## What changed, by surface

- **The Present page** ([no phone](present-phone-none.png), [phone on USB](present-phone-on-usb.png), [two screens](present-phone-choose.png), [video restricted](present-phone-restricted.png), [narrow window](present-narrow.png)): the scene list on the left; the preview on the right is the stage itself, with the phone's one status inside the device frame where the phone will appear, and the same words under the preview with the one next step, Reconnect where looking again can change something, and Can’t see your phone?. One **Present** button (Show presentation while one runs) and an **Options** menu (Start full screen, Export image…). Scene options (device frame and size, logo, backdrop zoom, device shape, position, hand cutout) fold under the preview. Gone from the page: Connection & audio…, Full screen and Window as two buttons, More, Use as desktop, Use as animated desktop, Gentle motion and its Pause/Play, the desktop motion controls, Switch to Browser Tab…. Restore desktop stays, only while a recovery journal from an earlier version exists.
- **The stage** ([no phone](stage-phone-none.png), [two screens](stage-phone-choose.png)): the device frame says what is true and the next step until the phone is live; the edge tile and its click-only controls stay (status, next step, Reconnect where it helps, Source… only with more than one screen, Position, End). The source sheet is "Which screen?" with the list, Match device proportions and Look again; the route guide is gone from it.
- **The Present menu** (panel Options, the pill's View menu, the live settings on the page): the status as a note, the next step, Source with more than one screen, Reconnect where it helps, Can’t See Your Phone?…, Show Presentation Window, Full Screen, Window Size, Window Position, End Presentation. Gone: Source & Connection Help…, Match Device Proportions, End Preview & Open QuickTime Player / iPhone Mirroring, Pause/Play Background Motion.
- **Can’t see your phone?** is one sheet (`PhoneConnectionHelp`): the live status, the three checks that happen away from Workbench (data cable; unlock and Trust; allow the accessory on this Mac, or IT's USB policy on a managed Mac), *Check in QuickTime Player* (ends a running presentation's capture first), the two ways in a call when this Mac cannot receive the phone (Zoom's cable share on the Mac; sharing from the phone's own Teams or Zoom), Apple's iPhone Mirroring as one line with its same-Apple-Account condition, and *Copy connection details* (facts with no identifiers; Copied shows for four seconds).

- **The whole window** ([no phone, light](page-present-state-no-phone-light.png) and [dark](page-present-state-no-phone-dark.png), [phone on USB](page-present-state-phone-on-usb-light.png), [video restricted](page-present-state-restricted-light.png)): from `LocalVoice --render-surfaces`, the production window with the sidebar, the new summary "Your phone on a clean stage, for calls and demos.", Saved Prompts… as the only button above the page, and the page in each pinned state on a synthetic "Customer demo" scene imported as a scene file (the bare gallery binary carries no bundled starters). The gallery reads the status back and fails if the page's words differ from the pinned signals or a notice shows.
- **Home's live row** reads "Presenting · " and the phone's status while a presentation shows a phone (`PhoneLinkObserver` in `WorkbenchHome.swift`); it needs a live presentation, so it is not pictured.
- **The receipt**: `LocalVoice --phone-link NEW_FOLDER [SECONDS]` ran at 4 s and 8 s on this Mac (no phone attached): exit 0, `phone-link.txt` and `receipt.json` written with "No phone on USB" and access not asked yet; an existing folder, 0 seconds and a missing folder argument each fail with a message and write nothing. The receipt reads its final facts before the bus watch stops.

## The words

`PhoneLink.status` is the only place the words live. Every row below is a test in `Tests/StageKitLegacy/PhoneLinkTests.swift`.

| Signals | Title | Next step |
| --- | --- | --- |
| Nothing on USB, no screen | No phone on USB | none (Can’t see your phone?) |
| iPhone on the bus, no screen | iPhone connected, screen not available yet | Reconnect as a nudge |
| One phone screen, nothing remembered | Connecting to iPhone… (the capture adopts and remembers it) | none |
| One plain video device | Capture card found | Show Capture card |
| Two screens | 2 screens available | Choose screen… |
| Remembered phone away, another screen present | Waiting for your remembered iPhone | Choose screen… |
| Session live | Showing iPhone | none |
| No frames for 5 s | iPhone stopped sending its picture | Reconnect |
| Session interrupted or the phone unplugged | iPhone disconnected (Phone disconnected with nothing on the bus) | Reconnect |
| Session could not start | Another app is using the iPhone’s screen | Reconnect |
| Camera access denied | Workbench can’t use device video | Open Camera settings |
| Camera access restricted by policy | Device video is restricted on this Mac | none, ask IT |

## Validation on this revision

- `bash scripts/test-stage.sh --ci` equivalent (the same compile and `--ci` run): **280 tests · 5925 assertions · 0 failures** with the two exclusive-shortcut checks skipped while the installed Workbench Preview held ⌥D–⌥R. A later run on the same sources failed one unrelated assertion, `TimerTransportTests` "The control takes the keyboard", while another worktree's `--render-surfaces` pass was taking key windows on this Mac; the rerun with nothing else rendering is recorded in the PR.
- `--persona-workspace-only` with `WORKBENCH_LAYOUT_EVIDENCE`: 6 tests · 262 assertions · 0 failures, which also holds `DemoScenesLayout.previewSize` to half the editor height.
- `LocalVoice --render-surfaces`: **SURFACE_GALLERY_OK: 332 renders, 162 entries, 0 flags** on the window side's binary (two runs, Present PNGs byte-identical). `python3 scripts/check-surfaces.py`: **Surface registry OK: 558 entries** (two Present menu entries classified, ten removed doors dropped; a sidebar entry re-sorted). `bash scripts/test.sh harnesses`: exit 0.
- Signed scratch Preview from the integrated branch (`bash scripts/build.sh --preview`, not installed; unpacked under `.build/verify`): `codesign --verify --deep --strict` OK; `--build-info` reports Workbench Preview 2.4.1 (20261006082236) from source fdfbe01; `--check-core` from the packaged binary exits 0 with 30 `_OK` groups; `--phone-link .build/verify/phone-link 4` exits 0 and writes `phone-link.txt` and `receipt.json` reading "No phone on USB", `usbCount` 0, `sourceCount` 0, access not asked yet (no phone was attached). The bundle carries `SceneBackdrops`, so the packaged app's gallery would use the real starter.
- `bash scripts/test.sh` on the integrated branch (main ac82c2a merged in): `harnesses`, `package-tests` and `checks` exit 0, and `stage` reports 281 tests · 5933 assertions · 0 failures with the two exclusive-shortcut checks skipped while the installed Workbench Preview held ⌥D–⌥R.
- After the independent review's fixes (9ff2817): StageKit's runner **283 tests · 5980 assertions · 0 failures**; `swift build -c release` OK; `--check-core` exit 0 with 30 `_OK` groups; `python3 scripts/check-surfaces.py` **Surface registry OK: 559 entries** (the Present menu's Choose screen submenu and Match Device Proportions classified); `--render-surfaces` **SURFACE_GALLERY_OK: 332 renders, 162 entries, 0 flags**. The images in this folder are from that tree.

## Hardware, 6 October evening

Ethan ran the receipt from the signed scratch Preview (build 20261006103836, source 4ac88b1) through LaunchServices with his iPhone on this Mac's USB, unlocked and trusted:

```
USB: iPhone (product 0x12A8)
Screen sources: <the phone's name> (screen)
Remembered device: present
Device video access: authorized
Session: no session
Status: iPhone ready — Present shows <the phone's name>.
  0.2 s  No phone on USB — …
  0.2 s  iPhone connected, screen not available yet — …
  0.5 s  iPhone ready — Present shows <the phone's name>.
```

So macOS offers the phone's screen here within half a second, the bus watch sees the phone, the remembered device from an earlier session is found, and the words move through the rows in order.

A second run with `--live` (build 20261006105547, source 25a77af) ran the capture session headless and proved frames arrive:

```
Session: live 1320×2868
Status: Showing iPhone — Use the phone itself for taps, typing and its own voice features.
Frames: first after 10.2 s, 1320×2868
  0.3 s  Connecting to iPhone…
  6.2 s  iPhone stopped sending its picture — …
 10.1 s  Showing iPhone — …
```

The first frame took ten seconds, during which the five-second stall check wrongly said the phone had stopped sending its picture; the capture now gives the first frame fifteen seconds of grace and keeps "Connecting" until then, while a feed that has flowed and then gone quiet is still called stalled after five. An earlier run of the same receipt from build 20261006082236 found the screen source but reported "no iPhone or iPad on the bus": IOKit silently rejects a vendor-only USB matching dictionary, so the watch matched nothing. Fixed in 4ac88b1 by matching the device class and classifying in code. The live picture drawn on the page and the stage, and the two preview layers, are still owed (below); the session and its frames are proven.

## End, USB, reports and the plugged-in phone, 7 October

The integration review on #285 held the branch for one P1 and four P2 findings, and the lead's read-only review of 45e70e4 added nine more, with decisions. Main (3c1e6aa, the smaller-Workbench foundation consolidation) was merged first in 0b144f0, keeping main's retirements (Read, Present's Saved Prompts, the browser door) beside the Present rebuild. Then:

- **Reports carry kinds, never names** (b6c2b12): Copy connection details and the receipt word everything from anonymised signals, so "Ethan’s iPhone" reaches neither, even through status text.
- **End is final** (5d767ea): `DemoScenes` records a release before the stage closes, so End stops the capture even with the Present page on screen; `DemoCapture`'s run token drops a permission answer for a stopped run, and only the current session's output can make the phase live. AVFoundation is reached through `CaptureHardware`, so the owner tests run the real `DemoScenes`, `DemoPresentation`, `DemoCapture` and `PhoneLinkMonitor`.
- **A failed USB check is not an empty bus** (8f12683), **QuickTime only where it applies** (ea14672) and **Copied only when it was** (45e70e4).
- **The plugged-in phone** (66d691f): the one phone screen is adopted beside a camera; Present and Reconnect after End try at once; the health check says a disconnect; a stall keeps the last frame on the stage, whose frame carries no words once the phone has appeared and names devices by kind; another app's interruption reads as busy and recovers by itself; the page keeps its preview for sixty seconds after it leaves the screen; the stage is wired before the page's preview; frames are not converted and unchanged answers are not republished; after End a fresh visit to the page or plugging the phone in again resumes the preview.

**Negative check.** With only `DemoScenes`' End release reverted (the old `releaseCapture`), the End checks fail 18 assertions across the three End tests: the capture keeps discovering after End with the page on screen, the permission answered after End opens the phone (`["screen-1"] != []`), a frame after End leaves the phase `live`, and the status stays `connecting`/`live`/`chooseScreen` instead of `ended`. The stale stage step still opened nothing, because `DemoPresentation` ignores steps once End has begun, which is a separate guard. With the fix restored they pass.

**Validation on 66d691f.** `swift build --disable-sandbox` OK. `bash scripts/test-stage.sh --ci`: 299 tests · 6134 assertions, every Present, phone link, End and capture check passing; the one failure is `TimerTransportTests` "The control takes the keyboard", the key-window flake recorded above, which also fails on the merge commit's own sources and passes alone (`--timer-transport-only`: 7 tests · 133 assertions · 0 failures) and in runs when no other worktree is running its window tests on this Mac (290 tests · 6061 assertions · 0 failures on 45e70e4). `python3 scripts/check-surfaces.py`: Surface registry OK: 623 entries. `bash scripts/test.sh harnesses` exit 0. The full `bash scripts/test.sh` on 45e70e4: harnesses, package-tests (343 tests, 0 failures) and checks exit 0; stage hit the same timer flake. Site tests: 22 pass.

**Present page polish (7 October, after the receipt build).** "iphone.and.landscape" and "exclamationmark.folder" do not exist on macOS 26.5.1, so the Scenes heading, the empty state's illustration, the quick controls' Demo scenes row and the blocked-library notice drew no symbol; they now use "iphone.landscape" and "folder.badge.questionmark", and `SymbolTests.testEverySymbolStageKitNamesExists` resolves every symbol name in StageKit's sources and every phone status symbol with `NSImage(systemSymbolName:)`, so a missing one fails the run (it flags both old names). With no scenes the search field ("Search scenes", which fits the narrow column) and the list hint are hidden; the notice card has a hairline because the surface colour equals the window on macOS 26; Present's header has no divider, like every other page; and the scene library's local status reads "Saved on this Mac" on the Mac. Outside StageKit the same scan finds "keyboard.badge.exclamationmark" in `Sources/LocalVoice/ReadbackView.swift` (Snap & Talk), left to its owner.

## Not verified here

- The phone drawn by the app: the morning of 6 October no phone was on this Mac's USB bus; from that evening Ethan's iPhone was attached and the headless receipts above (and on 7 October, below) prove the bus, the screen source and frames. Still owed with the installed app: the live preview on the page before Present, the second preview layer on the stage, reconnect after a cable pull, the macOS accessory prompt, and all of it on the managed work Mac. `--phone-link FOLDER` from the installed app (`open -n -a "…/Workbench.app" --args --phone-link ~/phone-link`) writes the receipt that names what that Mac can see.
- Two preview layers on one session: `AVCaptureSession.canAddConnection` is checked per layer; the stage is wired first, and a refused stage layer takes the connection from the page's preview (7 October), so the shared window keeps the phone. Whether macOS accepts the second connection for a screen device is a hardware check.
- Teams and Zoom receiver view, a second display, full-screen entry from the saved Start full screen option, and the handoff to QuickTime Player keeping the capture released until the person returns to Present.
- The surface checker does not see the Present page's own controls (`DemoScenesView` is embedded as `stage.scenesView`), the help sheet or the stage window, so Present, Options, the status row, the source sheet and the help sheet have no registry entries. This predates the rebuild: Connection & audio…, Use as desktop and the other removed page doors were never registered either. Registering them needs targeted `ENTRY_POINTS` rows in `scripts/check-surfaces.py`.
