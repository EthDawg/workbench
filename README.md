# Workbench

**Free everyday Mac tools for speaking, explaining and presenting.**

[![CI](https://github.com/EthDawg/workbench/actions/workflows/ci.yml/badge.svg)](https://github.com/EthDawg/workbench/actions/workflows/ci.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-mintcream.svg)](LICENSE)

[Product guide](https://workbench-mac.vercel.app/guide/) · [Contribute](CONTRIBUTING.md) · [Issues](https://github.com/EthDawg/workbench/issues) · [Project website](https://workbench-mac.vercel.app)

Workbench brings Voice and StageMark into **one native app, one home window and one menu-bar icon**. Dictate a thought, capture and narrate a screen, read a draft, draw over a live demo, or give a connected phone a presentation scene. The aim is a useful baseline that improves with better models and small, dependable workflows.

**Workbench is the active project, developed on `main` in this repository.** Feature descriptions below describe its implementation, not proof of a published release or successful testing on every supported Mac. The [acceptance record](docs/unification.md) tracks the remaining verification. Older Voice/StageMark releases and their validation records describe those separate apps; StageMark is retained as an archive.

**Contributors:** branch from `main` and send PRs back to `main`. The [contributor setup and Matt's screenshot/annotation handoff](CONTRIBUTING.md#start-from-the-current-workbench-code) include exact clone commands and code entry points. Issues, reviews and releases all live in this repository.

An **iPhone and iPad Preview for iOS/iPadOS 26+** is also in development as a separate native SwiftUI target. It offers foreground dictation, installed-voice reading, PencilKit image markup, independent wallpaper crop/export and editable scenes prepared for Mac. The Mac capabilities below retain their own platform boundaries. See the [mobile scope, build instructions and test record](docs/ios-preview.md) and [mobile research](docs/mobile-research.md); no mobile App Store or TestFlight release is claimed.

**Mac download:** [Workbench Preview 3](https://github.com/EthDawg/workbench/releases/tag/v2.0.0-preview.3) is Developer ID signed, Apple-notarized and stapled. The exact downloaded ZIP was hash-verified. Its notes distinguish verified packaging from remaining physical-device acceptance. The iOS build is uploaded to App Store Connect, with tester distribution and review still pending.

## What is in the app?

| Capability | What it does |
| --- | --- |
| **Dictate** | Record speech or import audio; keep original and cleaned text, a dictionary and recent transcripts; copy or optionally paste into the original field. |
| **Read aloud** | Send an explicit selection from another Mac app into a reviewable draft, listen with installed Mac voices and export M4A. Speko is an explicit online option using your own key, with automatic routing or a chosen compatible voice. |
| **Snap & Talk** | Capture the display under the pointer, record linked narration, and keep an ordered portable session for slide generation. |
| **Annotate** | Draw, highlight, add shapes/text, emphasise the pointer and use saved boards over a live presentation. |
| **Present a device** | Prepare a scene with a background, logo and persona, display a supported USB video source, and use a break timer that remembers where you placed it. QuickTime and iPhone Mirroring can be opened separately. |
| **Saved resources** | Keep searchable prompts, web links and references to local files; preview files in Quick Look and review new or changed items before importing a shared library. |
| **Switch to** | In this development build, return to a named demo tab in its paired Chrome profile from any app. [Setup and evidence](docs/presenter-direction.md). |
| **Keyboard** | See all Workbench assignments, change or disable them, and practise on a virtual keyboard without activating tools. |

The core app requires no account or subscription. Built-in Parakeet recognition and Mac reading work locally after their initial setup. Optional integrations have their own setup and privacy boundaries.

## Current integration candidate

The [September contribution Preview checklist](docs/releases/2026-09-20-integration-preview.md) explains what changed and what to test. This source includes pending release work; it does not change the public Preview 3 download.

## First use

1. Open **Workbench Preview** and choose an action from Home. **Models** prepares the default Parakeet recognizer; its first download can take several minutes.
2. Try **Dictate** with a short, disposable sentence. Microphone access is requested when recording needs it. Copy works without Accessibility; automatic paste is an optional setting.
3. To hear text from TextEdit or a supported browser, select it and choose **Services → Read Selection in Workbench**. Review the imported text in Read aloud, then choose Listen; a different existing reading is never replaced without your choice.
4. Open **Keyboard** to see or practise a shortcut. The defaults include **Control–Option–Space** for dictation, **Control–Option–Backslash** for Snap & Talk, **Control–Option–V** for quick controls, **Control–Option–J** for saved resources and **Control–Option–G** for Switch to in this development build.
5. For a mobile demo, choose **Present a device**, prepare a scene and select an available source. Workbench's device view is video-only. iPhone Mirroring runs in Apple's own window; Workbench does not embed or control it.

The menu-bar icon provides quick access while another app is active. The normal window is for editing and setup. Closing it leaves the utility available; **Quit Workbench** stops the app. **Open Workbench at login** is optional in Settings.

During dictation, a draggable compact panel keeps the microphone level, elapsed time and **Stop** visible. Expand it for details, cancellation and named positions. Drag toward a corner or edge centre to snap. Changing size or position keeps the same recording and destination. Processing can be cancelled before the transcript is saved. The result shows **Ready to paste**, a confirmed destination, or **Paste unconfirmed**; review uncertain insertion before pasting again. Pin the receipt if useful. A clipboard cue remains in quick controls until that copied text is replaced. Only Workbench transcript copies are tracked, using clipboard change counts; other clipboard contents are not collected.

In **Snap & Talk**, create or reopen an ordinary Finder folder and grant Screen Recording and Microphone access. Move the pointer to the intended display and press **Control–Option–Backslash**: Workbench captures that whole display with the pointer, then starts narration. Press it again to save the original WAV and queue transcription. More captures can begin while earlier narration transcribes. The visual editor supports transcript editing, independent screenshot/narration replacement, drag reordering and recoverable deletion. Each folder includes `session.json`, `README.md` and a `SKILL.md` that asks a compatible agent to create a 16:9 PowerPoint with an uncropped screenshot, concise narration-grounded slide copy and the full edited narration in speaker notes. **Hand off…** copies a ready prompt, reveals the folder and opens Claude, ChatGPT or Codex when installed; you still grant folder access and paste, so Workbench does not upload the session. Screen capture can contain sensitive information; inspect the folder before sharing it.

During a phone presentation, a small phone-icon tile starts at the right edge centre. Click it or press **⌘/** for source, reconnect, position and end controls. **Esc** closes open controls first; a further **Esc** ends the presentation. Hovering is not required. Type and use Dictation on the physical phone: the Mac preview is video-only. These controls appear in whole-display sharing; verify individual-window capture with your meeting app.

In **Annotate**, **Open Screenshot…** hands off to Apple Screenshot without reading the display itself. Workbench commits the current stroke, hides its palette and pointer, makes the canvas click-through, and pauses auto-fade until Apple Screenshot closes. Use a region or entire-display capture to include visible ink. A single-window capture may omit Workbench's separate annotation layer. **Copy board** and **Save board PNG…** remain the controls-only-free export for an open whiteboard or blackboard.

Import a finished transparent image in **Personas** to show a movable, resizable card over a browser. Lock it to pass clicks through. Add the same persona to a saved mobile scene. A separate native overlay is not included in browser-tab sharing. See the [interaction specification](docs/product-spec.md) and [persona guide](docs/personas.md).

Keyboard recording and practice temporarily suspend Workbench's global shortcuts. Practice counts three full presses and releases; Escape, leaving the window or changing the selected action ends the interaction. Workbench checks its own duplicates, common Mac commands and registration failures; macOS does not expose a complete list of other apps' shortcuts. The virtual keyboard uses ANSI geometry with labels from the current input layout.

## Choose your speech tools

| Choice | Included / setup | Boundary |
| --- | --- | --- |
| **Parakeet on this Mac** | Default English recognizer, using FluidAudio and a downloaded Core ML model | On-device inference; no server or API key. |
| **Local model server** | You run a compatible server and supply its full transcription URL and model ID | Loopback addresses only. Workbench does not install the server or bundle a Whisper model. The server may itself forward audio; inspect its configuration. |
| **Mac voices** | Installed macOS reading voices, with pace control | Local text-to-speech and audio export. |
| **Speko TTS** | Optional personal account and Keychain-stored API key | Browse compatible English voices, keep balanced automatic routing or pin a voice; explicit readings send text online and may be billed. Speko STT is not a Workbench recognition choice yet. |

Model settings apply to the next request; the active request keeps its original provider. There is no automatic cloud fallback. A valid local-server configuration is not a successful connectivity or model test—the first real transcription checks those. See [model setup and limits](docs/model-providers.md).

**Text refinement** is a separate model job. Original and Light use no text model. Natural uses available Apple Intelligence or an explicitly configured local Ollama model, with conservative fallback when a response fails preservation checks. Models provides installed-model checks, explicit download, load and save controls. Ollama must already run on your Mac; Workbench refuses cloud-model metadata but cannot audit your server. Cleanup, dictionary and delivery settings are captured at the start of each operation. The original transcript remains available.

**Apple Shortcuts** can compose `Record Audio → Transcribe with Workbench → a text action`. Apple owns recording; Workbench's App Intent transcribes the supplied audio and returns text. Native discovery requires packaging with full Xcode metadata. **macOS Services** supplies only the text explicitly selected in another app to **Read Selection in Workbench**; it opens a review draft and never starts audio, reads the general clipboard or submits text. See [integration setup and validation boundaries](docs/voice-integrations.md). Share extensions and Spotlight actions beyond normal app discovery remain future options.

## Build and install Preview

These commands build the **Mac Preview**. Source development requires an Apple Silicon Mac, macOS 14+, Swift 6.2+ and the macOS 26 SDK. Run `bash scripts/doctor.sh` to check prerequisites. Full Xcode is required for distributable Apple Shortcuts metadata. The macOS 14 deployment target is not evidence of testing on every older OS or device. For the separate mobile target, generate `Mobile/Workbench.xcodeproj` with `python3 scripts/mobile-project.py` and follow the [Xcode and Simulator instructions](docs/ios-preview.md#build-and-test).

Quit Workbench, Workbench Preview and legacy Voice/StageMark apps before running the test suite. Its exclusive shortcut-registration checks will conflict with a running copy, including in CI test mode.

From the unified source checkout:

```sh
bash scripts/doctor.sh
bash scripts/test.sh
REQUIRE_APP_INTENTS=1 bash scripts/build.sh --preview
bash scripts/install.sh --archive "dist/Workbench Preview.zip" --no-open
```

The Preview build needs a **Developer ID Application certificate and its private key** in Keychain. If more than one exists, select its fingerprint with `--identity`. It creates `dist/Workbench Preview.zip`; the installer places `Workbench Preview.app` in `~/Applications`. Open it when ready. The install preserves the previous Preview as `dist/Previous-Workbench Preview.zip` for rollback. Quit the running Preview before updating.

Without a signing identity, `bash scripts/build.sh --preview --ad-hoc` creates a disposable development archive. The default installer requires Developer ID signing; ad-hoc packages are for disposable development testing. `bash scripts/build.sh` also produces a disposable Preview archive. Neither command alone establishes notarization or publication.

The installer does **not** run the regression suite or speech round-trip. First-open model preparation and optional live checks are separate:

```sh
"$HOME/Applications/Workbench Preview.app/Contents/MacOS/WorkbenchPreview" --self-test
"$HOME/Applications/Workbench Preview.app/Contents/MacOS/WorkbenchPreview" --transcribe /path/to/audio.m4a
```

The Swift target/module retains its internal `LocalVoice` name for compatibility. Packaged executables are `Workbench` and `WorkbenchPreview`. The self-test synthesizes known text, transcribes it with the selected recognizer, exports audio and transcribes the export; it does not prove live microphone capture, paste or device presentation.

Keep a consistent Preview identity and path between updates. Preview has its own macOS permissions. Quit older Voice/StageMark copies when testing global shortcuts; they may compete for the same combinations. Do not clear permissions or erase saved data as an update step. [Release tooling](scripts/release/README.md) describes the separate production workflow.

## Cross-device preparation

### Photo for Mac · Preview

Take or choose a photo on iPhone, keep the original locally and deliberately send an optimised copy through private iCloud. Mac Saved resources → From iPhone opens an existing scene’s backdrop preview or saves an independent copy. The [photo handoff guide](https://workbench-mac.vercel.app/handoff/) and [canonical specification](docs/photo-handoff.md) record the research, limits and signing route. A real existing iPhone photo has now downloaded on Mac after a retry. Repeated deferred delivery remains an acceptance task; this feature is not in the public Preview 2 download.

### Personal scenes — Preview

Prepare an editable scene on iPhone or iPad and present it on Mac. New scenes keep their original pictures, device placement and optional logo/persona. Personal iCloud sync is opt-in and tied to the same Apple Account; an editable `.workbenchscene` copy also works without cloud. Existing mobile compositions remain recoverable. The Mac has eight starter portraits, editable role/colour cards and floating controls limited to a prepared persona group.

The [visual scene guide](https://workbench-mac.vercel.app/scenes/) includes generated design studies and actual native screenshots. The [scene contract](docs/research/personal-scenes.md) owns persistence, migration, conflict rules and current evidence. Mac upload has succeeded; a complete paired scene round trip remains unverified. The notarized Mac Preview 3 includes this implementation. iOS upload, tester distribution and App Review are separate stages; see the [mobile release record](docs/ios-preview.md#release-preparation--14-september-2026).

The newer local Preview adds **Window light, Campus breeze and Coastal sky**: three original starter pictures with optional, localized cloud or foliage motion. [The ambient scene guide](https://workbench-mac.vercel.app/scenes/ambient/) shows the artwork, native captures and Apple platform boundaries; [the implementation record](docs/research/ambient-scenes.md) owns the research and remaining acceptance checks. Motion runs inside Workbench on iPhone/iPad and in app-owned presentation or desktop layers on Mac. Export stays still. These starters are not in the public Preview 3 download; editable exchange requires updated apps that support scene format v2.

## Data, privacy and recovery

- **Transcripts:** originals, drafts, dictionary, reading preferences and the last 100 captures are stored locally. Cleanup is optional: Original, deterministic Light, or guarded Natural editing using available Apple Intelligence or a configured local Ollama model. Saved dictionary replacements apply to delivered text in every cleanup mode; the recogniser's original remains available. Cleanup checks cannot prove meaning is unchanged.
- **Capture and delivery:** microphone capture is explicitly started and limited to five minutes; imported audio to 30 minutes. Automatic paste checks the original app/field, excludes secure fields and never presses Return. If delivery cannot be confirmed, the transcript stays on the clipboard. Imported originals are not modified.
- **Snap & Talk sessions:** each user-chosen folder keeps screenshots, original narration audio, original/edited transcripts and recoverable deleted sections. Workbench captures only the display under the pointer, includes the pointer and requires macOS Screen Recording access. The bundled slide skill keeps generation local unless the user explicitly chooses an external service.
- **Resources:** the library stores prompts, links, notes and local file references, not copies of media or a password vault. Its JSON import preserves existing entries and skips matching IDs. Exported paths may need reconnecting on another Mac. Unreadable data is preserved rather than overwritten.
- **Models and services:** setup downloads Parakeet from FluidInference's Hugging Face hosting. Recognition uses the selected local engine or user-managed loopback server. Speko sends only explicitly submitted readings online. Downstream Shortcuts actions may sync their results elsewhere.
- **Presentation:** the device preview does not record video or microphone audio. Share its presentation window through your meeting app. QuickTime and iPhone Mirroring have their own requirements, permissions and lifecycle.

Unified Preview stores voice files under `~/Library/Application Support/Workbench Preview/LocalVoice` and presentation files under `~/Library/Application Support/Workbench Preview/StageMark`. The non-Preview equivalents are under `Workbench`. First use copies supported legacy data into a missing component directory; it does not move or delete the old app's data. Once a unified component exists, it is not repeatedly merged with later legacy changes. [Architecture and migration details](docs/design.md) explain the boundaries.

Mac reading is limited to 50,000 characters per reading; Speko to 5,000. The local-server option adds a 64 MB input cap and supports WAV, M4A, MP3 and FLAC subject to that server's decoder. English recognition quality, permissions, hardware support and network-provider behaviour need real workflow testing.

## Contribute and verify

A useful first contribution can be a confusing instruction, an accessibility improvement, a synthetic test case or a hardware report. Use [Issues](https://github.com/EthDawg/workbench/issues) as the work queue and discuss substantial changes before implementing them. [CONTRIBUTING](CONTRIBUTING.md) explains the workflow and proposed two-maintainer practices.

`bash scripts/test.sh` runs release-tool checks, core/cleanup/history/library/integration/keyboard checks, provider checks and StageKit regressions. Checks use synthetic input; model downloads, real microphone input, other apps' focus, signed-package permissions and actual device sharing require additional evidence. See [the current acceptance record](docs/unification.md), [product contract](docs/workbench.md) and [implementation map](docs/design.md).

## Credits and license

- Voice and [StageMark](https://github.com/EthDawg/StageMark) are the sources of this consolidation; [source provenance](docs/consolidation-source.md) records the import.
- [FluidAudio](https://github.com/FluidInference/FluidAudio), pinned to 0.15.6: Apache 2.0.
- [Parakeet TDT v2 CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml): see its upstream model card and license.
- Apple AppKit, SwiftUI, AVFoundation and installed macOS voices.
- Workflow inspiration: [Pat Simmons's local Wispr Flow replacement](https://www.youtube.com/watch?v=IMQw3aHjf2Q&t=437s).
- Matt ([@mattywhitenz](https://github.com/mattywhitenz)) proposed Apple Shortcuts dictation and optional Speko reading in [#10](https://github.com/EthDawg/workbench/issues/10) and [#11](https://github.com/EthDawg/workbench/issues/11).

The app code is [MIT licensed](LICENSE). Third-party components retain their own licenses. Contribution credit does not imply a GitHub permission level or approval of this branch.

## Staying current

Published updater-enabled Mac releases check their own edition for signed updates. Use Settings → Workbench updates, and Copy build details for feedback. Older downloads need one manual upgrade. See [installation and updates](docs/updating.md) for the shared user and contributor workflow.
