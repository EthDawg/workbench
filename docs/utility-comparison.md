# The next useful step in each utility

Review date: 13 September 2026. Scope: the existing Workbench categories, not new product lines. The ranking is a product judgment based on source review and documented workflows; it is not a user survey or a feature-parity claim. The September 2026 baseline below updates the comparison against macOS and AI assistants; the rest of this record is unchanged.

## September 2026 baseline

Review date: 27 September 2026. Hands-on on macOS 26.5.1 (Apple M5); macOS 27 and assistant features from official documentation.

Single actions into one assistant are now built in: Claude Code dictation (`/voice`), Claude Desktop Quick entry (screenshots, window sharing, dictation), ChatGPT and Codex Appshots (the front window's image and text), and Visual Intelligence on a selected window in macOS 27. macOS Phone call recording transcribes and summarises Phone and FaceTime calls into Notes and announces itself to every participant. Superwhisper's CLI and MCP server (July 2026) give agents search over dictation history and a notify-and-reply loop. Wispr Flow's Prompt Engineer transform turns dictation into a prompt.

Do not rebuild those. A Workbench verb must be at least as good as the Mac at the action itself, work in any app, keep what it made together with the material that produced it, and move results between the person and any assistant.

| Verb | Standing | Next step | Kind |
| --- | --- | --- | --- |
| Read | Below macOS. The Karen default is the lowest voice tier and the only Australian voice installed; Spoken Content with a free Premium voice sounds better. | Best installed voice with its quality shown, word-by-word follow-along, Markdown and agent output read naturally, and a pointer to the free Premium voice for the person's region. Neural voices became an option on 1 October 2026 at Ethan's request, downloaded once and made on this Mac; Mac voices stay the default, and whether one beats the best free Apple voice is for the ear to judge with the sample button ([model providers](model-providers.md#reading-voices)). | Quality |
| Dictate | Level. Workbench adds local recognition, original wording and safe delivery into any app. | Sharpen my prompt ([#120](https://github.com/Ship-Work/workbench/pull/120)) on a chosen engine, with a check that flags names, numbers and negations from the person's words that the result dropped; style from two or three of their own examples per situation. | Option |
| Snap | Level. Screenshot and Markup already crop, draw and sign. | Text search ([#116](https://github.com/Ship-Work/workbench/pull/116)), screenshots off the Desktop ([#121](https://github.com/Ship-Work/workbench/pull/121)), app and window context carried into Hand off. Editing stays with Markup. | Quality |
| Transcribe meeting or call | Ahead. Silent after opt-in and not limited to Phone and FaceTime. | Any call app, You and Others kept apart, then Hand off. Show when it records and remind the person once that others may need to agree. | Quality |
| Snap & Talk, Hand off | Only in Workbench. | Ship [#113](https://github.com/Ship-Work/workbench/pull/113). Results keep their inputs so they can be revised or heard. | Quality |

Engines measured for Sharpen my prompt, using four synthetic rambles of 380 to 475 words scored on points that had to survive: Claude Code and Codex CLIs kept all points with no fabrication; Gemma 3 4B kept 86% with none; Llama 3.2 3B 67%; Apple's on-device model 65% with one fabrication; Gemma 3 1B 40% with two. Local restructuring is usable only with the missing-details check; Apple's model remains the choice for tagging and faithful cleanup.

Reading timings on the same Mac: `say` rendered 65 to 308 words before any sound in 0.8 to 1.2 seconds. `AVSpeechSynthesizer.write(_:toBufferCallback:)` with the same voices produced first audio in about 0.25 seconds and reported one word range per word while rendering. Kokoro through the pinned FluidAudio 0.15.6 has one English voice, a 510-phoneme limit per call, a 112-second first-time setup, and a vendor warning of an Apple crash on macOS 26.4 to 26.5.

Agent access: a stdio MCP prototype offering History search and reading aloud worked in Claude Code 2.1.236 and Codex 0.158 with per-invocation configuration. Neither CLI's flags confined the agent to that tool, so any agent-facing entry keeps consent inside Workbench: a visible request, allowed once per session and recorded in History. It is a new integration and needs a maintainer decision before work starts.

## What was compared

| Category | Baseline / comparison | Evidence and implication |
| --- | --- | --- |
| Read aloud | Apple Read & Speak, TextEdit Speech; Speech Central | TextEdit's Start/Stop Speaking was exercised on synthetic notes. Apple's richer accessibility controller and Speech Central were read in official docs. Workbench adds reusable audio/export; seeking is a useful missing control. No narration-quality comparison was run. |
| Annotation / screenshots | Apple Screenshot/Markup; DemoPro, Presentify, ScreenBrush | Official docs and Workbench renderer/input source were reviewed. DemoPro/Presentify lean on native capture; ScreenBrush documents snapshot export/editing. Existing Workbench drawing is broad enough to prioritise getting a board image out. Commercial annotation apps were not installed or exercised in this pass. |
| Device presentation | QuickTime, iPhone Mirroring; Reflector, DeskPad | Official docs and native Workbench window/capture code were reviewed. Apple's apps had been opened in the earlier native pass. Normal window sharing is a useful composition point; no Teams/Zoom receiver, physical phone or competitor capture benchmark was completed in this increment. |
| Saved resources | Finder and Quick Look; Raycast actions, file search, Quicklinks | Finder Quick Look was exercised on a synthetic text file. Workbench now uses Apple's native Quick Look view for an explicit, non-modifying preview after resolving the saved bookmark. Raycast was researched through official docs. |

Wispr Flow and Superwhisper were already explored through their installed settings and replacement forms. That separate [dictation comparison](dictation-comparison.md) records versions and limits. Its next two ideas are now [contextual insertion #14](https://github.com/Ship-Work/workbench/issues/14) and [first successful dictation #15](https://github.com/Ship-Work/workbench/issues/15).

## Top three in each category

| Category | 1 — implemented in this increment | 2 — contributor idea | 3 — contributor idea |
| --- | --- | --- | --- |
| Read aloud | Scrub/skip existing audio; import an explicit selection through macOS Services | [Cancel local and remote generation consistently #16](https://github.com/Ship-Work/workbench/issues/16) | [Validate installed selected-text handoff #17](https://github.com/Ship-Work/workbench/issues/17) |
| Annotation / screenshots | Copy board or save its PNG | [Native Screenshot handoff with ink preserved #18](https://github.com/Ship-Work/workbench/issues/18) | [Select/move an annotation with Undo #19](https://github.com/Ship-Work/workbench/issues/19) |
| Device presentation | Present in a resizable window; leaving fullscreen keeps it active; remember the break timer's dragged or named position | [One fresh branded scene snapshot #20](https://github.com/Ship-Work/workbench/issues/20) | Validate the separate timer in a receiving meeting view |
| Saved resources | Return performs the selected copy/open action; truthful copy feedback; explicit native Quick Look | [Review shared-library import changes #23](https://github.com/Ship-Work/workbench/issues/23) | Validate exchange demand before adding another library feature |

These are priorities within each job, not a promise that every idea will ship. Personas and the break timer remain parts of presenting. Logo discovery and stock motion backgrounds remain asset-library work, outside these four targeted improvements.

## Implementation contracts

### Read aloud

The app's existing reading view owns playback. Mac voices render through `AVSpeechSynthesizer` into a growing file, far faster than real time, and playback starts once the first quarter second exists while the rest renders. Back/Forward 15 seconds and a native slider operate on the current player; neither calls a renderer, provider or network service, and while a voice is still rendering they move only within audio that exists. Seeking is bounded and preserves paused/playing state. Stop and completion clear active progress; Stop or Cancel during rendering discards the partial audio. Late callbacks from an old player or render cannot change a newer reading. Speko still renders a complete file, then plays it.

Word highlighting follows Mac voices. The synthesizer reports each word while rendering, so its displayed character range is recorded at the audio frame reached at that moment, and the playback clock then selects the current word. A render check keeps those frames within 35 ms of each word's audible onset for Samantha, Karen and Daniel. While a reading plays or is paused, the Read page shows the text read-only with the spoken word marked, without animated scrolling under Reduce Motion; editing returns on Stop. Neural voices report no word timing, so their sentence is marked instead. Speko has no timing data, so nothing is highlighted.

Only the spoken copy is prepared for listening: heading and emphasis markers are dropped, links speak their text, a bare address becomes "link to" its host, list items and table rows become sentences, fenced code is announced as "Code block skipped." and a path speaks its file name ("file Core.swift"). Numbers, names and identifiers stay literal, and plain prose is unchanged. Words read as written highlight one for one; a replaced element highlights its whole original span.

Voices are saved by identifier and listed with accent and quality, such as "Karen (Australian, compact)". A name saved by an earlier build keeps its voice, preferring the person's locale, and a missing voice is reported rather than replaced. A fresh install uses the highest-quality voice for the person's language, preferring their region. While every voice for that language is compact, one line names a free Enhanced or Premium voice and opens the Spoken Content (Read & Speak) settings pane; a small button plays a sample of the chosen voice. Pace keeps its words-per-minute meaning through a mapping measured against the earlier `say` renderings.

**Read Selection in Workbench** is a plain-text macOS Service with no return type. It reads only the request pasteboard supplied by Services and opens the selected text for review; no selection fails rather than consulting the general clipboard, screen or surrounding document. A different existing reading remains intact until Keep current or Replace reading. Importing never starts audio. Provider limits remain visible, and an online Speko request still requires a later explicit Listen or Save audio action.

### Board export

Copy board / Save board PNG exports the active Workbench whiteboard or blackboard and its ink, using the same `InkRenderer`. It includes the board background, committed text and stroke state, with bounded Retina resolution. It does not take a screenshot of apps beneath an overlay. Controls, cursor effects and the drawing palette are excluded. Rendering happens before the clipboard write. The native Save panel temporarily receives input; cancelling it restores the board and leaves drawing intact.

### Windowed presentation

The scene editor offers **Present in window** beside the existing fullscreen action. The window is titled and resizable. Its contents and device tile keep the same semantics. The Mac green window control or Control–Command–F can enter/leave fullscreen without stopping the scene. Explicit End/close still stops capture and releases the keep-awake activity; Escape closes controls first, then ends.

Select the scene window in the meeting app when that suits the session. This provides a possible sharing surface, not a guarantee about Teams/Zoom capture. Controls inside the scene may be captured. Floating personas, annotation windows and the separate timer must not be promised inside that single-window share. Verify on a receiving device before a live meeting.

The separate break-timer window remembers either a free dragged position or one of the shared eight named anchors. Reopening resolves the placement on its saved display when available and falls back within a current visible display after disconnection, resolution or scale changes. Its keyboard-accessible Position menu moves immediately without animation. Only placement and display identity are stored; the countdown and appearance keep their existing owners. Corrupt, future or concurrently changed placement files are preserved, with a usable session-only default and visible notice.

### Saved resources

Library → Import library previews New, Changed and Unchanged items. Each changed ID has an explicit Keep mine / Use incoming choice with both versions visible; the default keeps local work. Apply adds new records and saves selected updates atomically. The review reports unavailable incoming file references because exports contain metadata, not media. Identical re-imports are no-ops, and incoming browser assignments and access bookmarks are discarded. A failed write or a newer outside edit preserves the saved library and leaves the review available for retry or refresh.

Return in search or the focused results list performs the current selected item's visible primary action: copy a prompt or open a link/file. It acts only on a valid selection. It does not intercept multiline editing, a sheet, IME marked text, modified keys or held repeats. Buttons retain the same actions and labels. Copy reports a failed pasteboard write honestly; retry can recover. No automatic paste, focus switching, clipboard watching or additional indexer is added.

Quick Look is a separate explicit action for an available, non-executable local file. Workbench resolves and, when needed, refreshes the saved bookmark, then displays the original through a native `QLPreviewView`; it does not copy or modify the file. Supported images, PDFs, text and movies share the same panel. The app holds security-scoped access until the panel closes and releases it on close, removal or navigation. Missing files keep the existing Locate file recovery. Unknown or unsupported types report that no preview is available instead of claiming success. Escape closes only the preview panel and leaves library selection and search intact. Movies do not autoplay.

## Checks and evidence

The import fixture runs the actual store, comparison and model against synthetic files: 37 checks cover classification, exact notes/IDs, defaults, cancellation, write failure/retry, stale reviews, byte-for-byte no-ops, malformed/future/oversized input, local attachment retention, original-file preservation and bounded reads that reach EOF even when a file provider returns short chunks. Its screenshot renders the production review sheet; it is not a live multi-Mac or VoiceOver acceptance result.

Focused tests execute actual production playback methods with the real player rendering offline and a scripted Mac voice renderer (streaming start, seeking within rendered audio, word highlighting, reuse, cancellation, stale and failed renders), synthetic voice catalogues, listening-preparation cases and a real synthesizer render timed against its own audio, the selected-text provider selector/review policy with exact, empty and long synthetic input, and the actual saved-library model/view with injected effects. Nine isolated checks also exercise the actual selection-to-draft methods, including Keep current, explicit replacement, active generation and unchanged provider/voice settings. The packaged Services declaration and Preview-specific identity are inspected separately; installer tests cover upgrading and rolling back a previous bundle that predates Services. Stage tests cover board pixel orientation/background/opacity/export and fullscreen lifecycle transitions.

Native playback QA used the exact production strip/buttons and methods in a temporary in-memory app with a bundled 45-second silent WAV. Pause, accessible slider increment, ±15 skip, Resume and Stop were exercised; audio loads stayed at one. This verifies controls and audio reuse, not audible voice quality or provider generation.

Native library QA used the actual view/model with synthetic resources and simulated copy/open effects. Search Return and list Return each produced one selected action; failed copy reported failure, retry recovered, no-match Return did nothing, and Return inside a multiline editor inserted a line without invoking the resource. Cancel preserved the original. Focused Quick Look checks cover image/PDF/text/movie eligibility, unknown and missing inputs, moved bookmark refresh, failed presentation, retry and exact access release while preserving search and selection. A native panel smoke test opened real text, PNG, PDF and MP4 fixtures, verified their bytes were unchanged and invoked Escape on each panel while its owner stayed visible. The `APP_STORE` bookmark path compiles separately; a signed sandbox runtime, multilingual IME and VoiceOver session remain unverified.

Break-timer checks use synthetic display frames for free/named placement, screen removal, resolution changes, restart, future/corrupt files and concurrent-write preservation. A native AppKit panel check exercises the actual timer window, Position action, saved file, hide and reopen lifecycle. Physical multi-display removal, a VoiceOver session and receiving meeting views remain unverified.

The selected-text Service still requires an installed-package pass from TextEdit and a supported browser, plus VoiceOver review; these are not inferred from selector or metadata checks.

The release record adds final build/regression and native board/window evidence. Keep hardware and meeting receiver acceptance separate from fixtures. No private draft, library, microphone sample or competitor transcript was replaced or published.

## Official sources

- [Apple Read & Speak](https://support.apple.com/en-au/guide/mac-help/mh27448/mac) — selected-text reading and controller.
- [Speech Central Mac help](https://speechcentral.net/speech-central-macos-help/) — a broader document-reading comparison.
- [Apple Screenshot](https://support.apple.com/en-la/102646), [Presentify FAQ](https://presentifyapp.com/faq), [DemoPro FAQ](https://www.demoproapp.com/faq.html) — native capture alongside annotation.
- [ScreenBrush official listing](https://apps.apple.com/ca/app/screenbrush/id1233965871?mt=12) — snapshot/export and editing.
- [QuickTime connected-device recording](https://support.apple.com/en-au/guide/quicktime-player/qtp356b55534/mac), [iPhone Mirroring](https://support.apple.com/en-au/120421) — distinct Apple device workflows.
- [Reflector screenshots/recording](https://www.airsquirrels.com/reflector/features/recording), [DeskPad](https://github.com/Stengo/DeskPad) — adjacent presentation approaches, not promised Workbench capabilities.
- [Raycast actions](https://manual.raycast.com/action-panel), [file search](https://manual.raycast.com/file-search), [Quicklinks](https://manual.raycast.com/quicklinks) — contextual primary action, preview and reusable references.
- [Apple QLPreviewView](https://developer.apple.com/documentation/quicklookui/qlpreviewview) — the native embedded Quick Look surface and its window-lifetime closure contract.

Native board/window QA saved a real PNG after Save → Cancel → retry, then checked its top/bottom text, arrow and highlighter. Window → fullscreen → window kept the scene and control tile alive; the controls still opened afterward. These used a synthetic saved scene without a camera. A standard opaque native titlebar was then retained for readable window titles against arbitrary scenes.
