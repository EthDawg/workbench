# Device scene snapshot contribution

Issue: [#20](https://github.com/EthDawg/workbench/issues/20). Branch: `feature/issue-20-scene-snapshot`.

## Observable change

Expand a live device presentation's controls and choose **Copy scene snapshot**. The PNG combines one fresh video frame with the presentation's frozen still backdrop/crop, hand, logo and placed persona. It keeps the window's aspect ratio and Match device proportions choice; a fixed viewport letterboxes the picture. Separate overlay windows, controls, other apps and audio are not captured. Animated backgrounds use their static poster, explicitly described in the controls. Existing preparation PNGs keep their empty device frame.

`DemoCapture` retains only the most recent sample. `DemoSnapshotStore` invalidates it on selection, reconnect, End, matching disconnect/error notifications and teardown. A request freezes its generation before joining the capture queue. The final clipboard commit requires the same generation, a connected/running device session and a monotonic sample age of at most one second. The receipt identifies the selected source and when the sample arrived on the Mac, not a claimed device exposure time.

The capture output is already configured as BGRA. Explicit copy makes an immutable pixel copy off main, respecting row stride, color space, clean aperture and pixel aspect. The shared scene renderer composites on main; no recorder, GPU conversion requirement, new dependency or durable storage format is added.

## Automated and rendered evidence

Validation is in progress. Reproduce the focused checks with:

```sh
bash scripts/test-stage.sh --snapshots-only
node --test site/tests/*.test.mjs
node site/build.mjs
```

The focused suite exercises real synthetic `CMSampleBuffer` input, newest-frame replacement, delayed/stale clipboard commits, source identity, same-device replacement, the real capture model's immediate End/selection/reconnect invalidation, clipboard refusal, image orientation, clean aperture/pixel aspect, fixed versus matched viewports, preserved branding/persona pixels, hidden-device export and bounded canvas geometry. Fake clipboard writes establish decision behavior, not native delivery.

An optional `--snapshot-evidence OUTPUT_DIRECTORY` runner path renders the production snapshot control with synthetic ready/success/failure state and writes a synthetic scene PNG. This is native view/compositor evidence, not a physical feed or a window-server screenshot.

## Limits and remaining acceptance

The full `--scenes-only` run could not complete in this host: existing board clipboard checks failed, and `BreakTimerPlacementTests.swift` dereferenced an unavailable `NSScreen.main`. An escalated native retry had the same limitation. Do not describe that run as a passing full suite. Core Image also could not access its image-conversion service here; the final implementation instead copies the explicitly configured BGRA sample directly.

Before closing #20, verify with physical iPhone and iPad feeds and a receiving app: portrait/landscape rotation, clean aperture and color, the fixed/matched viewport, static background, logo/persona layering, actual clipboard paste, stall/unplug/reconnect/reselect/End during Copy, and recovery after a failed copy. Check keyboard focus, VoiceOver and controls at the minimum window size. No physical device, live clipboard success, installed signed build or published release is established by this contribution's synthetic checks.
