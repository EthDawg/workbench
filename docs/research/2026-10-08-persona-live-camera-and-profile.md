# My Profile and Live Camera: the voice ring, one-click switching and camera features · 8 October 2026

Ethan, 8 October 2026: "I can no longer see the audio waves around either camera or my profile, and I can't easily toggle between my live camera and my profile photo… Both should be supported, live camera and the profile, and they should have really delightful experiences. Maybe the live camera could support Center Stage as a setting, or other relevant features like that." He named the two sources **Live Camera** and **My Profile** the same day. [docs/personas.md](../personas.md) owns the behaviour; this record keeps the evidence, the Apple research and the declined ideas.

## Why no ring showed

Checked at `0b86b69` (the release train head) with `--persona-check`, a read-back of the real overlay window through ScreenCaptureKit, run from a signed scratch Preview (`open -n -W -a … --args --persona-check DIR`). The photo is a synthetic Circle portrait, the camera a synthetic picture in the bubble's own preview layer, and the voice synthetic frames. No microphone or camera opened.

**Live Camera never had a ring. It was excluded on purpose, not hidden.**

- `PersonaLibrary.updateVoice()` (`Sources/StageKit/Persona.swift:1391`) is the one place that decides whether the ring shows and the microphone runs. Its comment at `:1400` reads "The outline frames saved artwork only. A camera bubble never opens the microphone", and `framing` at `:1402` is `session.map { $0.voiceTargetID != nil } ?? artworkVisible`.
- When the bubble's first frame arrives, `cameraChanged()` (`:1207`) hides the card and sets `artworkVisible = false` (`:1211`). So `framing` is false whenever Live Camera shows, and `stopVoice()` runs.
- Nothing ever turned the ring on for the bubble. `PersonaLiveCamera.showBubble()` (`Sources/StageKit/PersonaCamera.swift:367`) shows the bubble through the same `PersonaOverlayController` as a card, but never calls `setVoiceRing`. `deliverVoice` (`Persona.swift:1437`) sends frames only to a card or a prepared set.
- It came in with the bubble in `4b9a51b` (1 October). A test held it: `PersonaCameraTests.swift:578`, "A camera bubble never opens the microphone". The product contract said the same: the Persona row of the Scope table, `docs/workbench.md:131`, "never opens the microphone".

Before the fix, at `cf4389d` (`0b86b69` plus the check):

```
PASS Live Camera is showing its synthetic picture
FAIL Live Camera: the ring listens while it shows (a synthetic microphone is open)
PASS Live Camera: the picture shows in the real window (100% of its circle)
FAIL Live Camera: the resting ring of dots surrounds the picture in the real window — ring 0 px in 0/4 quadrants, reaching 0 px past the picture; picture 100% of its circle (412×412 px)
FAIL Live Camera: a voice raises the dots into bars in the real window — ring 0 px in 0/4 quadrants, reaching 0 px past the picture; picture 100% of its circle (412×412 px)
```

**The photo's ring is drawn, in the real window.** It shows when the photo is shown directly, and when it comes back from Live Camera through the pill's picker. The offscreen `layer.render` agrees with the window server, so no layer sits under another view here (the Present failure of 7 October).

```
PASS My Profile: the resting ring of dots surrounds the picture in the real window — ring 9412 px in 4/4 quadrants, reaching 23 px past the picture; picture 100% of its circle (656×656 px)
PASS My Profile: a voice raises the dots into bars in the real window — ring 30700 px in 4/4 quadrants, reaching 82 px past the picture; picture 100% of its circle (656×656 px)
NOTE My Profile offscreen layer.render while speaking: ring 30737 px in 4/4 quadrants, reaching 82 px past the picture; picture 100% of its circle (656×656 px)
PASS choosing the photo in the picker ends Live Camera and shows the photo
PASS My Profile after Live Camera: the resting ring of dots surrounds the picture in the real window — ring 9412 px in 4/4 quadrants, reaching 23 px past the picture; picture 100% of its circle (656×656 px)
PASS My Profile after Live Camera: a voice raises the dots into bars in the real window — ring 30700 px in 4/4 quadrants, reaching 82 px past the picture; picture 100% of its circle (656×656 px)
```

**Correction (review, 8 October):** the photo path was not broken. Its ring is drawn in three independent window read-backs at the base: shown directly, after switching back from Live Camera, and again at `b21e12e`. Ethan most likely had Live Camera up when he saw no ring. Two things the code does show:

