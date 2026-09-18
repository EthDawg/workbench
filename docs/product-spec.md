# Workbench: jobs, surfaces and interaction contract

Specification: 12 September 2026. Maintained with the code. The release record distinguishes implemented, tested and published behavior. The public guide lives at `/guide/` on the Workbench site.

## Product outcome

Make frequent Mac tasks easy to start, understand and leave. Local dictation is the core utility. Annotation, persona overlays and mobile scenes help explain software. Share native conventions and placement components; keep each job's controls and state distinct.

## Jobs and input ownership

| Job | Input owner | Workbench's job |
| --- | --- | --- |
| Dictate into a Mac document or web form, including a mobile-width page | Mac microphone and selected Mac field | Record, transcribe, optionally clean, verify delivery, retain original |
| Demonstrate a real phone over USB | Physical phone touchscreen, keyboard and Dictation button | Display video in a scene; source, reconnect, position, end |
| Apple's iPhone Mirroring | Apple's separate app and supported input mechanisms | Open that app; no embedded control or microphone forwarding |
| Explain a browser demo | Browser owns page input; explicit Workbench overlay edit mode | Annotation and saved persona, move/size/lock/hide |
| Hear a draft | Reading engine, not microphone capture | Read, pause, resume, stop, export |
| Narrate a screen for later slides | Display under the pointer, then Mac microphone | Capture once with the pointer, retain linked audio/transcripts, order and revise sections |
| Take a break | Timer session | Duration, start/pause/resume, hide |
| Chain an audio workflow | Shortcuts Record Audio owns recording/cancel | Transcribe with Workbench receives a file and returns text |

Tapping an iPhone field focuses it; the user then taps the Dictation button. Workbench's USB preview sends no touches, keys or Mac dictation to the device. A narrow Mac browser page remains a Mac field. Apple documents that iPhone Mirroring does not support the iPhone microphone or camera.

