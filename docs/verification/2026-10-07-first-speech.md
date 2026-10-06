# First speech: deliberate setup and retained cache

Foundation J ([#15](https://github.com/Ship-Work/workbench/issues/15), [#165](https://github.com/Ship-Work/workbench/issues/165)). Source starts at `7cd3b0a923d1119861a7e4524f0dc2b1aeb229b4`; independent-review repairs and retained fixture updates are frozen at `281a5003fd2add67377189d37952844326f8497d`. The latter includes the parent Packs preference-isolation repair `e61322e` and its preceding signed Library evidence. This record covers source, synthetic owner checks, offscreen production renders and the isolated real-CoreML probe below. It is not an installed first-speech acceptance.

## Ownership and behavior

`RecognitionEngine` owns one typed readiness snapshot and one heavy preparation slot. Startup and Retry saved files use a cached-only loader. Both transcription entrypoints require admission and cannot acquire assets. Only explicit Download reaches the downloader, using a private candidate. Four CoreML components load sequentially off the main and recognition actors; the pinned FluidAudio 0.15.6 manager receives those models without a second load. Vocabulary validation checks UTF-8, bounded size, v2 token coverage, canonical identifiers and duplicate JSON members.

Cancel immediately revokes admission, rejects stale progress/completion, and retains a noninterruptible load's slot until it finishes. A failed or cancelled candidate leaves the prior cache bytes intact. Atomic exchange retains the previous directory; no cache sweep is introduced. A configured local server remains unverified until an actual successful transcription, while allowing the person's deliberate first attempt without a hidden probe or fallback.

Home has one visible deferral in its fresh guide. Models provides explicit Download, Retry saved files, Not now and busy Cancel. Setup completion starts no recording. Dictate keeps Stop/Cancel reachable when readiness changes and shows actual denied/restricted microphone state. Returning from Settings only refreshes permission state. Snap & Talk checks existing permission state without prompting merely because a session is opened; requesting access is explicit. Meetings' separate source-admission/recovery work remains outside this slice.

## Focused verification

All model acquisition, model loading, credential and OS-permission boundaries in this focused-check section are injected or use synthetic files. The existing transport checks use local loopback HTTP fixtures. No real model, account, live cache, privacy setting or installed application was changed.

| Check | Result |
| --- | --- |
| `swift build -c release --product LocalVoice` | Repair build passed in 116.12 seconds; final frozen source including the stronger transient-session assertion passed in 108.53 seconds. Existing compiler warnings remain. |
| `.build/release/LocalVoice --check-providers` | 63 retained provider checks, transport fixtures and 36 recognition lifecycle checks passed. |
| `.build/release/LocalVoice --check-readback-pack` | 32 retained and 43 Packs-owner checks passed. |
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-capture-persistence.py` | 184 checks passed using exact AppModel methods, real temporary recovery files, injected recognition/delivery and the actual readiness value types. |
| `.build/release/LocalVoice --check-core` | Passed, including Library, prompt picker, shared controls, delivery and feedback. |
| `python3 scripts/check-surfaces.py` | 628 entries passed. |
| `WORKBENCH_SPEECH_GALLERY_ONLY=1 .build/release/LocalVoice --render-surfaces .build/first-speech-final-gallery` | 16 production renders, three catalogue entries, zero flags; owner permission/cancellation and transient-session checks passed in both themes. |
| Delayed Preferences boundary | Before provider/Packs checks and after an explicit 20-second cfprefsd wait: 3,672 UUID-suffix filenames both times; zero new names. Only filenames were inventoried, and no pre-existing preference was removed. Both new test suites use absolute temporary paths. |

The lifecycle checks hold a noninterruptible operation through Cancel, duplicate calls and configuration reversal, then release old and current replies separately. They verify one maximum concurrent load, no stale adoption/progress, neutral Models cancellation even when underlying transport returns a cancellation error, cache preservation after missing/corrupt files and failed exchange, and failed unverified-server use with exact audio retained. The gallery holds microphone replies and engine-admission replies; cancellation must prevent even a transient capture-session creation, while an old false reply cannot fail a newer attempt. These are production-owner tests, not string-only readiness assertions.

The recording-race negative control restored the exact `startRecording` method from `7cd3b0a`, adapting only its `engine.isReady` await to the held-reply fixture seam. That temporary source built in 108.46 seconds, then failed with exit 1 in both gallery themes: “An old true readiness reply started or failed cancelled capture.” A snapshot subscription detects transient session creation even when subsequent failure cleanup clears recovery files. The actual engine was asserted unavailable before injection, so the old path could not reach microphone hardware. The exact `281a500` source bytes and its previously built passing executable were restored with hash verification. The restored gallery again passed all owner checks and produced 16 renders with zero flags. This is a test of the exact older method's control flow under the new fixture, not a claim to have tested an unmodified older app binary.

Local logs use `.build/first-speech-` with repair build, providers, pack, core, surfaces and gallery suffixes; final/restored gallery logs identify the strengthened race assertions. The retained exact-method harness is `first-speech-capture-persistence.log`, the filename guard is `first-speech-preferences-result.json`, and the negative control has `first-speech-readiness-negative.patch`, `first-speech-negative-result.json` and negative build/gallery logs. Earlier source checkpoint `7cd3b0a` also passed retained `--check-readback` and `--check-meetings`; the latter's capture/recovery implementation is unchanged here.

## Render review

The focused gallery uses the production Home, Models, Dictate and Snap & Talk views at 1050 × 730 content size in light and dark. Only the isolated gallery child opts out of automatic cached preparation and accepts a synthetic recording snapshot. Production defaults start the real lifecycle. Controls, captions, cancellation and recovery are readable at this width.

- [Fresh Home with one deferral](2026-10-07-first-speech/speech-offer-light.png)
- [Explicit acquisition and Cancel](2026-10-07-first-speech/speech-download-dark.png)
- [Cancelled noninterruptible load](2026-10-07-first-speech/speech-cancelled-load-dark.png)
- [Cached model failure and deliberate retry](2026-10-07-first-speech/speech-cache-failure-light.png)
- [Stop after readiness loss](2026-10-07-first-speech/speech-stop-without-readiness-light.png)
- [Restricted microphone with usable saved text](2026-10-07-first-speech/speech-microphone-restricted-dark.png)

The local server and deferred Snap & Talk renders remain in the local gallery. The latter is the first-run session page; it does not establish a loaded saved-session journey. Native keyboard focus, VoiceOver, real permission dialogs and live capture were not exercised by rendering.

Integration with merged main at `c04dacfa1615cb29f8f9b83e99d205e9f34180ee` preserved the reviewed app and capture-harness source exactly. The integrated release build passed in 119.17 seconds; providers/lifecycle, core, the 184-check capture-persistence harness and the 628-entry surface registry passed again. Integration logs use `.build/first-speech-integration-`. Only this verification record changed after that source checkpoint.

## Real CoreML adoption and offline reload

The lead compiled the exact `281a5003` recognition/readiness/local-loader/ending sources and unchanged `VoiceError`/`LiveVoiceWord` declarations into a disposable command-line probe, linked against the existing pinned FluidAudio `4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b` objects. The production loader, engine admission, atomic adoption and both inference paths were unchanged. Only the acquisition dependency copied an already-cached model into the private candidate using an APFS clone; no download was exercised.

Three separate processes ran on arm64 macOS 26.5.1 under an explicit network-denying sandbox that also denied writes to the real FluidAudio model directory, both editions' saved data and real Preferences. Each engine used an absolute temporary preferences path and scratch-owned models. A 6.72-second mono 16 kHz synthetic Daniel-voice WAV supplied the same sentence, without microphone recording or speaker playback.

| Runtime case | Result |
| --- | --- |
| Initial adoption into an absent scratch cache | Production loading and adoption succeeded; file transcription and live timed words returned the asserted sentence after the candidate path was removed. |
| Atomic replacement of an existing scratch cache | The previous compiled directories were renamed unusable **only in scratch**, so reopening those old paths could not silently pass. After production `RENAME_SWAP`, both inference paths returned the sentence; the entire previous scratch cache remained byte-exact in the retained candidate. |
| New-process offline reload | Production `prepareCached` succeeded and both inference paths returned the sentence. Acquisition and server transport were forbidden by the injected services; their call counts were zero. |

All three returned “This is a synthetic workbench acceptance test. The meeting starts at 9. Keep the original words.” The live path returned 16 nonempty timed word groups with finite, ordered start/end values. Initial/replacement invoked one clone acquisition each and no server transport. All adopted files matched the fixture; the original 22-file, 464,413,250-byte user model cache matched its pre-probe SHA-256 manifest afterward. The WAV SHA-256 is `cebe673460bf1fd5290a50de7075a596497c0fec9a399f2c676ad4257181d744`; the final probe executable is `20d0fc572e0417daaa2535c270d1568dd074a890498c06a72fcb5f64fe74894b`.

The pinned runtime emitted an E5RT zero-shape inference warning in each process; both recognition paths still completed with the asserted content. This is a short usability/correctness probe, not an accuracy or performance benchmark. Two earlier private-driver path-guard failures happened before model loading; the driver was corrected to resolve existing ancestors for not-yet-created scratch paths. No production repair was required by these probes.

To reproduce without touching a user's cache: compile the same production declarations with their pinned dependency, give `RecognitionLocalModels.acquire(cache:operations:)` an explicit scratch destination, replace only `operations.download` with a clone into `candidate/cache.lastPathComponent`, and keep `Operations.live.load`. Inject those services into a fresh engine. Test initial adoption, deliberately unusable old scratch contents, then cached-only loading in a new network-denied process; assert known words, live timing, adoption/retention manifests and unchanged originals. Do not use the legacy `--check-live-voice-model` for this check: it selects the real default cache and the dependency's repair-capable wrapper. Private source hashes, driver, logs and manifests remain in the local first-speech evidence folder.

This establishes real inference after pathname adoption/exchange and process-restarted offline preparation. Actual downloading, signed app controls, physical capture, OS denial and Settings-return behavior remain separate.

## Remaining signed-native gates

Verify actual cached-only preparation and speech inference offline, relaunch without hidden acquisition, explicit download/cancellation/retry, initial candidate adoption and replacement of an existing cache followed by inference, and permission denial/Settings return/Stop on the exact signed candidate. The real-CoreML probe above resolves the source-runtime inference check after pathname exchange; it does not transfer its result to untested signed UI or real-download journeys. Keep those distinctions in the [model contract](../model-providers.md). Real disk exhaustion, model accuracy and device timing also remain native limits.