- The pill named his photo "Persona 3", not "My Profile". The profile persona (`persona.me.id.v1`) has an empty card label, so it was one numbered card among the frozen candidates of the last Show. Nothing told him it was his profile, or that it was one click from the camera.
- Most of the time his live source was Live Camera, which had no ring at all.

A real microphone and his real photo still need his eyes. See the acceptance at the end.

## What changed

[docs/personas.md](../personas.md) is the contract; these are the owners.

- **The ring around Live Camera.** `PersonaLibrary.updateVoice()` now treats a visible Live Camera bubble as a framed persona. The bubble's owner, `PersonaLiveCamera`, keeps the ring's on/off and colour whether or not it shows, so a bubble is placed with the ring's room at once. `cameraChanged()` decides again on every camera change, so Hide, End, sleep and Quit close the microphone with the camera. `deliverVoice` reaches the bubble. The bubble passes its circle as the edge the ring follows. The camera session stays video only (`addInputWithNoConnections`, audio ports disabled), and the ring's `AVAudioEngine` tap is a separate microphone user. They are two AVFoundation clients on two devices; neither takes the other's device.
- **My Profile and Live Camera first.** `PersonaLibrary.sourceChoices()` is one list for the pill's Choose Persona, the live Persona menu's Choose Persona (card, camera, hidden-card and nothing-live states) and the menu panel's Persona options. `profilePersonaID` reads the same `persona.me.id.v1` preference the profile editor writes. `showProfile()` keeps a shown deck that holds the photo; otherwise it starts the prepared group, or all saved personas.
- **Switching keeps the place.** Starting Live Camera from a shown card gives the bubble the card's place and size. A card replacing a live bubble takes the bubble's. Each source keeps its own lock. One crossfade path (revised after review): the incoming window fades in on top over 0.2 s while the outgoing one stays at full opacity beneath it, stops taking the pointer, and goes 0.25 s later. Two windows fading against each other would let a quarter of the desktop through halfway. From Live Camera to a card, the visit ends at once, but the bubble keeps its picture and the device until it is covered; only then is the camera released, and not at all if a newer visit has started. Hide, End, sleep and a prepared set starting elsewhere stay immediate. A show during a step aside keeps the window whole, and a window that lost the camera's layer to a newer visit leaves the layer alone.
- **Review fixes (8 October).** `PersonaCameraDisplaying` and `ProfileCameraCapturing` lost their do-nothing defaults, so a changed signature cannot silently drop the ring. Only switching React to my voice on asks macOS for the microphone; showing a card or starting Live Camera never does. A lost input or failed restart stops the ring without saving it off. My Profile is always the first row (My Profile… opens the editor until a photo is saved). Live Camera is checked only while it shows. The camera menu is in the card menu's title case and groups, Centre Stage is spelled as macOS shows it in en-AU, and the Persona panels use the kit card rather than a tint.
- **Centre Stage and Video Effects.** `ProfileCameraSession` reports whether the running camera has a Centre Stage format, and with Centre Stage on it keeps a format that supports it. `PersonaCameraEffects` wraps the per-app switch (cooperative control, KVO) and `showSystemUserInterface(.videoEffects)`. Checks pass fakes, and the window check passes `.inert`.
- **Names.** Ethan named the sources Live Camera and My Profile (8 October). Every surface uses those names; device words such as Switch camera and Camera Settings… stay.

## After the fix

The same check at `b21e12e`, from a signed scratch Preview (build `20261007203454`, source `b21e12e`). It passes all 22 checks and fails none (before the fix: 12 passed, 3 failed, all three on Live Camera). Rerun at the final head `250c234` (build `20261007204853`) with the same 22 passes:

```
PASS Live Camera: the ring listens while it shows (a synthetic microphone is open)
PASS Live Camera: the picture shows in the real window (100% of its circle)
PASS Live Camera: the resting ring of dots surrounds the picture in the real window — ring 9412 px in 4/4 quadrants, reaching 23 px past the picture; picture 100% of its circle (656×656 px)
PASS Live Camera: a voice raises the dots into bars in the real window — ring 30700 px in 4/4 quadrants, reaching 82 px past the picture; picture 100% of its circle (656×656 px)
PASS choosing the photo in the picker ends Live Camera and shows the photo
PASS My Profile after Live Camera: a voice raises the dots into bars in the real window — ring 30700 px in 4/4 quadrants, reaching 82 px past the picture; picture 100% of its circle (656×656 px)
PASS choosing Live Camera in the picker shows the bubble in the photo's stead
PASS Live Camera takes My Profile's place and size (centres 0 pt apart, 328 and 328 pt wide)
PASS Live Camera after My Profile: a voice raises the dots into bars in the real window — ring 30700 px in 4/4 quadrants, reaching 82 px past the picture; picture 100% of its circle (656×656 px)
PASS Hide Live Camera closes the ring's microphone
```

