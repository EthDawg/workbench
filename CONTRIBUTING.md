# Contributing to Workbench

A small, useful improvement is a good first contribution. Bug reports, documentation, accessibility checks, design feedback and hardware testing all count.

Workbench combines Voice and StageMark into one app. Its purpose is dependable everyday Mac utilities for speaking, annotating and presenting. Improve a concrete workflow and compare against what macOS already offers before adding another feature.

**Current priority: Mac desktop quality. iOS, iPadOS and Chrome extension development and releases are paused.** Work from the [Mac release gate](https://github.com/Ship-Work/workbench/issues/7). Existing platform code and research are retained; do not restart paused work without an explicit scope decision. Public users install **Workbench**. Contributors use the separate **Workbench Preview** edition for integration testing.

## Start from the current Workbench code

The canonical repository is **[`Ship-Work/workbench`](https://github.com/Ship-Work/workbench)** and the development base is **`main`**. Start new changes from `main` and target it in your PR. StageKit and the native mobile target are included here; a separate Voice or StageMark checkout is unnecessary. The former `local-voice` repository URL redirects here, preserving existing issues, PRs and releases.

Matt ([@mattywhitenz](https://github.com/mattywhitenz)) is a Workbench co-contributor. His September contributions include native Screenshot handoff, Snap & Talk, accessibility, transcript export, reading cancellation, Speko voices, Quick Look and timer placement. See the [integration acceptance checklist](docs/releases/2026-09-20-integration-preview.md) for that release's testing scope. Current source adds independent capture, editing and durable [Snap History](docs/snap.md); its combined delivery and native acceptance are tracked in [issue #112](https://github.com/Ship-Work/workbench/issues/112). Source implementation and a published package remain separate claims.

Repository collaborators can push their own feature branches after accepting their GitHub invitation. No fork or shared credentials are needed. Coordinate scope in the issue or PR before touching another contributor's active work.

Matt's ServiceNow branding and deck helpers originated in [#104](https://github.com/Ship-Work/workbench/pull/104), whose authorship and public history remain intact. From 2.2, company content is maintained in its private pack repository; open its source link in Packs to contribute there. Changes to Workbench's generic loader and handoff contracts belong in this public repository. Preserve original artwork and credit, publish changed payloads as a new pack version, verify rendered examples in the pack repository, and leave existing sessions' snapshots unchanged. Colleagues use the [team guide](https://workbench-mac.vercel.app/guide/#servicenow-pack) and their team's pack link.

## Choose a first step

For the current refinement work, start with the [focused Mac foundation](docs/mac-foundation.md) and its issue/owner map. Complete one bounded journey, including unavailable setup and usable output, and keep implementation, native acceptance and release claims distinct. Existing owners and preserved data take priority over a fresh rewrite.

Apply [Value before scope](docs/workbench.md#value-before-scope) in the existing issue/PR: explain the evidenced outcome, simpler alternative, existing owner, net complexity and complete-use acceptance. This includes infrastructure and marketing. Prefer removing friction over adding choices; a small fix needs a concise explanation, not another proposal document.

1. Check the [open issues](https://github.com/Ship-Work/workbench/issues). An unassigned [good first issue](https://github.com/Ship-Work/workbench/issues?q=is%3Aissue%20is%3Aopen%20label%3A%22good%20first%20issue%22) is a useful starting point. Comment that you want to take it so others can coordinate; no repository write access is needed.
2. A typo or clear, small fix can go directly to a PR. Discuss a larger feature in an issue or [Discussions](https://github.com/Ship-Work/workbench/discussions) first. Agree the smallest useful outcome and who is working on it.
3. Ask for help on the issue when stuck. Incomplete attempts and draft PRs are welcome. Coordinate before replacing work another contributor has offered to do.

**No Mac or no Swift experience?** Edit documentation through GitHub's pencil and fork/PR workflow. Say “documentation only” in the PR; native checks are unnecessary for that change. Hardware findings can be an issue comment with the Mac/device/OS versions and steps tried.

## Build and check the Mac app

Use an Apple Silicon Mac, macOS 14+, Swift 6.2+ and the macOS 26 SDK. The deployment target and build SDK are different: optional newer Apple features need the newer SDK to compile. Full Xcode is required for App Intents metadata; Command Line Tools support source development.

Clone the current source. Choose a short branch name for your contribution.

You can run the tests with Workbench open. The suite probes exclusive global shortcuts even in its CI mode, so while Workbench, Workbench Preview or an earlier Voice/StageMark copy holds the defaults, the two checks that need them are reported as SKIP with that app's name instead of failing. Quit it to run them locally; GitHub CI, where nothing else runs, checks them in full.

```sh
git clone https://github.com/Ship-Work/workbench.git
cd workbench
git switch -c improve/small-change
bash scripts/doctor.sh
bash scripts/test.sh
bash scripts/build.sh
```

**Already have a fork or checkout?** Preserve any unfinished edits first. Fetch the canonical repository and create a new branch from its current `main`:

```sh
git fetch https://github.com/Ship-Work/workbench.git main
git switch -c feature/screenshot-annotation FETCH_HEAD
```

If you do not have repository write access, create a GitHub fork and point your push remote at it after cloning:

```sh
git remote rename origin upstream
git remote add origin https://github.com/YOUR-USERNAME/workbench.git
```

The first build downloads the pinned dependency. The default test script covers release tooling, core and integration behaviour, provider contracts/transport, keyboard practice and StageKit. It does not need a speech-model download or microphone access. It runs in four phases that share only the source: `harnesses` (the surface registry, the Python harnesses and the browser extension's tests), `package-tests` (`swift test`), `checks` (the release build, every `LocalVoice --check-*` and `scripts/test-snap.sh`) and `stage` (StageKit's own runner). `bash scripts/test.sh checks` runs one; with no phase named it runs all four in order. The ordinary build creates the disposable ad-hoc `dist/Workbench Preview.zip`; it does not install an app.

For persistent native testing, use the [signed Preview build/install commands](README.md#build-and-install-preview). A Developer ID Application identity is needed for that workflow. Quit the running Preview before installing, and quit legacy Voice/StageMark instances when checking global shortcuts. The installer preserves the previous Preview archive and saved data; it does **not** run the speech round-trip or prepare a model until the app is opened.

`REQUIRE_APP_INTENTS=1` makes packaging fail if real action metadata cannot be extracted. A successful source compile does not establish Shortcuts discovery. See [the integration guide](docs/voice-integrations.md).

CI always checks the site, contracts and surface registry. Documentation/site-only changes can skip native work; other changes run those phases, the two galleries and packaging across five macOS jobs. The required **Build and test** check passes only when Site and every selected job pass. The [CI and merge queue workflow](docs/updating.md#ci-and-the-merge-queue) describes selection and the required gates. A maintainer may need to approve a fork's first workflow run. For a behavioural change, add or run focused checks for the actual risk. Record relevant manual evidence: microphone permission/cancellation, cross-app paste, device disconnect/reconnect, keyboard conflicts, light/dark layout or other affected behaviour. Use synthetic content in public screenshots and recordings. If something cannot be tested, say why.

Several Python checks in `scripts/` compile exact members of `AppModel.swift` and other sources beside synthetic fixtures. Each check names the members it needs, and `scripts/swift_extract.py` reads each one whole, with its comments and attributes, so moving a method never changes what a check compiles. A missing, ambiguous or repeated name fails with that name. When a check needs another member, add it to that check's list; `python3 scripts/swift_extract.py Sources/LocalVoice/AppModel.swift AppModel` lists every member's name and selector.

CI also keeps a `surface-gallery` artifact: `LocalVoice --render-surfaces DIR` draws the menu-bar panel in fixed states and the top of every Home page at the default and minimum window sizes, in light and dark, with an `index.html` listing each entry and where it leads. It uses synthetic data in a temporary home and never reads saved work, preferences or Keychain. It flags an entry whose route has no page and a page no entry opens. When you add a button or key that opens a page, add it to the catalogue in `Sources/LocalVoice/SurfaceGallery.swift`; the app menus are read from the menu bar itself. `scripts/check-surfaces.py` also fails an app menu item that opens a page under a name other than the page's own.

For native History acceptance with synthetic content, quit both editions and run the installed signed Preview through the existing gallery's isolated home and preferences:

```sh
python3 scripts/history-acceptance.py --app "$HOME/Applications/Workbench Preview.app" --output .build/history-native-acceptance
```

Use a new output folder each time. This opens the production History and reading-replacement views with a long transcript, an assistant result and an inspector for unrelated drafts. The complete app shell and its device, credential and system-setting controls are excluded. No live saved data is replaced, no provider process runs and no new app identity is created. Use Copy build details in its app menu. `history-acceptance.json` names the synthetic result file for edit/removal checks; the fixture stays after quitting. This verifies these native views and actions, not live microphone, provider, global-shortcut or receiver behavior.

For the sidebar update action, use the same isolated launcher with `--updates` and a new output directory inside the checkout. It opens only the production updater control, a synthetic active-recording switch and status text. No updater is started and no application is replaced. While the switch is on, Update must retain its offer and explain the busy state; after switching it off, one click or keyboard activation writes `update-choice.json` with one install choice. Copy build details remains available in its app menu. This verifies the native control and admission policy; a real signed old-to-new Sparkle replacement is still a separate release gate.

## Paused mobile development reference

Mobile development and distribution are paused. These commands remain for maintaining historical work; they are not an invitation to extend the mobile release.

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

If mobile work is explicitly resumed, update [the mobile contract and evidence](docs/ios-preview.md); [mobile research](docs/mobile-research.md) records the native baselines and platform constraints. Keep mobile results separate from the Mac acceptance record.

## Shared installation and updates

Ethan, Matt and all coding agents follow [one build, installation and release workflow](docs/updating.md). Local builds are labelled and never automatically replaced by public releases. Use Copy build details when reporting a bug or handing off a tested change.

## Send your change

Keep one clear purpose per PR. Follow surrounding Swift style and avoid unrelated formatting or generated build products.

```sh
git add path/to/changed-file
git commit -m "Describe the user-visible improvement"
git push -u origin improve/small-change
```

Open **Compare & pull request** for your branch on GitHub. Set the destination to **`Ship-Work/workbench` → `main`**, including when the branch is in your fork. Check the Files changed tab contains only your contribution. Explain what improves, link the issue, and describe the evidence and limitations. Use `Closes #123` only when the change fully resolves it. Draft means ready for feedback; it does not mean ready to release. Screenshots or short recordings help with UI changes.

AI-assisted work has the same ownership and testing expectations. The submitting person must understand the change and check its claims. Never include private prompts, recordings, credentials or customer assets. There is no CLA or DCO signing step. Contributions use this repository's [MIT license](LICENSE); preserve upstream notices and contribute only material you have the right to share.

## Working together

Keep one writer per worktree and one integration owner for a shared installed app. This workflow does not assign GitHub roles or grant publishing authority.

- Ethan and Matt share direction and review meaningful changes from each other.
- Either can experiment. Claim a shared issue before implementation; coordinate if the work overlaps an existing contribution.
- Keep independent features in separate PRs. Automated checks and AI review support the other person's review.
- Obtain the applicable task authority before introducing services, telemetry, broad permissions, major dependencies, migrations or publishing a release.
- AI can investigate, implement and draft. Public replies and commitments follow the submitting maintainer's explicit delegation. Writing in Ethan's style alone does not grant permission to speak or commit for him.
- Keep consequential WhatsApp decisions in the relevant issue or PR. Issues are the work queue; releases are the download and change record.

A maintainer review should establish scope, clarity, user-data preservation and relevant validation. A green build, merge, signed archive and published release are distinct states. Keep Preview internal, identify the public product as Workbench, and verify the actual production package before promotion. The signed feed, public download and website version must refer to the same artifact. Response times vary; no support SLA is promised.

Be kind and specific. Read [community expectations](CODE_OF_CONDUCT.md) and use [private security reporting](SECURITY.md) for vulnerabilities.
