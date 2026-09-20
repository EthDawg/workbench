# Workbench: jobs, surfaces and interaction contract

Specification updated: 20 September 2026. Maintained with the code. The release record distinguishes implemented, tested and published behavior. The public guide lives at `/guide/` on the Workbench site.

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
| Hear a selection from another Mac app | That app and macOS Services own the explicit selection | Open a review draft; keep or replace an existing reading; wait for Listen |
| Narrate a screen for later slides | Display under the pointer, then Mac microphone | Capture once with the pointer, retain linked audio/transcripts, order and revise sections |
| Take a break | Timer session | Duration, start/pause/resume, hide |
| Chain an audio workflow | Shortcuts Record Audio owns recording/cancel | Transcribe with Workbench receives a file and returns text |

Tapping an iPhone field focuses it; the user then taps the Dictation button. Workbench's USB preview sends no touches, keys or Mac dictation to the device. A narrow Mac browser page remains a Mac field. Apple documents that iPhone Mirroring does not support the iPhone microphone or camera.

**Connection & audio…** is available in preparation and Source. First source selection is explicit; reconnect uses only the saved device ID. End preview & open releases capture and closes the presentation before launching Apple’s app. This does not add phone audio to Workbench. The [phone presentation contract](phone-presenting.md) owns route-specific steps and voice rehearsal.

