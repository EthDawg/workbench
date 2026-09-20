# Personas and presentation overlays

A saved persona is reusable finished artwork or an editable portrait card. A **group** collects the cards for one audience. Its **layout** places several copies on screen; its private name stays in preparation. Mobile scenes still use one independent placed persona.

## Quick: show one card

Open **Overlay cards…** in the Workbench menu. Import or paste finished artwork, or choose a starter portrait and edit its visible label/colour. **Show one card** preserves the simple one-card workflow. The nearby controls provide Hide, Lock and Size; a prepared group's candidates remain scoped to that group, while **All saved** offers one card at a time from the frozen saved list. A shown card never changes merely because you browse another library item.

From any app, press **Control–Option–I** to show or hide the selected persona. Press **Control–Option–Left Arrow** or **Control–Option–Right Arrow** to flip through the current prepared group, or through all saved personas when no group is selected. These three defaults are editable and practisable under **Keyboard**. If no card is visible, either arrow shortcut first shows the current persona; it never starts a multi-overlay session.

## Prepare several overlays

1. Create a group and choose its members in Personas. Prepare each audience separately.
2. Open **Arrange overlays…**. Add the members you want to place. Each placed copy has its own visibility, lock, size and position; the same image can appear twice. New copies start locked so clicks pass through to the demo.
3. Select each copy in the placement preview/list. Adjust it using the native Position menu and size control. Reorder, duplicate or remove a copy without deleting the original image. Save the layout explicitly. The small preview is approximate; native display framing must be checked.
4. Use **Demo groups…** to choose and order the groups in this presentation. Only those explicitly prepared choices become available during the demo. Public labels are optional; the live menu otherwise says Set 1, Set 2 and numbered personas, never private group names or filenames.
5. Choose **Start overlays**. Optional **Soft reveal** fades in the initial artwork or a newly added copy briefly; it does not animate faces or loop. It respects Reduce Motion. Start defaults to still appearance.

A session supports up to eight groups, eight placed overlays per group and 32 different prepared personas, within a 256 MB rendered-image budget. Unreadable images or unsupported preparation block Start before replacing the current session. This avoids loading a whole unbounded library during a meeting.

## During the demo

The compact tile shows a stack-of-cards icon and visible count. **Click** opens a native menu; hover only provides a hint. The tile can be dragged/snapped, and Control position offers the same named destinations without dragging.

- **Next/Previous set** changes the prepared overlays as you manually change browser tabs or apps. Each set retains its current placements when you return. This does not navigate the browser for you.
- **Choose overlay** targets one copy. Show/hide, lock, size, position, order and replace affect that copy; Add creates another copy from the frozen prepared members.
- **Hide all temporarily** conceals artwork without discarding any per-copy hidden states. **Show again** restores that exact arrangement. Switching sets while paused stays hidden.
- **Save this layout for next time** explicitly saves the current group's arrangement. A conflicting preparation change is reported instead of overwritten. Other groups' temporary changes are not implicitly saved.
- **End overlays** removes all of this session's cards and controls. It keeps saved personas/layouts, leaves browser tabs and other apps alone, and does not restore desktop wallpaper. Unsaved live placement changes are temporary.

The menu-bar panel also exposes controls, Previous/Next, Hide/Show and End while a multiple-overlay session exists. **Keyboard shortcuts** includes the same five actions. They remain off by default so they do not collide with the three enabled single-persona shortcuts; assign and practise combinations in Workbench's existing conflict-checking interface. Stream Deck can send a configured hotkey; there is no special Stream Deck integration. No global Escape, browser-tab shortcut or hover-only action is added. Explicit keyboard focus selects the tile; Space opens its native menu.

## Before sharing and after presenting

Prepare private names and image choices before screen sharing. Private preparation windows can themselves be captured if you show them; only the floating controls' input is restricted to audience labels. Inspect a receiving Teams/Zoom device before promising an audience result.

