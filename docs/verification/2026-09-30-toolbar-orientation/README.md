# Toolbar edge orientation

Source: the commit containing this record on `codex/snap-hover-actions`, following `4840859d1e296bd6469d27fc7ddf58bfaa9c2b2d`. The preceding capture-action change is `a613728ff86ff478b1093b85eaa43731e36cb53e`.

## Result

- Top and bottom use horizontal controls. Left and right use vertical columns with upright icons and the same launcher, Region, Window, Screen, Review, More order. Corners remain horizontal and open inward; free placement stays horizontal.
- Attached windows keep an eight-point outside inset. Opening stays centred along the edge. Resting targets are 48 × 28 horizontally and 28 × 48 vertically.
- The drag guide predicts the destination orientation and accessory fit. The current shape stays stable during dragging. Short edges put the accessory in More; returning to a longer edge restores it.
- Native motion, chrome and glyph reveal share one clock. Interrupted turns restart from the actual frame. Recording, timer and warning signals fit inside the changing target, including corners and free placement.
- Hints share a fixed inboard rail at side edges. The chooser, Saved Prompts, Position and native options also open inboard. Narrow panels measure their content to the available width.
- Size reports identify their orientation and content. Stale horizontal reports cannot corrupt a column; result cards keep separate horizontal measurements.

## Verification

Production native views and animation samples were rendered with synthetic state on an Apple silicon Mac, macOS 26.5.1 (25F80). This is source verification. This task did not replace the shared Preview, reset privacy grants, acquire real audio or screen content, or change live sessions.

| Check | Result |
|---|---|
| `swift build --disable-sandbox` and final test build | Passed |
| `swift test --disable-sandbox --filter 'ToolbarCoreTests\|ToolbarKitTests'` | 203 tests, two explicitly gated on-screen tests skipped, zero failures |
| `.build/debug/LocalVoice --check-floating-toolbar` | 190 controls checks; 38 picker, 19 insertion, 12 delivery and nine accessibility checks passed |
| `.build/debug/ToolbarGalleryRenderer --motion OUTPUT` | 18 native offscreen sequences passed: eight open/close and ten interrupted edge changes |
| `WORKBENCH_TOOLBAR_GALLERY_ONLY=1 .build/debug/LocalVoice --render-surfaces OUTPUT` | 54 production-host renders, zero flags |
| `python3 scripts/check-surfaces.py` | 437 entries classified |
| `python3 scripts/test-check-surfaces.py` | 56 tests passed |
| `git diff --check` | Passed |

The [motion samples](motion.json) contain 948 frames. Open/close sequences check reference stability within half a point and collapsed padding no stronger than one 8-bit alpha step. Edge turns check immediate retarget continuity, final placement and recording/warning visibility throughout. Each turn has seven to nine distinct native sizes. All sequences include interrupted motion.

The [host manifest](host-manifest.json) records sizes and placement checks, including side layouts, saved placement, migration, results and source dispatch. Focused tests cover native hit coordinates, keyboard order, disabled controls during resizing, both recording badges, native menu placement, stable hints and narrow chooser content. Production checks reject stale measurements and verify short-screen preview/release agreement.

### Selected renders

- [Horizontal open/close](motion-bottom.gif) and [vertical open/close](motion-left.gif).
- [Interrupted bottom-to-left turn](edge-bottom-left-revealed.gif).
- [Recording into a corner](edge-right-bottomRight-resting.gif) and [into free placement](edge-left-free-resting.gif).
- [Snap on the left](toolbar-snap-left-revealed-dark.png) and [Snap & Talk on the right](toolbar-snapAndTalk-right-revealed-dark.png).

A bounded Codex review identified destination-axis fitting, narrow popup content and compact-signal recentering gaps. The parent corrected them and ran the checks above. An initial visibility assertion assumed unconverted RGB colors and rejected a visibly intact badge. It now checks the actual sRGB hue and saves a diagnostic PNG on failure. The recorded final run passes.

### CI portability follow-up

