# Gentle background motion

Implemented in source, 15 September 2026. The [visual contract](../site/handbook/contract.json) owns Mac capability status and lifecycle; [the mobile specification](ios-preview.md) owns iPhone/iPad behaviour. This is not a claim that the public signed download or App Store build includes the change.

## The experience

The [authored ambient starters](research/ambient-scenes.md) extend this foundation with motion limited to clouds or foliage. They use version 2 scene packages and a preserved v1 library backup. The original gentle-zoom behavior below remains available for ordinary photographs.

For an ordinary photograph, the optional treatment is: the photograph slowly grows from its authored crop to 103.5%, then returns. Each direction takes 24 seconds with eased endpoints. These are restrained product choices, not measured thresholds for comfort or battery life. Device video, frame, hand cutout, logo, persona and controls do not move with it. Existing scenes remain still until the person chooses **Gentle motion**.

| Surface | Entry and behaviour | What remains still |
| --- | --- | --- |
| Mac presentation, non-App-Store build | Enable Gentle motion in the scene editor. Present in a window or full screen; click the compact tile for Pause/Play. | Editor crop/positioning, foreground artwork and PNG export. |
| iPhone/iPad scene preparation | Enable Gentle motion. Pause/Play preview changes only this viewing session; the saved preference travels with the editable scene. | Gallery thumbnails, crop editing and foreground layers. |
| Mac desktop, non-App-Store build | More beside the presentation buttons → Use as animated desktop. Verify a native rendered still, then start an independent click-through layer on that display. Pause/Resume/Stop appear in the scene window. | The applied PNG, recovery records and the saved scene. Quit or Stop removes the layer; the native still remains. |
| iPhone/iPad wallpaper | Save the composed still to Photos. Follow the linked Apple instructions for an eligible Spatial Scene or an existing eligible Live Photo. | Workbench exports a PNG. It neither creates a Live Photo nor installs a Lock Screen or Home Screen wallpaper. |

The desktop action currently reuses the whole prepared scene, including any foreground artwork. For a plain wallpaper, turn off Device frame and remove artwork before applying. The independently useful direct wallpaper picker remains proposed; this increment does not add another library or pretend that entry already exists.

## Native foundations and decisions

- [Apple’s desktop image API](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)) supplies a persistent still. A separate [desktop-level window](https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey) supplies optional app-owned motion. This does not install an Apple aerial or replace the system wallpaper engine.
- [Plash](https://sindresorhus.com/plash) documents the same important distinction between a layer above the desktop and the underlying wallpaper, as well as muted playback and battery considerations. We use native photograph transforms instead of a web renderer.
- [Apple iPhone wallpaper guidance](https://support.apple.com/en-au/102638) describes Spatial Scenes for eligible photos and devices. [Live Photo Lock Screen guidance](https://support.apple.com/en-us/120734) describes playback on wake. The [current iPad guide](https://support.apple.com/guide/ipad/create-a-custom-lock-screen-ipad782d4de8/ipados) also describes supported photo effects. None establishes continuous Home Screen playback or permission for an app to install wallpaper.
- [Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion), Low Power Mode, high thermal state and visibility suppress playback. A Mac presentation is not paused just because Teams or another app has keyboard focus; [an active Mac scene need not be frontmost](https://developer.apple.com/documentation/swiftui/scenephase/active).

Claude reviewed a public-source-only hypothetical design. Its useful criticism was the permanence mismatch between an applied still and an app-lifetime renderer, and the need to avoid energy claims without measurement. We kept explicit runtime copy. We did not add its suggested login control, automatic mirroring suppression or an undocumented direct Live Photo handoff: these either add scope, conflict with intentional presenting or lack a supported route in the evidence.

The [generated study](../site/assets/guide/gentle-motion-concept.png) helped establish a quiet photo treatment. Its invented sidebar and decorative card were not copied. [Actual iPhone controls](../site/assets/guide/gentle-motion-iphone-actual.png) and [actual Mac presentation](../site/assets/guide/gentle-motion-mac-actual.png) show the native work. These are still screenshots and cannot prove playback by themselves.

## State and rendering

`PortableScene.gentleMotion` is an optional Boolean: missing means still. The Mac adapter preserves it through the existing validated package and local store. The original zoom treatment adds no media files, iCloud containers, permissions, dependencies, background service or automatic account choice. Old clients can display the still; their unknown-field decoding may drop the preference if they resave.

`GentlePhotoMotion` owns the shared Core Animation parameters and eligibility predicate. A cached photo layer receives the scale animation; there is no app-driven bitmap render or display-link loop. `MovingSceneView` separates the Mac photograph from stationary artwork and captured video. Transparent PNGs reveal the same base fill as the still renderer. `SceneMotionPreview` uses the matching UIKit layer and existing orientation-normalized thumbnail cache.

Pause removes the transform and returns to the authored still crop. iOS also stops while editing crop, outside the visible scroll area, behind another editing sheet or when inactive. The current native hosts also observe Apple’s animated-image autoplay preference. Mac observes window occlusion, power, thermal, Reduce Motion and independent computer/display/session sleep reasons. No keep-awake assertion is added for motion.

`DesktopMotionController` owns one session on one display and the current Space. It never writes wallpaper. The existing apply method renders the immutable still, journals restoration, requests macOS application and confirms its URL before starting this controller. Its five-second timer with tolerance checks ownership; unknown or changed wallpaper state stops it. Display removal and Space changes stop it. Pause survives sleep; waking rechecks ownership. A subsequent explicit still apply or Restore stops the desktop layer. Ending a presentation does not. No automatic login or relaunch playback is added.

## Evidence and remaining limits

The native scene suite, shared-store suite and focused iPhone tests cover legacy/persisted settings, portable scene round trips, unchanged still exports, foreground transparency, transparent-photo base colour, desktop ownership/sleep/removal policy, and UIKit layer cleanup. Final counts and source revision are recorded in the structured contract and PR.

Parent native checks used disposable scene libraries and an unprovisioned Mac host linked to the production StageKit sources. A windowed synthetic presentation changed background pixels between captures while an opaque logo region stayed identical. Pause exposed Play; End reopened the editor. A separate desktop-layer test started against the existing native wallpaper as its ownership token, without writing any wallpaper: Pause/Resume/Stop controls worked, and End presentation retained the desktop session. This is not a fresh end-to-end native wallpaper-apply test.

The iPhone 17 Pro / iOS 26.5 Simulator created Coast, enabled motion, paused/resumed and opened crop controls; the crop preview stayed still. Unit tests exercised actual scene save/reopen/duplicate preservation. The connected physical iPhone was left untouched.

Energy/GPU use, overnight battery behaviour, multiple displays, Stage Manager, actual sleep/wake ordering, physical Reduce Motion transitions, device video during motion and receiving Teams/Zoom views still require their own measurements. No battery-friendly, receiver-invisible, physical wallpaper eligibility or App Store release claim follows from these checks. Whole-screen sharing can include motion; the user can pause it explicitly.

The signed Mac Preview at source `9fe7959`, build `20260914171004`, was subsequently installed at the existing Preview path. Strict signature verification with native trust access passed; the installed executable exactly matches the signed archive. Native launch retained the saved scene rows and exposed Gentle motion (off for existing scenes) and **More** beside the presentation buttons → **Use as animated desktop**. No saved scene or system wallpaper was changed during this installed-app check. The previous app archive is retained for rollback. This local update is not notarized or published; the public download remains Preview 3.
