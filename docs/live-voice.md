# Live voice integration

Status: shared capture, live transcription, Meetings/Dictate UI and guarded in-field dictation implemented in source. Installed call, receiver and headphone acceptance remain separate.

## Ownership

The integration owner on `codex/live-voice-engine` owns the shared capture, recognition, persistence and voice experience. Bounded toolbar and exact-field delivery changes were integrated from separate worker worktrees. One integration owner controls the existing signed Preview installation.

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

Meetings keeps its existing `start()`, `stop()`, `cancel()` (keep for later), recovery and recording-review owners. `pause()` and `resume()` affect the same session. `startOffered(_:)` validates the displayed offer before starting its exact source. A stale offer cannot select or start a different app. Dictate retains its existing shortcuts and delivery choice. Live words appear in its workspace and, for eligible external text fields with automatic paste selected, in the captured field. The floating pill stays compact and carries no transcript bubble.

The session remains open across a device change. Unavailable audio is represented on its real timeline and reported; audio is never compressed across a missing interval. Pause creates no speech. Stop flushes the remaining speech before saving. Capture and confirmed words remain recoverable if recognition fails.

One-click offers are available only for sources the metadata detector can identify. Browser capture can include its other tabs. The app name is not a meeting title or participant identity. Microphone-only recording remains an explicit choice. Detection stays off until enabled and never starts recording itself.

## Recognition and recovery

Parakeet v2 remains the model. The adapter requests a provisional update after roughly two seconds of new audio and commits eight-second ranges with two seconds of context on each side. These are scheduling parameters, not a measured latency promise. Each request uses fresh decoder state. It retains individual word times and reconciles the last committed word across windows, allowing timing jitter. An ambiguous boundary invalidates live completion and uses original-audio recovery. The view groups timed words into actual source turns; independent identical replies are preserved. Short endings are padded to the model's minimum input rather than discarded. Original capture runs independently of inference.

The selected model is reserved until capture and its last live request finish. The loopback server remains a file-transcription option and does not silently switch to Parakeet. A live processing backlog, missing word timings, callback overflow or failed checkpoint write leaves completion false and retains the original audio. Meetings checks journal identity and each source's saved duration before skipping batch recognition. An incomplete live journal is supporting recovery data, never a complete History result.

Pause and route gaps retain real elapsed time. The source writer records structured gap intervals and pads the corresponding original track with silence; it does not compress later speech across a missing interval. Device changes attempt to rebind the same authorized app and microphone. An unavailable source has a bounded recovery period before capture stops with retained audio and an explanation. This cannot recover speech that never reached the Mac or arrived while a device was unavailable.

## Acceptance

Finalized live meetings use meeting format 2, holding the confirmed text without creating another whole-session mixed audio copy. The first such save keeps the exact previous format-1 manifest as `meeting-v1.json`; original tracks remain unchanged. Existing format-1 meetings are still readable and are not bulk migrated. Older binaries cannot open format-2 recordings. New timing sidecars also carry optional gap records, which can exceed older binaries' 1 KiB read limit after repeated interruptions. A binary rollback must retain these folders and use a compatible build to review them; it is not a data rollback.

Join a supported call, accept Start, see progressive words, switch Mac/headphones in both directions, pause/resume, stop, and verify one transcript and original recording in History. Check recognition failure, device disappearance, short replies, simultaneous sources, cancellation, relaunch recovery and a long session. Dictate must show progressive text while preserving its draft and shortcut. Supported fields receive owned-span updates; final cleanup replaces that same span after History commits. Unsupported fields keep one final delivery. Once a live write is attempted, uncertainty must never trigger a duplicate paste. Synthetic checks and renders do not establish physical-device or installed acceptance.

Individual voice identification, automatic recording, calendar-title lookup and automatic sending/scheduling remain outside this change.

## Evidence from 5 October 2026