Sources: [iPhone dictation](https://support.apple.com/en-gb/guide/iphone/iph2c0651d2/ios), [iPhone Mirroring](https://support.apple.com/en-au/120421), [QuickTime device capture](https://support.apple.com/en-au/guide/quicktime-player/qtp356b55534/mac).

## Surfaces

| Surface | Activation | Owns | Closing/focus |
| --- | --- | --- | --- |
| App window | Open app/menu/configured shortcut | Drafts, history, models, settings, scenes/personas, keyboard practice | Ordinary editing focus; close does not quit or delete saved work |
| Readback editor | App navigation; dedicated global shortcut captures outside it | User-chosen session folder, ordered screenshots, narration and recovery | Closing or switching sessions does not delete work; queued transcription resumes from saved audio |
| One menu bar entry | Click/configured shortcut | Discover and launch jobs; truthful status | Transient launcher, not a universal persistent mode picker |
| Dictation HUD | Explicit Mac capture/preview; completion or error | Current recording and result, compact/expanded | Stop completes; cancellation is explicit; closing options or collapsing preserves audio and paste target |
| Presentation tile | Workbench presentation is active | Device presentation only | Starts collapsed: phone icon, divider, chevron. Click or Command-/ opens. Escape closes open controls first, otherwise ends presentation |
| Persona overlay | Explicit Show over browser | Audience-visible finished artwork | Drag or Position menu; lock enables click-through; hidden on app launch |
| Annotation layer | Explicit drawing action/shortcut | Marks over the current screen | Escape leaves drawing; existing clear/undo semantics remain |

The mobile tile contains no Dictate, Read aloud, cleanup modes or model downloads. Presentation does not redefine a global voice shortcut. Reject new Mac microphone capture when the presentation is the intended input surface; an explicitly selected Mac text field remains a separate job.

## Dictation states

1. Idle: setup in the app/menu. No compulsory idle capsule.
2. Permission: describe the request honestly and allow cancel.
3. Recording: compact view retains state, elapsed time/input level, Stop and click-to-expand. Expanded view adds details and cancellation. No essential action is hover-only.
4. Processing: microphone off; distinguish transcription and optional cleanup. Cancellation/generation checks prevent late results replacing a later capture.
5. Delivery: paste only to the intended verified Mac target, otherwise copy and explain. Preserve the original.
6. Complete/error: truthful receipt, review/original/retry where available. Temporary results may dismiss; active capture cannot silently disappear.

Cleaning an existing draft uses the same cancellable processing lifecycle. Cancel leaves the draft, retained original and cleanup method untouched. A late model result cannot overwrite cancellation or an edit made while cleanup was running. Draft cleanup never delivers text to a previously captured app target.

Snapshot cleanup configuration for each capture. Changes cannot silently alter an in-flight operation. Original, Light cleanup and Natural/local-model editing describe output behavior, not unrelated jobs. Speech recognition and text refinement are distinct responsibilities. The ordinary model-manager view owns readiness and download/load progress. Optional Ollama refinement is explicitly selected, loopback-only, bounded and cancellable; failures fall back visibly to conservative cleanup and retain the original. Never silently switch to a cloud service.

## Placement and accessibility

Compact/expanded views share one operation state. Resizing preserves the chosen anchor. Each job remembers its own placement and recovers within visible display bounds after screen changes. Dragging near a corner or edge centre previews a snap destination; release snaps. Eight named positions in a menu provide the same result without dragging. Guides only appear during drag.

Presentation defaults to right edge centre; persona to bottom right; dictation to bottom centre above the Dock. User choices override defaults. Use native buttons/menus, system type/materials, accessible names, contrast/reduced-transparency fallback and Reduce Motion. Keyboard opening focuses controls; mouse recording actions preserve the destination. Source selection closes presentation controls before opening the chooser.

## Sharing

Whole-display sharing includes visible overlays. Browser-tab capture excludes separate native windows. A persona embedded in a scene belongs to that scene's rendering. Receiver-side tests are required before claiming individual-window inclusion or hidden controls in Teams/Zoom. Window sharing flags do not guarantee exclusion from another app's capture. Customer artwork remains separate from controls and original images are preserved.

## Scope

Implement contextual presentation controls, compact/expanded recording HUD, shared placement, local refinement management, and persona overlays. Logo web discovery and animated backdrop playback are separate extensions of the asset library, not reasons for a universal mode picker. The earlier publication hold was superseded by the maintainer’s 14 September release instruction. Mac Preview 3 is now notarized and published; iOS is uploaded to App Store Connect with testing and review stages still separate.

## Acceptance

- Build and native suites pass; preserve old saved data and handle missing assets.
- Exercise compact/expanded states, Stop/cancel/results, frozen capture settings and focus.
- Exercise click-only presentation, keyboard opening/Escape, source/reconnect and persona rendering.
- Geometry tests cover anchors, negative display origins, removed displays, snap thresholds and resizing.
- Test refinement with a loopback fixture, failures, cancellation and original preservation. Report actual model/hardware testing separately.
- Inspect native UI using synthetic data. Real phone, physical unplug and meeting receiver checks are distinct claims.
- Deploy the tested guide to the existing Vercel project, publish source and a signed Preview archive with checksum, and update installed Preview while preserving data. Use the explicit distribution workflow and report notarization, upload, tester availability and App Review separately; none is implied by a successful compile.

## Design evidence

The seven linked-task studies and three follow-up boards are illustrations, not shipping screenshots. Apply the mini/full recorder and placement principles from [Superwhisper](https://superwhisper.com/docs/get-started/interface-rec-window), contextual action discovery from [Raycast](https://manual.raycast.com/action-panel), and anchored controls from [Apple](https://developer.apple.com/design/human-interface-guidelines/popovers/). Images should explain the job and distinguish concepts from actual UI.

## Deliberate dictionary corrections

The app-window review flow follows the [dictation comparison and correction contract](dictation-comparison.md). Remember correction connects the existing dictionary to the current draft, with explicit before/after fields, preview, transactional saving and scoped Undo. It does not add a live recording or presentation control.

## Everyday utility increment

[Utility comparison and contracts](utility-comparison.md) specifies playback seeking, board image export, windowed presentation and contextual resource recall. [Commodity strategy](commodity-strategy.md) records the architecture and model-upgrade acceptance process. These extend existing surfaces; they do not add a universal floating mode menu.

## Backdrop editing contract

Within Present a device, **Change backdrop…** previews a replacement in the existing composition. Apply patches only the image and crop; Cancel leaves the saved archive and files untouched. The same operation repairs missing images. This remains scene preparation. Persistent wallpaper is a separate accepted product direction, with its current/proposed boundaries and lifecycle in the [visual-experience contract](../site/handbook/contract.json). See [the comparison, decisions and test contract](background-management.md).
