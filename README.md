# Workbench

**Free everyday Mac tools for speaking, explaining and presenting.**

[![CI](https://github.com/Ship-Work/workbench/actions/workflows/ci.yml/badge.svg)](https://github.com/Ship-Work/workbench/actions/workflows/ci.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-mintcream.svg)](LICENSE)

[Download Workbench](https://workbench-mac.vercel.app/) · [Product guide](https://workbench-mac.vercel.app/guide/) · [Contribute](CONTRIBUTING.md) · [Mac release gate](https://github.com/Ship-Work/workbench/issues/7)

Workbench brings dictation, narrated screen captures, drawing, presentation and saved prompts into one native Mac app.

## Current focus: get Mac right

**Mac desktop quality is the active priority. iPhone, iPad and the Chrome extension are paused.** Their existing code and research remain available, but we are not accepting platform expansion or preparing those releases while the Mac release gate is open. Resuming a platform requires an explicit new decision.

The public app is **Workbench**. **Workbench Preview** is the separate development edition used by contributors. A Preview package is never the production download. The [release gate](https://github.com/Ship-Work/workbench/issues/7) records current acceptance; the website reads the verified release receipt for its download and version. Historical preview notes describe their dated builds, not today's release status.

## Three surfaces, one app

| Surface | Purpose |
| --- | --- |
| **Menu-bar panel** | Start utilities, make quick adjustments, configure shortcuts and recover from problems. |
| **Floating toolbar** | Carry out the current workflow without leaving the task or disrupting the demonstration. |
| **Desktop app** | Prepare scenes and personas, organise saved prompts, review captures and configure deeper settings. |

These surfaces share the same underlying jobs and saved resources. Starting or adjusting one utility must preserve independent work. The [product contract](docs/workbench.md) owns the interaction direction; older proposals are historical input.

## Get started

1. Install **Workbench** from the [website](https://workbench-mac.vercel.app/). Open it from Applications.
2. Open **Settings → Models** to prepare the default local Parakeet recognizer, then try Dictate with a disposable sentence. The first model download can take several minutes.
3. Use the menu bar for quick actions and the floating toolbar while working. Open the desktop app for preparation and review.
4. Open **Settings → Keyboard** to see, change or practise shortcuts. Recording a shortcut temporarily suspends Workbench's global shortcuts.
5. Use **Settings → Workbench updates** for updates and **Copy build details** when reporting a problem.

Closing the desktop window leaves Workbench available. Quit Workbench stops the app. Open at login is optional. Older releases without the updater need one manual upgrade; see [installation and updates](docs/updating.md).

The [product guide](https://workbench-mac.vercel.app/guide/) explains dictation, Snap & Talk, drawing, device presentation, personas and saved resources. Device presentation is video-only; Apple's QuickTime and iPhone Mirroring remain separate apps. A connected iPhone used as a Mac presentation source does not imply an active Workbench iOS release.

**Team packs (2.2+):** open **Library → Packs**, connect GitHub and add the private repository link your team shares. Choose a compatible skill or import your own scene/persona copy. New sessions carry the complete versioned skill and resources for the existing **Hand off** flow. Share the [installation guide](https://workbench-mac.vercel.app/guide/#servicenow-pack) and pack link with colleagues. Ordinary Workbench tools remain account-free; existing sessions keep their own files.

## Build and install Preview

Develop on `main` in **Ship-Work/workbench**. Branch from current `main` and return changes through a PR. Voice and StageKit are modules here; a separate legacy checkout is unnecessary.

Source development requires an Apple Silicon Mac, macOS 14+, Swift 6.2+ and the macOS 26 SDK. Full Xcode is required for distributable Shortcuts metadata. The deployment target is not evidence of testing every older OS or device.

The suite runs with Workbench open. Two StageKit checks need the exclusive default shortcuts free; while Workbench, Workbench Preview or a legacy Voice/StageMark copy holds them, those two are reported as SKIP, naming that app, and the rest still counts. Quit the app to run them here; CI runs them in full.

```sh
bash scripts/doctor.sh
bash scripts/test.sh
REQUIRE_APP_INTENTS=1 bash scripts/build.sh --preview
bash scripts/install.sh --archive "dist/Workbench Preview.zip" --no-open
```

The persistent Preview workflow requires a Developer ID Application certificate and private key. The installer preserves its identity, location, saved data and previous package. The ordinary `bash scripts/build.sh` creates a disposable ad-hoc Preview archive without installing it. Do not use that archive to replace a persistent signed installation.

Follow [the shared installation and release workflow](docs/updating.md). One integration owner controls the shared installed Preview. Source tests, installed acceptance, merged code and public delivery are separate facts. Local builds identify themselves and do not take public updates. Stable and Preview have separate identities, saved data and signed feeds; switching editions never silently copies live data or permissions.

## Data and privacy

The core Mac app needs no account or subscription. Parakeet recognition runs locally after setup. Original transcripts remain available. Optional text refinement has explicit model/provider choices; there is no automatic cloud fallback. Read text-to-speech is retired; existing Read drafts are preserved as exact text files in Library. See [model setup and limits](docs/model-providers.md).

Automatic text delivery checks the original destination, excludes secure fields and never submits it. Review any unconfirmed insertion. Screen captures and narrated sessions can contain sensitive information: inspect a session before sharing it. Workbench's handoff opens your chosen tool and copies a prompt; you still grant access and submit it.

Library holds prompts, links and local file references, not a password vault. Original media and recoverable session deletions remain in their user-chosen folders. Keep saved-data directories when replacing the app. Stable uses `~/Library/Application Support/Workbench`; Preview uses `~/Library/Application Support/Workbench Preview`. See [storage and migration boundaries](docs/design.md).

## Contribute and verify

Use [GitHub issues](https://github.com/Ship-Work/workbench/issues) as the work queue. Agree one Mac outcome and its owner before a substantial change. Prefer reliable existing workflows, accessible controls and clear recovery over additional features or parallel design specifications.

[CONTRIBUTING](CONTRIBUTING.md) has setup, code entry points and review expectations. Automated checks use synthetic input. Microphone permissions, cross-app focus, physical devices, meeting receivers and first installation on another Mac require separate evidence. Report what was actually tested and its limits.

## Credits and license

- Voice and [StageMark](https://github.com/EthDawg/StageMark) are the sources of this consolidation; [source provenance](docs/consolidation-source.md) records the import.
- [FluidAudio](https://github.com/FluidInference/FluidAudio), pinned to 0.15.6: Apache 2.0.
- [Parakeet TDT v2 CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml): see its upstream model card and license.
- [Pocket TTS](https://huggingface.co/kyutai/pocket-tts) by Kyutai, in [FluidInference's Core ML conversion](https://huggingface.co/FluidInference/pocket-tts-coreml): CC BY 4.0. Downloaded only when someone chooses Neural voices.
- Apple AppKit, SwiftUI, AVFoundation and installed macOS voices.
- Workflow inspiration: [Pat Simmons's local Wispr Flow replacement](https://www.youtube.com/watch?v=IMQw3aHjf2Q&t=437s).
- Matt ([@mattywhitenz](https://github.com/mattywhitenz)) proposed Apple Shortcuts dictation and optional Speko reading in [#10](https://github.com/Ship-Work/workbench/issues/10) and [#11](https://github.com/Ship-Work/workbench/issues/11).
- Matt's [Snap & Talk crash fix](https://github.com/Ship-Work/workbench/pull/103) ships in Workbench. His original [ServiceNow deck skill, artwork and generation helpers](https://github.com/Ship-Work/workbench/pull/104) are preserved in the private company pack, alongside their public contribution history. Existing sessions retain their chosen complete version.

The app code is [MIT licensed](LICENSE). Third-party components retain their own licenses. Contribution credit does not imply a GitHub permission level or approval of this branch.
