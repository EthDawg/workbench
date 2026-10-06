# Library consolidation and companion-app decision context

Checked 6 October 2026. Research and source audit for the [build-ready Library section](../mac-foundation.md#build-ready-library-and-surface-consolidation). This is not an implementation or installed acceptance record. The user asked for a complete, value-focused app and research into a possible phone companion, explicitly without building that companion.

## Verdict

Remove From iPhone from normal Mac navigation and new-use setup. Finish Resources and Packs as support for existing jobs, with preserved legacy material reachable contextually. Keep Present as the owner of a readable phone stage. Do not fund another photo-transfer system or a general companion merely to mirror a screen.

Apple's existing routes cover several different jobs. A companion could add value only where a demonstrated task remains unsolved, such as an approved wireless stream to a specifically supported receiver, explicit paired presentation controls, or domain-specific capture metadata. These are hypotheses, not current capabilities or a resumed mobile roadmap.

## Evidence and gaps in the current source

Baseline: main `7f2b00aa629f3d76b3697925d2f6bfdd6c9b2ee6`. The primary checkout was older and had unrelated edits; the audit used an isolated worktree at this revision. The current surface registry has 567 entries. That count is descriptive, not a quality metric or desired ceiling.

| Evidence | Finding | Consequence |
| --- | --- | --- |
| Supplied Library screenshot | Resources/Packs/From iPhone, preserved Read file, broad recovery warning, long internal path and “Saved Saved Read text” | Visible acceptance cases, not proof of the currently installed build. Do not publish the screenshot's private path; reproduce with synthetic data. |
| `Sources/LocalVoice/WorkbenchHome.swift`, `DemoLibraryView.swift` | Three Library sections, Chrome setup, Read aloud, demo-specific heading/search and prompt helper advertising Present's toolbar | A/G/H/E must converge on the same final routes/copy. Registry updates alone miss internal page controls. |
| `DemoLibrary.swift`, `DemoLibraryImportView.swift`, `DemoLibraryImport.swift` | Prompt/link/file owners; referenced file vs content copy; selected Return admission, hidden local shortcuts, reviewed import/conflict protection | Preserve meaningful existing safety. Keep one Library and improve its row/action hierarchy. |
| `PackLibraryView.swift`, `PackLibraryModel.swift` | Connection/add forms precede installed packs. Disk-only resource save has no Library return. A skill supporting both kinds defaults to Snap & Talk. Installed content and account access are separate. | Explicit target decisions in the spec; do not present these improvements as already implemented. Preserve device-flow cancel, update preference and immutable copies. |
| `PhotoHandoffKit/PhotoHandoffStore.swift`, `PhotoHandoffModel.swift` | Local manifest owns records, enable/account state and pending outcomes. General refresh may replay remote deletes/uploads before receiving. | Read-only recovery needs a bounded selected-record path; inspecting old material must not resume sync. |
| `SceneSyncKit/SceneLibraryModel.swift`, `SceneLibraryStore.swift` | Local portable scene owner has preservation/concurrency checks; ordinary refresh can sync dirty work | Keep the existing canonical no-write legacy retrieval rule. |
| PR [#286](https://github.com/Ship-Work/workbench/pull/286), head `6e4d84ebc0b454d1b1e33133efcd256bc30c67e8` | Removes PhotoHandoffModel wiring, arrival/Settings/view and refresh; old photos route redirects to Resources. The branch also carries Present work from #285. | Source inspected, not installed acceptance. Do not cherry-pick the entire branch as a “five-door removal.” Conditional inspect/export/stop/cloud recovery remains to be established against the canonical preservation requirement. |
| PRs [#291](https://github.com/Ship-Work/workbench/pull/291), [#292](https://github.com/Ship-Work/workbench/pull/292) and issues [#279](https://github.com/Ship-Work/workbench/issues/279), [#284](https://github.com/Ship-Work/workbench/issues/284) | Manual handoff, browser pause, ownership cleanup and Read retirement already have owners | Consume/reconcile their current source and evidence. No duplicate issue list, competing product spec or assertion that open PRs are released. |

`docs/mac-foundation.md` remains the target contract. `docs/workbench.md`, `docs/product-spec.md`, `docs/design.md`, `docs/photo-handoff.md`, `docs/private-packs.md`, the handbook and guide describe their owning areas and must be updated with implemented changes. This research does not silently rewrite their implemented-status claims.

## Native alternatives before a companion

| Job | Existing route | What a Workbench companion would actually add |
| --- | --- | --- |
| Control the phone with Mac input | Apple's iPhone Mirroring | No established added value. Installing a companion does not provide permission to control arbitrary other iOS apps or embed Apple's mirroring transport. |
| Show an operated phone in a call | Present's approved USB route, QuickTime USB, or AirPlay where permitted | A custom wireless transport might avoid a cable, but adds pairing, encoding, receiver, latency, lifecycle and support work. It does not prove meeting audio or managed-device compatibility. |
| Get a photo or file onto the Mac | AirDrop, Finder/Files, Mirroring drag-and-drop; Continuity photo/scan in supported apps | Generic transfer alone does not justify another sync store. Only demonstrated structured capture/provenance beyond these routes might. |
| Use the phone camera/mic as a Mac device | Continuity Camera | No established reason to duplicate it. Camera streaming is a different job from sharing the phone's screen. |
| Remote-control Workbench's own presentation | No claim of an existing Workbench phone remote | A small paired control surface is technically plausible but needs a real hands-busy presentation case. It would control Workbench, not the rest of iOS. |

Apple [iPhone Mirroring requirements](https://support.apple.com/en-au/120421) specify macOS 15+ on Apple silicon/T2, iOS 18+, the same Apple Account with two-factor authentication, nearby locked iPhone, Wi-Fi/Bluetooth, and no concurrent Mac AirPlay/Sidecar/internet sharing. The page still excludes the EU. Camera/microphone access on iPhone is unavailable through Mirroring; media audio and protected-content limits are separate. Mirroring can transfer selected items by drag-and-drop. A companion does not remove these restrictions. This is Apple's documented behavior, not a test of Workbench or the user's managed Mac.

[QuickTime's USB guide](https://support.apple.com/guide/quicktime-player/record-a-movie-qtp356b55534/mac) documents selecting a connected iPhone/iPad as the recording source. [AirPlay's guide](https://support.apple.com/guide/iphone/stream-video-and-audio-from-your-iphone-iphd668e80e6/ios) describes nearby network streaming and mirroring; receiver configuration, VPN/network policy and content can constrain it. Neither guide proves the call recipient receives both sides of a voice conversation. Keep the existing [phone/audio rehearsal contract](../phone-presenting.md).

[Continuity photo/scan](https://support.apple.com/en-gb/102332) already inserts a chosen image/document in supported Mac apps, including Finder. [WWDC22: Bring Continuity Camera to your macOS app](https://developer.apple.com/videos/play/wwdc2022/10018/) covers using an iPhone as a camera through Apple's integration. Prefer those existing routes before adding an app account, duplicate photo queue or mobile installation requirement.

## API, SDK and release boundaries

Inspected locally: Xcode **26.6**, build **17F113**; `xcrun --sdk macosx --show-sdk-version` and `--sdk iphoneos --show-sdk-version` both returned **26.5**. Workbench's `Package.swift` minimum is macOS **14**; the paused mobile generator targets iOS **26.0**. A newer installed Xcode label does not imply that every SDK or deployment target moved with it. No SDK installation or target change is part of this work.

- In the inspected iOS 26.5 ReplayKit headers, `RPBroadcast.h` declares `RPSystemBroadcastPickerView` from iOS 12; `RPBroadcastExtension.h` declares `RPBroadcastSampleHandler` from iOS 10 and video/app-audio/microphone sample types. A selected system broadcast could supply media to a custom sender. It supplies neither a complete secure transport/receiver nor arbitrary remote touch injection. Consent, interruption, protected content and audio-session behavior still constrain capture.
- Apple's current [ReplayKit picker](https://developer.apple.com/documentation/replaykit/rpsystembroadcastpickerview) and [sample-handler](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler) metadata now records deprecation at 27.0. Do not design a new long-lived companion around the older extension path without re-evaluating deployment coverage.
- Current [ScreenCaptureKit documentation](https://developer.apple.com/documentation/screencapturekit) adds iOS/iPadOS at **27.0**. Apple's [iOS capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios) requires iOS 27+ and uses the system content-sharing picker; it includes app/full-display capture and recording. This is published newer-platform capability, not something present in the inspected iOS 26.5 SDK or established for the paused iOS 26 target. The current metadata is non-beta; older indexed release-note pages still carry beta/RC headings. Apple's [14 September release announcement](https://www.apple.com/newsroom/2026/09/siri-ai-a-profoundly-more-capable-and-personal-assistant-is-here/) confirms the newer software generation shipped. None of this is local compile/device validation of the new capture path.
- The inspected macOS `SCStream.h` declares screen streams from 12.3, app audio from 13, microphone output from 15 and the picker-related generation from 14. [WWDC24: Capture HDR content with ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/) explains stream/microphone/recording output. These Mac APIs may capture permitted windows; they do not document a Workbench entitlement to Apple's iPhone Mirroring session. A Mirroring-window-to-Present experiment would be a separate Mac capture experiment with permission and receiver tests, not a reason to require mobile software.

Reviewed the [macOS 26.6 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-26_6-release-notes) and [iOS/iPadOS 27 notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) alongside symbol availability, rather than treating search snippets or a newer OS name as SDK proof. No reviewed source established a public API for embedding or remotely controlling Apple's proprietary Mirroring transport from Workbench. That is a bounded research finding, not a claim that Apple can never offer one. Future roadmap behavior stays unknown.

For any later phone sender, microphone/camera/local-network access is requested only when the chosen route needs it; broadcasting requires the person's explicit system-mediated start. A stream ending, app switching, locking, revoked permission or network loss needs its own state and receiver evidence. No silent start, background-delivery guarantee, DRM bypass or claim that a companion defeats employer controls.

## Reopen only for a concrete advantage

Keep mobile paused. If a later user job warrants investigation, first record the actual device/OS/receiver, current native alternative, permitted network/account constraints and the failure that matters. Try the simpler approved route. Only then run one bounded experiment, without shipping a general companion or reviving photo sync.

| Candidate | Evidence needed before a build decision | Stop condition |
| --- | --- | --- |
| Custom wireless phone screen feed | Permitted network, physical iPhone, selected broadcast, explicit pairing, receiver latency/rotation/reconnect/End, thermal/background interruption and protected-content behavior | Apple's route already solves the job, policy disallows it, or reliable end-to-end delivery costs more than the benefit |
| Presentation remote | Real need away from the keyboard; minimum named Workbench commands; reliable visible acknowledgement and revocation; no automatic capture | Keyboard/clicker/native control is adequate or remote state creates more uncertainty |
| Structured field capture | Repeated need for metadata/sequence/provenance unavailable through a chosen file import, with a receiving owner and offline/cancel recovery | Merely another photo-transfer bucket or a duplicate of ordinary phone sharing |
| Mac-only Mirroring window capture | Explicit capture permission, actual capturable image/audio on supported OS and readable meeting receiver result; no private API | Protected/blank content, unsupported account/policy or extra setup without improvement |

No latency, audio-duplex, battery, background, pairing or managed-device claims have been tested in this research. The future decision must compare total setup/correction/support cost and later voluntary reuse, not just whether a sample app compiles. Retain these findings as context; implement none of these candidates in this consolidation.
