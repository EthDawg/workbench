# The next useful step in each utility

Review date: 13 September 2026. Scope: the existing Workbench categories, not new product lines. The ranking is a product judgment based on source review and documented workflows; it is not a user survey or a feature-parity claim.

## What was compared

| Category | Baseline / comparison | Evidence and implication |
| --- | --- | --- |
| Read aloud | Apple Read & Speak, TextEdit Speech; Speech Central | TextEdit's Start/Stop Speaking was exercised on synthetic notes. Apple's richer accessibility controller and Speech Central were read in official docs. Workbench adds reusable audio/export; seeking is a useful missing control. No narration-quality comparison was run. |
| Annotation / screenshots | Apple Screenshot/Markup; DemoPro, Presentify, ScreenBrush | Official docs and Workbench renderer/input source were reviewed. DemoPro/Presentify lean on native capture; ScreenBrush documents snapshot export/editing. Existing Workbench drawing is broad enough to prioritise getting a board image out. Commercial annotation apps were not installed or exercised in this pass. |
| Device presentation | QuickTime, iPhone Mirroring; Reflector, DeskPad | Official docs and native Workbench window/capture code were reviewed. Apple's apps had been opened in the earlier native pass. Normal window sharing is a useful composition point; no Teams/Zoom receiver, physical phone or competitor capture benchmark was completed in this increment. |
| Saved resources | Finder Quick Look; Raycast actions, file search, Quicklinks | Finder Quick Look was exercised on a synthetic text file. Raycast was researched through official docs. Source review found the more immediate gap: search selection lacked a Return action, and clipboard failure could report success. |

