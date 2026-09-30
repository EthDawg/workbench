# Mac experience candidate — 29 September 2026

[PR #229](https://github.com/EthDawg/workbench/pull/229) brings together the Home, sidebar, local Me profile, floating controls, voice feedback and download-copy changes. It is an installed Preview candidate. No new public archive, update feed or website deployment is claimed.

## 30 September integration

The combined candidate includes profile camera recovery, the shared image workspace, direct Snap / Snap & Talk capture choices, and toolbar edge orientation. Camera, image and toolbar work had separate writers and worktrees; this chat alone integrated the changes and updated the shared Preview.

### Installed source

- **Workbench Preview 2.3.1, build 20260930031442**, clean source **bd6d2ba1063397ce498e97027af891c5fa859d90**. Native Copy build details was pasted into a local test document and matched the installed bundle. The existing path, `com.ethdawg.workbench.preview` identity and `GHVAAH9P5Z` signing team were retained through `scripts/install.sh --no-open`.
- Detailed image editing and camera recovery checks first ran on build **20260930023227**, source **f3992dcf4851bb847d0aa41ebf7c0421297ccad3**. The final build adds toolbar orientation; image and camera implementation is unchanged. Image reopening, navigation, archive/copy behavior and capture integration were checked again on the final build.
- Stable, public binaries, update feeds and the deployed website were not part of this install. The receipt below for 29 September describes an earlier candidate.

### Combined checks

At `bd6d2ba`, `bash scripts/test.sh` passed: **327 Swift package tests** (two gated on-screen skips), **253 StageKit tests / 4,903 assertions**, **139 Snap checks**, and the required capture, image workspace, history, handoff, provider, meeting and release checks. The two gated native window-hit and keyboard-traversal tests were also run explicitly and both passed.

The focused toolbar run passed **203 tests**, production controls passed **190 checks**, and the motion renderer passed **18 sequences**. The surface registry classified **444 entries**. The signed installer passed its packaged resource checks. Existing keychain deprecation warnings remain unrelated to this change.

CI run [36662608243](https://github.com/EthDawg/workbench/actions/runs/36662608243) exposed runner-specific drag-coordinate and warning-pixel assertions after local success. Follow-up `4129f61` corrects queued test-event coordinates, allows one pixel of rendering variation while requiring a deliberately clipped reference to fail, and completes the native display pass before hit testing. It changes tests and their receipt only; the installed production implementation remains identical. The final CI result is recorded on PR #229; a local pass alone does not satisfy that gate.

### Installed acceptance

| Journey | Result and boundary |
| --- | --- |
| Image editing | Imported a synthetic 1600 × 1000 image, added multiline text, cropped to 16:9, moved and resized text with the pointer, and verified keyboard Undo/Redo. Original comparison retained edits and ignored editing keys. Rotation changed dimensions and newly added text stayed upright. |
| Draft protection | Cancel, window close and Quit asked before discarding changed edits. Keep editing retained the draft. Closing the main Home window left the separate draft open. Deliberate discard preserved the saved image. |
| Save, copy and export | Save & Copy produced a saved Snap and an image on the clipboard. Native export produced 1600 × 900 PNG. Decoded sRGB pixels matched the stored rendered image; the stored original matched the synthetic input pixels. PNG byte encodings differ because the app normalizes images. |
| Shared viewing | Home and Snap opened the same saved-image window. Right/Left keys moved through the source collection and returned to the synthetic image. Zoom and Fit worked. An archived image offered Edit a copy, opened a separate New Snap draft, and returned to the unchanged source on Cancel. |
| Capture controls | The installed Snap toolbar exposed Region, Window and Screen. Screen opened New Snap at the captured display size; Cancel saved nothing. Snap's Region and Window selectors showed the expected source and their Cancel capture button returned with no history entry. Snap & Talk's Region selector started with the same 39-section session; quitting ended the test selector without adding a section or narration. The controller could not deliver Escape to Apple's selector, so physical Escape cancellation is not certified here. |
| Toolbar layout and keyboard | Left and right positions rendered upright vertical controls; free placement remained horizontal. Native Tab traversal reached More; keyboard menus opened Position, and the chooser switched to Snap & Talk with Region / Window / Screen / Review in order. Top/bottom, corners, transitions and guide geometry have source/render coverage; this run did not establish physical drag or hover acceptance. |
| Camera recovery | Take photo opened an in-profile preview without trapping the sheet. The selected camera reached its ready state, then reported a stalled feed; a bounded recovery message and Try again appeared. Retry, Cancel, Choose photo, appearance review and cancellation all worked. No new permission was granted and no profile photo was saved. Successful live photo capture and denied-permission behavior remain hardware/OS acceptance checks. |

The synthetic saved Snap was archived through the app. Capture and copy drafts were discarded. Home, the expanded sidebar, Dark appearance, Snap toolbar mode and original free placement were restored; the loaded session retained 39 sections. Of 171 files hashed before testing, 169 remained byte-identical, no file was missing, and only the existing app-state and boards manifests changed during normal app use. Original image files remained unchanged. The temporary placement preferences were restored with Preview closed, touching only the six placement keys after verifying they still held this test's right-edge choice.

### Remaining merge and release gates

PR #229 remains draft for outstanding installed acceptance; final CI must also pass before merge. The native controller returned `windowNotFoundAtPosition` for pointer actions on the floating panel, while pointer actions in the image editor worked. This limits physical hover, drag, reveal/collapse and click-through conclusions. Full VoiceOver traversal, physical display arrangements, successful camera capture and the earlier natural-speech/coexistence audio gap also remain separate from automated checks. The [Mac release gate #7](https://github.com/EthDawg/workbench/issues/7) stays open.

Snap text or rotation uses format 2. Prior v1 metadata is retained on first promotion; original and earlier rendered files remain immutable. Older binaries reject v2 records. See [Snap compatibility](../../snap.md#one-image-workspace) before a binary downgrade.

## 29 September baseline

## Build and test boundary

- Installed and running: **Workbench Preview 2.3.1**, build **20260929121540**, clean source **bca3ecf1d7bbc0152f88c0dfb5083835189f8c85**.
- Identity: `com.ethdawg.workbench.preview`, signing team `GHVAAH9P5Z`, existing signed Preview install/update path. In-app Settings showed the matching build and source; Copy build details was invoked. Bundle metadata and the installer's signature/profile checks matched.
- Hardware: MacBook Air / Apple M5, macOS 26.5.1, built-in microphone. The lid was open for the earlier baseline and reported closed during the final audio probe. No external microphone, receiver or additional-display acceptance is included.
- Stable remained 2.3.1 build `20260929044112`, source `6aac0cba05764556321216296fb524f240f4b1eb`.
- Later commit `9592c90` changes only a test's accessibility-mode setup. It does not change the installed app implementation. Later receipt and contract edits likewise do not identify a new installed binary.

One integration owner installed and operated Preview. Worker builds and galleries used synthetic data. The installed review preserved the existing loaded session, transcripts, library and profile; toolbar mode and sidebar state were restored. No permission resets or grants were used.

## Installed checks

These actions used the native app through accessibility and keyboard controls.

| Scenario | Result | Evidence and boundary |
| --- | --- | --- |
| Home and branding | Pass | Dictate, Snap and Snap & Talk lead the page; one recent-work section and Open History; Me profile; settled action greeting. Existing loaded-session count and recent items remained visible. The greeting's timing is source/fixture coverage, not a frame-timed native claim. |
| Sidebar | Pass | Collapse retained named accessibility controls; Dictate navigation worked while collapsed; Control–Command–S expanded it; Home remained reachable. Native physical hover and tooltip timing were not exercised. |
| Profile choose/cancel | Pass | Choose photo accepted a synthetic gallery PNG, opened the existing Circle/Card/Original appearance editor, and Cancel returned to the unchanged Me profile. Take photo, permission denial and camera capture remain untested. Saved identity and old scene artwork preservation are covered with disposable-library tests. |
| Floating toolbar chooser and More | Pass, scoped | All seven modes opened their More menu. Dictate's menu also opened after native Tab/Tab/Space traversal from the launcher. This proves accessibility and keyboard operation. |
| Floating accessories | Pass, scoped | Draw's Tools menu opened. Snap & Talk's Review opened the existing session with the same capture count. An initial AX read after navigation failed; a fresh read confirmed the destination. An immediate More activation during menu dismissal needed a retry after tracking ended. |
| Reported unresponsive pointer-hover pill | Not verified | Source fixes native popup tracking to begin on the original mouse-down. The controller has no hover/mouse-move API, and baseline coordinate attempts returned a controller window-position error. Earlier Stable also opened More through accessibility. These observations do not establish that the user's physical-hover report is fixed. |

## Voice evidence

The recording trace uses a faster input response and admits softer microphone levels. Persona keeps the audience-facing response and a quieter resting outline. Neither change substitutes synthetic samples for microphone input.

- A new low-level regression failed against the baseline at the intended assertions and passed after the change: a **−50 dBFS** input becomes visible within the first **100 ms** of the simulated sequence.
- Review found and corrected a Reduce Motion outline cache mismatch. Native layer assertions now check opacity when presence changes while intensity is unchanged.
- The signed candidate opened the real microphone and received its first frames in **101 ms**, with **42 deliveries in four seconds**. Hiding, disabling, the Persona key and shutdown closed input in **under 3 ms** in this run.
- **The final speech/coexistence audio-amplitude probe failed.** Every input sample was zero (the recorder measured −120 dBFS) while `AppleClamshellState` reported closed. Both the Persona source and independent recorder/engine received silent buffers. Lifecycle delivery passed; hearing speech, visible speech timing and usable concurrent recorded audio did not. The run retained no audio.
- The earlier open-lid baseline demonstrated real input and recording coexistence, but its synthetic playback calibration did not establish all onset/release targets. Natural speech, soft speech, continuous speech and headset/receiver behavior still need a suitable hardware run.

No current native speech-response acceptance is claimed. The local receipts retain the failed measurements; public images below use synthetic content only.

## Automated validation

- Full `bash scripts/test.sh` passed locally at the installed implementation: **305 Swift package tests**, including **one explicitly gated on-screen keyboard skip**; **243 StageKit tests / 4,808 assertions**; **120 Snap checks**, plus the script's core, keyboard, delivery, history, handoff, meeting and other required checks.
- The integrated surface gallery passed: **260 renders, 140 entries, zero flags**. It uses isolated synthetic homes and production hosts, and covers light/dark, constrained layouts, loaded-session Home, profile, menus and toolbar states.
- The production toolbar motion renderer passed at both anchors: **66 frames each**, ten distinct window widths, fixed launcher anchor, expansion before the final icon fade. This is an offscreen host check.
- The packaged archive and signed Preview installer passed resource checks, including **32 pack checks**, **129 transcript handoff checks** and **11 handoff runner checks**.
- Website: **19 tests** and the production-record build passed. Browser checks at 1280, 390 and 320 pixels found no overflow or console errors. Existing archive URLs and signed update feeds were preserved.
- First Mac CI run exposed a new hosted-trace test inheriting the runner's Reduce Motion setting. The app's fixed 1.5-point reduced-motion shape was correct; the test assumed a zero-amplitude quiet line. `9592c90` explicitly checks both native drawing modes, including sample-driven brightness and quiet recovery. All **nine focused interaction tests** passed locally afterward. Final CI status is recorded on [PR #229](https://github.com/EthDawg/workbench/pull/229).

Review also caught and corrected tooltip handoff timing and a Control–Command–S conflict with saved global shortcuts. Both shortcut backends preserve the saved choice but reject a conflicting active registration.

## Visual review

These are rendered production views with synthetic records, not screenshots of the user's library or proof of physical hover acceptance.

![Home in dark appearance](home-dark.png)

![Collapsed sidebar and loaded-session Home in light appearance](home-collapsed-light.png)

![Local Me profile](profile-light.png)

![Expanded Dictate toolbar](toolbar-dictate.png)

[Left-anchored motion](motion-left.gif) · [Right-anchored motion](motion-right.gif)

## Remaining acceptance

Physical hover and click-through across reveal/collapse, camera capture/denial, natural speech and concurrent usable audio, full VoiceOver traversal, additional displays and audience receivers remain open. This candidate does not close the [Mac release gate #7](https://github.com/EthDawg/workbench/issues/7).

[Draft release notes](../../releases/2026-09-29-mac-experience-candidate.md) are ready for an accepted release. Public publication must follow the shared signed archive/feed/site workflow.
