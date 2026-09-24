# Mac menu and shared control refinement

## Scope and source

This candidate refines the existing menu bar, shared floating controls and desktop preparation roles. It includes main through `a1a9de9`. Matt's persona size/add/remove contribution is retained as `fc61e03` (original `06ef310`), and Snap & Talk recovery as `93fdbf0`, `9b5c1d8` and reviewed correction `04ec31c`. There are no new data stores, default prompt shortcuts or permission resets. The delivery coordinator owns production packaging and publication.

The fixed menu rows are Dictate, Read, Snap & Talk, Draw, Present, Persona Overlay and Timer. The existing Keyboard Coach handles inline shortcut changes. Clipboard feedback stays below the rows, with no empty well while idle. The shared toolbar consumes existing drawing, device and persona owners, with compact active reading/dictation. Saved prompts use exact field/value/selection ownership and never replay partial delivery or send a submit key.

## Source and renderer verification

- `bash scripts/test.sh` passed on integrated source `04ec31c` and again after the final native panel and updater corrections: 174 Swift tests and 149 StageKit native tests / 3,012 assertions, plus the script's core, provider, capture, reading, library, browser, release-helper and refinement checks. Preview was quit through its native menu for exclusive global shortcut registration.
- Prompt insertion: 15 synthetic runner checks exercise Unicode/newlines, selected-text replacement, bounds, queued cancellation, focus/selection edits, shortcut editing and no replay after refusal/uncertain writes. Actual Accessibility delivery remains a separate native check.
- Shared persona menus use frozen public labels, a session generation and a prepared-set guard. Native menu target/action checks cover retained instance targets, stale menus across restart and legal duplicate instance IDs across separate groups. Saved artwork remains intact when removing a live copy.
- `node --test site/tests/*.test.mjs`: 16 tests passed after incorporating current main; `node site/build.mjs` passed. The guide describes this controls increment separately from the currently published download.
- A postponed explicit update restart no longer sets the final termination guard while merely waiting for the user. The actual updater policy checks ordinary busy Quit before/after postponement, guard activation before the stored handler runs, busy refusal after resume, failed-save refusal, successful idle saving and no consumed-handler replay. An independent isolated compilation against pinned Sparkle 2.10.0 also passed these checks. Actual Sparkle installation remains a release-owner check.
- The final paused-timer correction passed a fresh compile, all `--check-core` checks (including 31 control and 15 prompt checks), and 149 StageKit tests / 3,014 assertions. It adds no storage migration.
- 164 production-row fixtures rendered. Light/dark and standard/larger-text overviews are in `docs/assets/floating-toolbar`. They cover the Prompts action, active insertion, personas and session capture counts. These establish layout and appearance, not pointer acceptance.

## Installed checks and limits

The baseline canonical Preview reported version 2.0.0, build 20260924084421 and source `ceb5c55`. Native menus, named toolbar placement and keyboard focus were exercised. The ordinary pointer was not successfully driven over the small non-key panel: CUA's documented scroll and drag both returned `windowNotFoundAtPosition` at its visible resting glyph (including screen point 726,875 at bottom centre). No hover cause, hover fix or all-anchor native pass is claimed from those attempts.

Signed Preview `04ec31c`, version 2.0.0, build `20260924133635`, was installed at the existing path with no modified source. Native Copy build details confirmed that identity on macOS 26.5.1. All 116 pre-existing saved files matched their pre-install SHA-256 hashes before the first launch. The installer retained the existing signing identity and CloudKit provisioning. No recovery, library or session data was removed.

Native observations on that candidate:

- Exact seven-row names/order and Destination before Text Style were checked. The updater correctly said Local Build. Shortcut editing rejected the Spotlight conflict, saved a synthetic binding and restored Read to Off; other assignments remained unchanged.
- Native inspection exposed the empty Read options cell moving its shortcut column, a wrapping Review link, excess idle feedback space and the colour picker not becoming key. Signed source `c7c936b`, build `20260924140320`, corrected these. Its running Copy build details reported no modified source. The quick panel passed light/dark inspection; the inline editor expanded below unchanged action rows; Choose Colour opened the native Colors window with keyboard focus. System appearance was restored.
- Closing Home retained the floating utility. Dismissing the recovered-recording notice removed only its HUD; the original recovery remained saved.
- A new synthetic prompt with Unicode and newlines appeared as a favourite and under its Product and Persona tags. Menu invocation through automation safely refused an unavailable destination; TextEdit's selected text remained unchanged. This is refusal evidence, not successful progressive or fallback insertion.
- CUA coordinate input also rejected the revealed panel at screen point 733,875. Its keyboard injection did not invoke the external global shortcut and instead reached the synthetic document. The temporary Focus overlay controls binding was restored to Off. These tool limits leave native cross-app progressive insertion, fallback, cancellation and repeated keyboard-target checks outstanding.
- Starting, pausing and stopping a timer worked through native controls. Pausing exposed an admission/description mismatch: the shell used the running clock flag instead of the retained timer session. The correction derives session visibility and active-job status from the existing timer owner; paused timers defer an updater restart, while reset/finished timers do not. No countdown behavior or storage was replaced.

After the second replacement all 116 original saved files remained. Three JSON files differed from the initial pre-launch snapshot after ordinary application use and the new synthetic library item; original non-JSON files remained byte-identical. The synthetic TextEdit target was moved to the task's temporary directory. Existing transcripts, recordings and Snap & Talk sessions were not used as test fixtures.

All-anchor pointer entry/exit, stationary-pointer resizing, menu dismissal, screen edges and Reduce Motion remain unverified. An independent offscreen test of the real toolbar row found zero horizontal glyph displacement across all eight anchors at both 1.0 and 1.35 text scale; that is stable geometry evidence only. No hover patch or native hover pass is claimed.

Receiver-side meeting visibility, physical multi-display dragging, USB reconnect and fresh-Mac first-run behavior require separate hardware evidence. Source tests and gallery images do not satisfy those gates. Keep the PR in draft until installed and release-owner checks are resolved.