[CI run 36662608243](https://github.com/EthDawg/workbench/actions/runs/36662608243) exposed two test assumptions after integration. The drag test queued a mouse-up carrying an offscreen window number; AppKit remapped its coordinates, effectively applying the window origin twice. It now follows the existing native click helper by queuing a windowless mouse-up, while the directly delivered mouse-down retains its window. Exact final-delta and single-move assertions remain.

The warning comparison differed by one thresholded orange pixel at every anchor (29/30 horizontally, 27/28 vertically). It now allows exactly one pixel of rasterization variation and renders the old capsule-clipped reference at every anchor. The test requires that deliberate clipping exceed the tolerance, so the original regression still fails.

Stress runs also exposed an intermittent resize-fixture failure: one native launcher's frame remained at its initial position while its neighbours were placed. The test now completes AppKit's display pass before collecting targets and asserts the full expected control count. The exact native hit-target assertions remain, with no retries or excluded controls.

The focused CI pair and the full toolbar suite passed locally: 203 tests, two explicitly gated on-screen tests skipped, zero failures. A further full-suite stress run increased the resize test from three to 30 cycles per tool and anchor (1,680 reveal cycles); all 203 tests passed with the same two skips. The normal three-cycle count was retained in commit `5870b5b860f2e2af343ddfa841b8f096e64bdd29`. That commit changed tests and verification notes only.

### Native rendering and admission follow-up

An integrated repeat at `4129f61` reproduced the resize fixture failure despite the AppKit display pass: Persona's left-side More target still had an unfinished native frame. AppKit layout/display is insufficient to synchronise this synthetic, uninterrupted sequence of SwiftUI updates. The fixture now calls the SDK's `NSHostingView._renderForTest(interval: 0)` once per simulated frame. This hook is confined to tests. There are no sleeps, assertion retries, skipped controls or writes to SwiftUI-owned child frames; every expected native target must still receive its exact hit.

The stronger fixture also checks native enabled states during expansion and at the start of collapse, including Region, Window and Screen. These checks exposed two production gaps: a primary-button update overwrote the parent's disabled state, and the fading closing row lacked an explicit native disabled state. `ToolbarPrimary` now combines its own enabled value with `context.environment.isEnabled`; the closing overlay is disabled. Both checks failed on the preceding code and pass with these changes.

A separate test uses the real `ToolbarWindowMotion` completion callback, with no test rendering hook, extra layout pass or retry. It checks the full control count, enabled state and every native hit at 112 completions: seven tools at eight anchors, with both immediate and animated placement. Snap and Snap & Talk include all three capture sources. The production completion boundary passes this check; the synthetic fixture explicitly completes rendering instead of guessing that native layout has done so.

The final full toolbar suite passed locally: 204 tests, two explicitly gated on-screen tests skipped, zero failures. A further full-suite run passed with 30 iterations per tool and anchor: 1,680 simulated reveals with closing admission checks, plus the 112 unforced native completions. The committed fixture retains three iterations. The rebuilt source also passed 190 production control checks, 38 picker, 19 insertion, 12 delivery and nine accessibility checks. All 18 native offscreen motion sequences passed again, including interrupted expansion, collapse and edge changes. Installed acceptance of the production admission changes and the integrated CI rerun remain with the integration owner.

## Installed acceptance

The integration owner is combining this branch with camera and image-workspace changes in PR #229 and owns the single signed Preview install. Follow the [update workflow](../../updating.md), then verify Copy build details before claiming installed acceptance. Source work is ready for integration.

After installation:

1. Drag resting and open pills to every edge, corner and free position; reverse during expansion. Confirm guide and landing agree.
2. Hover source actions and accessories on both sides. Check hints, options, chooser, Saved Prompts, Tab, Shift-Tab, Return and Escape.
3. Use Region, Window and Screen in Snap and prepared Snap & Talk, including cancel and retry. Confirm the intended capture/session receives each result.
4. Move while recording near the time limit with a background warning. Verify the dot, trace and both badges throughout turns and collapse.
5. Run `TOOLBAR_WINDOW_HIT_TESTS=1` for the collapsed native hit query and `TOOLBAR_KEY_WINDOW_TESTS=1` for native keyboard traversal. On-screen interaction remains reserved for integration.
6. Check Reduce Motion and available physical display arrangements. Synthetic negative-coordinate and resized-display checks do not establish physical multi-display or full-screen Space acceptance.
