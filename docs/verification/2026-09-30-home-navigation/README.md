# Home recovery and collapsed navigation, 30 September 2026

Home no longer treats retained dictation audio as current work or shows the permanent Retry transcription banner. Completed transcripts remain in History. Unfinished dictation audio is a separate recovery record, reachable on Dictate through Retry transcription or Retry saving, Show recovery files and the confirmed Discard recovery action. Starting another recording retains eligible old audio in Saved recordings. This change does not edit those owners or their data.

Collapsed sidebar icons now reveal their page name on hover. Settings, the expansion control and an available update use the same hint. The hint draws beside the icon above the native scroll content, ignores clicks and adds no accessible control. The original buttons keep their accessible names and selection. Pointer exit, clicking a page, changing pages, expanding the sidebar and loss of window focus clear the hint.

This is a separable quality change on `codex/home-navigation`, based on `b06fbaa944e6b624641f2fb5557f83329c1c263d`. The commit containing this record identifies the reviewed source. The shared Preview integration owner retains installation and combined acceptance.

## Ownership

- `Sources/LocalVoice/WorkbenchHome.swift`: remove Home's duplicate recovery row and its current-work trigger; show and clear collapsed sidebar hints.
- `Sources/LocalVoice/WorkbenchDesktopChrome.swift`: hint anchors, passive native hosting and appearance.
- `Sources/LocalVoice/SurfaceGallery.swift`: pending-audio fixture, hint layout and click-through checks, and rendering native hints after native scroll layers.
- `docs/workbench.md`, `docs/design.md`, `docs/surfaces.json`: update the owning contracts and remove the two obsolete Home recovery entries.

No capture, transcript or recovery storage implementation is changed. History does not currently list unfinished dictation audio, so it must not be described as replacing Dictate's recovery path.

## Validation

| Check | Result |
| --- | --- |
| `swift build --disable-sandbox` | Passed |
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-capture-persistence.py` | 155 checks passed using exact AppModel methods and synthetic audio |
| `python3 scripts/check-surfaces.py` | 442 entries classified |
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-check-surfaces.py` | 56 tests passed |
| Home journey, page and recent-work checks within the Home gallery | 37, 111 and 14 checks passed in each appearance |
| `WORKBENCH_HOME_GALLERY_ONLY=1 .build/debug/LocalVoice --render-surfaces OUTPUT` | 38 renders, zero flags, light and dark, default and minimum widths |
| `git diff --check` | Passed |

The bounded Home pass starts with a retryable synthetic recording under its verified temporary home. It refuses an existing recovery folder or a path outside that temporary home. Visiting Home and reviewing History retain the recording and journal byte for byte, with retry and explicit discard still available. Existing checks also preserve the current Dictate draft and selection when an older transcript is opened.

The gallery checks that each rendered hint has the expected name, fits in the window and passes hit testing through to the underlying controls. The fixture selects the hovered item; it does not simulate a physical pointer. Actual pointer entry/exit, native keyboard navigation, VoiceOver and signed installed Preview acceptance remain for the combined build. The full `scripts/test.sh` suite requires exclusive shortcuts and is left to that integration run. No app was installed or published by this change.

## Visual evidence

These are production views with synthetic content, including a pending recording. They show layout, not installed acceptance.

![Home without a recovery banner and the Snap and Talk hover label](home-light.png)

![The pinned Settings hover label in dark appearance](settings-dark.png)

## Reusable acceptance scenarios

These scenarios belong to Desktop. They also explain the boundary the Pill must preserve: retained audio is durable work with a recovery path, not a permanent indicator of live activity. No new storage or global warning is needed for this change.

### Desktop: Home with retained dictation audio

Given an idle, ready app with a synthetic recording awaiting transcription, open Home. There is no recovery banner or empty Current work section. Visit another page, return Home, and open an older transcript in History. The unfinished recording and its journal remain unchanged, and the current Dictate draft and selection remain intact. Open Dictate: Retry transcription, Show recovery files and the explicit, confirmed Discard recovery action remain reachable. Completed transcripts are in History; unfinished dictation audio is not.

Repeat with another actual operation active, such as Read: Home shows that operation and its own controls, without making the older recording a second live task. Stopping that operation must not resolve or delete the recording. If a fresh dictation is started, the existing Dictate owner must first retain eligible old audio in Saved recordings. The 155 capture checks cover that admission path; this UI change must not replace it.

Evidence: the bounded Home gallery uses a real synthetic recovery journal and checks exact audio/journal bytes after Home and History visits. Its current-work render covers active controls alongside retained audio. The capture-persistence checks exercise the existing save, retry, discard and fresh-recording behavior. Installed confirmation remains below.

### Desktop: collapsed navigation discovery and exit

Given the collapsed sidebar, hover each of the eleven page destinations, including pinned Settings, then the expansion control and an available update. Each label uses the destination's own name, appears beside its icon and fits outside the scrolling clip. Hovering starts nothing and does not take focus. Move into the page, click a destination, scroll away from an item, expand the sidebar or switch apps: no stale label remains. The selected destination and hovered destination remain visually distinct.

Click a labelled icon: the original button receives the click and opens its existing page. Selecting the current page also dismisses its hint. Use Control-Command-S and normal keyboard navigation with the pointer elsewhere: collapse/expansion and page navigation still work, and a hint never becomes an extra Tab stop. VoiceOver retains each button's page name and selected state. Hover is an aid to discovering an icon, not the only way to identify or activate it.

Evidence: the gallery verifies production hint names, native bounds and click-through behavior at both widths in light and dark. It selects hover state directly, so physical entry/exit, scrolling, keyboard and VoiceOver behavior still require the signed Preview.

## Installed acceptance remaining

The shared integration owner first verifies Copy build details on the signed combined Preview, then runs the two scenarios above with disposable recordings. Record pass/fail against that build. Do not discard real user recordings for these tests.

The remaining UX boundary is deliberate: keeping audio safe should not keep Home in an alarm state. Any later proposal to put unfinished recordings in History must make those recordings and their recovery actions actually reachable there before retiring Dictate's path.
