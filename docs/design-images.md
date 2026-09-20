# Product-guide image experiments

## Reuse the work before generating again

Added 20 September 2026. This is the existing home for visual exploration, prompts and decisions. Image generation is useful for trying different design languages, control hierarchies, experience states and handoffs, and for producing original backdrop/persona artwork or explanatory collateral. A concept can be valuable even when the implementation deliberately differs.

Start with a relevant existing asset and its critique below. These are useful entry points, not an exhaustive asset register:

| Question or output | Existing material to reuse | Where behaviour is decided |
| --- | --- | --- |
| Compact controls, expansion and placement | [Voice alternatives](../site/assets/guide/voice-experiments.png), [placement study](../site/assets/guide/voice-placement-study.png), [refined jobs](../site/assets/guide/jobs-refined.png) | [Floating-control decisions](hud-design.md), [interaction contract](product-spec.md) |
| Mobile capture and a recognisable Mac handoff | [Photo handoff B](../site/assets/guide/photo-handoff-concept-b.png), [scene preparation](../site/assets/guide/scene-preparation-concept-a.png) | [Photo handoff](photo-handoff.md), [mobile contract](ios-preview.md) |
| A coherent scene with editable persona controls | [Persona study](../site/assets/guide/persona-controls-concept-b.png), [reusable persona artwork](../Resources/PersonaPortraits) | [Persona contract](personas.md), [scene decisions](research/personal-scenes.md) |
| Backgrounds and finished artwork | [Scene backdrops](../Resources/SceneBackdrops), [ambient assets and prompts](../Resources/AmbientScenes/prompts.md) | [Background management](background-management.md), [Mac experience contract](../site/handbook/contract.json) |
| Product explanation and contribution collateral | [Refined feature study](../site/assets/guide/commodity-features-refined.png), [architecture study](../site/assets/guide/commodity-architecture-refined.png) | [Product direction](commodity-strategy.md), [guide and publishing route](../site/README.md) |

Use generation actively when seeing alternatives would resolve a decision. For example, compare two or three treatments of the same idle → recording → completion flow, using the existing selected study as a visual reference. Keep the job, wording and native constraints stable so the comparison is useful. Record the selected idea and rejected details beside the prompt; make another round when a meaningful question remains. Improving a label or matching an implemented control may only need a normal code or document edit.

