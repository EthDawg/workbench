# Workbench design language

Drafted: 21 September 2026. Audit revision: `c692a4b`.

**Status: proposed.** This record describes the vocabulary Workbench already uses and names the places it is inconsistent. The themes are read out of shipped behaviour and the existing contracts; the atoms and components section reports measured facts about the current source. Nothing here is a claim that a token layer exists, that a refactor has been agreed, or that any pictured concept was built. Ethan and Matt agree changes to this record the same way they agree the [working agreement](../CONTRIBUTING.md#proposed-ethanmatt-working-agreement).

## What this record owns

Workbench already has four owning records. This is a fifth, and it is deliberately narrow.

| Record | Owns |
| --- | --- |
| [`docs/workbench.md`](workbench.md) | The product contract: what the app promises |
| [`docs/product-spec.md`](product-spec.md) | Jobs, surfaces, input ownership, placement, closure |
| [`docs/design.md`](design.md) | The implementation map: targets, state owners, entry points |
| [`site/handbook/contract.json`](../site/handbook/contract.json) | Visual-experience capability status, lifecycle and acceptance |
| **This record** | **The shared vocabulary: themes, atoms, components and the experience checks that apply to every surface** |

When this record and any of the four disagree, the other four win and this one is wrong. Interaction rules stay in `product-spec.md`; capability status stays in `contract.json`. This record exists so that a person adding the eleventh floating surface makes the same choices as the person who added the first.

## Themes

Eight themes are already visible in shipped behaviour. They are the reason Workbench feels like one app, and they are what a contributor should check a change against before checking anything else.

### 1. Truthful state

The most distinctive thing about Workbench is that it refuses to overstate what happened. A delivery is **Ready to paste**, a confirmed destination, or **Paste unconfirmed**. A photo is **Queued for iCloud**, **In iCloud**, or **Downloaded on this Mac** — and the phone never claims the Mac received anything. A failed state write "must never be described as a saved transcript".

This is a design theme, not only an engineering one. It sets the tone of every label, every status chip and every empty state. Certainty is earned, and the interface says which kind of certainty it has.

**Check:** can this string be false? If yes, it names the weaker fact instead.

### 2. One job, one owner

Each job owns its own state, its own controls and its own remembered placement. The break timer's position is not the dictation HUD's position. A persona group frozen at Show does not change because the library was edited behind it. Starting a device scene pauses independent overlays rather than blending them.

**Check:** does this change let one job read or write another job's state? Route it through the owning model instead.

### 3. Click, never hover

Essential actions are never hover-only. This is an explicit product choice recorded in [`hud-design.md`](hud-design.md), taken in deliberate contrast to Superwhisper's hover-revealed controls. Hover may preview; it may not be the only way to reach a control.

**Check:** with a trackpad untouched, is every essential action still reachable?

### 4. Placed by the person, remembered per job

Eight named anchors. Drag to snap, or pick the same destination from a Position menu — full parity, because dragging is not available to everyone. Guides appear only during a drag. Placement survives display changes by resolving onto currently visible bounds, and corrupt or future placement data is preserved rather than overwritten.

**Check:** does the new surface offer both routes, persist its own placement, and recover when the display it remembered is gone?

### 5. Preserve the original

Originals, prior drafts, replaced media, deleted sections and the person's later manual desktop choice all survive. Deletion moves a section to `trash/` until explicitly emptied. Ending a presentation is not Restore desktop.

**Check:** after this action, is the previous state still reachable?

### 6. Audience surface and operator surface are different

A persona card is audience-visible artwork. A control tile is operator chrome. They never merge, and Workbench never promises that operator chrome is invisible to a screen share — "Window sharing flags do not guarantee exclusion from another app's capture."

**Check:** which surface is this on, and does any copy imply a privacy guarantee the app cannot keep?

### 7. Leaving is designed as carefully as arriving

Escape closes expanded controls first and ends the presentation only on a second press. Closing the window does not quit. Cancel preserves the draft, the retained original and the cleanup method. A late model result cannot overwrite an edit made while it was running.

**Check:** what does Escape do here, and what does the second Escape do?

### 8. Native first

System controls, system materials, system type. Reduce Motion and Reduce Transparency are honoured. Apple's popover guidance supplies the behaviour before any custom chrome is written. The generated design studies say it plainly: "no neon, no purple gradients", "hairline borders, realistic but quiet shadows".

**Check:** does AppKit or SwiftUI already do this? Use it.

## Atoms

An atom is the smallest shared decision. Workbench has two excellent ones and is missing most of the rest.

### What exists and works

| Atom | Owner | Note |
| --- | --- | --- |
| `FloatingControlAnchor` — eight named anchors | `Sources/StageKit/FloatingControlGeometry.swift` | The model atom to imitate. Public, `Codable`, ordered, with display titles. Shared by both modules. |
| `FloatingControlGeometry` — clamp, targets, snap | same | Handles negative display origins, removed displays and tiny frames. Tested. |
| `InkColor.presets` — coral, amber, mint, blue, violet, white | `Sources/StageKit/Core.swift` | A named, indexed palette with `presetName` for VoiceOver. |
| `Workbench.accent` / `background` / `surface` / `border` / `controlWidth` | `Sources/LocalVoice/Workbench.swift`, `Sources/StageKit/Workbench.swift` | Correct values — but see below. |

### What is missing, measured at `c692a4b`

| Atom | Current state |
| --- | --- |
| Radius scale | **19 distinct corner radii** across 136 sites: 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 24, 28 |
| Type scale | **27 distinct `.system(size:)` values** across 190 sites, from 8 to 68. Fixed points, so they do not respond to accessibility text sizes or Dynamic Type |
| Spacing scale | **19 distinct numeric `.padding()` values** |
| Motion | Two ad-hoc durations (`0.1`, `0.16` ease-out). No named fast/standard pair, no single place that honours Reduce Motion |
| Status colour | Recording red, warning orange and ready mint are written inline at each site rather than named |

None of this is a crisis — the app looks coherent because one person made consistent choices by hand. It is a scaling problem. The tenth contributor cannot infer "12 here, 18 there" from the existing code, because the existing code contains every value between 2 and 28.

### The duplication fact

The token block in `Sources/LocalVoice/Workbench.swift` and `Sources/StageKit/Workbench.swift` is **byte-identical** — same MD5 over the `background`/`surface`/`accent`/`border`/`controlWidth` span. So are three view types: `WorkbenchHeader`, `WorkbenchAppearancePicker` and `WorkbenchTheme`.

[`design.md`](design.md) says these files "are not identical mirrored files", and as whole files that is true — each owns a different migration path. But the design surface inside them is a verbatim copy. A contributor who changes the accent in one module ships an app whose two halves disagree, and no test catches it.

This does not argue for the "larger shared framework" that `design.md` rightly refuses. It argues for one small shared file containing only the design surface.

### The mobile fact

`Mobile/` contains **zero** references to the `Workbench` token enum, but it is not unbranded. It carries its own `AccentColor.colorset`, wired up through `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in `scripts/mobile-project.py`. The mobile root's `.tint(Color.accentColor)` therefore resolves to that asset, not to the system blue.

The two definitions agree in dark mode and disagree in light:

| | Light | Dark |
| --- | --- | --- |
| Mac, `Workbench.accent` (Swift literal) | sRGB `0.04, 0.43, 0.32` | sRGB `0.43, 0.89, 0.73` |
| iOS, `AccentColor.colorset` (JSON) | sRGB `0.16, 0.43, 0.36` | sRGB `0.43, 0.89, 0.73` |

So Workbench ships two slightly different greens in light mode, one per platform. Whether that is a deliberate platform adjustment or a drift nobody noticed is not recorded anywhere, which is the actual problem: the same brand value is written twice, in two formats, in two files that have no link and no check between them.

Mobile's use of iOS grouped-background semantics is correct and should stay. It is the accent value and the radius/type scales that want a single source.

## Components

A component is a recurring arrangement of atoms. Workbench has several — most are conventions repeated by hand rather than code.

| Component | Where it recurs | State |
| --- | --- | --- |
| **Collapsed control tile** — icon, hairline divider, chevron | `CapturePanel.swift`, `PersonaHUD.swift`, `PresentationControls.swift` | A convention, described precisely in `product-spec.md`, implemented separately each time |
| **Position menu** — eight anchors | `CapturePanel.swift:478`, `DemoPresentation.swift:368`, `PersonaPresentationPreparation.swift:188`, `StageKit/Views.swift:489` | Hand-rolled **4×** in view code over the shared model. The geometry is shared; the menu is not |
| **Snap guides** | `FloatingControlGuides.swift` | Shared. One hosting path is unthemed — see the experience checks below |
| **Status receipt** — truthful outcome plus optional pin | `ClipboardReceipt.swift`, quick controls, menu bar | The clearest expression of theme 1; no shared presentation type |
| **Review before apply** — New/Changed/Unchanged, Keep mine default, explicit Apply | `DemoLibraryImportView.swift`, Snap & Talk `Reorder…` | A strong, repeated pattern worth naming |
| **Section header** — eyebrow, title, subtitle, symbol | `WorkbenchHeader` | Exists, duplicated across both modules |
| **Permission / empty state** | Recording, Screen Recording, model preparation, missing files | Each written independently |

The pattern is consistent: **Workbench shares models well and presentation poorly.** `FloatingControlGeometry` is shared and tested; the menu that exposes it is written four times. That is the single most useful generalisation in this record, and it points at where the work is.

## Experience checks

These apply to every surface and belong in review.

- **Keyboard.** Opening by keyboard focuses controls. Mouse actions preserve the destination field. Focus ring visible.
- **VoiceOver.** Every icon-only control has an accessible name. Current coverage by `accessibilityLabel` count: `Sources/LocalVoice` 88, `Sources/StageKit` 67, `Mobile/Workbench` 27 — mobile is the thinnest and has had the least VoiceOver attention.
- **Reduce Motion / Reduce Transparency.** Honoured at `CapturePanel.swift`, `ReadbackView.swift`, `DemoPresentation.swift`, `MovingSceneView.swift`, `PersonaOverlay.swift`, `FloatingControlGuides.swift`. Per-site, not systematic — a new surface gets it only if its author remembers.
- **Appearance.** `workbenchTheme()` is applied at 23 separate roots. It is opt-in per window, so a new window that omits it silently ignores the person's Light/Dark choice. `FloatingControlGuideController` hosts `NSHostingView(rootView: guides)` with neither `.tint(...)` nor `.workbenchTheme()`, so that standalone guide panel takes the system accent and the system appearance while the control being dragged takes Workbench's.
- **Frozen settings.** Cleanup configuration, replacements and delivery preferences are snapshotted before an operation. Changing a setting mid-flight must not alter work in progress, and the UI must say when a change takes effect.
- **Share visibility.** Never claim a control is hidden from capture without receiver-side evidence from the actual meeting app.
- **Synthetic content.** Public screenshots and recordings use synthetic data. No customer assets, no personal data.

## Contributor checklist

Before opening a PR that changes a visible surface:

1. Which **theme** does this change serve, and which one might it break?
2. Does it introduce a new radius, type size, spacing value or colour? Reuse an existing one and say which.
3. If it adds a floating surface: does it use `FloatingControlGeometry`, offer drag **and** a Position menu, and persist its own placement?
4. Does it apply `workbenchTheme()` and tint with `Workbench.accent` at its root?
5. Can every essential action be reached without hover, and with the keyboard?
6. Does every icon-only control have an accessible name?
7. Does any new string claim more certainty than the code can establish?
8. Which record needs updating — `product-spec.md`, `contract.json`, or this one?

## What this record does not authorise

It does not authorise a visual redesign, a new design framework, a component library dependency, a change to any shipped colour, or extraction of a shared UI module. Those are separate agreed changes with their own PRs and evidence. It does not change any capability's status in `contract.json`, and it is not evidence that any surface was tested.

The measurements above were taken by static inspection at `c692a4b`. They count source occurrences, not rendered pixels, and they are not a substitute for looking at the running app.

## Evidence and sources

- Measurements: `grep` over `Sources/` and `Mobile/` at `c692a4b`, counting `cornerRadius:`, `.system(size:)`, `.padding(<n>)`, `accessibilityLabel`, `.tint(` and `ForEach(FloatingControlAnchor.allCases)`. Reproducible from the issue that tracks this work.
- Themes are read from [`docs/workbench.md`](workbench.md), [`docs/product-spec.md`](product-spec.md), [`docs/hud-design.md`](hud-design.md) and the five principles in [`site/handbook/contract.json`](../site/handbook/contract.json).
- The visual vocabulary — off-white surfaces, restrained mint accent, hairline borders, quiet shadows, system typography — is currently recorded only as prose inside the image prompts in [`docs/design-images.md`](design-images.md). Naming it here is the point of this record.
- External references already adopted: [Apple popover guidance](https://developer.apple.com/design/human-interface-guidelines/popovers/), [Superwhisper recording window](https://superwhisper.com/docs/get-started/interface-rec-window) (mini/full split adopted, hover rejected), [Raycast action panel](https://manual.raycast.com/action-panel) (contextual action discovery).