Sources: [iPhone dictation](https://support.apple.com/en-gb/guide/iphone/iph2c0651d2/ios), [iPhone Mirroring](https://support.apple.com/en-au/120421), [QuickTime device capture](https://support.apple.com/en-au/guide/quicktime-player/qtp356b55534/mac).

## Surfaces

| Surface | Activation | Owns | Closing/focus |
| --- | --- | --- | --- |
| App window | Open app/menu/configured shortcut | Drafts, history, models, settings, scenes/personas, keyboard practice | Ordinary editing focus; close does not quit or delete saved work |
| Selected-text Service | Services menu while another app exposes selected plain text | One pending reading import, never surrounding content or clipboard fallback | Opens Read aloud; Keep current or Replace reading resolves a conflict; neither starts playback |
| Snap & Talk editor | App navigation; dedicated global shortcut captures outside it | User-chosen session folder, ordered screenshots, narration and recovery | Closing or switching sessions does not delete work; queued transcription resumes from saved audio |
| One menu bar entry | Click/configured shortcut; Window offers recovery | Discover and launch jobs; truthful status | Closing the launcher leaves active work and the floating toolbar intact |
| Floating toolbar | Shown on first launch; remembered Show floating toolbar setting | Quiet idle indicator, hover actions or remembered expanded tools, then recording and result in one window | Shares one saved position. Hidden during screenshot acquisition; returns to tools when done. Hiding idle tools never hides active recording controls |
| Presentation tile | Workbench presentation is active | Device presentation only | Starts collapsed: phone icon, divider, chevron. Click or Command-/ opens. Escape closes open controls first, otherwise ends presentation |
| Persona overlay | Explicit Show over browser | Audience-visible finished artwork | Drag or Position menu; lock enables click-through; hidden on app launch |
| Switch to | Configured global shortcut, menu or Chrome extension | Named saved-link destinations in paired Chrome profiles | Transient picker; Escape restores the prior app, selection hides it before routing, failures explain recovery. Labels may be visible in a screen share. |
| Break timer | Explicit timer action/shortcut | One countdown session and its separate window | Drag or choose one of eight Position menu anchors; Hide/close keeps the countdown and placement |
| Annotation layer | Explicit drawing action/shortcut | Marks over the current screen | Escape leaves drawing; existing clear/undo semantics remain |

Snap & Talk preserves completed narration while the next screenshot captures. Cancelling a rerecord (or discarding silence) restores the section's prior readiness and keeps its earlier audio, original transcript and edited text. Portable sessions accept only each section's own UUID folder under `items/` or `trash/`; malformed paths and symbolic links are rejected before edits or deletion.

Snap & Talk's **Reorder…** action opens a compact list with screenshot thumbnails and narration previews. Drag a row to the native insertion line, or select a row and use **Move up** / **Move down**. Hovering and cancelled drags never reorder the session. **Save order** commits the complete order once; **Cancel** discards it. Only drags from the same list are accepted, and completed/cancelled drag tokens expire. Saving retains the latest section metadata, media and original/edited narration; changed section membership or another saved order requires reopening the list.

Snap & Talk's **Hand off** menu is an explicit local bridge, not an agent platform or upload API. It copies a target-neutral task prompt that points to the session's bundled `SKILL.md`, reveals the folder in Finder and opens Claude, ChatGPT or Codex when installed. The user grants the chosen app folder access and pastes the prompt; Workbench neither uploads the screenshots nor submits the request.

The mobile tile contains no Dictate, Read aloud, cleanup modes or model downloads. Presentation does not redefine a global voice shortcut. Reject new Mac microphone capture when the presentation is the intended input surface; an explicitly selected Mac text field remains a separate job.

The selected-text Service preserves the supplied string exactly, including whitespace and line breaks. No selection is an error; it must not read the whole screen, general clipboard, focused window or Accessibility tree to invent input. A selection beyond the active reading provider's limit remains reviewable but Listen and Save audio stay unavailable until it is shortened. Speko disclosure remains visible, and only an explicit Listen or Save audio action may send text online.

## Saved-resource import review

Saved resources → Library → Import library opens a review before changing saved data. Show New, Changed and Unchanged counts, unavailable incoming file references, and an explicit note that files are not bundled. Selecting a changed row exposes both versions of its name, kind, product, persona, text/path, notes and favorite state. Keep mine is the default; Use incoming selects that record for replacement. New records are added on Apply import. Keep library completes a no-op review; Cancel discards the review.

Apply commits all chosen changes together. Invalid, unsupported, oversized or duplicate-ID input cannot mutate the library. A failed save retains review choices for retry. A changed saved file blocks Apply; Review again reloads it and resets decisions. Export/import do not share browser-profile bindings or security bookmarks. Retain local attachments on a metadata-only update of the same destination; changing its path/URL removes the old attachment. Missing files remain references with Locate file recovery.

## Dictation states

1. Idle: the optional floating toolbar rests as a small indicator. Hover gently reveals Dictate, the current dictation cleanup mode, Snap & Talk and Expand. Leaving collapses after a short grace period; an open native menu or drag retains the controls. Click the indicator or Expand to keep all tools open, including Draw and Present. Collapse returns to the indicator without reopening from window-resize events. Reveal uses a restrained spring and fade, disabled by Reduce Motion. Drag empty header space or choose Position in the menu. Every drop snaps to the highlighted named position; arbitrary free placement is no longer used for this toolbar. The resting pill is vertical at Left/Right centre and horizontal at top/bottom positions, including corners. Side hover controls retain the full pill height so its tips stay inside the revealed window. Previously saved free placement resolves to its nearest dock. Both show/hide and explicit expansion are remembered. Change mode selects Original, Light or Natural cleanup with a native checkmark, separate from the highlighted menu row. Settings remain frozen for an active capture. Window → Focus floating toolbar explicitly enables keyboard access to its native action menu; Escape leaves that interaction. Ordinary hover/click remains nonactivating. Actual configured shortcuts appear beside actions; disabled or failed bindings are labelled honestly.
2. Permission: describe the request honestly and allow cancel.
3. Recording: compact view retains state, elapsed time/input level, Stop and click-to-expand. Expanded view adds details and cancellation. No essential action is hover-only.
4. Processing: microphone off; distinguish transcription and optional cleanup. Cancellation/generation checks prevent late results replacing a later capture.
5. Delivery: paste only to the intended verified Mac target, otherwise copy and explain. Preserve the original.
6. Complete/error: truthful receipt, review/original/retry where available. Temporary results may dismiss; active capture cannot silently disappear.

A capture’s history commit precedes text delivery. Save failure keeps one local recovery with a stable ID. Retry saving performs no recognition or delivery; it preserves later draft edits and adds the original capture once. Quit retains unfinished recovery, and normal Dictate offers a confirmed discard. Cold recovery preserves a newer saved draft. Failed state and recovery writes must never be described as a saved transcript.

Cleaning an existing draft uses the same cancellable processing lifecycle. Cancel leaves the draft, retained original and cleanup method untouched. A late model result cannot overwrite cancellation or an edit made while cleanup was running. Draft cleanup never delivers text to a previously captured app target.

Snapshot cleanup configuration for each capture. Changes cannot silently alter an in-flight operation. Original, Light cleanup and Natural/local-model editing describe output behavior, not unrelated jobs. Speech recognition and text refinement are distinct responsibilities. The ordinary model-manager view owns readiness and download/load progress. Optional Ollama refinement is explicitly selected, loopback-only, bounded and cancellable; failures fall back visibly to conservative cleanup and retain the original. Never silently switch to a cloud service.

## Placement and accessibility

Compact/expanded views share one operation state. Resizing preserves the chosen anchor. Each job remembers its own placement and recovers within visible display bounds after screen changes. Dragging near a corner or edge centre previews a snap destination; release snaps. Eight named positions in a menu provide the same result without dragging. Guides only appear during drag.

Presentation defaults to right edge centre; persona to bottom right; dictation to bottom centre above the Dock; the break timer initially centres. User choices override defaults. The timer reopens at its normalized dragged position or named anchor and resolves that placement onto an available visible display after display or scale changes. Use native buttons/menus, system type/materials, accessible names, contrast/reduced-transparency fallback and Reduce Motion. Named timer movement is immediate rather than animated. Keyboard opening focuses controls; mouse recording actions preserve the destination. Source selection closes presentation controls before opening the chooser.

## Sharing

Whole-display sharing includes visible overlays. Browser-tab capture excludes separate native windows. A persona embedded in a scene belongs to that scene's rendering. Receiver-side tests are required before claiming individual-window inclusion or hidden controls in Teams/Zoom. Window sharing flags do not guarantee exclusion from another app's capture. Customer artwork remains separate from controls and original images are preserved.

### Persona controls and group boundaries

Showing a persona always provides nearby Hide, Lock and Size controls, including an older or ungrouped image. **Focus floating controls** provides keyboard access. An ungrouped overlay has one candidate: the displayed persona. It never gains access to the rest of the library through the floating picker or previous/next buttons.

For a prepared group, freeze allowed candidates and rendered artwork when showing the overlay. An ungrouped card stays scoped to itself. The [persona contract](personas.md) additionally defines explicitly prepared multiple-overlay sessions: ordered groups, independent placed copies, a compact click menu, reversible Hide all, explicit layout saves and End. Browsing or editing preparation cannot silently change a running session. Removing an item only subtracts affected copies. Read-only browsing and temporary placement must not write the archive.

Multiple-overlay sessions and device scenes have distinct owners. Starting a device scene pauses independent overlays; they do not reappear until explicitly resumed. Mobile's single placed persona and native image exports remain unchanged. Five optional global overlay actions share the existing Keyboard Coach; they start disabled. Native menu keyboard focus and click routes remain available.

The previous public Preview and a newly installed source build are separate releases. The persona contract and its actual verification record must identify which behavior was built, installed, tested and published.

## Scope

The subsequent [presenter increment](presenter-direction.md) adds Chrome profile/tab navigation to Saved resources. It does not add a persistent notes HUD or change persona artwork, device capture or mobile input. The browser adapter and native picker share the same resource IDs and local app state. Its acceptance record distinguishes automated rules from real Chrome focus and installed release evidence.

The current source includes contextual presentation controls, one persistent floating toolbar with recording states, shared placement, local refinement management, persona overlays, embedded logo discovery and live scene previews. The 20 September usability work is tracked in GitHub issues #56–58. Public download links identify the published Mac Preview separately from source and local installed builds; iOS testing and App Review remain separate stages.

## Acceptance

- Build and native suites pass; preserve old saved data and handle missing assets.
- Exercise compact/expanded states, Stop/cancel/results, frozen capture settings and focus.
- Exercise click-only presentation, keyboard opening/Escape, source/reconnect and persona rendering.
- Geometry tests cover anchors, negative display origins, removed displays, snap thresholds and resizing.
- Break-timer checks cover drag and named-position persistence, corrupt/future-data preservation, display recovery and keyboard-accessible Position actions.
- Test refinement with a loopback fixture, failures, cancellation and original preservation. Report actual model/hardware testing separately.
- Test Services metadata and selector dispatch with empty, exact and long synthetic selections; verify TextEdit and a supported browser from an installed package, including Keep/Replace and online-provider disclosure.
- Inspect native UI using synthetic data. Real phone, physical unplug and meeting receiver checks are distinct claims.
- Deploy the tested guide to the existing Vercel project, publish source and a signed Preview archive with checksum, and update installed Preview while preserving data. Use the explicit distribution workflow and report notarization, upload, tester availability and App Review separately; none is implied by a successful compile.

## Design evidence

The seven linked-task studies and three follow-up boards are illustrations, not shipping screenshots. Apply the mini/full recorder and placement principles from [Superwhisper](https://superwhisper.com/docs/get-started/interface-rec-window), contextual action discovery from [Raycast](https://manual.raycast.com/action-panel), and anchored controls from [Apple](https://developer.apple.com/design/human-interface-guidelines/popovers/). Images should explain the job and distinguish concepts from actual UI.

## Deliberate dictionary corrections

The app-window review flow follows the [dictation comparison and correction contract](dictation-comparison.md). Remember correction connects the existing dictionary to the current draft, with explicit before/after fields, preview, transactional saving and scoped Undo. It does not add a live recording or presentation control.

## Everyday utility increment

[Utility comparison and contracts](utility-comparison.md) specifies playback seeking, board image export, windowed presentation and contextual resource recall. [Commodity strategy](commodity-strategy.md) records the architecture and model-upgrade acceptance process. The floating toolbar provides a shared entry point while each operation retains its own state and preparation screen.

## Scene preparation

The native scene list supports Command/Shift selection, Backspace/Delete with a confirmation naming the captured selection, double-click or Return to rename, and drag insertion to reorder. Escape cancels a title edit; Return commits it. Search and title fields retain ordinary text-deletion behavior. Reordering is available with an empty search, with Move up/down as keyboard-accessible alternatives. Multi-selection shows the selection count instead of silently choosing a scene to present. A stale library revision prevents partial deletion or overwriting newer edits; original images are kept.

**Add scene** groups starter, image, clipboard and editable-scene import choices. **Add persona…** chooses artwork for the current scene. Independent browser overlays live under **Overlay cards** and **Arrange overlays…**; they are not a prerequisite for presenting a scene.

**Add logo → Find on the web…** opens public Google Images inside a temporary in-app browser. The person chooses an image, reviews it, then selects **Use logo**. This commits to the scene captured when the sheet opened and saves a reusable logo. Cancel leaves the scene unchanged. The importer validates bounded raster data, supports a direct image URL, and cancels superseded downloads. Search does not open an external browser or connect a personal Google Photos account.

An enabled animated starter plays in the visible, active Mac scene editor. **Pause preview** changes only the current viewing session. Crop/layout interaction, another sheet, inactivity and system motion/energy preferences pause it with a visible reason. Exported PNGs and gallery thumbnails remain still. The [motion record](gentle-motion.md) and [visual contract](../site/handbook/contract.json) own the shared motion lifecycle.

## Backdrop editing contract

Within Present a device, **Change backdrop…** previews a replacement in the existing composition. Apply patches only the image and crop; Cancel leaves the saved archive and files untouched. The same operation repairs missing images. This remains scene preparation. Persistent wallpaper is a separate accepted product direction, with its current/proposed boundaries and lifecycle in the [visual-experience contract](../site/handbook/contract.json). See [the comparison, decisions and test contract](background-management.md).

## Optional background motion

[Gentle motion](gentle-motion.md) adds a saved scene preference with off-by-default legacy behavior. Mac preparation stays still for accurate dragging; Mac presentation gets a Pause/Play background control. The iOS scene editor previews it with a separate transient Pause/Play button and still crop controls.

The non-App-Store Mac **More → Use as animated desktop** action creates an independent applied snapshot after verifying its native still. **Pause**, **Resume** and **Stop motion** sit in the scene window while that desktop session exists. End presentation keeps it; Quit, Space changes and ownership loss stop it. This is an explicit reuse action, not the proposed independent wallpaper picker. The canonical [visual contract](../site/handbook/contract.json) owns exact lifecycle/evidence.
