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
- `bash scripts/test.sh` on the integrated branch (main ac82c2a merged in): `harnesses`, `package-tests` and `checks` exit 0, and `stage` reports **281 tests · 5933 assertions · 0 failures** with the two exclusive-shortcut checks skipped while the installed Workbench Preview held ⌥D–⌥R.

## Not verified here

- A real iPhone: none was on this Mac's USB bus on 6 October (IOKit and AVFoundation probes both returned no device, and the only external AVCapture device was the wireless Continuity Camera, which Present filters out). The adoption of the one phone screen, the live preview on the page before Present, the second preview layer on the stage, reconnect after a cable pull and the macOS accessory prompt need Ethan's phone on this Mac and on the managed work Mac. `LocalVoice --phone-link FOLDER` from the installed app (`open -n -a "…/Workbench.app" --args --phone-link ~/Desktop/phone-link`) writes the receipt that names what that Mac can see.
- Two preview layers on one session: `AVCaptureSession.canAddConnection` is checked per layer and a layer that cannot be wired is left unattached rather than failing the session; whether macOS accepts the second connection for a screen device is a hardware check.
- Teams and Zoom receiver view, a second display, full-screen entry from the saved Start full screen option, and the handoff to QuickTime Player keeping the capture released until the person returns to Present.
- The surface checker does not see the Present page's own controls (`DemoScenesView` is embedded as `stage.scenesView`), the help sheet or the stage window, so Present, Options, the status row, the source sheet and the help sheet have no registry entries. This predates the rebuild: Connection & audio…, Use as desktop and the other removed page doors were never registered either. Registering them needs targeted `ENTRY_POINTS` rows in `scripts/check-surfaces.py`.
