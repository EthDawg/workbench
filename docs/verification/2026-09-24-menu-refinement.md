# Mac menu and shared control refinement

## Scope and source

This candidate refines the existing menu bar, shared floating controls and desktop preparation roles. The baseline is main `ceb5c55`; Matt's persona size/add/remove contribution is retained as authored commit `fc61e03` (original `06ef310`). There are no new data stores, prompt shortcuts, permission resets or public release changes in this increment. The delivery coordinator owns production packaging and publication.

The fixed menu rows are Dictate, Read, Snap & Talk, Draw, Present, Persona Overlay and Timer. The existing Keyboard Coach handles inline shortcut changes. Clipboard feedback occupies a fixed well below the rows. The shared toolbar consumes existing drawing, device and persona owners, with compact active reading/dictation. Saved prompts use exact field/value/selection ownership and never replay partial delivery or send a submit key.

## Source and renderer verification

- `bash scripts/test.sh`: 174 Swift tests and 149 StageKit native tests / 3,010 assertions passed, plus the script's core, provider, capture, reading, library, browser, release-helper and refinement checks. Preview had to be quit through its native menu for exclusive global shortcut registration.
- Prompt insertion: 15 synthetic runner checks exercise Unicode/newlines, selected-text replacement, bounds, queued cancellation, focus/selection edits, shortcut editing and no replay after refusal/uncertain writes. Actual Accessibility delivery remains a separate native check.
- Shared persona menus use frozen public labels, a session generation and a prepared-set guard. Native menu target/action checks cover retained instance targets, stale menus across restart and legal duplicate instance IDs across separate groups. Saved artwork remains intact when removing a live copy.
- `node --test site/tests/*.test.mjs` and `node site/build.mjs` passed. The guide describes this controls increment separately from the currently published download.
- 164 production-row fixtures rendered. Light/dark and standard/larger-text overviews are in `docs/assets/floating-toolbar`. They cover the Prompts action, active insertion, personas and session capture counts. These establish layout and appearance, not pointer acceptance.

## Native baseline and outstanding installed checks

The baseline canonical Preview reported version 2.0.0, build 20260924084421 and source `ceb5c55`. Native menus, named toolbar placement and keyboard focus were exercised. The ordinary pointer was not successfully driven over the small non-key panel: CUA's documented scroll and drag both returned `windowNotFoundAtPosition` at its visible resting glyph (including screen point 726,875 at bottom centre). No hover cause, hover fix or all-anchor native pass is claimed from those attempts.

The signed candidate's Copy build details, menu/shortcut/receipt checks, independent scene/persona controls, saved-prompt target and native pointer results are recorded after installation. Receiver-side meeting visibility, physical multi-display dragging, USB reconnect and fresh-Mac first-run behavior require separate hardware evidence. Source tests and gallery images do not satisfy those gates.
