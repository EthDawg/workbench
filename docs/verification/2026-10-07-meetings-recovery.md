# Meetings admission and complete-text recovery

Foundation B, [#280](https://github.com/Ship-Work/workbench/issues/280). Source checkpoint `5552a6d1a8b4668953e4ef386f1b79aa274ad89b` is based on accepted first-speech integration `c04dacfa`, with the separate Home download-size caption `11b17e8`. This record covers synthetic behavior and offscreen production views, not signed native acceptance.

## Behavior and boundaries

The existing MeetingModel publishes operation-specific admission from actual speech readiness, microphone authorization, source enumeration and host activity. Only explicit Start can request microphone access. Permission completion, source changes and speech reservation recheck admission and the operation generation. Returning from Models or Settings never starts capture. Failed source enumeration keeps the selection and differs from a successful empty query. A known Core Audio permission constant offers Settings; other OSStatus values stay unknown and retain their actual code.

Saved-audio recognition bypasses current microphone and app admission. A validated complete checkpoint instead takes `commitOnly`, with no mixing, recognition or optional speaker separation. Full coverage is checked against maximum source start plus duration and the actual segment plan. The borrowed 599.6 + 0.5 second tail and recognized final silence are valid; a prefix, mismatched duration or over-cap timeline cannot become a completed or silently settled transcript. Changed selected journal bytes are held rather than falling back to recognition.

Complete text remains savable without original audio, with playback and retranscription explicitly unavailable. If History saved but the final meeting journal failed, retry resolves the durable same-UUID record and notes before committing. A later edited conversation, raw wording, date, duration and metadata are preserved.

## Checks on the frozen source

| Check | Result |
| --- | --- |
| `swift build -c release --product LocalVoice` | Passed, 108.82 seconds; existing compiler warnings remain. |
| `.build/release/LocalVoice --check-meetings` | 250 Meetings checks, 34 recording-removal checks, 21 live-voice checks and 14 experience checks passed. |
| `.build/release/LocalVoice --check-core` | Passed, including retained recognition/provider, capture, transcript, clipboard and update contracts. |
| `python3 scripts/check-surfaces.py` | 629 registered entries passed. |
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-check-surfaces.py` | 58 scanner checks passed. |
| `WORKBENCH_MEETINGS_GALLERY_ONLY=1 .build/release/LocalVoice --render-surfaces .build/meetings-phase-gallery-final` | 12 production renders, 6 entries, zero flags; production owner assertions passed in both themes. |

The complete-text regression uses two intact voiced tracks and instruments recognition to fail if called. A separate fixture performs one mixed and two speaker recognitions, saves a labelled conversation, then fails the final journal write. It edits the durable transcript and notes and retries through MeetingModel while speech is unavailable and the microphone denied. Retry finishes the same journal without another recognition or History write; exact History and metadata bytes remain unchanged. Repeated save failures, missing originals, changed/incomplete selected checkpoints, passive permission reads, Cancel/late grant, readiness reversal, explicit source alternatives and failed Settings opening are covered with injected owners.

The timeline negative control compiles the exact old `MeetingModels.swift` from `c04dacfa` and the current file against the same metadata-only driver. The old owner exits 1 because an empty recognized prefix with a missing final tail is accepted or settled. The current owner exits 0, holding that prefix and accepting the complete borrowed tail with recognized silence. The only unused IO dependency is replaced by a trap; no journal write or audio operation runs in this driver. The production source was not mutated for this check.

All new preferences use absolute paths below temporary synthetic roots. No real model, microphone, tap, privacy setting, installed application, user recording or cache was changed. The core suite uses its existing isolated fixtures; this run does not claim a delayed real-preferences inventory check.

Local logs are `.build/meetings-phase-build.log`, `meetings-phase-checks.log`, `meetings-phase-core.log`, `meetings-surface-harness.log`, `meetings-phase-gallery-final.log` and `meetings-timeline-negative.log`. The negative driver is retained beside those local logs.

## Production render review

The gallery renders the real Meetings page at 1050 × 730 content size in light and dark. It injects source/permission/readiness state and creates synthetic journals only. No installed UI or device is used. Source choices, typed recovery, complete-text Save and the retained completed Copy/Review actions are readable at minimum width.

- [Denied microphone and explicit app-only choice](2026-10-07-meetings-recovery/meetings-microphone-dark.png)
- [Failed source check with the selection retained](2026-10-07-meetings-recovery/meetings-source-failure-light.png)
- [App audio only after explicit preparation](2026-10-07-meetings-recovery/meetings-app-only-dark.png)
- [Complete text with missing originals and unavailable speech](2026-10-07-meetings-recovery/meetings-complete-text-light.png)

Native acceptance still needs the exact signed candidate: permission denial and Settings return, source disappearance and actual known/unknown OS failure handling, headphone coverage, Stop/Cancel timing, long-call final-tail capture, keyboard focus and VoiceOver. Synthetic timeline metadata establishes the commit boundary, not a two-hour hardware recording. Earlier completed-Meetings Copy acceptance remains separate from this recovery slice.
