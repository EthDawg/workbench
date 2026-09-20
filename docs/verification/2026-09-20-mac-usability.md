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

## Every original report

Implementation and acceptance are separate. [PR #62](https://github.com/EthDawg/workbench/pull/62) contains the changes; the linked issues retain the remaining work even after code is merged.

| Original report | Implemented and observed | Remaining acceptance owner |
| --- | --- | --- |
| Missing Mac menu-bar item | Status item restored at launch; installed popover and Window recovery actions exercised. | [#56](https://github.com/EthDawg/workbench/issues/56): crowded/notched menu bar and multiple displays. |
| Floating controls disappear between actions; confusing continuity and HUD wording | Remembered toolbar, shared recording/narration panel and normal labels. Closing the main window leaves the toolbar available. | [#56](https://github.com/EthDawg/workbench/issues/56): fresh microphone, processing, paste/cancel and return-to-idle walkthrough. |
| Scene delete, multi-select, inline rename and drag reorder | Native selection and deletion confirmations; double-click/Return rename and Escape cancellation checked. Atomic deletion and drag/order rules tested. | [#57](https://github.com/EthDawg/workbench/issues/57): successful physical drag and persistence after reopening. |
| Too many scene menus; personas/prepare presentation confusing | One Add scene menu; scene artwork separated from independent Overlay cards and Arrange overlays. | [#57](https://github.com/EthDawg/workbench/issues/57): first-use walkthrough without explanation. |
| Find a logo through the web without leaving Workbench | Embedded public Google Images, source-page image selection, preview and application exercised. | [#58](https://github.com/EthDawg/workbench/issues/58): retain this evidence alongside animation work. Public logo search is the interpretation of “Google photos”; private Google Photos account access is not implemented. |
| Animated starter images/backgrounds do not animate | Live editor renderer and playback explanations implemented. Native state transitions checked. | [#58](https://github.com/EthDawg/workbench/issues/58): choosing-flow clarity, visible movement for all three starters, presentation and separate animated-desktop lifecycle. Still open. |

Window light, Campus breeze and Coastal sky use static thumbnails in the starter chooser. Choosing opens the editor; the gallery itself does not animate. A follow-up disposable Campus breeze check produced different screenshot frames, but the paused comparison also differed, so that comparison alone is not an isolated measurement of animation. A Playing label, renderer test or changing screenshot bytes does not complete visual acceptance. Ordinary wallpaper and PNG exports stay still; **Use as animated desktop** explicitly starts the separate moving layer. This pass did not alter the user's desktop to test it.

## Decisions to preserve in follow-up work

- **One nearby control surface:** the menu bar, Window recovery commands and remembered floating toolbar reach the same tools. Recording temporarily uses that panel and placement, then returns to tools. Hide remains deliberate. Do not introduce another persistent control palette to fix discoverability.
- **One scene library:** the native list changes selection and editing behavior, not storage ownership. Deletion commits against the captured selection/revision, preserves original images and retains existing sync boundaries.
- **Separate scene artwork from independent overlays:** a scene persona is part of that saved scene; Overlay cards are independent presentation tools. Plain labels replace ambiguous preparation menus without joining their state owners.
- **A bounded logo browser:** public web search and explicit image application complete one task. This is neither a general browser/profile manager nor a personal photo-library connection. Unsupported image pages retain URL/file/clipboard alternatives.
- **Motion belongs to a surface and lifecycle:** editor preview, presented output and animated desktop have different focus/stop rules. Layout editing and system accessibility/power constraints still pause preview. Quiet movement must be visibly verified and discoverable, not inferred from status text.
- **One app/docs home:** simplify the existing guide and navigation. The proposed domain can point to the existing hosting project after DNS/HTTPS checks; it does not require another site or a new account service.

## Reconciliation with newer product work

The product-manager review arrived while this repair was underway. Its [direction PR #66](https://github.com/EthDawg/workbench/pull/66) and [mobile/team research PR #61](https://github.com/EthDawg/workbench/pull/61) remain independent contributions. Their proposals are not implemented by this repair and must not be closed by its merge.

| Related work | Relationship to this change |
| --- | --- |
| [#55 Browser setup packs](https://github.com/EthDawg/workbench/pull/55) | Separate contributor branch and Chrome acceptance. The embedded logo browser does not implement profile packs, bookmarks or tab setup. |
| [#59 Personal profiles](https://github.com/EthDawg/workbench/issues/59) | Toolbar placement/hide preferences stay machine-local. This repair adds no profile, account service, new sync domain or cross-library store. |
| [#60 Import images into Snap & Talk](https://github.com/EthDawg/workbench/issues/60) and [#63 Handoff scope](https://github.com/EthDawg/workbench/issues/63) | This PR changes access and recording controls, not image import or the session/template/output contract. Rebase work touching ReadbackView/ReadbackModel on the merged control changes. |
| [#64 Selected scene/group context](https://github.com/EthDawg/workbench/issues/64) | Simpler scene/persona controls do not attach scene or group context to captures. Keep any future association explicit through StageKit's public boundary. |
| [#65 Background brief experiment](https://github.com/EthDawg/workbench/issues/65) | Logo discovery and motion preview are existing-workflow repairs. No generator, background brief or brand-management workflow is added; that experiment remains conditional on its own trial. |
| [#29 Real receiver walkthrough](https://github.com/EthDawg/workbench/issues/29), [#20 Live scene snapshot](https://github.com/EthDawg/workbench/issues/20) and [#21 Timer placement](https://github.com/EthDawg/workbench/issues/21) | These retain their existing evidence gaps. A local toolbar, screenshot or compositor result does not establish receiver visibility, captured live phone pixels or placement across real displays. |

GitHub issues remain the queue. This dated record preserves evidence and decisions; it is not a second backlog or a promise to build the proposed directions. Ethan explicitly requested pushing, merging the ready code and reconciling the GitHub items at session completion. Merge acceptance does not close the remaining physical checks or authorize a public binary/site release.

## Verification

- Swift package tests: 107 passed. Release build and core, capture, readback, ordering, presenter, provider/transport and refinement checks passed. Browser-extension suite: 64 passed.
- Native StageKit suite: 139 tests, 2,827 assertions, zero failures. This includes seven scene-list tests, a real AppKit field-editor commit/cancel regression, atomic deletion with preserved images, stale revisions, drag tokens, media validation/cancellation and scene-motion policies. The first native run encountered shortcut conflicts from other Workbench copies; rerunning after quitting them passed.
- Website: eight tests passed, static build and diff checks passed. The simplified guide was inspected in the browser at the local preview address.
- Disposable debug app, using separate preferences and scene storage: closing the main window left the floating toolbar visible; double-click rename, Return commit and Escape cancel worked; Backspace opened a confirmation naming the scene; Shift-selection produced a two-scene confirmation; Cancel retained both. Destructive fixture behavior is covered by model tests rather than deleting live scenes.
- Embedded browser: searched public Google Images, opened the Wikimedia source page inside the app, selected its logo, reviewed the downloaded raster and applied it to the disposable scene. The scene and reusable-logo store received it without opening another browser.
- Editor motion: the native UI changed between playing, paused, inactive and layout-editing explanations. Actual renderer and stationary-export behavior are covered by compositor tests. The UI screenshots are still evidence, not a recording of animation.
- Installed package: strict signature verification passed with the existing Developer ID and Production iCloud provisioning profile. The installed executable matches the signed archive. All 97 checked app-data and native-browser-host files were byte-identical across installation, including Chrome for Testing's existing registration. The installer retained the previous app in `dist/Previous-Workbench Preview.zip`.
- Installed launch: existing scene rows and Snap & Talk folders remained available. The confusing HUD switch was gone. Window recovery commands and the menu-bar-anchored quick-controls popover worked. Closing the main window left the floating toolbar available in Ready state.
- Final app/test revision `a218148` passed all [Mac, iPhone and iPad CI jobs](https://github.com/EthDawg/workbench/actions/runs/35508801826). Its timer follow-up waits for native restoration before simulating drag instead of relying on fixed sleeps; the focused test passed 12 assertions. That adds one assertion to the earlier full local-suite count. A final documentation/whitespace follow-up preserves app behavior and records the reconciliation above; current merge checks remain visible on PR #62.

## Limits before release

Native drag insertion is implemented through AppKit and its ordering/cancellation rules are tested; this run did not establish a successful physical mouse drag through the UI automation tool. Multi-display/notch menu-bar placement, a new microphone recording and paste into another app, physical phone video, and meeting receiver capture were not freshly exercised. A visible AppKit status item can still be concealed by macOS when the menu bar is crowded; the toolbar and Window menu provide another way in. No claim of receiver-invisible controls follows from these checks.

This is a locally installed candidate for maintainer review. No Apple submission, notarization, binary publication, production website deployment or DNS mutation occurred in this pass.

Design references: [Wispr Flow's movable Flow bar](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop), [Superwhisper recording controls](https://superwhisper.com/docs/get-started/interface-rec-window), and [Apple status-item visibility](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible).