Whole-display sharing is the intended initial route for multiple native overlays. A browser-tab share excludes these separate windows. Individual-window and multi-application sharing depend on the meeting app and need receiver testing. Workbench cannot promise its controls are invisible in another app's capture. A window flag is not proof of exclusion.

Starting a mobile device scene pauses the independent multiple-overlay session; it does not automatically resume on ending that scene. A persona embedded in the scene remains part of its rendering. Choose Show again explicitly after returning to browser/app demonstrations, or End overlays to finish. Quit ends all app-owned overlay windows; nothing reappears automatically at launch.

## Ownership, compatibility and recovery

The existing scene directory owns normalized PNG originals and `persona-library.json`. Saving a prepared multi-overlay layout or demo sequence promotes the persona archive to **version 3** and first retains an exact hashed pre-upgrade manifest. Versions 1 and 2 remain readable and are not automatically turned into several visible cards. Older apps reject version 3; retain the prior app and manifest together if rolling back.

`persona-overlay.json` still holds legacy single-card positioning. `persona-controls.json` holds the one HUD location. The multiple-overlay layout lives with its group, not in another database. A live session owns frozen rendered images, public labels, allowed groups and working placements. Library edits cannot silently alter those pixels or add candidates. Successful explicit removal can subtract affected items; it never substitutes another persona. Missing or newer files are preserved, and stale writes fail rather than overwriting external changes. Removing an entry retains its original image because saved scenes can still use it.

This increment adds no cloud sync for overlay groups, browser extension, DOM/tab tracking, URL reading, camera, screen capture or backend. Multiple live browser-window composition is a separate capture job. See the [category research and decision record](research/multiple-overlays.md) and [visual guide](https://workbench-mac.vercel.app/personas/) for evidence, concepts and the current release boundary.

## Validation status

At source `163f30a` on `feature/multiple-persona-overlays`, the integrated scene suite passed **88 tests / 2,367 assertions**. A sandboxed run could not access existing display/private-pasteboard checks; the normal-desktop rerun passed. The broader StageKit CI-mode suite also passed **114 tests / 2,533 assertions**, excluding its live menu-bar popover check. Its previous all-shortcuts-enabled assertion now checks the five new opt-in actions are disabled while existing defaults remain enabled. Nine new session tests cover independent copies, bounded snapshots, paused switching, frozen images, conflict-aware saving, old/future archives, empty-set return and safe visible feedback.

The later single-persona shortcut increment adds a focused mode with **5 tests / 76 assertions** covering the three enabled defaults, conflict-safe migration, frozen ungrouped cycling, show/hide lifecycle and read-only cycling without writes. The changed persona cases also pass inside the broader scene run; this working source has not yet been installed as a signed Preview or physically exercised with the three global keys.

Focused native QA used a disposable library and bundled fictional portraits. Preparation, Duplicate, named positioning, explicit Save, unsaved Done/Keep editing, sequence inspection/Cancel and Start after dismissal passed. The live menu was opened by click and explicit keyboard focus/Space. Hiding one copy, Hide all, changing sets while paused, returning and Show again retained the intended visibility mask. A native receipt recorded three click-through artwork windows and one control tile. See `site/assets/guide/overlays-preparation-actual.png` and its provenance record.

The isolated host initially failed to load external test dylibs and had unbounded fixture-window sizing; both harness problems were corrected before native acceptance. The app release target compiled successfully. Eight site tests and the static site build passed. Receiving Teams/Zoom views, multiple displays, VoiceOver and physical configured hotkeys remain unverified. No public binary or App Store release is claimed by this guide.

Signed local Preview **20260914204356** was installed and opened with the existing scene and persona library present. Its strict Developer ID signature passed normal macOS verification; the installed executable matches the archive. The preparation entry and five disabled shortcut defaults were confirmed in the installed UI without saving a user layout. The previous app was retained by the normal installer. This build is not notarized or in the public download.