For background or collateral work, reuse the original artwork and generation brief. State dimensions, crop, palette, negative space for the device/annotation, and required variants. Keep product labels, logos, sizes and interactive controls editable in their existing owners rather than baking them into a background. Check actual transparency where required. The [background-brief proposal](https://github.com/EthDawg/workbench/issues/65) should start from this material.

### Worked example: the waveform is a design choice

![Generated recording alternatives with waveform shapes; exploration, not app evidence](../site/assets/guide/voice-experiments.png)

The generated study above explores compact, labelled and expanded controls with waveform shapes. The agreed pairing in [the control review](hud-design.md) is compact plus explicitly expanded. That borrows the hierarchy and footprint; it does not make every generated detail a requirement.

At source `f63cf35197221866c0501d6f1ced23c808401d20`, [CaptureLevelMeter](../Sources/LocalVoice/CapturePanel.swift) renders eight equal-size segments whose fill follows the current input level. It has no waveform history. The interaction contract requires input-level feedback, so this is a design difference to evaluate, not an established broken waveform requirement. The usefulness question is whether someone can tell that sound is being received without losing sight of Stop or the task beneath the controls.

![Native recording-panel preview labelled Panel preview and Microphone off](../site/assets/guide/recording-expanded-actual.png)

This existing native image is a **panel preview with the microphone off**. It helps compare layout but cannot demonstrate live meter response, microphone permission or preserved paste focus. The guide already records that distinction. A future waveform experiment should compare silence/speech feedback and compact/expanded legibility, preserve Stop/focus and respect Reduce Motion. Capture its actual state and source revision before using it as evidence.

### Carry the decision into implementation and collateral

In the existing issue or PR, link the selected image, name the details to keep, explain material differences from it, and point to the behaviour owner and acceptance check. This can be a short paragraph. Do not silently overwrite the concept when code changes; keep the reasoning and add a matching native capture when available. An incidental generated label or animation is not a requirement unless adopted explicitly.

Use actual UI evidence for instructions and claims about the current release. Put a visible concept label beside exploratory illustrations wherever they are reused. A native capture still needs its state, build/revision and evidence limits: a preview fixture or Simulator image is not a live device/receiver test. Finished artwork can be reused as artwork without pretending it is app evidence. Preserve the original and any relevant provenance or usage restrictions; do not infer rights from an image being present in a folder.

Claude and Codex can help compare alternatives, critique a design, draft a prompt or implement a bounded choice. Reuse the same linked decision and relevant approved material so the next assistant does not reconstruct the project from screenshots. State the useful output and allowed scope; the submitting contributor still checks the result against source and observed behaviour. Share confidential material only within its authorised recipient/tool and purpose; use a synthetic example or a selected public excerpt when sufficient. Keep credentials, unrelated private context and raw private transcripts out of public issues and assets. This is part of the existing [contributor responsibility](../CONTRIBUTING.md#send-your-change), not another handoff system.

## Personal scene refinement — 13 September 2026

Both experiments were shown inline for review. They use fictional imagery and are retained as exploration, not evidence of implemented or tested behavior. The newer [personal-scenes decision](research/personal-scenes.md) supersedes the earlier photo-only navigation limit below.

| File | Critical decision |
| --- | --- |
| `site/assets/guide/scene-preparation-concept-a.png` | Keep editable scene preparation and matching Mac layout. Reject the invented extra tabs, favourites, brand tagline and third quick action. Keep Tools/Saved and only two quick actions. |
| `site/assets/guide/persona-controls-concept-b.png` | Keep the separate click control, scoped group and all-target drag study. Reject the oversized card, audience-facing edit icon and invented settings categories. Private control content is scoped; screen-share invisibility is not promised. |

### Scene preparation prompt

```text
Use case: ui-mockup. Create a carefully composed high-fidelity native Apple product design exploration for the open-source app Workbench. Landscape 1800x1200-ish canvas. This is a working interface study, no advertising slogan. Off-white neutral board, system typography, very restrained mint accent. Title small: "Scene preparation · Concept A". Show three readable native interface frames left-to-right: iPhone Scenes library with two fictional saved scenes and a clear primary camera button; iPhone editing a saved scene with a realistic coastal office reception backdrop, an empty phone-shaped preview positioned to left, a small original generic logo and a persona card at bottom right; Mac Scenes window showing that same scene ready to present. Use captions below frames "Choose a saved scene", "Capture or replace the backdrop", "Open on Mac". Existing scene sample is "Harbor · Reception". Keep customer grouping in editing UI only. iPhone editor title "Reception"; top small status "Saved · iCloud"; an honest separate transfer status "Changes in iCloud", not a false confirmed Mac receipt. Core edit controls: "Backdrop", "Device position" with Left/Centre/Right, "Logo", "Persona". The large primary action is "Done" because edits are saved and synced. No "Present on this device", no Share PNG dominating the scene flow, no web login or avatar dashboard. Mac has sidebar Home, Dictate, Read aloud, Annotate, Scenes, Wallpapers, Saved. Clear "Present" action only on Mac. Under board add two native Home Screen quick-action menu rows "Capture for scene" and "Dictate". Use natural generous spacing, highly legible compact controls, light mode material, SF-like line icons. Not a fake screenshot or release claim: visibly label bottom "Design exploration — behavior requires implementation and testing". All imagery generic fictional, no actual customer brands, no personal data. Grounded in iOS 26 and macOS native controls.
```

### Persona control prompt

```text
Use case: ui-mockup. Make a high-fidelity Mac utility interface interaction study for Workbench persona controls. Landscape design board on warm neutral background, large readable realistic UI details, restrained system typography, mint accent. Small title "Personas · Concept B". Left two-thirds: fictional business website on a Mac screen with a carefully illustrated Black female healthcare operations manager persona overlaid bottom right, bright approachable professional illustration, teal circle backdrop and an editable label "Operations manager" in a restrained native card. Beside artwork a tiny floating dark material click tile with person icon, divider, chevron; no prospect names, no words Demo or Live. Above tile an open compact popover with heading "Personas", three thumbnails of diverse industry personas from the current selected group only, readable job labels "Operations", "Front desk", "Team lead", hide control, Next control, and no all-customer dropdown or long list. No fake privacy invisibility promise: small note "Controls can appear in whole-screen sharing". Right upper detail: pre-presentation library settings window shows group "Harbor" editable, portrait chooser, separate label text field "Operations manager", native color well "Background", and clear native "Use in scene" button. Distinguish editable text/color from artwork; no typography baked into portrait. Right lower detail: miniature screen drag-placement study showing all eight valid edge/corner snap targets as subtle outlines simultaneously, one nearest target highlighted mint, floating tile drag path. Explain "Drag to place. Click to open." and "Only the selected group appears while presenting." Show a keyboard-focus ring and sensible generous click areas. Visual cohesion across light and dark material, no glowing futuristic HUD or dashboard clutter. Footer "Design exploration — not shipping UI".
```

## Selected-photo handoff — 13 September 2026

Two built-in image-generation experiments were shown inline in the task and are retained on the [photo handoff page](../site/handoff/index.html). Both use a synthetic reception, without people, real branding or location claims. They are design hypotheses, not cloud-transfer evidence.

| File | Critical decision |
| --- | --- |
| `site/assets/guide/photo-handoff-concept-a.png` | Kept the optional name, recognisable same photo and explicit backdrop action. Rejected any implication that phone upload proves Mac delivery; local and cloud state must remain distinct. |
| `site/assets/guide/photo-handoff-concept-b.png` | Kept Queued for iCloud / In iCloud / Downloaded as different facts. Rejected invented Projects navigation. Actual mobile keeps Tools/Saved and Mac uses Saved resources → From iPhone. |

The native implementation and account/deletion contract are owned by [photo-handoff.md](photo-handoff.md). Existing backdrop previews remain the reuse surface; the concepts do not authorise a new scene editor.

### Experiment A prompt

```text
Use case: ui-mockup.
Asset type: grounded Workbench photo-handoff product exploration, not shipping UI.
Create one landscape review board with two large, sharply readable native UI mockups side by side, iPhone left and Mac right. Restrained system typography, off-white surfaces, dark slate text, muted mint accents, realistic Apple-native controls. No marketing hero headline or decorative AI sparkles.
Job: photograph a real office reception away from the desk; deliberately send just that image to private iCloud; later find it in the existing Mac Saved resources. Use the same synthetic, plausible photograph of a warm reception desk, indoor plant and timber wall in both UIs, no people, no real logos, no address. Photo should be the dominant visual.
iPhone navigation title "Send to Mac". Large image preview. One optional name field "Office reception". A simple primary button "Send photo". Small helper "Only this photo. Your original stays here." Show a small alternate-state inset "Saved on this iPhone" and "Waiting for connection" so uncertainty is visible.
Mac native app window with a modest sidebar: Home, Dictate, Read aloud, Annotate, Present a device, Saved resources. Saved resources selected. Main heading "From your iPhone". A single photo tile named "Office reception", status "Downloaded on this Mac". An opened detail shows deliberate actions "Use as backdrop" and "Save a copy". Do not show a success status on the phone claiming the Mac received anything. Do not show automatic wallpaper changes, active presentation, account sign-up, folder pairing, many dashboards, badges, gradients, fake controls, or excessive explanatory prose.
Small board label exactly "PHOTO HANDOFF · CONCEPT A". Footer exactly "Design hypothesis — actual device testing required". Show practical control hierarchy and ample click targets.
```

### Experiment B prompt

```text
Use case: ui-mockup. Create a second, more practical Workbench photo-handoff UX review board. Landscape, flat UI study rather than photorealistic hardware product render. Reference the previous image only for the same synthetic office-reception photograph and muted mint/slate styling. Reuse that photo visibly. Keep all UI clean, native, spacious, readable. No marketing slogan, cloud infrastructure diagram, excessive settings or phantom functionality.
Layout: three equal large rounded iPhone-style application panels across the top, and one slim Mac Saved resources strip across the bottom. Header exactly "PHOTO HANDOFF · CONCEPT B". Small subheading "Clear even when the connection is not."
Panel 1, title "Send to Mac": medium photo, optional name field "Office reception", primary "Send photo"; small detail "A smaller JPEG is shared. The original stays on this iPhone."
Panel 2, title "Photo handoff": photo row named "Office reception", a quiet outlined clock symbol, status "Queued for iCloud"; small sentence "Your photo is saved here. Try again when connected." A secondary "Try again" control. This is an alternate offline state, not another step asking to upload again.
Panel 3, title "Photo handoff": same photo row, status "In iCloud"; short text "Open Workbench on your Mac to download it." Do not say delivered or received on Mac in this phone UI. No confetti, completion hero or celebratory badge.
Bottom Mac panel: toolbar title "Saved resources" with segmented switch "Resources | From iPhone", From iPhone selected. A single row thumbnail "Office reception" with "Downloaded on this Mac" and explicit "Use as backdrop…" and "Save a copy…". Small footnote "Choosing a backdrop opens a preview. Your current scene stays unchanged until Apply."
Footer exactly "Design hypothesis — source and device tests decide what ships". Typography at realistic accessible UI sizes. No mock data outside the one synthetic office photo.
```


Generated with the built-in image-generation tool on 12 September 2026. These are design concepts, not shipping screenshots. All selected files are stored in `site/assets/guide/`; the public guide labels their status.

## Jobs study, first experiment

File: `site/assets/guide/jobs-study.png`

Use case: ui-mockup. Asset type: durable Workbench product-guide illustration, landscape 3:2, polished editorial product design, not a marketing poster.
Create three clearly separated numbered horizontal rows with generous whitespace on a warm off-white background, finely rendered native Mac windows and restrained graphite panels. Large title "The right control for the job." Small subtitle "Workbench · interaction study".
Row 1 title "01  Dictate on your Mac". A Mac text-editor window with fictional short bullet note. At its bottom a small charcoal recording capsule with red dot, "0:18", short waveform, square stop button, chevron. Nearby a restrained expanded detail panel showing "Recording", "Light cleanup", "Stop", "Cancel". Include short caption "The Mac field receives your text."
Row 2 title "02  Present a phone". A landscape presentation window showing a single upright iPhone over a quiet coastal background. A TINY tile at the right edge centre contains only outline phone icon, thin vertical divider, right chevron. Small open popover illustration outside window shows "Presentation", "Change source…", "Reconnect", "End presentation". Show separate physical phone held at side with native keyboard microphone highlighted. Caption "Type or dictate on the phone."
Row 3 title "03  Explain a browser demo". A Mac browser fictional service dashboard, a simple hand-drawn circle on a card, and a small round persona portrait card at bottom right labelled "Site manager". Separate modest app controls labelled "Move · Resize · Lock". Caption "The browser keeps normal page input."
Use actual readable concise labels, no invented brand logos, no neon, no purple gradients, no fake broadcast badge, no word Live or Demo on collapsed tiles, no microphone anywhere in phone-presentation controls. Maintain clear boundary between audience-visible content and utility controls. Footer "Design concept · not a screenshot". Elegant system sans typography, hairline borders, realistic but quiet shadows; focus on usable UI, not decoration.

## Refined jobs study, selected for the guide

File: `site/assets/guide/jobs-refined.png`. Corrects the settings control, phone-video parity and persona position from the first experiment.

Refine this Workbench product-guide concept while preserving its three-row composition, restrained native styling, typography and exact three jobs. Make ONLY these corrections:
1 In the expanded recording panel, replace the interactive blue checkbox and the filler caption with plain, non-interactive text: "This recording" then "Light cleanup". Add small note "Changes apply next time." Preserve Stop and Cancel. This is frozen per-recording status, not a checkbox.
2 The phone inside the middle presentation window must display the SAME simple Notes editor state as the physical phone on the right (a text field titled "Client update", keyboard visible). This is a video preview of the physical device. The small presentation tile must remain phone icon, divider, chevron only. No microphone controls in its menu.
3 Move the small Site manager persona card so it sits INSIDE the lower right corner of the browser content, overlaying that content. Remove its green availability dot. The card is a static persona image, not a person online. Keep its plain label and friendly portrait.
4 Footer must say "Design concept · not a screenshot".
Do not add other modes, features or text. Professional editorial visual, calm, clear, hand-crafted feel.

## Earlier studies retained

- `voice-experiments.png`: compact capsule, labelled strip and expanded details.
- `presentation-study.png`: phone/chevron control and separate persona artwork.
- `voice-placement-study.png`: anchored expansion, snap hints and named positions.

These earlier studies were generated and reviewed in the task before this specification. Their frozen-setting and input-ownership details are governed by `product-spec.md`, not incidental generated labels.


## Example persona artwork

File: `site/assets/guide/site-manager-persona.png`. Generated as a reusable finished persona image, not an app screenshot.

Prompt brief: a fictional friendly woman working as a site manager, wearing a white hardhat and olive work shirt, inside a warm gold circular portrait with a restrained dark teal outline and a matching lower name plate reading “Site manager”. Transparent background outside the card, no real company marks, no online-status dot. Polished, approachable illustration for a browser or phone demonstration.

The generated PNG has an alpha channel. Its actual import, floating display and placement inside a scene were checked in Workbench Preview.

## Commodity utility studies — 13 September 2026

Four new image-generation experiments were shown inline during the review and retained in `site/assets/guide/`. They are concepts, not screenshots. The actual implementation map is in `commodity-strategy.md`; the feature contracts are in `utility-comparison.md`.

| File | Generation brief and decision |
| --- | --- |
| `commodity-first-study.png` | Explore four useful moments: listening, exporting a board, presenting a phone, recalling a file. Rejected the generated reversed device-video direction, an unsupported audience-view verification indicator, and word highlighting without timing data. Retained for traceability. |
| `commodity-architecture-first.png` | Stable jobs above small contracts and replaceable implementations, with user-owned originals and a reviewed upgrade loop. Rejected the camera metaphor, implied file-version history and an overly literal hardware-rack illustration. It also omitted Saved resources. |
| `commodity-features-refined.png` | Four precise native UI panels: ±15-second reading navigation in existing audio; board-only Copy/PNG export; a resizable Mac scene showing phone video with icon/chevron controls; search/selection/Return to deliberately copy a saved resource. No word highlighting, invisible audience controls or reverse phone input. This grounded the chosen interactions. Existing app styling/layout remains the implementation owner. |
| `commodity-architecture-refined.png` | One app and five explicit jobs; native Mac controls; recognition/refinement/speech-generation modules; candidate → same inputs → quality/speed comparison → reviewed release; keep originals, read older files, preserve unknown formats. Phone video points to a Mac scene. This is direction; voice engines do not serve every non-voice utility. |

Final image-generation prompt for the architecture refinement:

> Make a professional product architecture decision illustration for a small free native Mac utility called Workbench. Wide landscape, white background, restrained mint/charcoal, clean sans serif. Exact title 'One app. Five useful jobs.' Top row five simple line icons and labels: 'Dictate', 'Read aloud', 'Annotate', 'Present a device', 'Saved resources'. Beneath show one understated long bar 'Native Mac controls'. Beneath show three equally sized small modules 'Recognition', 'Text refinement', 'Speech generation'. Caption directly underneath 'Replace an engine when a measured improvement earns it.' Bottom left show an ordered review sequence as four simple cards: 'Candidate' → 'Same test inputs' → 'Compare quality + speed' → 'Reviewed release'. Bottom right protected outlined box with document icon and exact text 'Keep originals' then 'Read older files' then 'Preserve unknown formats'. Do not draw arrows that imply every job depends on models; modules apply to voice jobs only. Five jobs must all be present; no camera metaphor, no plugged hardware racks, no claims of automatic updates or saved version history. A small separate inset with an iPhone screen sending a single arrow to a Mac display, labeled 'Phone video → Mac scene'. This means video display only, no remote phone input. Footer 'Architecture direction • actual boundaries are recorded in the specification'. Precise professional diagram, not marketing poster; no invented labels or paragraphs.

Actual `reading-playback-actual.png` and `library-recall-actual.png` were captured through native computer controls using production UI/methods in disposable apps. Their diagnostics identify the isolated state and simulated library effects. `board-export-actual.png` is the actual PNG produced by the native Save action, not generated artwork.

## Background and pillar review — 13 September 2026

Built-in `image_gen` produced five experiments, all shown in the task. Sources and decisions are in `background-management.md`; product priorities are in `commodity-strategy.md`. Generated details do not override those contracts.

| Retained file | Decision |
| --- | --- |
| `backdrop-options-study.png` | Compared an in-context sheet, inline filmstrip and a separate wallpaper library. Chose the sheet. Rejected the invented brand/tagline and portrait-shaped scene preview. |
| `backdrop-refined-study.png` | Corrected to a landscape composition with native crop controls and an explicit apply/cancel transaction. Actual implementation uses a compact list of image choices; it is not obliged to copy the illustrated grid. Missing-backdrop artwork is conceptual. |
| `pillars-first-study.png` | Five current strengths and five recommendations. Rejected the absent device in the current Present row, invented aspect presets and implied team/date metadata. |
| `pillars-second-study.png` | Restored the device and preserved the full correction sentence. Rejected newly invented import badges in the current resource list and branding placed inside the device. |
| `pillars-refined-study.png` | Final priorities board: import review appears only in the proposed column; branding belongs to the scene. Future recommendations are clearly marked. Visual examples are synthetic and are not proof of shipped features. |

Final backdrop generation prompt:

> Use case: ui-mockup. A precise refined DESIGN STUDY for a native macOS Workbench sheet titled 'Change backdrop'. Wide landscape composition, system font, quiet light appearance with restrained mint accent, spacious but compact around 920 by 650 points. This is NOT a website or app marketing poster. Show one sheet with left 16:9 widescreen scene preview (critically do not make the scene portrait): a coastal landscape, tall neutral black device frame with gray screen, and a small generic text wordmark 'Example Co' top right. Right chooser with readable thumbnails in two columns grouped 'In your scenes' and 'Starters', and a 'Choose image…' button. Under the preview: caption 'Preview only', three native sliders labelled 'Zoom', 'Horizontal crop', 'Vertical crop', and a small 'Centre crop' text button. Bottom bar at left 'Your device, logo and persona stay in place.' and at right Cancel plus Use backdrop, large clear click targets. Selected thumbnail mint outline and checkmark. Do not show top-level app navigation, favourites, animations, Live badges, camera controls, broadcast status or new brand logos/taglines. Add a small external caption below mockup 'Refined concept · same scene, new backdrop · not shipping UI'. Include a modest inset to right or below showing missing backdrop state: 'Backdrop missing' and button 'Change backdrop…', with retained phone and logo outline. No implied actual device feed or remote interaction. Craft reference: measured Apple native panel proportions, normal materials, readable contrast, no exaggerated glass, no 3D laptop hardware.

Pillar generation brief: five rows labelled Dictate, Read aloud, Annotate, Present, Saved resources. Columns Current strengths and Recommendations — not implemented here. The final recommended labels are Context-respecting insertion; Resume one retained reading; Capture the marked image; A fresh branded snapshot; Review an exchanged library. Footer states voice engines support Dictate/Read aloud and requires same-input comparisons before changing defaults. Two editing passes removed unsupported UI details described above.

Final pillar editing prompt:

> Make only two precise corrections to this five-row Workbench product-direction board. 1) In bottom Saved resources row LEFT Current strengths cell, remove Added and Unchanged badges completely. It should only show file names and types. Keep Added/Changed/Unchanged in the RIGHT recommendation cell. This distinction is essential: import review is future work. 2) In BOTH Present row cells, move Example Co branding OUTSIDE the phone, onto the top-left of the landscape. Keep the same phone and landscape on both sides, with a neutral blank light-gray phone screen. Branding belongs to the surrounding scene, not the phone's content. No other changes. Preserve all row titles, column headings saying recommendations not implemented here, labels, engine note and footer 'Product direction study · not app screenshots'. No new badges, captions, timelines, controls, words or colours.
# Two independent visual journeys · 13 September 2026