- Synthetic checks: 206 meeting lifecycle checks, 34 recording-removal checks, 21 live-window checks, 184 Dictate persistence/delivery checks, 27 exact-field delivery checks, 14 voice-experience checks and 14 actual PCM writer/conversion checks. They cover timing jitter in both directions, repeated short replies, cancellation of queued inference, incomplete-live fallback, exact prior-format backups, route gaps, bounded callback loss, call-end countdowns and uncertain field writes.
- The combined Swift package suite passed 341 tests with two skips. Provider, capture, History, handoff, core app controls and the remaining independent regression checks passed. The earlier full script stopped at five exclusive-shortcut assertions while installed Workbench owned the default shortcuts; it is not a clean full-script pass. Quit other editions before the full run, as README requires. The surface registry passes with 559 entries; its checker suite passes 57 tests. Synthetic desktop rendering produced 158 light/dark renders with zero gallery flags, plus ten shared transcript state renders.
- Cached Parakeet v2, Apple M5, 16 GB, macOS 26.5.1: one 20.699-second generated English fixture, delivered to the adapter at real-time speed. First words appeared at 2.19 seconds; Stop flushed in 0.19 seconds. The same fixture on two simultaneous source lanes completed with first words at 2.26 seconds and a 0.20-second Stop flush. Both passes completed without saved-audio fallback. These small synthetic samples establish API operation and initial feasibility, not phone-call accuracy, long-session performance or battery behavior. CoreML printed a shape-inference diagnostic; both calls returned successful transcripts.
- Installation status is recorded separately in the PR. Physical headphone switching, a relayed phone call, permission changes on hardware and real external text-field behavior still require signed Preview acceptance. Speakers can leak app sound back into the microphone; the live path preserves overlapping words and does not claim echo-free speaker identification.

## Voice experience

Meetings offers one explicit Start for the displayed call source, with Change source when needed. Opening Meetings while recording shows that same session, its source health, elapsed time and live words. Pause/Resume keeps the session; Finish saves it. Provisional words are visually quieter. The selectable native transcript preserves selection and scroll position while the reader looks back, with Latest words to return to the end. Dictate uses the same transcript component without speaker labels. The compact toolbar exposes the same Pause/Resume/Finish actions through its existing chooser and keeps its existing geometry and focus behavior.

After a successful meeting save, its transcript stays visible. Prepare follow-up opens the existing Hand off review with that exact transcript, independent of any other History selection. The prepared request asks for purpose, decisions, evidenced commitments, missing owners/dates and the most useful draft; social calls may need no action. Interpreting context uses the chosen handoff destination, not a new automatic model run. Nothing is sent or scheduled.

### Guarded automatic finish

Finish when call audio ends defaults on for supported app recordings and can be changed in Recording options. It first requires observed activity from the chosen app or its recognized helpers. Both input and output must then remain inactive for 20 seconds, followed by a 10-second cancellable countdown. A source using audio, even silent or muted audio, remains active. Unknown metadata, Pause and reconnecting audio revoke the countdown and require fresh active evidence. Keep recording disables automatic Finish for that session and is reachable in the page and toolbar chooser. Microphone-only and unclassified sources remain manual. This is an audio-activity heuristic, not a meeting-provider call-end API; a provider that leaves audio running still needs Finish.

### Live words in another app

The native path requires a captured nonsecure readable field, writable SelectedTextRange and SelectedText attributes, and focus/value/selection notifications. It replaces only the owned speech span, never the whole document or clipboard-pastes every chunk. Full field value and caret are checked before and after each write. User input, app/focus/selection changes, errors or uncertainty permanently close that capture's writer. IPC and update cadence are bounded. Final cleanup updates the same span only after History is durable; no fallback paste follows an established live owner failing. Cancel restores the original selected words only when exact ownership can still be verified. Otherwise the field is left alone, the original audio is retained and the result explains that review is needed. Explicit clipboard delivery remains clipboard-only.

[Claude's native quick entry](https://support.claude.com/en/articles/12626668-use-quick-entry-with-claude-desktop-on-mac) establishes the real-time composer baseline. [Apple's selected-text attribute](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute) and [attribute-setting API](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue) support the cross-app approach, but do not guarantee a receiver implements it correctly. External app compatibility must be established in installed testing; an owned NSTextView fixture is not that evidence.

UI integration checks include the automatic-finish policy, known helper processes, metadata failures, exact-field span ownership, uncertain-write fallback, Cancel rollback and durable original recovery. Native transcript renders use synthetic words in light/dark listening, paused, reconnecting, finishing and completed states. See the PR evidence for the final combined counts and build revision.