With either source showing, the pill's picker opens with `My Profile, Live Camera`. At rest the dots are deliberately quiet: 34% opacity, per [the decided look](../personas.md#react-to-my-voice). Real speech raises them into bars.

## Apple research (checked 8 October 2026)

Apple's US pages and the API spell it Center Stage; Workbench's words follow the en-AU spelling that macOS's own Video menu shows on Ethan's Mac, Centre Stage. Code keeps the API names.

Deployment minimum macOS 14 (Package.swift). Built with the macOS 26.5 SDK (Xcode, `xcrun --show-sdk-version`). All of the following are released APIs, not beta. Header facts were read from `AVFoundation.framework/Headers/AVCaptureDevice.h` in that SDK.

| Fact | Source |
| --- | --- |
| `AVCaptureDevice.centerStageControlMode` is a class property: `.user` (the default; setting `isCenterStageEnabled` throws), `.app` (exclusive; greys out the user's control) or `.cooperative` (the app may set it and must honour the user's changes). macOS 12.3+. | SDK header; [centerStageControlMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/centerstagecontrolmode-swift.type.property) |
| `isCenterStageEnabled` is a class property and key-value observable. `isCenterStageActive` is per device and key-value observable. `AVCaptureDevice.Format.isCenterStageSupported` is per format. While active, zoom and frame-rate ranges narrow; depth delivery deactivates it. "The onus is on you … to conform your AVCaptureSession configuration to make Center Stage active." | SDK header; [isCenterStageEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscenterstageenabled), [isCenterStageActive](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscenterstageactive), [Format.isCenterStageSupported](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/iscenterstagesupported) |
| Center Stage is "one state per app, not one state per camera"; user control is the default and app control is discouraged. | [WWDC21 10047, What's new in camera capture](https://developer.apple.com/videos/play/wwdc2021/10047/). The session is from the iPad era; that the per-app rule also holds on the Mac is an inference. |
| Cameras with Center Stage: iPhone 11 or later (not SE) through Continuity Camera; built-in cameras of MacBook Pro and iMac from 2024 and MacBook Air from 2025; Studio Display (and Studio Display XDR). On macOS 14 and later it is in the menu bar's Video menu. The M4 MacBook Air (2025) has a "12MP Center Stage camera"; the M3 MacBook Air (2024) has a "1080p FaceTime HD camera" and is not listed. | [Use Center Stage](https://support.apple.com/en-us/111102) (12 May 2026), [MacBook Air M4](https://support.apple.com/en-us/122209), [MacBook Air M3](https://support.apple.com/en-us/118551), [Studio Display](https://support.apple.com/en-us/111890), [Continuity Camera](https://support.apple.com/en-us/102546) |
| `showSystemUserInterface(.videoEffects)` presents the system UI and deep-links to its module, without blocking. macOS 12+. In macOS 14 video effects moved from Control Center into their own Video menu: Center Stage, Portrait, Studio Light, Edge Light (macOS 26.2+), Background, Reactions, Desk View. | SDK header; [showSystemUserInterface(_:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/showsystemuserinterface(_:)); [WWDC23 10105](https://developer.apple.com/videos/play/wwdc2023/10105/); [Use the camera on Mac](https://support.apple.com/guide/mac-help/use-the-camera-mchlp2980/mac) |
| Portrait (`isPortraitEffectEnabled`/`Active`), Studio Light (`isStudioLightEnabled`/`Active`) and Background (`isBackgroundReplacementEnabled`/`Active`, macOS 15+) are read-only to apps. On macOS every app is opted in to Portrait and reactions; the `NSCamera…Enabled` Info.plist keys are iOS opt-ins. Reactions (`reactionEffectsEnabled`, `canPerformReactionEffects`, `performEffect(for:)`, macOS 14+) are always on for macOS apps through gestures. | SDK header; WWDC21 10047; WWDC23 10105; [reactionEffectsEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/reactioneffectsenabled); [isBackgroundReplacementEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isbackgroundreplacementenabled); [video conferencing requirements](https://support.apple.com/en-us/105117) |
| `AVCaptureVideoPreviewLayer.isPreviewing`, which would say when the first frame is drawn, is `API_UNAVAILABLE(macos)`. `centerStageRectOfInterest`'s support flag and `geometricDistortionCorrection` are unavailable on macOS too. | SDK header |

Not confirmed from a primary source: whether a value set in cooperative mode persists across launches as the Video menu's own toggle does. That depends on macOS keeping the per-app state, and Ethan's camera confirms it.

## Decided, and declined with reasons

| Idea | Decision | Why | What would change it |
| --- | --- | --- | --- |
| A Centre Stage switch in Live Camera | **Implemented**, only where the camera has a Centre Stage format, in cooperative control | Ethan asked for it. It is one switch on the bubble a presenter is already using, and it stays in sync with the Video menu. | — |
| Workbench's own remembered copy of Centre Stage | Declined | macOS keeps one switch per app, and the Video menu changes it too. A second copy would fight the user's own switch. | Ethan's Mac shows an app-set value forgotten at relaunch. |
| Exclusive (`.app`) control of Centre Stage | Declined | Apple discourages it, and it greys out the user's own Video menu switch. | None foreseen. |
| Portrait, Studio Light, Background and Edge Light switches in Workbench | Declined; **Video Effects…** opens the system menu instead | Apps can only read them, and macOS applies them to the camera feed itself. | Apple ships settable APIs. |
| Reaction buttons (`performEffect(for:)`) | Declined | On macOS, gestures already trigger reactions in every app. Buttons would crowd a bubble that should stay a face, and a reaction would land in the bubble rather than in the call. | Ethan wants on-cue reactions while presenting. |
| Gesture reactions on by default | **Changed**: off by default for Workbench (`NSCameraReactionEffectGesturesEnabledDefault` = false in Info.plist; honoured from macOS 14.4, per the SDK header) | A thumbs-up mid-demo would fill the bubble with balloons. The person can still turn Gestures on in the Video menu, and that choice wins. | Ethan wants gestures on by default. |
| Microphone Modes door (`.microphoneModes`) | Declined | The ring measures loudness and pitch only. Voice Isolation hardly changes it, and the door would be one more control. | Real use shows the ring reacting to room noise that Voice Isolation would remove. |
| Desk View | Declined | It is a different job: showing the desk, in its own app. | A demo that needs the desk on screen. |
| Manual Centre Stage framing (rect of interest) | Not possible | Unavailable on macOS. | Apple adds it to macOS. |
| Waiting for the preview layer's first frame | Not possible; the crossfade covers it | `isPreviewing` is unavailable on macOS. The card stays up until the first data frame, and the bubble fades in over it. | Apple adds it to macOS, or Ethan sees an empty frame. |
| Remembering the bubble's place across launches, or reopening a source at launch | Declined (unchanged rule) | Nothing reappears at launch, and the camera's place resets at quit. A switch now carries the place within a session. | Ethan asks for it. |
| Other bubble shapes | Declined | The circle is the decided look; there was no ask. | Ethan asks for it. |
| The camera choice | Unchanged | Switch camera, and the page's camera list, already appear when there are several cameras. Continuity Camera is one of them. | — |

This is a deliberate exception to the Grammar's "freeze advanced Persona" rule, on Ethan's explicit request of 8 October. It adds two Options of Persona (Centre Stage, Video Effects…) and one shared list. It adds no capability, place, setting group or saved preference.

## Still needs Ethan's camera, microphone and eyes

The source checks and the window read-back use a synthetic photo, picture and voice. These need the real thing on his Mac, with the installed Preview:

1. **The ring with a real voice.** Turn on React to my voice and start Live Camera, then talk. The dots should rise into bars around the bubble. Do the same with My Profile. If the resting dots are too faint to notice, that is the decided look (34% opacity), not a fault, but say so.
2. **Microphone and camera together.** While the bubble shows with the ring on, the menu bar should show both the camera and the microphone indicators. Hide Live Camera should turn both off, and End Live Camera too.
3. **One-click switching.** In the pill's Choose Persona, switch from My Profile to Live Camera and back. Each should appear in the other's place and size with a short crossfade. The photo should stay up until the camera's first frame, with no empty or black circle in between.
4. **Centre Stage.** On the M4 MacBook Air's built-in camera, a Studio Display or an iPhone with Continuity Camera, Centre Stage should appear in the bubble's menu and on the Persona page, and keep him framed as he moves. Changing it in the menu bar's Video menu should update Workbench's switch. Quit and relaunch, and check that it is remembered. On a camera without Center Stage it should not appear.
5. **Video Effects….** It should open macOS's Video menu, and Portrait or Studio Light should show in the bubble.