Built-in image generation produced `site/assets/guide/experience-journeys-first.png` and `experience-journeys-refined.png`. Both were shown in the task. The first was rejected for scenery inside the phone, disappearing persona and invented poetic document text. The refinement clarifies independent desktop and presentation journeys. It remains a concept: the desktop picker/motion control is proposed, and the three-column preparation layout is not an instruction to replace the actual editor.

The handbook pairs this experiment with the previously verified actual native backdrop screenshots. New website screenshots were captured during desktop/lifecycle/mobile review, separate from image generation.

Initial prompt (built-in tool):

```text
Use case: ui-mockup. Create a polished landscape product design study for Workbench, a restrained native macOS utility. This is an exploration for a public product handbook, not shipping UI. Show TWO INDEPENDENT USER JOURNEYS as two spacious horizontal rows of three realistic Mac screen mockups each. Editorial, precise typography, off-white paper, slate labels, small mint accent. No giant marketing slogans.
Title exactly "Two ways to make a space your own".
Upper row label exactly "Everyday desktop". Three frames labeled "Choose", "Settle in", "Motion, if wanted". Same beautiful photoreal coastal headland wallpaper across these frames: first small native picture picker, second a normal quiet desktop with a small document window and wallpaper behind it, third same desktop with delicate ocean-motion annotation, a small visible pause control ONLY inside an open wallpaper settings popover. Do not paint motion streaks over the desktop. This route works by itself with no phone and no presentation.
Lower row label exactly "Presentation". Frames labeled "Prepare", "Present", "End". First a minimal composition editor using that same coastal source picture plus centered portrait phone frame and a small persona card. Second clean presentation of that composition with only a bottom-right mobile icon, divider and chevron control tile; NO "Live" or "Demo" words, no dictation controls. Third normal desktop and document window again, phone frame/persona/presentation controls gone. The normal desktop uses a DIFFERENT calm woodland wallpaper to make it clear the presentation scene is temporary.
A small note between rows reads exactly "Reuse a picture when you choose. Each keeps its own crop and settings."
Footer exactly "CONCEPT STUDY · PROPOSED DESKTOP EXPERIENCE". Equal visual weight to both rows. Clear ordered labels; large readable images and 16:10 Mac windows. No fake app logos, no tenant dashboards, no agent buttons, no computer hardware bezels, no lock screen or clock, no forced arrow that implies everyone must traverse both rows. The lasting desktop is not automatically changed by a presentation.
```

