# Personas and presentation overlays

A saved persona is reusable finished artwork or an editable portrait card. A **group** collects the cards for one audience. Its **layout** places several copies on screen; its private name stays in preparation. Mobile scenes still use one independent placed persona.

## Quick: show one card

Open **Persona** in Workbench, or **Persona Overlay → Options → Prepare Personas…** in the menu panel. The desktop workspace shows and hides overlays directly; it does not require opening Present or dismissing a preparation sheet. **Add persona…** imports or pastes finished artwork, or chooses a starter portrait with an editable visible label/colour. The empty library also offers direct starter and image-import buttons. **Show one card** preserves the simple one-card workflow. Drag the labelled **Size** slider left to make the floating card smaller, or right to enlarge it, without unlocking the artwork. The percentage is the requested display width (6–40%); tall artwork is also limited by available height. A prepared group's candidates remain scoped to that group, while **All saved** offers one card at a time from the frozen saved list. A shown card never changes merely because you browse another library item.

**Hide** only removes the floating card from the screen. **Remove saved persona…** in the library asks for confirmation before removing that entry and its group memberships; original artwork stays available to saved scenes. **Members…** changes only the selected group's membership.

From any app, the default **Option–F** shows or hides one persona and **Option–R** advances through the current prepared group, or through all saved personas when no group is selected. **Previous floating persona** starts disabled; its suggested key is **Option–Shift–R**. Shortcuts are editable and practisable under **Keyboard**, and existing custom assignments are retained. If no card is visible, Next or an enabled Previous first shows the current persona; these single-card shortcuts never replace a prepared multi-overlay session.

## Persona and Present

