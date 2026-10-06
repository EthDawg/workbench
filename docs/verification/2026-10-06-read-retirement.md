# Read retirement: source and synthetic evidence

Foundation H ([#284](https://github.com/Ship-Work/workbench/issues/284)), source `64da2c69ab2b8ae5a9cc6175458548a938a823c7`, based on integrated browser-pause source `8060010d07f439bb1a857e223906e1079f7576f5`. This record covers implementation and synthetic verification. It does not establish installed Preview or production acceptance.

Read's page, toolbar mode, shortcut admission, contextual actions, voice/provider settings, Services declaration and production speech-generation commands are removed. Recognition, original recording review, captured narration, VoiceOver and prompt-insertion update guards retain their existing owners. The optional Persona native-check speech argument is refused; its microphone-only check remains. The isolated StageKit synthetic speech fixture remains in source with no production speech admission.

Nonempty legacy `speechText` is preserved as one ordinary UTF-8 Library file, using a fixed resource identity and private atomic writes that never replace a conflicting file. The file and persisted Library reference are read back before the separate completion receipt is written. Original SavedState text, voice and rate remain intact. A valid receipt prevents resurrection after deliberate removal. A failed preservation stays on Library with a plain-language notice, a Details disclosure, Retry saving Read text and Show original saved state. Empty profiles get no preservation notice or file. No cache, credential or exported-audio cleanup runs.

## Passed checks

All stores, preferences, audio, sockets, pasteboards and signing/update fixtures used for these checks were synthetic or isolated. No provider task, model download, permission change, installed-app replacement or live saved-data edit was performed.

| Check | Result |
| --- | --- |
| `swift build -c release --product LocalVoice --disable-automatic-resolution` | Passed for the pinned source. |
| `LocalVoice --check-read-retirement` | 43 checks: near-million-character exact UTF-8, decomposed Unicode, CRLF/whitespace, private file, two model reloads, unchanged source fields, deletion without resurrection, full/corrupt/newer Library protection, conflicting files/receipts, partial write/readback failures and retry. |
| `LocalVoice --check-core` | Passed, including retained control admission, saved-state compatibility, Library/Quick Look, Snap & Talk, synthetic WAV/M4A recognition inputs, feedback and update insertion guards. |
| `LocalVoice --check-shortcut-migration` | 39 checks: retained cross-owner choices/conflicts plus the retired Read key remaining stored but unregistered and non-reserving. |
| `LocalVoice --check-presenter` | Browser pause 43 and isolated compatibility transport 27 checks; late dispatch of inactive browser/Read keys has no effect. |
| `python3 scripts/test-read-retirement.py` and `--binary .build/release/LocalVoice` | Four source-boundary tests; 13 retired commands and Persona's speech option rejected before startup. |
| `swift test --disable-sandbox --filter 'ToolbarCoreTests\|ToolbarKitTests'` | 217 tests, no failures; two explicitly on-screen native interaction tests skipped. |
| `LocalVoice --check-meetings` | 218 meeting checks plus 21 live-voice and 14 experience checks; no live devices or models. |
| `python3 scripts/test-capture-persistence.py` | 184 checks against extracted production capture methods, including recovery, delivery and unchanged owner safeguards. |
| `python3 scripts/release/test_preview.py`, `test_release.py`, `test_updates.py` | 12, 20 and 28 checks. Incoming Preview/production artifacts reject the retired Service; old installed/historical bundles remain valid for protected replacement, inspection and rollback. |
| `python3 scripts/check-surfaces.py`; `python3 scripts/test-check-surfaces.py` | 520 registered entries; 58 scanner checks. |

`WORKBENCH_READ_RETIREMENT_GALLERY_ONLY=1 LocalVoice --render-surfaces OUTPUT_DIRECTORY` rendered ten production views in disposable homes: Home, Models, Keyboard, preserved Library file and conditional Library recovery, each in light and dark appearance. The pass reported zero flags; the changed surfaces were visually inspected. The pass also exercised AppModel's startup preservation hook. It did not exercise live capture, an installed Services menu, a real update or a host/provider round trip. Path-bearing Library images remain local evidence.

## Remaining native gate

The integration owner must verify the exact signed Preview build, an upgrade containing an existing Read draft, preserved file use and two actual relaunches, removed Services/menu/shortcut/contextual doors, and retained Dictate/Meetings/Snap & Talk plus original-recording/narration playback. Installed signature, replacement/rollback, physical microphone/audio, VoiceOver and the two skipped native toolbar interactions are not proved by these source checks or renders. Do not describe the broader foundation reset or a production release as accepted from this record alone.

## Integration follow-up

Integrated merged handoff #291, current main through #294 and independently accepted verifier #277. The verifier now runs `--check-read-retirement` instead of the retired speech modes; its seven failure/receipt fixtures pass, and the four retirement source checks pass. The registry retains all handoff and recovery entries (541 on this integration).

CI run 37458609236 found the isolated Library harness omitted the new preservation dependency. The harness now compiles production `ReadRetirement` and `AtomicPrivateFile`; recall (31), import/concurrent-write protection (37) and image reuse (30) checks pass. This fixes the harness compile failure without changing preservation behavior. These remain source checks; signed upgrade acceptance is still required.

## Signed native upgrade, 7 October

The sole installation owner replaced the existing Preview in place with signed **2.4.1 (20261006123415)**, clean combined source `dec1f343413b9c3ce68583e81863e6c9278ec0df`, on macOS 26.5.1 (25F80). Actual **Copy build details** confirmed the running identity. The installed archive SHA256 is `19ca078755751c7098187145948b53a9503e0f39a91907d0810132ac9e9c63ad`. This development candidate includes H unchanged plus independently reviewed A1/C; it is not a public release.

Before replacement, the installer recorded the existing Read draft locally. After replacement, the ordinary **Saved Read text** Library file matched it byte for byte, its original saved-state fields remained intact, and the preservation receipt and single Library reference were present. Opening that Library resource launched TextEdit normally. Two normal Quit/relaunch cycles retained the resource and exact file without a duplicate or recovery error. Private source text, paths and fingerprints remain local.

The installed bundle has no Read Service declaration or browser-extension resources, and the actual Window menu no longer offers Read or browser switching. The native Services check initially found an old Preview Read action: LaunchServices identified two obsolete, uninstalled development bundles as its providers. Targeted unregistering of those two obsolete paths removed that action from a fresh receiving app's Services menu; installed Preview and Stable, their data and privacy grants were not changed. Stable's separate Service remained. This was development-machine registration contamination, not a retired Service in the tested package; no production cache-reset behavior was added.

Native evidence is retained locally in `.build/native-foundation-dec1f34`, alongside private installer preservation receipts. Synthetic handoff records used for the combined acceptance were archived after normal Quit; original state/history files were restored byte for byte after validating that every other field and record was unchanged. The second relaunch returned to the original Home state.

This establishes the bounded upgrade, preserved-file use, relaunch and inspected menu/Service results above. It does not establish a fresh-profile permission-denied journey, physical recognition/narration/playback, VoiceOver, every shortcut/contextual door, a real Sparkle replacement or production-release readiness. Those broader acceptance gates remain open in #7.