Refinement prompt (built-in edit using the initial image):

```text
Edit this Workbench concept board while preserving the two-row six-frame layout, coastal desktop upper row, woodland desktop at lower End, exact headings and typography. Correct only misleading content: In BOTH lower Prepare and Present screens, the phone must display the SAME plausible white mobile app screen headed "Appointments" with short list rows "09:00 Team check-in", "10:30 Site visit", "14:00 Follow-up". The phone must not display scenery or be transparent. In Prepare replace the enormous wordy persona right panel with a SMALL finished overlay card at the bottom-right of the actual composition preview: round fictional portrait, label "Morgan", second line "Site manager"; no description or biography. In Present retain that SAME small persona card at bottom-right of scene above the little phone-icon/divider/chevron tile. Preserve phone and persona positions consistently between Prepare and Present. In the two upper Notes windows replace all poetic/promo text with a realistic simple document titled "Today" and three short lines "Review the draft", "Prepare the call", "Send the notes". The lower End document also says those same lines under "Today". All screens are proposed design concepts. Do not add controls, logos, language or new features. Keep footer "CONCEPT STUDY · PROPOSED DESKTOP EXPERIENCE".
```

## Native mobile Preview studies — 13 September 2026

These image-generation experiments were shown inline during the review. They are hypotheses, not runtime evidence. The mobile page pairs them with unedited Simulator screenshots.

