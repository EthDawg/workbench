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

The source does not show why Ethan saw no ring around his photo. Two things the code does show:

- The pill named his photo "Persona 3", not "My Profile". The profile persona (`persona.me.id.v1`) has an empty card label, so it was one numbered card among the frozen candidates of the last Show. Nothing told him it was his profile, or that it was one click from the camera.
- Most of the time his live source was Live Camera, which had no ring at all.

A real microphone and his real photo still need his eyes. See the acceptance at the end.
