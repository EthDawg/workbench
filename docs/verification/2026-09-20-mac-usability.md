# Mac usability repair — 20 September 2026

Source: `fix/mac-usability`, code revision `6ca995a`. Installed local Preview build: `20260920113032`. Public downloads remain Preview 4; this candidate is signed locally, not notarized or published.

## The three changes

| Work | Result | GitHub |
| --- | --- | --- |
| Keep tools within reach | A compact menu-bar icon, recovery commands and a persistent floating toolbar. Dictation and Snap & Talk use the same panel and position; finishing returns to tools. The user no longer chooses a “HUD”. | [#56](https://github.com/EthDawg/workbench/issues/56) |
| Make scenes behave like a Mac list | Native selection, inline rename, confirmation before deleting the selected scenes, drag insertion and keyboard move alternatives. One Add scene menu; scene artwork and independent overlay preparation have different entry points. | [#57](https://github.com/EthDawg/workbench/issues/57) |
| Complete logo and motion workflows | Public Google Images opens inside Workbench, with explicit image preview and application. Animated scenes play in the active editor, with Pause/Play and visible reasons when playback is suppressed. | [#58](https://github.com/EthDawg/workbench/issues/58) |

These items follow the narrow, observable workflow used in Matt's contributions: expected result, small change, and a checkable finish. Earlier utility priorities were checked against current source and [the utility comparison](../utility-comparison.md); this pass repairs access and completion before adding another presentation workflow. Browser setup packs remain in their separate PR. GitHub remains the work queue.

The everyday guide now covers starting, using and finishing each task. Design studies and implementation history stay in the deeper references. `workbench.mwdm.cloud` is a suitable custom address for the existing site; [the site instructions](../../site/README.md) record the domain/DNS and HTTPS checks needed before switching links. No domain change or second hosting project was created.

## Verification

- Swift package tests: 107 passed. Release build and core, capture, readback, ordering, presenter, provider/transport and refinement checks passed. Browser-extension suite: 64 passed.
- Native StageKit suite: 139 tests, 2,827 assertions, zero failures. This includes seven scene-list tests, a real AppKit field-editor commit/cancel regression, atomic deletion with preserved images, stale revisions, drag tokens, media validation/cancellation and scene-motion policies. The first native run encountered shortcut conflicts from other Workbench copies; rerunning after quitting them passed.
- Website: eight tests passed, static build and diff checks passed. The simplified guide was inspected in the browser at the local preview address.
- Disposable debug app, using separate preferences and scene storage: closing the main window left the floating toolbar visible; double-click rename, Return commit and Escape cancel worked; Backspace opened a confirmation naming the scene; Shift-selection produced a two-scene confirmation; Cancel retained both. Destructive fixture behavior is covered by model tests rather than deleting live scenes.
- Embedded browser: searched public Google Images, opened the Wikimedia source page inside the app, selected its logo, reviewed the downloaded raster and applied it to the disposable scene. The scene and reusable-logo store received it without opening another browser.
- Editor motion: the native UI changed between playing, paused, inactive and layout-editing explanations. Actual renderer and stationary-export behavior are covered by compositor tests. The UI screenshots are still evidence, not a recording of animation.
- Installed package: strict signature verification passed with the existing Developer ID and Production iCloud provisioning profile. The installed executable matches the signed archive. All 97 checked app-data and native-browser-host files were byte-identical across installation, including Chrome for Testing's existing registration. The installer retained the previous app in `dist/Previous-Workbench Preview.zip`.
- Installed launch: existing scene rows and Snap & Talk folders remained available. The confusing HUD switch was gone. Window recovery commands and the menu-bar-anchored quick-controls popover worked. Closing the main window left the floating toolbar available in Ready state.

## Limits before release

Native drag insertion is implemented through AppKit and its ordering/cancellation rules are tested; this run did not establish a successful physical mouse drag through the UI automation tool. Multi-display/notch menu-bar placement, a new microphone recording and paste into another app, physical phone video, and meeting receiver capture were not freshly exercised. A visible AppKit status item can still be concealed by macOS when the menu bar is crowded; the toolbar and Window menu provide another way in. No claim of receiver-invisible controls follows from these checks.

This is a locally installed candidate for maintainer review. No Apple submission, notarization, binary publication, production website deployment or DNS mutation occurred in this pass.

Design references: [Wispr Flow's movable Flow bar](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop), [Superwhisper recording controls](https://superwhisper.com/docs/get-started/interface-rec-window), and [Apple status-item visibility](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible).