| File | Decision |
| --- | --- |
| `site/assets/guide/mobile-first-study.png` | Kept emphasis on Dictate and two tabs. Rejected invented PDF support and confusing Backdrops-as-focus framing. |
| `site/assets/guide/mobile-refined-study.png` | Kept separate Backdrops and Wallpapers, labelled composition parts, and explicit export. Rejected invented promotional copy and decorative home hero. |
| `Mobile/Workbench/Assets.xcassets/Coast.imageset/Coast.png` | Accepted as a synthetic bundled starter picture. Generated portrait despite the landscape request; checked visually for useful crop coverage. No real location or photographer attribution is claimed. |

The app icon adapts the existing five-bar Workbench mark using the native Core Graphics script `scripts/mobile-icon.swift`; it is not generated logo artwork.

### Initial mobile UI prompt

```text
Use case: ui-mockup. Create a polished native iPhone app design study for Workbench, an account-free everyday utility. Landscape board showing THREE full-height iPhone screens at realistic aspect ratio on warm off-white background, not a marketing landing page. Restrained mint/slate palette, Apple system typography, plenty of breathing room, native rounded cards and toolbar buttons, legible ordinary copy. Left screen: large title 'Workbench', small subtitle 'A few useful things.', a large Dictate card with microphone symbol and 'Speak. Review. Share.', then equal Read aloud and Mark up actions, then two smaller entries 'Backdrops' and 'Wallpapers'. Bottom native tab bar only 'Tools' and 'Saved'. Middle screen: a dictation result, title 'Your words', an Original / Clean segmented control, editable text 'Meet at 3pm. Bring the revised drawings.', a small understated status 'Saved on this iPhone', large bottom Share button, Copy secondary. No chat UI, AI sparkles, subscription, sync, hamburger, decorative graphs or made-up Live status. Right screen: independent 'Wallpapers' workspace, a beautiful calm coastal image portrait preview below two simple controls 'Picture' and 'Fit', bottom button 'Share image', one calm line 'Set it in Photos or Wallpaper settings.' Image should make realistic native affordances, touch targets, information hierarchy and one-handed use assessable. Board footer exact text 'CONCEPT • NOT SHIPPING UI'. The three screens should be the focus, crisp and beautiful with sensible spacing.
```

