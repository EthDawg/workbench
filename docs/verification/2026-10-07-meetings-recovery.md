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

## Independent-review repairs

Source `1a39741979a21c08a2d0d39db1799c02a4612034` closes the reviewed asynchronous selection gap: recognition carries the same reviewed checkpoint through the actual engine-snapshot await, and MeetingProcessor compares its first disk read against that selection before either recognition or complete-text commit. The existing initializer injects only that snapshot boundary in checks. Held replies cover incomplete-to-changed-incomplete and incomplete-to-complete replacements; both must preserve replacement journal bytes with zero ASR and zero commits.

Passive detection now reads the production `hostAdmission` callback. Missing speech, active Dictate, active Snap & Talk and closing suppress metadata polling and offers; returning to ready/idle restores only the passive confirmed offer. These checks do not rely solely on the older `mayStart` fixture hook. Start retains its own dispatch checks.

Completed Meetings says “Saved in History.” Missing-original details remain beside the result. Processing uses a neutral checkpoint explanation and omits an empty live-listening placeholder, while retained live words remain visible. The gallery exercises the actual commit callback with missing originals, unavailable speech, and counters proving no permission, capture or recognition calls.

Sub-0.5-second recordings remain ordinary format-1 `stopped` records, with the existing too-short explanation: no recognition happened and no segments are invented. This reader settles a validated complete short timeline without retry. A focused owner check verifies the updated journal state, identity, timing and exact original-audio bytes. The journal itself intentionally changes to record the explanation, so byte equality is not claimed for that write. A separate fixture generated by the current MeetingStore successfully decodes through the exact published `5f209ca` MeetingModels reader and current reader, without either reader rewriting it. This establishes decoding for that shape, not equivalent older retry UX or blanket Meetings downgrade support. Use the newer binary for current recovery behavior and preserve the session folder.

The repair build passed in 115.32 seconds. All 260 Meetings checks, 34 removal checks, 21 live-voice checks and 14 experience checks passed. The affected production gallery passed 16 renders, 6 entries and zero flags. The surface inventory remains 629 entries. Logs use `.build/meetings-review-` with build, checks, surfaces and gallery-final suffixes. The published-reader proof and driver are `.build/meetings-old-reader.log` and `meetings-old-reader.py`.

For the race negative control, only the new three-line recognition-checkpoint comparison was temporarily removed. That mutation built in 106.50 seconds and the same focused suite exited 1 at the intended held-boundary assertion: the changed-incomplete case performed one ASR call and one commit; the incomplete-to-complete case performed zero ASR calls but one unreviewed commit. Both are forbidden by the passing source. The exact committed `MeetingRecovery.swift` and previously passing executable were restored with SHA-256 verification; the restored suite again passed 260 + 34 + 21 + 14 checks. This is a targeted behavior mutation, not an unmodified old-app test. Local evidence is `.build/meetings-race-negative.patch`, `meetings-race-negative-build.log`, `meetings-race-negative-checks.log`, `meetings-review-good.sha256` and `meetings-review-restored-checks.log`. No mutation remains in production source.

- [Saving text with no original audio](2026-10-07-meetings-recovery/meetings-saving-without-audio-light.png)
- [Completed result with truthful missing-audio note](2026-10-07-meetings-recovery/meetings-saved-without-audio-dark.png)

## Integrated candidate

Integration `d1943eeb74cc23aa273ad040757cdcba48b3f3f2` combines the accepted source and evidence with merged #305 and the retained real-download/compatibility observations. Every app source matched reviewed `1a397419` at that boundary. The integrated release build passed in 118.97 seconds; Meetings (260 +34 removal +21 live voice +14 experience), core and the complete repository harness phase passed. The registry passed 629 entries and 58 scanner checks. The production gallery passed 16 renders, 6 entries and zero flags; the saving and missing-original completed views were visually inspected at minimum width in both relevant themes. Logs are `.build/meetings-integration-{build,checks,harnesses,gallery}.log`.

