# Layout and SwiftUI state faults, 6 October 2026

Source: branch `claude/layout-faults` on top of `5f209cab85fad6fef5c8337ff2a076bdeffbcd35`.
Everything here ran from the source tree with `.build/release/LocalVoice`; nothing touched the
installed app. Installed-app checks are owed to the release lead.

## What was measured

Each render ran under `log stream --predicate 'subsystem == "com.apple.runtime-issues"'`, with
the child pass processes' pids recorded so that faults from other renders on the same machine are
not counted.

| Run | Before (base) | After (this branch) |
| --- | --- | --- |
| `--render-surfaces` (light + dark passes, 300 renders) | 318 `Publishing changes from within view updates` (159 per pass) | 0 |
| `ToolbarGalleryRenderer` (388 fixtures) | 0 | 0 |
| `--render-live-voice` (10 renders) | 0 | 0 |
| `--check-floating-toolbar` | 0 | 0 |
| `--check-core` | — | 0 |
| `scripts/test-stage.sh --ci` (WorkbenchStageTests) | 4 `Accessing State's value outside of being installed on a View` | 0 |
| `Invalid view geometry: width/height is negative` | 0 in every run | 0 |

The 318 publishes came from two places, attributed by tracing each pass: the Settings › Keyboard
section's window observer (45–51 per visit to the Models section, which follows Keyboard in the
gallery) and the image preview's fitted zoom report (5 per preview or image-workspace render).

## What is synthetic

Every render uses the gallery's synthetic fixtures: isolated preferences, synthetic Snaps,
prompts, meetings and shortcuts. No personal data.

## Pixels

Of 300 surface renders, 296 are byte-identical before and after. The four that differ
(`page-history-state-from-home-*`, `page-history-state-from-meeting-*`) also differ between two
runs of the unchanged base code, so they are run-to-run noise in History's states, not this
change. All 388 toolbar gallery fixtures and all 10 live voice renders are byte-identical. No PNGs
are kept here because no touched surface changed.

## What remains untested

- The `Invalid view geometry` pairs (486 lines in the installed log) never appear in any render.
  Their persisted backtraces are entirely inside AppKit: `-[NSThemeFrame _positionSharingIndicator]`
  from `-[NSWindow _setIsSelectivelyShared:]`, reached from a SkyLight window-sharing notification,
  that is, when another process captures a Workbench window. No Workbench frame is on the stack.
  Calling that path directly in a scratch harness did not create the indicator, so there is no
  deterministic reproduction and no code change for it here. Owed to the lead: capture the Home
  window (for example `screencapture -l <windowID>`) while watching the log, then decide whether a
  title-bar configuration change is wanted.
- Installed-app behaviour of the Keyboard section's stop and the preview's zoom label after this
  change.