### Refined mobile UI prompt

```text
Use case: ui-mockup. A refined native iPhone design study for Workbench, composed of three accurate full-height iPhone screens on a plain off-white landscape board. Understated Apple system type, slate and mint, accessible touch targets, professionally crafted hierarchy. This is an iteration that corrects confusing wallpaper/presentation framing. Left phone: Workbench title, hero Dictate card with 'Speak. Review. Share.', small Read aloud and Mark up cards, then clear separate rows 'Backdrops' with 'Prepare a picture for presenting' and 'Wallpapers' with 'Make a picture fit your screen'. Bottom only Tools and Saved tabs. No PDF claims. Centre phone: title 'Backdrops', wide 16:9 preview with calm coastal background, a modest phone screenshot frame in centre and a small fictional persona round portrait bottom right, elegant but clearly an image composition. Below preview ordinary labeled rows Background, Image, Logo, Persona each with Replace action. Bottom Share image and Show buttons. This is preparation not a live camera or wallpaper dashboard. Right phone: title 'Wallpapers', immersive calm coastal image portrait crop, simple Zoom slider below, visible 'Position' control, bottom 'Share image'. Small helper 'Choose it in Apple’s Wallpaper settings.' Do not depict automatic installation, animatedvideo, live recording, floating controls over other apps, AI sparkle, marketingcopy, paywall or cloud sync. One concept footer 'CONCEPT • NOT SHIPPING UI'. Make the distinction between separate image jobs and reuse obvious through precise UI labels rather than diagrams.
```