A subsequent wording-only correction replaces both visible references to a “recording checkpoint” with “Finishing your transcript.” No admission, recovery, persistence or view layout behavior changes. Signed package compilation and native acceptance must identify the resulting candidate revision separately. No native result is inferred from these source checks.

## Signed native acceptance, 7 October

Workbench Preview **2.4.1 (20261006183720)**, clean source `eabf7e7be92eaf1a70027690947719dbcf0b7712`, Local development, macOS 26.5.1 (25F80). Actual **Copy build details** was pasted into a separate TextEdit document. The installer retained archive SHA-256 `aa0473da4623c592c696039174f158ed669ff214fefe25096d264273b45c71f2` and the previous signed Preview. Packaged resource/Readback/Packs/handoff checks and the installed executable's 260 +34 +21 +14 checks passed. [PR #306](https://github.com/Ship-Work/workbench/pull/306) merged as `c0466e8cfcd880ba1fdac834f45a4fba1d5c1937`; its required [merge-group run](https://github.com/Ship-Work/workbench/actions/runs/37512299111) passed every selected job.

The lead used the installed app's ordinary Meetings and History pages, current cached Parakeet engine and three owned synthetic sessions. Opening Meetings offered **Save transcript** for complete text and **Transcribe** for retained audio without starting either. The fresh complete-text case saved all 92 UTF-8 bytes with its original audio absent; the completed view explicitly said playback and retranscription were unavailable. Native Copy replaced an independent TextEdit sentinel, and the saved receiving RTF's extracted text matched exactly (`e6bbd5772a0a3efe07fbf3397299de6f31e0013546fac8a860f0d6737d286d0c`).

The retained 6.72-second synthetic CAF produced the expected 96-byte transcript through the actual local engine. Its original bytes remained unchanged. Native Copy into a second receiving document matched exactly (`9ed9a53c17747a40f884f7e8f3ddd25c96f56d489808446b002bfde2856f263f`). Review transcript opened the committed words and Escape returned to History. Reviewing a missing original disabled playback and explained the missing file; Escape retained the text. Normal Quit/relaunch showed all three results on Home, kept the full saved-state value and exact History metadata, and returned Meetings to Ready with no unfinished test recording.

One fixture preparation error is retained separately: hand-encoded JSON decoded correctly but differed from MeetingStore's exact serialization. Its first Save wrote the synthetic transcript to History, then the existing replacement guard refused the journal write. No original record changed. While Preview was quit, only the owned fixture journals were regenerated using the exact production MeetingStore and AtomicPrivateFile writers in a private helper. Native retry then committed the same journal with the entire saved-state value unchanged, proving no duplicate or replacement of its already-durable transcript. A separate fresh production-written fixture established ordinary Save. This is controlled fixture/retry evidence, not a naturally occurring storage failure or a native later-edit test. Future fixtures should be created through MeetingStore rather than hand-encoding mutable journals.

After acceptance, a guarded cleanup while Preview was quit verified that the only saved-state/metadata differences were the three owned records. It retained the completed synthetic folders privately and restored only that test delta. After relaunch, all 137 original transcripts and every other saved field matched; History metadata, the Library record and original meeting files remained exact. All 22 model files and every value in the main Preview defaults suite matched the pre-test baseline. Saved-state JSON was reserialized, so post-relaunch byte identity is not claimed for that file. The two owned receiving documents were closed, and Preview was left idle on Home. Private fixtures, production-writer helper, integrity comparisons and receiving files remain under the local acceptance folder `workbench-meetings-native-eabf7e7`.

These observations do not establish physical microphone/headphone/call capture, actual OS denial/Settings return, native recovery with the engine unavailable, late permission cancellation, two-hour recording coverage, VoiceOver or full keyboard traversal. No privacy reset, permission change, model download, original-recording playback or public release occurred in this native test. The automated unavailable-dependency and asynchronous checks above retain their separate scope.