Wispr Flow and Superwhisper were already explored through their installed settings and replacement forms. That separate [dictation comparison](dictation-comparison.md) records versions and limits. Its next two ideas are now [contextual insertion #14](https://github.com/EthDawg/workbench/issues/14) and [first successful dictation #15](https://github.com/EthDawg/workbench/issues/15).

## Top three in each category

| Category | 1 — implemented in this increment | 2 — contributor idea | 3 — contributor idea |
| --- | --- | --- | --- |
| Read aloud | Scrub and skip ±15 seconds in existing audio | [Cancel local and remote generation consistently #16](https://github.com/EthDawg/workbench/issues/16) | [Read selected text through a Mac Service #17](https://github.com/EthDawg/workbench/issues/17) |
| Annotation / screenshots | Copy board or save its PNG | [Native Screenshot handoff with ink preserved #18](https://github.com/EthDawg/workbench/issues/18) | [Select/move an annotation with Undo #19](https://github.com/EthDawg/workbench/issues/19) |
| Device presentation | Present in a resizable window; leaving fullscreen keeps it active; remember the break timer's dragged or named position | [One fresh branded scene snapshot #20](https://github.com/EthDawg/workbench/issues/20) | Validate the separate timer in a receiving meeting view |
| Saved resources | Return performs the selected copy/open action; truthful copy feedback | [Explicit native Quick Look #22](https://github.com/EthDawg/workbench/issues/22) | [Review shared-library import changes #23](https://github.com/EthDawg/workbench/issues/23) |

These are priorities within each job, not a promise that every idea will ship. Personas and the break timer remain parts of presenting. Logo discovery and stock motion backgrounds remain asset-library work, outside these four targeted improvements.

## Implementation contracts

### Read aloud

The app's existing reading view owns playback. Back/Forward 15 seconds and a native slider operate on the current `AVAudioPlayer`; neither calls a renderer, provider or network service. Seeking is bounded and preserves paused/playing state. Stop and completion clear active progress. Late callbacks from an old player cannot change a newer reading. Word highlighting is excluded because this pipeline has no word timing data.

### Board export

Copy board / Save board PNG exports the active Workbench whiteboard or blackboard and its ink, using the same `InkRenderer`. It includes the board background, committed text and stroke state, with bounded Retina resolution. It does not take a screenshot of apps beneath an overlay. Controls, cursor effects and the drawing palette are excluded. Rendering happens before the clipboard write. The native Save panel temporarily receives input; cancelling it restores the board and leaves drawing intact.

### Windowed presentation

The scene editor offers **Present in window** beside the existing fullscreen action. The window is titled and resizable. Its contents and device tile keep the same semantics. The Mac green window control or Control–Command–F can enter/leave fullscreen without stopping the scene. Explicit End/close still stops capture and releases the keep-awake activity; Escape closes controls first, then ends.

Select the scene window in the meeting app when that suits the session. This provides a possible sharing surface, not a guarantee about Teams/Zoom capture. Controls inside the scene may be captured. Floating personas, annotation windows and the separate timer must not be promised inside that single-window share. Verify on a receiving device before a live meeting.

The separate break-timer window remembers either a free dragged position or one of the shared eight named anchors. Reopening resolves the placement on its saved display when available and falls back within a current visible display after disconnection, resolution or scale changes. Its keyboard-accessible Position menu moves immediately without animation. Only placement and display identity are stored; the countdown and appearance keep their existing owners. Corrupt, future or concurrently changed placement files are preserved, with a usable session-only default and visible notice.

### Saved resources

Return in search or the focused results list performs the current selected item's visible primary action: copy a prompt or open a link/file. It acts only on a valid selection. It does not intercept multiline editing, a sheet, IME marked text, modified keys or held repeats. Buttons retain the same actions and labels. Copy reports a failed pasteboard write honestly; retry can recover. No automatic paste, focus switching, clipboard watching or additional indexer is added.

## Checks and evidence

Focused tests execute actual production playback methods with a synthetic audio player plus real `AVAudioPlayer` seek checks, and the actual saved-library model/view with injected effects. Stage tests cover board pixel orientation/background/opacity/export and fullscreen lifecycle transitions.

Native playback QA used the exact production strip/buttons and methods in a temporary in-memory app with a bundled 45-second silent WAV. Pause, accessible slider increment, ±15 skip, Resume and Stop were exercised; audio loads stayed at one. This verifies controls and audio reuse, not audible voice quality or provider generation.

Native library QA used the actual view/model with synthetic resources and simulated copy/open effects. Search Return and list Return each produced one selected action; failed copy reported failure, retry recovered, no-match Return did nothing, and Return inside a multiline editor inserted a line without invoking the resource. Cancel preserved the original. Break-timer checks use synthetic display frames for free/named placement, screen removal, resolution changes, restart, future/corrupt files and concurrent-write preservation. A native AppKit panel check exercises the actual timer window, Position action, saved file, hide and reopen lifecycle. Physical multi-display removal, a VoiceOver session and receiving meeting views remain unverified.

The release record adds final build/regression and native board/window evidence. Keep hardware and meeting receiver acceptance separate from fixtures. No private draft, library, microphone sample or competitor transcript was replaced or published.

## Official sources

- [Apple Read & Speak](https://support.apple.com/en-au/guide/mac-help/mh27448/mac) — selected-text reading and controller.
- [Speech Central Mac help](https://speechcentral.net/speech-central-macos-help/) — a broader document-reading comparison.
- [Apple Screenshot](https://support.apple.com/en-la/102646), [Presentify FAQ](https://presentifyapp.com/faq), [DemoPro FAQ](https://www.demoproapp.com/faq.html) — native capture alongside annotation.
- [ScreenBrush official listing](https://apps.apple.com/ca/app/screenbrush/id1233965871?mt=12) — snapshot/export and editing.
- [QuickTime connected-device recording](https://support.apple.com/en-au/guide/quicktime-player/qtp356b55534/mac), [iPhone Mirroring](https://support.apple.com/en-au/120421) — distinct Apple device workflows.
- [Reflector screenshots/recording](https://www.airsquirrels.com/reflector/features/recording), [DeskPad](https://github.com/Stengo/DeskPad) — adjacent presentation approaches, not promised Workbench capabilities.
- [Raycast actions](https://manual.raycast.com/action-panel), [file search](https://manual.raycast.com/file-search), [Quicklinks](https://manual.raycast.com/quicklinks) — contextual primary action, preview and reusable references.

Native board/window QA saved a real PNG after Save → Cancel → retry, then checked its top/bottom text, arrow and highlighter. Window → fullscreen → window kept the scene and control tile alive; the controls still opened afterward. These used a synthetic saved scene without a camera. A standard opaque native titlebar was then retained for readable window titles against arbitrary scenes.