### Coast starter prompt

```text
Use case: photorealistic-natural. Create a beautiful serene high-resolution landscape wallpaper image that also crops well to a portrait iPhone screen. A secluded Australian coastal headland at early morning, soft peach horizon in upper third, slate-blue ocean, layered sandstone cliffs with natural coastal grasses occupying lower left, gentle surf forming fine white lines, open quiet atmosphere. Realistic editorial landscape photography, restrained natural colour, no exaggerated HDR, no fantasy, no buildings, no people, no words, no logos, no devices, no interface, no border. Balanced composition with clear usable central portrait crop and uncluttered sky for readable clock/icons. This will be a freely bundled synthetic starter picture in Workbench. Produce only the full-bleed photograph.
```

Claude reviewed a generic public product brief with no repository source or private records. We accepted the emphasis on foreground recording, explicit reuse, retained originals and a small navigation hierarchy. We retained a bounded backdrop composition because it serves the already established presentation job; arbitrary layers, blend modes and a full design editor remain out of scope. Native tests and parent review, rather than model agreement, establish behavior.

Mobile actual evidence: `mobile-tools-actual.png`, `mobile-wallpaper-actual.png`, `mobile-reading-actual.png` and `mobile-markup-focus-actual.png` are unedited iPhone XCTest attachments. `mobile-ipad-tools-actual.png` is the corresponding iPad attachment. `mobile-ipad-present-actual.png` and `mobile-ipad-paused-actual.png` are native Simulator-window captures from manual testing. All use synthetic content; none proves physical-device model quality or audience visibility.

Actual photo-handoff captures (`photo-handoff-iphone-preview-actual.png`, `photo-handoff-iphone-saved-actual.png`) come from final native Simulator UI tests with cloud access disabled. `photo-handoff-mac-actual.png` and `photo-handoff-offline-actual.png` use the actual Mac view/shared model in a disposable app with an explicitly simulated transport. Its synthetic photo has a fixed fixture timestamp. Neither set proves a physical camera or live CloudKit transfer.

## Persona portrait starter library — 13 September 2026

Eight fictional portraits generated with the built-in image tool. Role labels and background colours are native editable controls, not baked into the picture. Actual PNG alpha was checked for every bundled asset. A reference-based intermediate batch produced opaque checkerboards and was rejected; the final four were regenerated from text. Demographic variety guides the artwork, not the app’s labels or filtering.

### care-lead

Asset: `Resources/PersonaPortraits/care-lead.png`

Prompt:

> Use case: stylized-concept. Asset type: individual fictional persona portrait for the Workbench native Mac/iPhone starter library. Create ONE centered head-and-shoulders bust portrait, polished contemporary editorial 3D illustration with restrained natural proportions, soft tactile shading and clear facial features, not childish or plastic. Square 1024x1024 composition, subject fills 82 percent height, complete top of head and shoulders inside frame, lower torso fades nowhere and has a clean cut edge at the bottom. Soft even frontal studio lighting. An adult Black woman healthcare team leader aged about 45, natural short coiled hair, subtle glasses, plain teal clinical scrub top, relaxed confident warmth. GENUINELY TRANSPARENT BACKGROUND with alpha channel, all outside pixels transparent, including around hair. No backdrop, no coloured circle, no text, no badge lettering, no logo, no frame, no label, no watermark, no checkerboard pixels. The app adds its own native editable background colour and role text. One person only, no equipment or gestures obscuring face.

### field-lead

Asset: `Resources/PersonaPortraits/field-lead.png`

Prompt:

> Use case: stylized-concept. Asset type: individual fictional persona portrait for the Workbench native Mac/iPhone starter library. Create ONE centered head-and-shoulders bust portrait, polished contemporary editorial 3D illustration with restrained natural proportions, soft tactile shading and clear facial features, not childish or plastic. Square 1024x1024 composition, subject fills 82 percent height, complete top of head and shoulders inside frame, lower torso fades nowhere and has a clean cut edge at the bottom. Soft even frontal studio lighting. An adult East Asian woman construction site supervisor aged about 40, navy collared shirt, simple orange high-visibility vest with reflective strips, plain white hard hat, confident friendly expression. GENUINELY TRANSPARENT BACKGROUND with alpha channel, all outside pixels transparent, including around hair. No backdrop, no coloured circle, no text, no badge lettering, no logo, no frame, no label, no watermark, no checkerboard pixels. The app adds its own native editable background colour and role text. One person only, no equipment or gestures obscuring face.

### front-desk

Asset: `Resources/PersonaPortraits/front-desk.png`

Prompt:

> Use case: stylized-concept. Asset type: individual fictional persona portrait for the Workbench native Mac/iPhone starter library. Create ONE centered head-and-shoulders bust portrait, polished contemporary editorial 3D illustration with restrained natural proportions, soft tactile shading and clear facial features, not childish or plastic. Square 1024x1024 composition, subject fills 82 percent height, complete top of head and shoulders inside frame, lower torso fades nowhere and has a clean cut edge at the bottom. Soft even frontal studio lighting. An adult South Asian man hospitality front-desk lead aged about 30, warm brown skin, short tidy hair, plain warm blue collared shirt without tie, approachable calm expression. GENUINELY TRANSPARENT BACKGROUND with alpha channel, all outside pixels transparent, including around hair. No backdrop, no coloured circle, no text, no badge lettering, no logo, no frame, no label, no watermark, no checkerboard pixels. The app adds its own native editable background colour and role text. One person only, no equipment or gestures obscuring face.

