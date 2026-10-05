# Live voice integration

Status: backend implemented and checked; shared UI integration and installed acceptance pending.

## Ownership

The backend work on `codex/live-voice-engine` owns capture, route recovery, recognition, persistence and the state published to views. The voice experience work owns Meetings, Dictate and their compact controls. Keep one writer per worktree. The backend integration owner installs the shared signed Preview after both branches are integrated.

`Sources/LocalVoice/LiveVoiceSession.swift` defines the shared presentation contract. `MeetingModel.voiceSession` and `AppModel.voiceSession` publish `LiveVoiceSnapshot`. This is a projection of the existing owners, not a second state store. Views may display provisional segments differently but must not change or finalize them.

| Field | Meaning |
| --- | --- |
| `sessionID` | Stable identity for this capture; changes only for a new session |
| `phase` | `idle`, `preparing`, `listening`, `paused`, `reconnecting`, `finishing`, `completed`, `recoverableFailure` |
| `elapsed` | Session timeline in seconds; device changes do not reset it |
| `sources` | Source, readable name, health, level and optional explanation, independently for microphone and app |
| `segments` | Timed source-labelled words, stable IDs, with `isFinal` distinguishing confirmed words from a revisable tail |
| `recognitionDelayed` | Audio capture can continue while recognition catches up |
| `message` | An actionable session-level explanation when needed |

Meetings keeps its existing `start()`, `stop()`, `cancel()` (keep for later), recovery and recording-review owners. `pause()` and `resume()` affect the same session. `startOffered(_:)` validates the displayed offer before starting its exact source. A stale offer cannot select or start a different app. Dictate retains its existing shortcuts and final delivery; live text is a preview and never writes progressively into another app.

The session remains open across a device change. Unavailable audio is represented on its real timeline and reported; audio is never compressed across a missing interval. Pause creates no speech. Stop flushes the remaining speech before saving. Capture and confirmed words remain recoverable if recognition fails.

One-click offers are available only for sources the metadata detector can identify. Browser capture can include its other tabs. The app name is not a meeting title or participant identity. Microphone-only recording remains an explicit choice. Detection stays off until enabled and never starts recording itself.

## Recognition and recovery

Parakeet v2 remains the model. The adapter requests a provisional update after roughly two seconds of new audio and commits eight-second ranges with two seconds of context on each side. These are scheduling parameters, not a measured latency promise. Each request uses fresh decoder state. It retains individual word times and reconciles the last committed word across windows, allowing timing jitter. An ambiguous boundary invalidates live completion and uses original-audio recovery. The view groups timed words into actual source turns; independent identical replies are preserved. Short endings are padded to the model's minimum input rather than discarded. Original capture runs independently of inference.

The selected model is reserved until capture and its last live request finish. The loopback server remains a file-transcription option and does not silently switch to Parakeet. A live processing backlog, missing word timings, callback overflow or failed checkpoint write leaves completion false and retains the original audio. Meetings checks journal identity and each source's saved duration before skipping batch recognition. An incomplete live journal is supporting recovery data, never a complete History result.

Pause and route gaps retain real elapsed time. The source writer records structured gap intervals and pads the corresponding original track with silence; it does not compress later speech across a missing interval. Device changes attempt to rebind the same authorized app and microphone. An unavailable source has a bounded recovery period before capture stops with retained audio and an explanation. This cannot recover speech that never reached the Mac or arrived while a device was unavailable.

## Acceptance

Finalized live meetings use meeting format 2, holding the confirmed text without creating another whole-session mixed audio copy. The first such save keeps the exact previous format-1 manifest as `meeting-v1.json`; original tracks remain unchanged. Existing format-1 meetings are still readable and are not bulk migrated. Older binaries cannot open format-2 recordings. New timing sidecars also carry optional gap records, which can exceed older binaries' 1 KiB read limit after repeated interruptions. A binary rollback must retain these folders and use a compatible build to review them; it is not a data rollback.

Join a supported call, accept Start, see progressive words, switch Mac/headphones in both directions, pause/resume, stop, and verify one transcript and original recording in History. Check recognition failure, device disappearance, short replies, simultaneous sources, cancellation, relaunch recovery and a long session. Dictate must show the same progressive text while preserving its draft, shortcut and single final paste. Synthetic checks and renders do not establish physical-device or installed acceptance.

Individual voice identification, automatic recording, calendar-title lookup and progressive typing into other apps are outside this change.

## Evidence from 5 October 2026

- Synthetic checks: 206 meeting lifecycle checks, 34 recording-removal checks, 21 live-window checks, 179 Dictate persistence/delivery checks and 14 actual PCM writer/conversion checks. They cover timing jitter in both directions, repeated short replies, cancellation of queued inference, incomplete-live fallback, exact prior-format backups, route gaps and bounded callback loss.
- The Swift package suite passed 338 tests with two skips. Provider, capture, History, handoff and the remaining independent regression checks passed. The full script stopped at five exclusive-shortcut assertions while installed Workbench owned the default shortcuts; it is not a clean full-suite pass. Quit other editions before the full run, as README requires.
- Cached Parakeet v2, Apple M5, 16 GB, macOS 26.5.1: one 20.699-second generated English fixture, delivered to the adapter at real-time speed. First words appeared at 2.19 seconds; Stop flushed in 0.19 seconds. The same fixture on two simultaneous source lanes completed with first words at 2.26 seconds and a 0.20-second Stop flush. Both passes completed without saved-audio fallback. These small synthetic samples establish API operation and initial feasibility, not phone-call accuracy, long-session performance or battery behavior. CoreML printed a shape-inference diagnostic; both calls returned successful transcripts.
- No production or Preview app was replaced. Physical headphone switching, a relayed phone call, permission changes on hardware and Claude's UI integration still require signed Preview acceptance. Speakers can leak app sound back into the microphone; the live path preserves overlapping words and does not claim echo-free speaker identification.
