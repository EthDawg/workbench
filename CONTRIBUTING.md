# Contributing to Workbench

A small, useful improvement is a good first contribution. Bug reports, documentation, accessibility checks, design feedback and hardware testing all count.

Workbench combines Voice and StageMark into one app. Its purpose is dependable everyday Mac utilities for speaking, annotating and presenting. Improve a concrete workflow and compare against what macOS already offers before adding another feature.

The separate [iOS/iPadOS 26+ Preview](docs/ios-preview.md) uses native phone/tablet workflows for the same useful jobs. Contributions should name the affected platform and preserve its own input, storage and lifecycle boundaries.

## Start from the current Workbench code

The canonical repository is **[`EthDawg/workbench`](https://github.com/EthDawg/workbench)** and the development base is **`main`**. Start new changes from `main` and target it in your PR. StageKit and the native mobile target are included here; a separate Voice or StageMark checkout is unnecessary. The former `local-voice` repository URL redirects here, preserving existing issues, PRs and releases.

Matt ([@mattywhitenz](https://github.com/mattywhitenz)) is a Workbench co-contributor. His September contributions include native Screenshot handoff, Snap & Talk, accessibility, transcript export, reading cancellation, Speko voices, Quick Look and timer placement. See the [integration acceptance checklist](docs/releases/2026-09-20-integration-preview.md) for their combined testing scope. Screenshot handoff launches Apple's capture tool; capturing and editing the resulting image inside Workbench remains a separate possible follow-up to [issue #18](https://github.com/EthDawg/workbench/issues/18).

Repository collaborators can push their own feature branches after accepting their GitHub invitation. No fork or shared credentials are needed. The working agreement below remains a proposal for Ethan and Matt to agree.

## Choose a first step

Read [product direction](docs/commodity-strategy.md) for the outcomes being tested and [the supporting review](docs/research/product-direction-2026-09.md) for evidence and alternatives. These explain priorities; the live issues remain the work queue. Check current source before implementing an older proposal.

1. Check the [open issues](https://github.com/EthDawg/workbench/issues). An unassigned [good first issue](https://github.com/EthDawg/workbench/issues?q=is%3Aissue%20is%3Aopen%20label%3A%22good%20first%20issue%22) is a useful starting point. Comment that you want to take it so others can coordinate; no repository write access is needed.
2. A typo or clear, small fix can go directly to a PR. Discuss a larger feature in an issue or [Discussions](https://github.com/EthDawg/workbench/discussions) first. Agree the smallest useful outcome and who is working on it.
3. Ask for help on the issue when stuck. Incomplete attempts and draft PRs are welcome. Coordinate before replacing work another contributor has offered to do.

**No Mac or no Swift experience?** Edit documentation through GitHub's pencil and fork/PR workflow. Say “documentation only” in the PR; native checks are unnecessary for that change. Hardware findings can be an issue comment with the Mac/device/OS versions and steps tried.

## Build and check the Mac app

Use an Apple Silicon Mac, macOS 14+, Swift 6.2+ and the macOS 26 SDK. The deployment target and build SDK are different: optional newer Apple features need the newer SDK to compile. Full Xcode is required for App Intents metadata; Command Line Tools support source development.

Clone the current source. Choose a short branch name for your contribution.

Before running the tests, quit Workbench, Workbench Preview and earlier Voice/StageMark copies. The suite probes exclusive global shortcuts even in its CI mode; another running copy will cause a real registration conflict.

```sh
git clone https://github.com/EthDawg/workbench.git
cd workbench
git switch -c improve/small-change
bash scripts/doctor.sh
bash scripts/test.sh
bash scripts/build.sh
```

**Already have a fork or checkout?** Preserve any unfinished edits first. Fetch the canonical repository and create a new branch from its current `main`:

```sh
git fetch https://github.com/EthDawg/workbench.git main
git switch -c feature/screenshot-annotation FETCH_HEAD
```

If you do not have repository write access, create a GitHub fork and point your push remote at it after cloning:

```sh
git remote rename origin upstream
git remote add origin https://github.com/YOUR-USERNAME/workbench.git
```

The first build downloads the pinned dependency. The default test script covers release tooling, core and integration behaviour, provider contracts/transport, keyboard practice and StageKit. It does not need a speech-model download or microphone access. The ordinary build creates the ad-hoc `dist/Workbench.zip`; it does not install an app.

For persistent native testing, use the [signed Preview build/install commands](README.md#build-and-install-preview). A Developer ID Application identity is needed for that workflow. Quit the running Preview before installing, and quit legacy Voice/StageMark instances when checking global shortcuts. The installer preserves the previous Preview archive and saved data; it does **not** run the speech round-trip or prepare a model until the app is opened.

`REQUIRE_APP_INTENTS=1` makes packaging fail if real action metadata cannot be extracted. A successful source compile does not establish Shortcuts discovery. See [the integration guide](docs/voice-integrations.md).

CI runs automated checks and packaging on a macOS runner. A maintainer may need to approve a fork's first workflow run. For a behavioural change, add or run focused checks for the actual risk. Record relevant manual evidence: microphone permission/cancellation, cross-app paste, device disconnect/reconnect, keyboard conflicts, light/dark layout or other affected behaviour. Use synthetic content in public screenshots and recordings. If something cannot be tested, say why.

## Build and check the mobile Preview

Use full Xcode 26.1+ with the iOS 26.1+ SDK and an installed iOS 26 Simulator runtime. From the same checkout:

```sh
python3 scripts/mobile-project.py
open Mobile/Workbench.xcodeproj
bash scripts/test-mobile.sh
```

Choose the **WorkbenchMobile** scheme in Xcode. The script selects an available iPhone Simulator; set `MOBILE_SIMULATOR_UDID` to an available iPad UUID for tablet coverage. It disables signing, runs the unit/UI targets and prints a fresh `Results.xcresult` path. UI tests use a fresh temporary library. The Mac suite's global-shortcut conflicts and requirement to quit Mac apps do not apply to this test path.

The generator owns project entries and the shared scheme: update `scripts/mobile-project.py` for project configuration, and regenerate after adding files. Keep only proven portable text logic shared with the Mac. A mobile change must not import StageKit/AppKit or silently couple either app's saved state.

Record simulator model/OS and actual test results in the PR. Physical speech availability, microphone/interruption recovery, background reading, Pencil/VoiceOver and meeting receivers need separate device evidence. An unsigned archive is not an installable app; iOS development provisioning is separate from Mac Developer ID signing. See the [mobile build and acceptance record](docs/ios-preview.md#build-and-test) for current limitations. No upload or App Store submission follows automatically from these commands.

## Find the code

| Area | Start here |
| --- | --- |
| App lifecycle, menu bar and shared navigation | `Sources/LocalVoice/main.swift`, `WorkbenchHome.swift` |
| Dictation, recent captures and delivery | `Sources/LocalVoice/AppModel.swift`, `CaptureHistoryView.swift`, `TextDelivery.swift` |
| Recording HUD and clipboard receipts | `Sources/LocalVoice/CapturePanel.swift`, `ClipboardReceipt.swift`, `ClipboardReceiptChecks.swift` |
| Narrated Snap & Talk screen sessions | `Sources/LocalVoice/ReadbackModel.swift`, `ReadbackView.swift`, `ReadbackChecks.swift` |
| Recognition selection and transport | `Sources/LocalVoice/RecognitionProviders.swift`, `ModelSettingsView.swift`, `ProviderChecks.swift` |
| Cleanup and regression cases | `Sources/LocalVoice/Cleanup.swift`, `CleanupChecks.swift` |
| Unified keyboard assignment and practice | `Sources/LocalVoice/KeyboardCoach.swift`, `KeyboardCoachChecks.swift` |
| StageKit's public boundary | `Sources/StageKit/StageKitController.swift` |
| Drawing, boards, timer and presentation | `Sources/StageKit/AppCoordinator.swift`, `DemoScenes.swift`, `DemoPresentation.swift` |
| Presentation control visibility and keyboard reveal | `Sources/StageKit/PresentationControls.swift`, `Tests/StageKitLegacy/DemoModeTests.swift` |
| Device capture and Apple alternatives | `Sources/StageKit/DemoCapture.swift`, `NativePresentationApps.swift` |
| Identity, appearance and legacy-data import | `Sources/LocalVoice/Workbench.swift`, `Sources/StageKit/Workbench.swift` |
| Packaging and Preview install | `scripts/build.sh`, `scripts/release/preview.py`, `scripts/release/config.json` |
| Mobile navigation, text and local state | `Mobile/Workbench/WorkbenchApp.swift`, `TextWorkspaces.swift`, `MobileDocument.swift`, `MobileStore.swift` |
| Mobile speech and reading | `Mobile/Workbench/SpeechService.swift`, `ReadingService.swift` |
| Mobile image editing and export | `Mobile/Workbench/ImageWorkspace.swift`, `ImageCanvas.swift`, `ImageRendering.swift` |
| Mobile project and native tests | `scripts/mobile-project.py`, `scripts/test-mobile.sh`, `Mobile/WorkbenchTests`, `Mobile/WorkbenchUITests` |

[The product contract](docs/workbench.md) owns app-wide behaviour; [the implementation map](docs/design.md) describes boundaries. Voice currently lives in the `LocalVoice` executable target; `StageKit` is a separate Swift library within the same process. Neither module should grow its own app lifecycle or another menu-bar icon. The original checkouts are provenance, not a requirement to maintain matching implementation PRs in two repos.

The [jobs and interaction specification](docs/product-spec.md) defines input ownership, surfaces, placement and closure. The [public guide](https://workbench-mac.vercel.app/guide/) explains them to users. Update that specification and `site/guide/index.html` alongside behavior changes.

For mobile behaviour, update [the mobile contract and evidence](docs/ios-preview.md); [mobile research](docs/mobile-research.md) records the native baselines and platform constraints. Keep mobile results separate from the Mac acceptance record.

## Send your change

Keep one clear purpose per PR. Follow surrounding Swift style and avoid unrelated formatting or generated build products.

For a larger proposal, leave a short breadcrumb in its issue: the user's job and workaround, evidence, smallest useful change, input/output and existing state owner, acceptance and known limits, and why wider work can wait. Link the relevant decision instead of repeating a research report. Include model calls, correction effort or maintenance costs when they affect the choice. A typo or straightforward fix does not need this ceremony.

```sh
git add path/to/changed-file
git commit -m "Describe the user-visible improvement"
git push -u origin improve/small-change
```

Open **Compare & pull request** for your branch on GitHub. Set the destination to **`EthDawg/workbench` → `main`**, including when the branch is in your fork. Check the Files changed tab contains only your contribution. Explain what improves, link the issue, and describe the evidence and limitations. Use `Closes #123` only when the change fully resolves it. Draft means ready for feedback; it does not mean ready to release. Screenshots or short recordings help with UI changes.

AI-assisted work has the same ownership and testing expectations. The submitting person must understand the change and check its claims. Never include private prompts, recordings, credentials or customer assets. There is no CLA or DCO signing step. Contributions use this repository's [MIT license](LICENSE); preserve upstream notices and contribute only material you have the right to share.

## Proposed Ethan–Matt working agreement

**This is a proposal for the two people to agree, not a statement of existing GitHub roles, branch protections or delegated publishing authority.**

- Ethan and Matt share direction and review meaningful changes from each other.
- Either can experiment. Claim a shared issue before implementation; coordinate if the work overlaps an existing contribution.
- Keep independent features in separate PRs. Automated checks and AI review support the other person's review.
- Agree together before introducing services, telemetry, broad permissions, major dependencies, migrations or a public release.
- AI can investigate, implement and draft. Public replies and commitments follow the submitting maintainer's explicit delegation. Writing in Ethan's style alone does not grant permission to speak or commit for him.
- Keep consequential WhatsApp decisions in the relevant issue or PR. Issues are the work queue; releases are the download and change record.

A maintainer review should establish scope, clarity, user-data preservation and relevant validation. A green build, merge, signed archive and published release are distinct states. Keep previews labelled and verify the actual packaged app before promotion. Response times vary; no support SLA is promised.

Be kind and specific. Read [community expectations](CODE_OF_CONDUCT.md) and use [private security reporting](SECURITY.md) for vulnerabilities.