### operations-lead

Asset: `Resources/PersonaPortraits/operations-lead.png`

Prompt:

> Use case: stylized-concept. Asset type: individual fictional persona portrait for the Workbench native Mac/iPhone starter library. Create ONE centered head-and-shoulders bust portrait, polished contemporary editorial 3D illustration with restrained natural proportions, soft tactile shading and clear facial features, not childish or plastic. Square 1024x1024 composition, subject fills 82 percent height, complete top of head and shoulders inside frame, lower torso fades nowhere and has a clean cut edge at the bottom. Soft even frontal studio lighting. An adult white woman operations director aged about 60, short silver hair, contemporary charcoal jacket over cream top, confident relaxed smile. GENUINELY TRANSPARENT BACKGROUND with alpha channel, all outside pixels transparent, including around hair. No backdrop, no coloured circle, no text, no badge lettering, no logo, no frame, no label, no watermark, no checkerboard pixels. The app adds its own native editable background colour and role text. One person only, no equipment or gestures obscuring face.

### logistics-lead

Asset: `Resources/PersonaPortraits/logistics-lead.png`

Prompt:

> Use case: stylized-concept. Asset type: individual fictional persona portrait for the Workbench native Mac/iPhone starter library. Create ONE centered head-and-shoulders bust portrait, polished contemporary editorial 3D illustration with restrained natural proportions, soft tactile shading and clear facial features, not childish or plastic. Square 1024x1024 composition, subject fills 82 percent height, complete top of head and shoulders inside frame, lower torso fades nowhere and has a clean cut edge at the bottom. Soft even frontal studio lighting. An adult Black man logistics manager aged about 55, closely cropped salt-and-pepper hair and short beard, dark green polo shirt and simple unbranded yellow high-visibility vest, friendly capable expression. GENUINELY TRANSPARENT BACKGROUND with alpha channel, all outside pixels transparent, including around hair. No backdrop, no coloured circle, no text, no badge lettering, no logo, no frame, no label, no watermark, no checkerboard pixels. The app adds its own native editable background colour and role text. One person only, no equipment or gestures obscuring face.

### care-coordinator

Asset: `Resources/PersonaPortraits/care-coordinator.png`

Prompt:

> Use case: stylized-concept. Asset type: individual fictional persona portrait for the Workbench native Mac/iPhone starter library. Create ONE centered head-and-shoulders bust portrait, polished contemporary editorial 3D illustration with restrained natural proportions, soft tactile shading and clear facial features, not childish or plastic. Square 1024x1024 composition, subject fills 82 percent height, complete top of head and shoulders inside frame, lower torso fades nowhere and has a clean cut edge at the bottom. Soft even frontal studio lighting. An adult Middle Eastern man healthcare coordinator aged about 35, warm olive skin, dark curls, short neat beard, plain navy clinical scrub top, relaxed warm expression. GENUINELY TRANSPARENT BACKGROUND with alpha channel, all outside pixels transparent, including around hair. No backdrop, no coloured circle, no text, no badge lettering, no logo, no frame, no label, no watermark, no checkerboard pixels. The app adds its own native editable background colour and role text. One person only, no equipment or gestures obscuring face.

### hospitality-lead

Asset: `Resources/PersonaPortraits/hospitality-lead.png`

Prompt:

> Use case: stylized-concept. Asset type: individual fictional persona portrait for the Workbench native Mac/iPhone starter library. Create ONE centered head-and-shoulders bust portrait, polished contemporary editorial 3D illustration with restrained natural proportions, soft tactile shading and clear facial features, not childish or plastic. Square 1024x1024 composition, subject fills 82 percent height, complete top of head and shoulders inside frame, lower torso fades nowhere and has a clean cut edge at the bottom. Soft even frontal studio lighting. An adult Latino man head chef aged about 45, medium brown skin, short dark hair, plain cream chef jacket without hat or lettering, calm friendly expression. GENUINELY TRANSPARENT BACKGROUND with alpha channel, all outside pixels transparent, including around hair. No backdrop, no coloured circle, no text, no badge lettering, no logo, no frame, no label, no watermark, no checkerboard pixels. The app adds its own native editable background colour and role text. One person only, no equipment or gestures obscuring face.

### field-technician

Asset: `Resources/PersonaPortraits/field-technician.png`

Prompt:

> Use case: stylized-concept. Asset type: individual fictional persona portrait for the Workbench native Mac/iPhone starter library. Create ONE centered head-and-shoulders bust portrait, polished contemporary editorial 3D illustration with restrained natural proportions, soft tactile shading and clear facial features, not childish or plastic. Square 1024x1024 composition, subject fills 82 percent height, complete top of head and shoulders inside frame, lower torso fades nowhere and has a clean cut edge at the bottom. Soft even frontal studio lighting. An adult white woman field technician aged about 28, fair skin, light brown hair tied back neatly, plain dark blue work shirt with no vest and no hat, relaxed confident expression. GENUINELY TRANSPARENT BACKGROUND with alpha channel, all outside pixels transparent, including around hair. No backdrop, no coloured circle, no text, no badge lettering, no logo, no frame, no label, no watermark, no checkerboard pixels. The app adds its own native editable background colour and role text. One person only, no equipment or gestures obscuring face.
