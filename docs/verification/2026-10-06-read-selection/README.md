# Read reads the selection; Options on Read's panel row — 6 October 2026

Branch `claude/read-selection`, built from `main` at `5f209cab85fad6fef5c8337ff2a076bdeffbcd35`. Refs #17 and #134 (the 1 October follow-up, Options on Read's panel row). These images are production views rendered offscreen with synthetic state by the surface gallery and the toolbar gallery; they are source evidence, not an installed-app acceptance.

Synthetic: every live state is set on the model directly (`playing`, `paused`), no audio is made, nothing is read from another app, and the voices listed are the compact voices installed on the development Mac (no premium or enhanced tier was installed, so only the Compact heading appears; the tiering itself is checked with a synthetic catalogue in `--check-reading`).

## Renders

- [Panel, Read row while reading, light](panel-reading-light.png) and [dark](panel-reading-dark.png): the row reads `Stop reading`, lit in the accent, with its `Options` control; the toolbar's pill shows the same `Stop reading` for the same state.
- [Panel, idle, light](panel-idle-light.png): the Read row reads `Read`, with `Options` at its right like every other row.
- [Pill while a reading plays, light](reading-playing-light-standard.png) and [dark](reading-playing-dark-standard.png): the next action is `Stop reading` with the stop glyph (was `Pause reading`).
- [Pill while a reading is paused, light](reading-paused-light-standard.png): `Stop reading`; Resume reading stays in the chooser's Read row.
- [Chooser while a reading plays, light](chooser-recovery-light-standard.png): the Read row keeps `Pause reading` and `Stop reading`.

Read · Options, as the gallery lists the panel's native menu (the chosen voice ticked; each item's recorded effect follows the arrow):

```
Voice
  Compact
  ✓ Samantha (American)
  Eddy (American)
  …  (44 installed English voices on this Mac, by quality tier, novelty voices last)
---
Models…  → models
Open Read…  → speak
```

Native menus are not rendered to PNG by the gallery; this listing is its record of the menu.

## Counts

- `swift build --disable-sandbox` and `swift build -c release --disable-sandbox`: built.
- `.build/release/LocalVoice --check-reading-service`: 36 checks (was 25; the 11 new ones cover the three-way start, the draft rule and the one Accessibility read against a scripted adapter).
- `.build/release/LocalVoice --check-reading`: 103 checks (4 new, the Voice menu's quality tiers).
- `.build/release/LocalVoice --check-floating-toolbar`: 233 control checks, plus 19 prompt insertion, 64 text delivery, 9 Accessibility setup and 38 prompt picker checks.
- `.build/release/LocalVoice --check-core`: exit 0.
- `swift test --disable-sandbox --filter "ToolbarCoreTests|ToolbarKitTests"`: 217 tests, 2 skipped; three assertions that pinned the pill's old Pause reading label and the Read key's hint were updated and the two suites rerun clean (36 tests).
- `python3 scripts/check-surfaces.py`: Surface registry OK, 565 entries (4 new, classified: Read's Options, Voice, Models… and Open Read…).
- `.build/release/LocalVoice --render-surfaces`: 300 renders, 210 entries, 0 flags.
- `swift run ToolbarGalleryRenderer`: 388 fixtures.

## Not verified

Installed-app checks are owed to the lead: a real selection in a browser, a PDF and a Mail message (the Accessibility read was exercised only against a scripted adapter); VoiceOver; the installed Read shortcut; the panel row's return of focus to the app it was opened over; Speko and neural engines on the row's Voice menu (neural needs the download; the gallery's engine is Mac voices).
