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

## Installed acceptance

The integration owner is combining this branch with camera and image-workspace changes in PR #229 and owns the single signed Preview install. Follow the [update workflow](../../updating.md), then verify Copy build details before claiming installed acceptance. Source work is ready for integration.

After installation:

1. Drag resting and open pills to every edge, corner and free position; reverse during expansion. Confirm guide and landing agree.
2. Hover source actions and accessories on both sides. Check hints, options, chooser, Saved Prompts, Tab, Shift-Tab, Return and Escape.
3. Use Region, Window and Screen in Snap and prepared Snap & Talk, including cancel and retry. Confirm the intended capture/session receives each result.
4. Move while recording near the time limit with a background warning. Verify the dot, trace and both badges throughout turns and collapse.
5. Run `TOOLBAR_WINDOW_HIT_TESTS=1` for the collapsed native hit query and `TOOLBAR_KEY_WINDOW_TESTS=1` for native keyboard traversal. On-screen interaction remains reserved for integration.
6. Check Reduce Motion and available physical display arrangements. Synthetic negative-coordinate and resized-display checks do not establish physical multi-display or full-screen Space acceptance.