The Persona workspace uses the existing saved library and overlay session. Opening it, changing pages or closing preparation leaves a shown overlay running over browsers and other windows. Use **Hide floating persona** for one card, **Hide all** / **Resume overlays** for a prepared arrangement, or **End overlays** to finish. These controls remain available even if no saved card is selected. The floating controls retain movement, locking/click-through, size, screen recovery and frozen live choices. A shown card also moves and resizes directly from its handles; see [Move and resize directly](#move-and-resize-directly). [React to my voice](#react-to-my-voice) adds an optional voice outline.

Present’s compact **Persona…** control sits beside the scene name above the preview. Add or change a card, set its size and position, or remove only its scene placement. A card placed in a scene is rendered into that presentation; a floating Persona is a separate window. Both use the same saved artwork without silently changing each other’s placements or live image snapshots.

Present keeps **Full screen**, **Window**, **Connection & audio…** and **More** below the editor. At narrower widths these actions wrap into two rows. **Scene details** contains logo, crop, device-shape and hand adjustments. The connection button opens the existing route guide, including QuickTime and iPhone Mirroring launch actions; device capture, audio limits and native fallback ownership are unchanged.

`StageKitController.personasView` supplies the standalone workspace. The host routes **Prepare Personas…** with `onOpenPersonas`; a host without that callback retains the existing preparation sheet. Scene-specific selection always uses its own sheet and keeps the original scene binding.

## React to my voice

**React to my voice** puts a quiet outline around the shown persona that brightens as you speak, so the audience can see who is talking, like the floating profile a streamer uses. Turn it on in **Persona** or in the live **Persona Overlay** menu. It is off by default and remembered.

- **Quiet at rest, lit while you speak.** While you are quiet it is a thin, still line just outside the artwork. A voice brightens it and widens it a little, outward only, so it never covers the artwork; a raised voice widens it a little more and adds a soft glow. Nothing travels around it, so it looks the same with Reduce Motion. A dark edge keeps it readable over white slides and dark editors; Increase Contrast strengthens that edge and the resting line.
- **Shape and colour come from the artwork.** A round badge gets an outline around its circle; anything breaking out of the badge, such as a hat or a name label, stays in front of it. Cards and other artwork get an outline around the rounded rectangle of their visible pixels. The colour is the artwork's most prominent vivid colour, brightened to read on screen, or Workbench mint when it has none.
- **It follows your voice, not the room.** A voice is recognised by its pitch, so fans, hiss, mains hum, typing and breaths leave the outline at rest, even when they are there from the moment it turns on. The room is learned only from steady sound, so talking for a long time without a pause never dims it, and a voice already under way when it turns on counts from its first frame. A word that opens on "s" lights it at the hiss; one that opens on "sh", "f" or "h" lights it at its vowel, because that softer hiss sounds like breath and paper. A voice through laptop speakers counts too: with speakers, other people on a call can light it, and headphones avoid that.
- **It keeps up.** The outline lights within 150 ms of the first frame of a voice reaching Workbench, and returns to rest within half a second of the last, holding through the short gaps between words. macOS hands the microphone over about a tenth of a second at a time; [the native check](verification/2026-09-28-persona-voice-ring.md) reports that delay separately.
- **The artwork keeps its size.** The persona's window grows by a few points to make room for the outline. Near a screen edge the persona moves in only as far as the outline needs to stay on screen and clear of the Dock; turning it off puts it back.
- **One speaker at a time.** In a prepared set the outline frames the selected overlay, so choosing another overlay passes the voice to it. A hidden selection has no outline.
- **Microphone use is bounded.** Turning it on asks macOS for microphone access at once, while you prepare, never later in front of an audience. The microphone runs only while the outline is on and the persona it frames is showing, and the menu item's second line names the input it is listening to. It measures loudness and pitch; nothing is recorded, kept or sent. Hiding the persona, Hide all, End, Quit, turning it off, a refused permission or a lost input stops it, the last two with a notice. When the Mac switches to another microphone, the outline follows it.

It measures alongside Dictate, meeting capture and Snap & Talk narration without taking their microphone, and none of them stops the outline.

## Prepare several overlays

1. Create a group and choose its members in Personas. Prepare each audience separately.
2. Open **Arrange overlays…**. Add the members you want to place. Each placed copy has its own visibility, lock, size and position; the same image can appear twice. New copies start locked so clicks pass through to the demo.
3. Select each copy in the placement preview/list. Adjust it using the native Position menu and size control. Reorder, duplicate or remove a copy without deleting the original image. Save the layout explicitly. The small preview is approximate; native display framing must be checked.
4. Use **Demo groups…** to choose and order the groups in this presentation. Only those explicitly prepared choices become available during the demo. Public labels are optional; the live menu otherwise says Set 1, Set 2 and numbered personas, never private group names or filenames.
5. Choose **Start overlays**. Optional **Soft reveal** fades in the initial artwork or a newly added copy briefly; it does not animate faces or loop. It respects Reduce Motion. Start defaults to still appearance.

A session supports up to eight groups, eight placed overlays per group and 32 different prepared personas, within a 256 MB rendered-image budget. Unreadable images or unsupported preparation block Start before replacing the current session. This avoids loading a whole unbounded library during a meeting.

## Move and resize directly

Bring the pointer near a card and its handles appear: a small grab handle above its top edge, and resize handles at its corners and edges. Drag the grab handle to move the card, or a corner or edge to resize it; the artwork keeps its shape, the opposite corner or edge stays put, and the size stays within the Size slider's range. Released partly off the display, the card comes back fully on screen.

The handles work while a card is locked and leave the lock as it was: the locked artwork keeps passing clicks through to the app beneath, and only the handles themselves take the pointer. They are small windows of their own, so the voice outline's room and the transparent corners of a round badge never block the app beneath. An unlocked card also drags by its artwork; a press that moves less than four points is a click, which selects the card without moving it. Using a handle changes only that copy and never changes which copy is selected. Handles never take keyboard focus from the app in front; **Position Artwork** and **Size** in the Persona Overlay menu remain the keyboard and precise route. As with every live change, saving a prepared layout stays explicit.

## During the demo

The shared floating toolbar's **Persona Overlay** menu names the selected copy and offers **Size**, **Add Overlay** and **Remove Selected**, plus set selection, artwork positioning and lifecycle controls. Add uses only the prepared set's frozen members. Remove affects the selected on-screen copy, not the saved persona. An empty set keeps Add available. The shared toolbar can be dragged/snapped or placed through its Position menu. Embedded Workbench does not open a second persona HUD.

- **Next/Previous set** changes the prepared overlays as you manually change browser tabs or apps. Each set retains its current placements when you return. This does not navigate the browser for you.
- **Choose overlay** targets one copy. Show/hide, lock, size, position, order and replace affect that copy; Add creates another copy from the frozen prepared members.
- **Hide all temporarily** conceals artwork without discarding any per-copy hidden states. **Show again** restores that exact arrangement. Switching sets while paused stays hidden.
- **Save this layout for next time** explicitly saves the current group's arrangement. A conflicting preparation change is reported instead of overwritten. Other groups' temporary changes are not implicitly saved.
- **End overlays** removes all of this session's cards and controls. It keeps saved personas/layouts, leaves browser tabs and other apps alone, and does not restore desktop wallpaper. Unsaved live placement changes are temporary.

The main **Persona Overlay** action shows or hides one card, or pauses/resumes an existing prepared arrangement. Its Options menu offers the shared live controls and explicit End actions. **Keyboard shortcuts** includes the same five actions. They remain off by default so they do not collide with the existing single-persona shortcuts; assign and practise combinations in Workbench's existing conflict-checking interface. Stream Deck can send a configured hotkey; there is no special Stream Deck integration. No global Escape, browser-tab shortcut or hover-only action is added. Explicit keyboard focus selects the tile; Space opens its native menu.

## Before sharing and after presenting

Prepare private names and image choices before screen sharing. Private preparation windows can themselves be captured if you show them; only the floating controls' input is restricted to audience labels. Inspect a receiving Teams/Zoom device before promising an audience result.

Whole-display sharing is the intended initial route for multiple native overlays. A browser-tab share excludes these separate windows. Individual-window and multi-application sharing depend on the meeting app and need receiver testing. Workbench cannot promise its controls are invisible in another app's capture. A window flag is not proof of exclusion.

Starting a mobile device scene pauses the independent multiple-overlay session; it does not automatically resume on ending that scene. A persona embedded in the scene remains part of its rendering. Choose Show again explicitly after returning to browser/app demonstrations, or End overlays to finish. Quit ends all app-owned overlay windows; nothing reappears automatically at launch.

## Ownership, compatibility and recovery

The existing scene directory owns normalized PNG originals and `persona-library.json`. Saving a prepared multi-overlay layout or demo sequence promotes the persona archive to **version 3** and first retains an exact hashed pre-upgrade manifest. Versions 1 and 2 remain readable and are not automatically turned into several visible cards. Older apps reject version 3; retain the prior app and manifest together if rolling back.

`persona-overlay.json` still holds legacy single-card positioning. `persona-controls.json` is retained for standalone StageKit compatibility; embedded Workbench uses its existing shared toolbar position. The multiple-overlay layout lives with its group, not in another database. A live session owns frozen rendered images, public labels, allowed groups and working placements. Library edits cannot silently alter those pixels or add candidates. Successful explicit removal can subtract affected items; it never substitutes another persona. Missing or newer files are preserved, and stale writes fail rather than overwriting external changes. Removing an entry retains its original image because saved scenes can still use it.

This increment adds no cloud sync for overlay groups, browser extension, DOM/tab tracking, URL reading, camera, screen capture or backend. Multiple live browser-window composition is a separate capture job. See the [category research and decision record](research/multiple-overlays.md) and [visual guide](https://workbench-mac.vercel.app/personas/) for evidence, concepts and the current release boundary.

## Validation status

At source `163f30a` on `feature/multiple-persona-overlays`, the integrated scene suite passed **88 tests / 2,367 assertions**. A sandboxed run could not access existing display/private-pasteboard checks; the normal-desktop rerun passed. The broader StageKit CI-mode suite also passed **114 tests / 2,533 assertions**, excluding its live menu-bar popover check. Its previous all-shortcuts-enabled assertion now checks the five new opt-in actions are disabled while existing defaults remain enabled. Nine new session tests cover independent copies, bounded snapshots, paused switching, frozen images, conflict-aware saving, old/future archives, empty-set return and safe visible feedback.

The later single-persona shortcut increment adds a focused mode with **5 tests / 76 assertions** covering the three enabled defaults, conflict-safe migration, frozen ungrouped cycling, show/hide lifecycle and read-only cycling without writes. The changed persona cases also pass inside the broader scene run. That source-check checkpoint did not establish signed installation or physical use of the three global keys; subsequent installed evidence is recorded below.

Focused native QA used a disposable library and bundled fictional portraits. Preparation, Duplicate, named positioning, explicit Save, unsaved Done/Keep editing, sequence inspection/Cancel and Start after dismissal passed. The live menu was opened by click and explicit keyboard focus/Space. Hiding one copy, Hide all, changing sets while paused, returning and Show again retained the intended visibility mask. A native receipt recorded three click-through artwork windows and one control tile. See `site/assets/guide/overlays-preparation-actual.png` and its provenance record.

The isolated host initially failed to load external test dylibs and had unbounded fixture-window sizing; both harness problems were corrected before native acceptance. The app release target compiled successfully. Eight site tests and the static site build passed. Receiving Teams/Zoom views, multiple displays, VoiceOver and physical configured hotkeys remain unverified. No public binary or App Store release is claimed by this guide.

Signed local Preview **20260914204356** was installed and opened with the existing scene and persona library present. Its strict Developer ID signature passed normal macOS verification; the installed executable matches the archive. The preparation entry and five disabled shortcut defaults were confirmed in the installed UI without saving a user layout. The previous app was retained by the normal installer. This build is not notarized or in the public download.

React to my voice has focused source checks and a signed Preview native check on this Mac's microphone, recorded in [the voice ring verification](verification/2026-09-28-persona-voice-ring.md). Its quiet outline and response targets ([#158](https://github.com/EthDawg/workbench/issues/158)) have an offline latency harness in that record; their native measurement, a real voice at the desk, Bluetooth headsets and a meeting receiver's view remain open.

The September 2026 Persona workspace / compact Present increment has source-level launch and layout regression checks plus synthetic offscreen renders. Signed Preview `9d4aff1` passed combined navigation, Persona display/hide and compact Present controls. Full keyboard and small-display coverage, browser/window persistence, focus/click-through, physical screen changes and real device/receiver fallback remain native checks. The [capability Preview acceptance record](releases/2026-09-27-capability-preview.md) identifies the installed candidate and these limits; offscreen views alone do not establish installed acceptance.
