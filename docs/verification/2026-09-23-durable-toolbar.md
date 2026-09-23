# Durable toolbar integration, 23 September 2026

The toolbar now uses the documented two-tier reducer in the actual app: a resting glyph and one content-sized row. Keep open is a preference, not another tier. The old boolean interaction model, duplicate hover monitors, spring loop and in-product polling harness are removed.

## Verified locally

- `bash scripts/test.sh`: 172 package tests, 64 browser tests, StageKit 146 tests / 2,961 assertions, plus release, capture persistence, keyboard, provider and refinement checks passed.
- After the final enum mappings, inactive-menu admission, idle-shortcut rule and palette regression: `swift test --disable-sandbox` passed 173 tests. The final upgrade regression passed with 174 tests: legacy expansion set to true does not opt into the new Keep open choice, while an explicit new choice survives relaunch. Tool mapping is an exhaustive switch with no string fallback. The gallery checks that every idle fixture retains a shortcut.
- Native tests cover measured standard/larger rows, long labels, all eight dock anchors and negative display coordinates, stationary crossings, menu dismissal/reentry, timer cancellation, native target/action, glyph alignment and interrupted window animation. The palette is checked against specified light/dark RGB values independently of rendered glyph/dot pixel comparisons.
- The production row renderer generated 140 fixtures and four overview sheets. Both themes and text sizes are included. Overview sheets are committed under `docs/assets/floating-toolbar`; CI retains the full render. This is visual review evidence, not an automatic pixel-baseline gate.
- `node --test site/tests/*.test.mjs`: 8 passed.
- Disposable native QA app: glyph accessibility activation and keyboard Return opened the real menu; Keep open retained the row after Home closed; Right centre mirrored the row with the glyph at the edge. These checks used isolated app storage.

## Review and scope

Claude supplied the reducer and reviewed the host integration using Opus at maximum effort. Verified findings led to pointer-gate reconciliation on menu dismissal, synchronous animation completion before drag, and a cancellable native drag event loop, exhaustive dock mappings and explicit menu admission after surface changes. The final Opus review found no P1 in its supplied packet; its two P2 findings were verified and fixed, with a native rejected-activation regression. The later user-supplied mapping, palette and idle-shortcut feedback was also applied. The parent applied the changes and ran the checks above. Private review packets and receipts are excluded from the repository.

`StageKit/WorkbenchPalette.swift` is the single Mac accent owner. Voice, StageKit, the native busy glyph/dot and gallery use it. ToolbarKit receives an accent value and remains application-agnostic. Issue #86 also asks whether the separate iOS light accent should match Mac; that platform decision remains outside this Mac fix. Issue #87's broader type classification is likewise not closed by the toolbar's scalable layout.

Idle Snap & Talk keeps its capture shortcut visible between captures; its Review menu item carries the capture count. Speech preparation retains the dictation shortcut, with availability explained in help and the existing app page. Only running work replaces the trailing key with status.

## Installation and limits

Signed Preview build `20260923012609` was installed from implementation `67bdb31`, superseding the initial integration candidate `20260923012017` from `bd7b57e`. The Developer ID signature passed `codesign --verify --deep --strict` with normal macOS certificate access. The embedded Production CloudKit profile is byte-identical to the previous app's. Before the initial integration launch, all 100 existing app-data files had identical paths and SHA-256 hashes. The final update retained all 100 files; 98 remained byte-identical, including every recording. Normal application shutdown rewrote the state and board JSON files through their existing save paths. The installer retained the previous app archive.

In the initial installed integration build, the recovered-audio banner reappeared correctly. Only its temporary message was dismissed; the recording was not retried, replaced or deleted. Native glyph activation and keyboard Return opened the menu. Keep open held the row. Selecting Snap & Talk displayed the actual configured shortcut while an existing session was open; Review showed its capture count. The original Dictate selection and Keep open = false were restored. The existing right-centre dock was retained. No new microphone capture or screenshot was started during these checks. The final build was launched again: audio recovery remained available, and dismissing only its banner revealed the resting glyph with the new Keep open preference defaulting off.

Physical multi-display dragging, VoiceOver end-to-end, a real phone/meeting receiver and new microphone accuracy measurements are not established by this change. Automated geometry covers all anchors and off-origin screens. An unusually narrow screen can clamp a long row and move the glyph; labels are not shrunk to conceal that limit. Prior dictation/annotation repair evidence remains in `2026-09-22-menu-repair.md`.
