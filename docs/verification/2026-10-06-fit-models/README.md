# Models follow-ups, 6 October 2026 (#134, #130)

Renders from `.build/release/LocalVoice --render-surfaces` with `WORKBENCH_DESKTOP_GALLERY_ONLY=1`, built from branch `claude/fit-models` on top of `main` 5f209cab85fad6fef5c8337ff2a076bdeffbcd35. The desktop pass ran under the worktree's ignored `.build` folder: a /tmp output trips its symlink check (pre-existing, unrelated). The full pass also ran from the scratch folder: `SURFACE_GALLERY_OK: 302 renders, 162 entries, 0 flags`; the desktop pass: `SURFACE_GALLERY_OK: 168 renders, 162 entries, 0 flags`.

Everything shown is synthetic. No Ollama ran: the download is `CleanupModelManager.presentDownload("gemma3:1b", fraction: 0.42)`, a presentation that no request backs, and the saved refinement choice is written only to the pass's isolated preferences. The Snap & Talk session is the gallery's 39-section walkthrough with section 1 saved without audio; the not-ready state sets the gallery model's `ready = false`, `modelFailure = "Check your connection and try again."` and the readiness line `The speech model couldn’t be prepared`.

| File | What it shows |
| --- | --- |
| `page-models-state-writing-model-download-{light,dark}.png` | Settings › Models while the app downloads a writing model: progress bar, explicit Cancel, the one line `Downloading gemma3:1b · 42%`, every other control waiting. |
| `page-dictate-state-writing-model-download-{light,dark}.png` | Dictate's engine line with the same download line under it, beside Models…. |
| `page-home-state-writing-model-download-{light,dark}.png` | Home's readiness banner with the same line under the speech model's. |
| `page-readback-session-narration-narrow-{light,dark}.png` | Snap & Talk, a section without narration: `Parakeet v2 · English · on this Mac` and Models… beside Record narration. |
| `page-readback-session-narration-not-ready-narrow-{light,dark}.png` | The same section when the speech model could not be prepared: the reason, Retry model and Models…, and the note that transcription waits. |

Counts on the release binary: `--check-refinement` 50 + 23 + 15 (new ownership checks), `--check-readback` 76 (3 new) + 11 + 41 + 19 + 18 + 32 + 44, `--check-providers` 63 + transport, `--check-core` all suites OK.

Not verified here: a real Ollama pull surviving a page change, Cancel and quit against a running Ollama; the failure line on Home and Dictate after a real refusal (only the fixture's 503 is checked); the Natural text style's first use after a completed download; Retry model and Models… clicked from Snap & Talk in the installed app; VoiceOver reading of the new lines. Those are installed-app checks owed to the lead.
