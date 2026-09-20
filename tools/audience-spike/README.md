# Audience output developer spike

This separate macOS **15.2+** experiment tests whether one local output window can keep a presenter's separate controls out of a meeting share while switching among explicitly chosen demo windows. It is **not part of Workbench Preview, the Chrome extension, the App Store target or any release package**. Its `.app` has a separate identity and no connection to Workbench user data, native messaging, personas or Chrome profiles.

Status: compiled locally; the pure selection/lifecycle checks ran. **Capture, system-picker interaction, permission handling on a real desktop, visual layout, performance and receiving Zoom/Teams views have not been tested.** A successful compilation does not establish privacy or corporate deployability.

## Recovery decision, 21 September 2026

This uncommitted experiment was recovered from the earlier presenter work rather than integrated into the app. Its original direction was to remain a developer spike. [Provenance](provenance.json) records the source base and original file hashes; all three Swift files and the build script are unchanged. This recovery reran the 24 pure checks and compiled the separate app successfully. It did not launch it or access the desktop.

The product question belongs to [contextual notes #38](https://github.com/EthDawg/workbench/issues/38) and [receiver verification #29](https://github.com/EthDawg/workbench/issues/29). First compare a selected-window share plus notes on an unshared display with this controlled output. Prefer the existing sharing route if it serves the demo. This prototype adds a second capture/composition path and support burden; it earns integration only if the simpler route prevents a needed multi-window demo.

Run one synthetic two-window rehearsal before expanding it. A second participant must observe the output while the presenter switches selected windows, puts a clearly marked private sentinel in the unselected controls, stops, reselects, closes a source and sleeps/wakes. Record actual OS/client versions and what the receiver sees, then measure ten minutes of CPU, memory and delay. A missing source must stay blank without broader capture or automatic replay. A privacy leak, unusable latency, policy block or inadequate value is a reason to keep it deferred. Do not disguise failure by choosing the whole display.

If the trial succeeds, the next design decision is an explicit audience-content registry for StageKit artwork and controls. That work is absent here. Do not promise annotations, persona overlays, phone scenes, sound, recordings or meeting integration on the strength of this prototype. No additional audience feature issue is needed until those results justify a bounded implementation proposal.

## Build and run

Requires full Xcode or compatible Apple Command Line Tools with a macOS 15.2+ SDK. From the repository root:

```sh
bash tools/audience-spike/build.sh
```

The script runs 24 pure checks and compiles an ad-hoc-signed app under this directory's ignored `.build/`. It does not launch the app, request permission or begin capture. Nothing is installed into Applications.

To run the experiment explicitly:

```sh
open "tools/audience-spike/.build/Workbench Audience Spike.app"
```

1. Put synthetic demo windows on one display. Keep personal tabs out of those windows.
2. Choose **Choose demo windows…** and select one to eight exact external windows in the macOS picker. Cancel leaves the output blank. Capture starts only after an accepted selection.
3. Inspect **Workbench Audience** locally. Multiple-window capture uses one fixed display; a single desktop-independent window is labelled separately and can follow that same window between displays.
4. In Zoom or Teams, choose the **single Workbench Audience window**. Do not choose the whole display or the Workbench Audience Spike application. Check a second participant's receiving view before using real material.
5. **Stop / blank** clears the pixels before awaiting stream teardown. Closing the audience window stops capture. Closing private controls or Quit stops the process. Sleep, session deactivation, display reconfiguration, a selected application's termination or unavailable frames stop it; restarting requires another selection.

If Stop is pressed while the system picker is open, finish/cancel that picker first. Its result is discarded; a new picker cannot overlap it.

To rerun only the pure checks after a build:

```sh
"tools/audience-spike/.build/StateTests"
```

## Synthetic live rehearsal

Use two ordinary browser windows containing visibly different, fictional Employee and Manager pages. Prefer a separate Chrome for Testing user-data directory with no signed-in account, personal bookmarks or extension sync. Place both on the same display. First test the spike without Workbench: select exactly those two windows in the system picker, change their focus, overlap them with the private controls, then Stop and cancel/reselect. Do not select an application or display to work around a rejected selection.

Next, if rehearsing Workbench's Smart Menu too, leave its window **unselected** and put a synthetic `PRIVATE QA SENTINEL` in test-profile notes. Share only the audience output to a receiving participant and explicitly reveal the notes. Their absence from the receiver is the relevant check. Native persona overlays are omitted from this spike even if they remain visible on the presenter's desktop; this rehearsal does not validate future artwork composition.

The existing `--presenter-fixture` route isolates Saved resources and presenter preferences, but currently does not instantiate StageKit or the profile-overlay coordinator. The separate `--persona-session-fixture` exercises temporary manual persona sessions, not Chrome profile following. Neither is evidence of an integrated profile-specific overlay. For an installed-app rehearsal that avoids changing persona records, use only already-existing, verified synthetic artwork and reversible test-profile preference mappings. Preserve unrelated preferences and never restore an old whole snapshot over intervening user changes.

Opening this spike's private controls does not start capture. The next consent boundary is **Choose demo windows… → explicit window selection in the macOS picker**. A managed Mac may reject it. Cancel/denial should stay blank; do not reset permission databases, grant persistent capture or switch to unrestricted screen access to make the test pass.

## Capture boundary

- The system picker is restricted to multiple-window selection and excludes this spike's windows/bundle. Its returned filter is additionally checked: nonempty exact windows, no application selections, identifiable external owner processes, no duplicate IDs, at most eight windows and one display for a display-bound selection. Unexpected/broad filters are rejected, never reconstructed into a broader filter.
- The original system-provided filter is retained; there is no global `SCShareableContent` enumeration, `CGPreflightScreenCaptureAccess`, permission reset, Accessibility grant, browser data read, DOM access or title-based window guessing.
- Menu bar and separate child windows are excluded. All pixels inside a chosen window remain in scope, including other tabs, inline popovers, passwords and private documents displayed there. This is a **window boundary**, not a Chrome-profile, URL or document boundary.
- New windows are not silently added. Closing/reopening a browser window may require choosing it again. Moving selected windows between displays, Stage Manager and Spaces need testing; changing display configuration stops the spike rather than selecting another screen automatically.
- Private controls and output are separate windows from the selected external processes. This prevents self-capture in the intended exact-window filter. The output itself contains only captured pixels over an opaque neutral background; it contains no source names, errors or private controls.
- There is only a `.screen` stream output. System audio and microphone capture are explicitly off. No recording output, file destination, network transport, telemetry or captured-content log is implemented. Frames are held in memory with at most one rendered image waiting for the main queue. Output is SDR, capped at 1920×1080 and 30 fps, with queue depth 3. These are configuration limits, not measured resource claims.
- Generations reject old picker/frame callbacks after Stop or replacement. Blank/suspended/stopped frames, inactive streams and errors clear the output. An idle frame may preserve a valid static picture; absence of changed pixels is not treated as a failure. There is no automatic retry or source fallback.
- **StageKit personas, annotation canvases, timers and device scenes are omitted.** Including an entire Workbench window would also include any controls embedded inside it. Production integration would need an explicit audience-window registry and separation of in-window private controls. This prototype does not expose that integration.
- No claim is made that an arbitrary meeting app will hide private windows when the user shares a whole display/application. macOS `NSWindow.sharingType = .none` is not a privacy mechanism used here.

## Corporate deployment and support boundary

The Chrome extension/ordinary Workbench Preview do not acquire capture permissions from this spike. Keep their installation path simple. This separate unsigned-for-distribution developer app is not a recommended corporate installer and should not be distributed as a supported feature.

The system content picker is the preferred explicit selection path. macOS or MDM may still deny screen capture or impose consent requirements. The spike surfaces the failure and stays blank. It does not bypass managed policy, modify TCC, request persistent-capture entitlements, grant itself permissions or fall back to whole-screen access. Ask the organisation's administrator if policy blocks a permitted test. Ad-hoc signing can create Gatekeeper/identity friction; a supported managed rollout would require a stable Developer ID identity, notarization and organisation approval after the experiment proves useful.

Only macOS 15.2+ is targeted because that SDK exposes the chosen windows/applications/displays for validating a picker result. No Windows, browser-only, ChromeOS, mobile or older-macOS support is implied. Corporate meeting clients, remote desktop sessions, virtual displays and security agents may behave differently.

## Acceptance matrix — all runtime rows pending

Use visible synthetic sentinel text, such as `PRIVATE CONTROL SENTINEL`, with no customer/account data. Observe the receiving participant, not just the presenter's preview.

| Check | Expected result | Current evidence |
| --- | --- | --- |
| Compile and exact-window/generation policy | No capture required; unsafe scopes and stale callbacks rejected | Build + 24 pure checks |
| First run, deny/cancel, MDM denial | No pixels or automatic retry; actionable private feedback | Pending |
| Two Chrome profiles, existing selected windows | Focus/profile changes appear in output; unrelated windows remain absent | Pending |
| Personal Chrome window, Mail, notifications | Unselected content absent, even when brought forward | Pending |
| Private controls/output moved over the source | No private controls or recursive output in the receiver | Pending |
| New private spike window / system sheet | Never added to capture | Pending |
| New browser window, child dialog, file picker | Never silently broadens selected scope; document actual omitted UI | Pending |
| Stop/reselect while frames are queued | Immediate blank, no old frame returns | Pure generation checks; runtime pending |
| Close all selected windows or terminate one selected app | Blank and explicit reselect | Pending |
| Sleep, logout/lock/session change, disconnect/rotate display | Blank; no fallback to another screen or automatic resumption | Pending |
| Static slide for several minutes | Remains visible while legitimately idle | Pending |
| Spaces, fullscreen, minimize, output occlusion | No unwanted source switch/stale frame; receiving view documented | Pending |
| Zoom and Teams, actual corporate builds | Single audience-window share excludes separate controls | Pending |
| Ten-minute CPU/memory/latency observation | Bounded use; decide whether a GPU-native display path is needed | Pending |

## Primary references

- [Apple: SCContentSharingPicker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker) and [picker modes](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpickermode): system selection rather than an unrestricted capture surface.
- [Apple: SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter): exact content filters; window/application/display distinctions.
- [Apple: Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/): inclusion/exclusion behavior, child windows, recursion avoidance and frame queues.
- [Apple: SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration) and [SCFrameStatus](https://developer.apple.com/documentation/screencapturekit/scframestatus): configuration and lifecycle signals.
- [Apple: NSWindow.SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none): explicitly not a dependable way to omit captured content.

API availability and default semantics were also checked against the local macOS 26.5 SDK `ScreenCaptureKit.framework/Headers/{SCStream,SCContentSharingPicker,SCShareableContent}.h` while keeping the deployment target at 15.2. No private API is used.
