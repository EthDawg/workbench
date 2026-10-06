# Working verbs you can trust: the 6 October 2026 batch

Evidence-and-decisions record for the release after Workbench 2.4.1. Written on 6 October 2026 from the batch's research, build, review and fix records, so a later lead can reuse the research and knows why each deferred idea was deferred. Base for this record: `main` at `539aff0`. The batch was planned against `main` at `5f209ca` (the merge of PR #259).

This is a working record, not acceptance evidence. The six states in [docs/updating.md](../updating.md) (source checked, Preview installed, native acceptance, merged, packaged, published) still need their own evidence. Section 5 lists what the installed-Preview owner still owes.

## 1. Why this batch

### The grounding rules

The lead was asked to choose the work itself and deliver a verified set of improvements that makes the next production release worthwhile. Two rules governed the choice:

- Choose from the maintainer's repeated product requests and from the installed app's own evidence (its unified log, its diagnostic reports, its saved artefacts), not from features a model thinks are missing.
- Treat every #164 QA ticket as already on `main`. All 23 of them (#151 to #163, #165, #169 to #175, #220, #223) had landing commits; they stay open only until a native acceptance line is posted.

A second lead (Codex) started the same goal minutes earlier and claimed the History saved-work journey (#137, #150) plus integration of the shared installed Preview. Coordination ran through GitHub issue comments: #137 and #150 for Codex, #7, #14, #17 and #134 for this lead. Codex also published Workbench 2.4.1 (v2.4.1, build 20261005234010, from `main` 5f209ca) during the session, so this batch is the release after 2.4.1.

### The maintainer's asks, as themes

Twenty-two distinct request themes were counted across the maintainer's sessions from 26 September to 6 October. The ones this batch answers:

| Theme (how often it came up) | What it asked for | How this batch answers it |
| --- | --- | --- |
| Verbs complete, stop repeating (8 messages, 6 sessions) | Every verb mature and cohesive so the same things are not asked again; each verb should beat the OS and the AI harnesses | The release objective itself: five verbs fixed at their root, no new entries except where #134 had already asked for a door |
| Dictation into other apps (5 messages, 3 sessions) | Hotkey dictation must land reliably in Claude and ChatGPT desktop, Sublime and other fields | #265 (dictated words fit the insertion point) and #264 (one door for Accessibility calls) |
| Local models and Read quality (6 messages, 3 sessions) | Read sounds poor; local models for Dictate and Read should just work | #269 (Read's voice catalogue), #270 (app-owned Ollama downloads, engine line in Snap & Talk) |
| Repeatable QA without the maintainer (8 messages, 4 sessions) | Catch bugs from real use, write build-ready tickets, make it repeatable | Field evidence from the installed app's log drove #264, #269 and #273; the acceptance runner itself is deferred (section 4) |
| Timer consistency (1 message) | Timer feels like an afterthought across surfaces | #268 (one Position… control) |
| Hands-off delivery (20 messages, 12 sessions) | Agents decide and ship; the maintainer uses the app and reports | Independent review and fix pass per stream; merge through the queue without the maintainer |

Themes the batch did not touch, for the record: the floating pill's hover and motion, Home and the sidebar, Persona camera, meeting and call detection, the website, the voice ring, the Snap image workspace, dictation feedback, the menu-bar panel, History tags and hand off, the Present page, prompt styles and subscription connections. Most of these had already shipped in 2.3.x and 2.4.x; the asks index in the research sources records which.

### Field evidence from the installed app

Read-only, metadata only, from the maintainer's Mac between 22 September and 6 October. Installed builds were Workbench 2.4.0 (build 20261001032329) and Workbench Preview 2.4.0 (build 20261005110512).

| Signal | Predicate or source | Count |
| --- | --- | --- |
| Accessibility fault `Potential Structural Swift Concurrency Issue: unsafeForcedSync called from Swift Concurrent context` | `log show --last 7d --predicate 'process BEGINSWITH "Workbench" AND messageType IN {16,17}'`, subsystem `com.apple.Accessibility`, category AXCommon | 126,307 in 7 days (10,383 / 61,704 / 42,235 / 2,964 / 4,446 / 4,575 on 29 Sep, 30 Sep, 1 Oct, 4 Oct, 5 Oct, 6 Oct); 128,619 error and fault lines in all |
| The same fault grouped by process and thread | the saved 7-day log | 150 bursts of exactly 741 and 8 of 1,482, each about 100 ms, 123,012 lines (97.4%) |
| AppKit `Invalid view geometry: width is negative` / `height is negative` | subsystem `com.apple.runtime-issues`, category AppKit | 486 lines = 243 pairs (456 on 30 Sep, 30 on 6 Oct) |
| SwiftUI `Accessing State's value outside of being installed on a View` | subsystem `com.apple.runtime-issues`, category SwiftUI | 128 (16 / 28 / 52 / 24 / 8); every line from the `WorkbenchStageTests` process |
| SwiftUI `Publishing changes from within view updates is not allowed` | same subsystem | 637 (28 / 477 / 132 on 29 Sep to 1 Oct), none in the installed log since 1 Oct, but 318 per `--render-surfaces` run |
| Siri `AFLocalization outputVoiceDescriptorForOutputLanguageCode:voiceName: No descriptor found for language code` | `log show --last 3d`, subsystem `com.apple.siri` | 398 on 6 Oct in two bursts (128, then 270 two hours later); 48 on 5 Oct; none before |
| Crash, hang, spin or jetsam reports for Workbench, Workbench Preview or StageMark | DiagnosticReports | none since 22 September (14 days); the only reports were scratch tooling |
| Most used capability | artefact counts and dates in the app's own Application Support folders | Snap (36 snap folders in Preview to 1 Oct, 9 in Workbench with 3 made on 6 Oct); dictation state and StageMark boards both written on 6 Oct; Hand off last used 27 Sep |

Non-Accessibility faults had already fallen from 1,062 on 30 September to 12 to 38 a day after the 1 October build. The AX flood, the Siri burst, the geometry pairs and the State fault were what remained.

### The release objective

**Working verbs you can trust.** Seven streams in seven worktrees, each with an implementer, an independent adversarial reviewer and a fix pass. Every stream was classified by the Grammar in [docs/workbench.md](../workbench.md) before building. All seven are Quality of an existing capability. Two of them add doors, which the Grammar counts as Options of what they open: #267 adds Options to Read's panel row and #270 adds the Models… and Retry model doors to Snap & Talk. #134's 1 October follow-ups had already asked for both.

## 2. What shipped

Status when this record was last updated (6 October, after the queue drained): #265, #268, #269, #270 and #273 are on `main`; #264 is queued on its bridge-only head dbf3ac9; #267 is held in draft because PR #278 proposes retiring Read and asked for the hold, which is the maintainer's decision (section 4, row 11). A signed scratch Preview built from `main` 5d12768 (2.4.1, build 20261006084435, Developer ID, clean source) passed all ten `scripts/verify-preview.sh` modes with 0 Siri lines; its remaining Accessibility faults (2 in `--check-core`, 2 in `--check-reading`, 8 in `--check-reading-render`) are the per-Listen voice lookup that #264's cache removes, and its 12 runtime-issue lines per core and reading run are the Keychain main-thread diagnostic (section 6, row 7). The full `bash scripts/test.sh` on that `main` exited 0 (StageKit 273 tests, 5862 assertions, 0 failures, 2 shortcut checks skipped while an edition ran). Verification folders, scripts and source files that an open PR brings are marked with that PR below. Each PR carries its own Validation section and Not verified list; the counts below come from the fix-pass and review records.

| PR | User-visible outcome | Mechanism | Evidence |
| --- | --- | --- | --- |
| #273 layout faults | Nothing visible changes. Settings › Keyboard and the image preview stop logging SwiftUI faults; the stage tests stop logging the State fault | Settings › Keyboard's window observer and the image preview's fitted-zoom report publish on the next run-loop turn; the Persona sheet flag moved from `ControlCenter` `@State` to `AppCoordinator.choosingPersonas` | `Publishing changes` 318 → 0 per `--render-surfaces` run (159 → 0 per pass); `Accessing State` 4 → 0 per stage run; 296 of 300 surface PNGs byte-identical (the 4 History renders differ between two base runs too); toolbar gallery 388 fixtures, live-voice 10 renders, `--check-capture-preview` 60, `--check-image-workspace` 69, all 0 runtime issues; `docs/verification/2026-10-06-layout-faults/` (README only, no pixels changed; arrives with #273) |
| #268 Timer Position… and Persona refusal | Timer's Position… (window, Timer menu, panel Timer Options, Home) opens the toolbar's compact eight-dock control; no anchor submenu anywhere; React to my voice refused shows Dictate's exact words with Microphone Settings… | `FloatingPositionControl` moved into StageKit with `ToolbarPositionControl` as a thin wrapper; `PersonaVoiceAccess.openMicrophoneSettings`; `PersonaLibrary.voiceRefusal` for the microphone refusal only | StageKit 275 tests · 5898 assertions · 0 failures; `--check-core` 30 `_OK` groups; `--check-floating-toolbar` 232; registry 562 entries (anchor submenu entry removed, Position… and Microphone Settings… classified); desktop gallery 164 renders 0 flags; full gallery 306 renders 0 flags; `docs/verification/2026-10-06-fit-timer-persona/` (6 PNGs). Review approved; its three P3 notes (suite theme on the Timer's Position… panel, README SHA, the hint saying "Return applies" where the control also takes Space) had no fix pass in the record |
| #270 app-owned Ollama downloads, Models… in Snap & Talk | Leaving Settings › Models no longer cancels a download; Cancel is explicit; a failure reason survives a Models visit until Save; the download or failure line reaches Models, Dictate, Dictate settings, Home and the menu-bar panel's readiness row; Snap & Talk shows its speech engine beside Record narration with Models…, and Retry model only on a real failure | `AppModel.cleanupModels` holds one `CleanupModelManager`; `resetStatus()` no longer clears the kept failure; `ReadbackView.NarrationEngine` derives preparing and failure from one host-owned signal; `ModelSettingsView.onFailure` reports into `AppModel.modelFailure` | `REFINEMENT_OWNERSHIP_CHECKS_OK` 15 → 18; `READBACK_CHECKS_OK` 76 → 77; registry 563 entries (Models…, Retry model); full gallery 308 renders 0 flags; `docs/verification/2026-10-06-fit-models/` (Models, Dictate, Home and panel during a synthetic download; Snap & Talk narration ready and not ready; arrives with #270) |
| #269 Read voice catalogue | Launch and activation stop scanning every `say` voice; the Siri errors stop; Read's picker lists installed voices by identifier. Five Siri-era say-only voices are no longer listed unless a saved choice is one of them | Catalogue built from `AVSpeechSynthesisVoice` identifiers only (`MacVoiceCatalog.listed` + `catalogue`); the `say` list is read once per process, on the main thread, only when the saved choice resolves to nothing else; refreshes run on a GCD utility queue | `--check-reading-render` 48 Siri lines / 933 faults → 0 / 8 on this PR alone, then 0 / 0 once #264's voice cache landed; `READING_CHECKS_OK` 99 → 106; standalone probe: the `say` scan logs 48 Siri lines (12 at enumeration + 6 × 6 Siri-era identifiers) and 931 faults from `Task.detached`, 0 faults on the main thread; `speechVoices()` 77 ms cold, 35 to 40 ms warm, 81 ms on a GCD queue with 0 faults; Karen first audio 0.088 s median, Daniel 0.106 s (release); `docs/verification/2026-10-06-read-voice/` (3 PNGs) |
| #265 dictated words fit the insertion point (#14) | Dictating mid-sentence gains the right spaces and no spurious capital; at a sentence start it capitalises; marker lines, abbreviations, acronyms, URLs, code and dictionary terms keep the dictated spelling; the clipboard always holds the transcript as dictated | Pure rule set `InsertionBoundary` applied at the owned-span start in live dictation and at the final paste; the fit uses the pre-paste snapshot delivery already reads; the transcript is copied first and copied back after the paste when Workbench still owns the clipboard | `INSERTION_BOUNDARY_CHECKS_OK` 313 checks over 97 fixtures (`--check-insertion-boundary`, also in `--check-core`); live dictation field checks 26 → 35; `TEXT_DELIVERY_CHECKS_OK` 64 → 74; AX field reads per fitted paste 3 → 2; 180 KB field with 20,000 sentence starts fits in 12 ms, a 1 MB field in 69 ms; harness lists taught the new file (capture-persistence 184, live-dictation 35). No render folder: no visible surface changed |
| #267 Read reads the selection (#17) | The Read key, the pill and the panel row read the front app's selection at once; while playing or paused they lead with Stop reading; Read's panel row gains Options (Voice by quality with the current one ticked, Models…, Open Read…) | One host-level start `ReadStart.decide` (preparing → cancel, playing or paused → stop, idle → read the selection, else the Read page); the selection is read through Accessibility, limited the way dictation's field reads are (never secure fields, never Workbench's own process, never collapsed or over-limit ranges, nothing without Accessibility trust), never the clipboard or the window; `ReadStart.draft` never discards an unheard draft silently and `heard` is judged by text whatever voice made the audio; the panel row gives focus back only when a reading started | `--check-reading-service` 25 → 42; `--check-reading` 99 → 103; control checks 232 → 233; registry 561 → 565 (Options, Voice, Models…, Open Read…); full gallery 300 renders 0 flags; toolbar gallery 388 fixtures; ToolbarCore and ToolbarKit tests 217, 0 failures; harness lists taught the renamed members (reading-playback 153 → 164, read-selection-service 46 → 57); `docs/verification/2026-10-06-read-selection/` (panel reading light and dark, panel idle, pill playing light and dark, chooser recovery; the paused pill render was dropped because it was byte-identical to playing; arrives with #267) |
| #264 AccessibilityBridge | Nothing visible changes. Every `AXUIElement*` and `AXObserver*` call goes through one inline door, and a guard fails CI on a stray call or on any voice listing from a Task closure | `AccessibilityBridge.swift` as the one door, inline on the calling thread; `scripts/check-accessibility-bridge.py` in the harness phase fails on element calls outside the bridge, on voice listings outside `ReadingVoices.swift`, and on any catalogue call or `AVSpeechSynthesisVoice(identifier:)` inside a `Task {}` or `Task.detached {}` closure in any file; a voice-object cache (`MacVoiceCatalog.voice(identifier:)`) so a reading or preview takes its voice with no lookup from its task | All five check modes (`--check-core`, `--check-live-dictation-delivery`, `--check-floating-toolbar`, `--check-reading`, `--check-reading-render`) 0 faults and 0 Siri lines, debug and release, confirmed by the reviewer under an unfiltered `log stream --process LocalVoice` as well; `ACCESSIBILITY_BRIDGE_CHECKS_OK` 10; `scripts/test-accessibility-bridge.py` 6 tests; `READING_CHECKS_OK` 107; the probe in `docs/verification/2026-10-06-ax-bridge/` (`axprobe.swift`, `run.sh`, README with the context table; the folder, the bridge and the guard arrive with #264) |

### Recorded taste calls

These are decisions a person could reasonably make the other way. Each is one line to flip (section 4, rows 6a and 6b).

- **Mid-sentence Title-case first word is lowercased** (#265) unless the dictionary or the field itself shows that spelling. An unknown capitalised name dictated mid-sentence becomes lower case; the dictionary and the field's own text are the evidence for keeping a capital.
- **Stop reading is the pill's and the key's primary while playing or paused** (#267). Pause and Resume stay in the chooser's Read row and on the Read page. This reverses the earlier pause-on-pill decision from #211; the label follows state (Read / Stop reading).
- **The five say-only voices are unlisted by default** (#269): Aman, Aru, Ona, Tara and Tara.premium (Indian English, no word timing) appear only when a saved choice is one of them.
- **No Reset position for the Timer** (#268): the Timer never had one, so the shared control hides it there and keeps it for the toolbar.
- **Snap & Talk's Record narration stays enabled while the model is not ready** (#270): the reason sits beside it with Retry model or Models…, and a failed transcription keeps the recording with Retry transcription.

## 3. Root causes worth remembering

### The voice listing fault (126,307 lines in a week)

The brief assumed Accessibility element IPC was the source. It was not. Grouping the log by process and thread showed 150 bursts of exactly 741 faults, each about 100 ms on a background thread in the same second as a Siri voice-descriptor burst. One Mac voice listing produced both: `MacVoiceCatalog.installed()` asked `NSSpeechSynthesizer` about all 186 `say` voices, at launch on the main thread and on every app activation from `Task.detached`.

The scratch probe (`docs/verification/2026-10-06-ax-bridge/axprobe.swift`, one context per run under `log stream`) settled the rules:

- `AXUIElementCopyAttributeValue` to another process logs 0 faults in every context (plain main, main-actor task, detached task, serial queue, `queue.sync` from a task).
- `AVSpeechSynthesisVoice.speechVoices()` and `AVSpeechSynthesisVoice(identifier:)` log 1 fault per call from any Swift task thread, 0 from a plain frame or from a GCD queue reached by `async` plus a wait. `queue.sync` from a task still faults because the block runs inline on the task's thread.
- `NSSpeechSynthesizer.availableVoices` plus `attributes(forVoice:)` for every voice logs about 930 faults from a detached task and 0 on a queue, and 48 Siri lines in either case (12 at enumeration and 6 for each of the six Siri-era identifiers only `say` keeps, which AppKit looks up by language and name and cannot find).

So the fix had two halves. #269 stopped the scan (catalogue from AV identifiers, `say` list once per process and only when needed, refreshes on a GCD utility queue). #264 made the rule hold: the bridge for element calls, the guard for listings from Task closures, and the voice-object cache so no reading or preview looks a voice up from its task. The guard's reach is what keeps this from coming back; its known gaps are in section 4.

Two reporting lessons came with it. First, early timing claims (a 7.7 s scan, 10× slower off-main) were taken while two builds ran in parallel; on an idle Mac the full scan takes 0.37 to 0.51 s on the main thread and about the same detached (0.37 to 0.52 s); the "about 2×" in the records compares the full scan with the attributes-only pass (0.37 s against 0.19 s). Measure on an idle machine or say the machine was loaded. Second, a capture filtered to `subsystem == "com.apple.Accessibility"` cannot count Siri lines; a review caught a "0 Siri lines" column claimed from such a capture. Count each subsystem with a predicate that includes it, or use an unfiltered `log stream --process`.

### The harnesses compile production Swift from fixed lists

`scripts/test-live-dictation.py`, `scripts/test-capture-persistence.py`, `scripts/test-reading-playback.py` and `scripts/test-read-selection-service.py` extract `AppModel` members by name and compile named production files with `swiftc`. Three PRs (#264, #265, #267) failed CI's "Harnesses and StageKit" job until those lists were taught the new files (`InsertionBoundary.swift` from #265, `AccessibilityBridge.swift` from #264, `ReadStart.swift` from #267 and its draft rule) and the renamed or added members (`selectedTextRefusal`, `readSelection(_:)`, `draftWasHeard`, the `readingWaitsFor…` members, `insertionContext`). Two branches adding a file to the same list also conflicted in `scripts/test-live-dictation.py`.

Rule: run `bash scripts/test.sh harnesses` before pushing any change to LocalVoice delivery, `AppModel` or Read, and grep `scripts/` for every file and member you add or rename.

### The sharing-indicator geometry faults are not Workbench layout

The 486 `Invalid view geometry` lines (243 width/height pairs) reproduced under no render. The persisted backtraces, symbolised with lldb, all run `_NSViewValidateGeometry` ← `-[NSView setFrameSize:]` ← `-[NSThemeFrame _positionSharingIndicator]` ← `NSWindowSharingSessionRecipientIndicator` ← `-[NSWindow _setIsSelectivelyShared:]` ← a SkyLight selective-sharing notification. That is AppKit positioning its window-sharing indicator when another process captures a Workbench window (an agent's screenshot tooling, for example). No Workbench frame is on the stack. The same week's log carries the identical stack in Finder, Safari, TextEdit, QuickTime Player and Chrome (a broader `log show --style json` query than the field count found 1,716 entries across processes: Workbench 840, Chrome 384, a LocalVoice render process 162, Safari 144, QuickTime 78, Finder 66, TextEdit 42). A scratch harness sending `_setIsSelectivelyShared:` over 11 title-bar configurations never created the indicator, so there is no deterministic reproduction and no blind title-bar change was made.

### Two branches rewrote one function

#264 and #269 both rewrote `MacVoiceCatalog.installed()` in `ReadingVoices.swift`: #264 to route the per-refresh `say` scan through the bridge, #269 to remove the scan. A naive resolution keeping #264's body would have reinstated the scan on every activation. The lead decided that the root-cause fix (#269) owns the function and reshaped #264 on top of it: the bridge lost its voice section, the queue hop and the semaphore, and gained the guard's Task-closure rule and the voice cache instead. #264's final head carried #269 and #265 merged in, so the five check modes were measured on the combined tree.

Rule: when two streams will touch one function, name the owner in the briefs or sequence the streams; and when a review finds the conflict, decide which fix is the root cause before resolving.

A second, quieter form of the same problem: #267 and #269 each added a local named `tiers` to the same check function on different lines. `git merge-tree` reported both branches clean against each other, every reviewer's merge check passed, and the merge queue's combined build failed with `invalid redeclaration of 'tiers'`. A textual merge check is not a build. Before queueing sibling branches that touch one file, build their combined tree once (merge the siblings into a scratch checkout and run `swift build`), or queue them one at a time and let each rebase.

### Process lessons

- **Independent review earns its cost.** Across the seven streams the reviewers found one P1 (the paste fallback leaving fitted words on the clipboard), thirteen P2s (a single serial queue putting the voice listing in front of every element call from a task; the guard missing the flood's own shape; the 0-fault bar not yet met on the reshaped bridge; a "0 Siri lines" column claimed from an Accessibility-only capture; a bullet line treated as mid-sentence; the two delivery paths leaving different words on the clipboard; a panel row covering the Read page it had just opened; a voice change turning a heard draft into a review; a silent Read refusal during dictation; Settings › Models wiping a kept download failure; Snap & Talk misreading Models' own apply as a failure; a registry re-sort conflicting with a sibling; the one-function conflict) and the rest P3. Every finding was reproduced by the reviewer before it was reported, and every P1 and P2 was fixed or decided before queueing.
- **CI runner contention.** The merge queue, several PR runs and post-merge push runs compete for five macOS slots; the queue waits seen on GitHub's timeline were 37 minutes (#269), 44 minutes (#268), 76 minutes (#270) and 90 minutes (#273). A post-merge push run duplicates the merge-group run that validated that exact tree and can be cancelled; a PR run for a superseded head can be cancelled.
- **Merge through the queue** with `gh pr merge <n> --repo Ship-Work/workbench --merge`, the spelling [docs/updating.md](../updating.md) documents (the old `EthDawg/workbench` spelling still redirects there). It enables auto-merge while checks are pending. Post the independent review on each PR before queueing; the lead reads every diff first-hand.
- **Fault counts are measured** with `log stream --process LocalVoice --predicate …` started a couple of seconds before each `--check-*` mode and ended a few seconds after, with the predicate naming every subsystem being counted.
- **Installed-app acceptance stays with the shared Preview's integration owner.** This lead verified from signed scratch builds and the project's check modes only, and never installed, launched or quit the installed editions.
- **Worker reports are claims.** Several "before" counts were the implementer's number until a reviewer rebuilt base from `git archive` and reran; several README SHAs named the base rather than the rendered head. Ask for the rerun and the head SHA.

## 4. Decisions not to build

| # | Idea | Where it came from | Why not now | What would change it | One-line switch |
| --- | --- | --- | --- | --- | --- |
| 1 | A queue hop or semaphore for AX element IPC | #264's first design | The probe showed `AXUIElement*` IPC never logs the fault from any context; the hop added a main-thread wait behind the voice listing (measured 669 to 676 ms cold) for no benefit | A macOS release where element IPC starts logging the fault; the bridge is the one place to add the hop | `AccessibilityBridge.perform` |
| 2 | A process-wide 1 s AX messaging timeout | #264's first design | Kept Apple's default plus the existing per-call budgets (0.03 s and 0.02 s in live delivery); a 1 s ceiling could turn a slow Electron tree's first enable into a Copied fallback where 6 s succeeded | Measured hangs attributable to the default, from spin or hang diagnostics on the installed app | `AccessibilityBridge.setMessagingTimeout` call sites |
| 3 | A change for the negative-geometry faults | field evidence; #273 | AppKit's sharing indicator, no Workbench frame, same stack in five other apps; no reproduction without a capturing process | A reproduction with no capturing process. Test by capturing the Home window with `screencapture -l <windowID>` while watching `log stream --predicate 'subsystem == "com.apple.runtime-issues"'`; if the pairs appear only then, the attribution stands | none; a title-bar change would be a guess |
| 4 | Listing the five say-only voices by default | #269 | They are Siri-era Indian English voices with no word timing, reachable only through the `say` scan that caused the fault flood; a saved choice still works and still lists them | Someone asking for them | `MacVoiceCatalog.needsSayVoices` |
| 5a | A Snap remembers its app and window | scout candidate 4; #64; the Snap row in [docs/utility-comparison.md](../utility-comparison.md) | Quality of Snap, but it adds fields to the Snap record, which needs the migration backup and old-binary readability statement [docs/updating.md](../updating.md) requires; window titles can hold private text; not a verb-trust fix | A Hand off recipe or #64 scope that needs the source context, with the privacy rule (optional, editable, never required by search) decided | n/a |
| 5b | One set of marks on screen and on a Snap, plus select-and-move on screen | scout candidate 9; #19; the Names rule in [docs/workbench.md](../workbench.md) | A large StageKit Draw change (hit testing across displays, keyboard focus during a demo, two renderers to keep aligned); Draw does not rise in the maintainer's asks | #19 being assigned, or Draw rising in the asks | n/a |
| 5c | The Snap & Talk deck through the connected Hand off | scout candidate 2; #63; the guide's "Explain your screens. Get a deck." | The product contract keeps rich-file skills on the manual route and Workbench runs no helper itself; a generated deck is not verified for faithfulness; the task cards live in History, which the Codex lead owned this round | A skill runner that can return files safely, and a deliberate change to the contract's rich-file wording | n/a |
| 5d | Agents reach History search and Read aloud | scout candidate 10; #131 | A new integration; [docs/utility-comparison.md](../utility-comparison.md) says it needs the maintainer's explicit go before work starts; consent must live inside Workbench because harness flags cannot confine an agent | The maintainer's recorded decision on #131 | n/a |
| 5e | A repeatable installed-app acceptance runner | the maintainer's repeated ask; #164 | Partly served by `scripts/verify-preview.sh` and the Codex lead's history acceptance host; driving the installed Preview with a pointer needs an approved route | An approved way for agents to drive the installed Preview with a pointer, decided by the maintainer and written into the contributor workflow | n/a |
| 6a | Keep a mid-sentence Title-case first word as dictated | #265 taste call | The dictionary and the field's own text are better evidence than the recogniser's capital; the fixture set records the choice | The maintainer preferring the dictated capital | `InsertionBoundary.keepReason` |
| 6b | Pause as the pill's primary while playing | #267 taste call; reverses #211 | Stop is the action people reach for from the pill and the key; Pause and Resume stay one step away | The maintainer preferring Pause on the pill | `ToolbarNextAction.resolve` |
| 7 | Guard rules for `Task.init`, `addTask`, `async let` and `Task.immediate` | #264 review | The guard's Task-closure rule is textual and tracks `Task {` and `Task.detached {` only; none of the other forms appear in `Sources` today (one unrelated `addTask` in StageKit's Core) | Those forms appearing in `Sources`, or a listing made from an async function that a Task calls (the checks use an off-main helper for that case rather than the guard) | `scripts/check-accessibility-bridge.py` |
| 8 | Closing the voice-cache staleness window | #264 review | When a listing is already in flight during `availableVoicesDidChangeNotification`, the refresh is skipped and the cache can refill with the old set until the next activation; it self-heals, and the only effect is a removed voice being used once instead of reported missing | A report of a removed voice being used after a change in System Settings | `AppModel.refreshVoices` pending guard |
| 9 | The writing-model download line in the floating toolbar's hint | #270 | The hint's runtime expression is a registry ID, so the line would be a new status entry; the panel's readiness row carries it, and so do Models, Dictate, Dictate settings and Home | A registry decision that the toolbar hint may carry readiness | n/a |
| 11 | Merging #267 (Read reads the selection) while PR #278 proposes retiring Read | PR #278, another lead, 6 October | Retiring a capability is the maintainer's decision under the Grammar; the other lead asked for the hold, so #267 left the queue and went back to draft with its review on record | The maintainer's decision on #278: if Read stays, `gh pr merge 267 --repo Ship-Work/workbench --merge`; if Read is retired, close #267 and let #284 remove Read's registry entries and voice picker | n/a |
| 10 | Home's engine spinner during Settings › Models' own apply | #270 fix pass | Home shows a spinner only for `model.preparing`; Models' own Use Parakeet sets ready false without preparing; the Snap & Talk warning and the second Retry model were the defects and are fixed | A report that Home looks idle while Models is preparing | `WorkbenchHome` engine banner |

## 5. Owed native acceptance

All of these are for the shared Preview's integration owner, on a signed Preview installed in place with Copy build details recorded. None is claimed from the check modes or the renders.

**#264 AccessibilityBridge**
- Run the installed app for a day, then count `log show --last 1d --predicate 'process BEGINSWITH "Workbench" AND subsystem == "com.apple.Accessibility"'`; the expected count is 0 lines for `unsafeForcedSync`.
- Dictate into another app's field through the bridge, including a Sublime window; the checks represent these synthetically only.

**#265 insertion fit**
- Dictate mid-sentence, at a sentence start and at a bullet into TextEdit, a browser textarea and an Electron composer (Claude or ChatGPT desktop); confirm the spacing and capitals, and that ⌘V afterwards pastes the transcript as dictated.
- Dictate a known name mid-sentence with and without it in the dictionary; confirm the lowercasing rule reads as intended (section 2 taste call).
- Known gap: a cancellation that lands during the 1.2 s confirmation poll leaves the fitted words on the clipboard.

**#267 Read reads the selection**
- Select text in a browser, a PDF and a Mail message and press the Read key (shortcut 6), the pill's Read and the panel row; confirm it reads at once, the pill shows Stop reading, and the panel row returns focus to the app only when a reading started.
- Press Read during a live recording; confirm the Read page opens with the wait reason and keeps the selection.
- With VoiceOver on, confirm the row's Options menu and the Stop reading label are announced.
- Open the panel's Voice menu with the neural engine downloaded and with Speko (no Voice submenu by design).

**#268 Timer Position… and Persona refusal**
- Open Position… from the menu-bar panel's Timer Options while a countdown runs, and from Home's current work before the window first opens; confirm the control appears at the pointer, takes the keyboard, and the panel's own close-on-focus-loss does not dismiss it.
- Press Escape in the control; confirm keyboard focus returns where it was.
- With Settings › General › Appearance forced to Light or Dark, compare the Timer's Position… panel with the toolbar's (the review's P3).
- Turn on React to my voice with the microphone refused; confirm the switch stays off, the reason shows with Microphone Settings…, and the stale refusal clears once allowed. `--check-persona-voice-native` via `open -n` needs a real microphone grant.

**#269 Read voice catalogue**
- Time launch and the first activation refresh; confirm no visible pause on app switch.
- Install or remove a voice in System Settings; confirm `availableVoicesDidChangeNotification` refreshes the picker.
- With a saved say-only choice (one of the five), confirm Read still speaks with it and the picker lists it.
- Compare the Voice picker in the signed build with the render.

**#270 app-owned Ollama downloads**
- Start a real Ollama pull in Settings › Models, change page, come back, press Cancel; then start again and quit the app; confirm the download continued, Cancel stopped it, and quit cancelled cleanly.
- Cause a real refusal (Ollama not running); confirm the failure line on Home and Dictate, and that opening Models keeps the reason until Save.
- After a completed download, make the first Natural capture.
- In Snap & Talk, click Retry model and Models…; with VoiceOver, confirm the new lines read.

**#273 layout faults**
- Leave Settings › Keyboard mid-practice; confirm it stops within a turn.
- Open and resize the image preview; confirm the zoom label updates.
- After a day of use, confirm `Publishing changes from within view updates` no longer appears in the installed log.
- Run the geometry test in section 4, row 3.

## 6. Candidates for the next batch

Ranked by the maintainer's asks and the field evidence, each classified by the Grammar and tied to an issue.

| Rank | Candidate | Grammar | Issue | Why it ranks here |
| --- | --- | --- | --- | --- |
| 1 | A Snap remembers its app and window, shown in details, searchable, carried into Hand off | Quality of Snap (record format change with a migration statement) | #64 | Snap is the most used capability in the field evidence; the privacy rule and the migration statement are the whole design cost |
| 2 | Native acceptance of this batch, then the open #134 owner checks (Option-V into Sublime, Claude and ChatGPT desktop; toolbar and Persona drags to each edge; one real call; Persona camera during Zoom) | not a product change | #134, #164 | The batch is only source-checked until section 5 is run; the #134 checks have been owed since 1 October |
| 3 | A repeatable installed-app acceptance runner with an approved pointer route | new capability for the maintainer (contributor tooling, no product surface) | #164, #7 | Asked eight times across four sessions; each batch pays the same acceptance debt |
| 4 | One set of marks on screen and on a Snap; select and move a mark on screen with one Undo | Quality of Draw | #19 | Named by the contract's Names rule; medium size; waits for Draw to rise in the asks |
| 5 | The Snap & Talk deck through the connected Hand off | Option of Hand off | #63 | Finishes the guide's promise; blocked on a safe file-returning skill runner and a contract change |
| 6 | Agents reach History search and Read aloud with consent shown in Workbench | new capability, needs the maintainer's decision | #131 | Agreed in principle; a prototype worked; cannot start without the recorded go |
| 7 | Keychain reads off the main thread: the signed scratch build's `--check-core` and `--check-reading` each log 12 `com.apple.runtime-issues:Security` lines ("This method should not be called on the main thread") from the integrations and provider checks, and the installed log carried 108 of them in the week | Quality of Settings (connections) | #7 | The last recurring non-Accessibility fault family in the installed log once this batch lands; small and measurable with scripts/verify-preview.sh |
| 8 | The #268 review polish (suite theme on the Timer's Position… panel, "Return or Space" hint, README SHA) and the Home spinner note from #270 | Quality of Timer, Quality of Models | #134 | Small; fold into the next Timer or Models change |

Not candidates: anything that opens a new place or result list outside History, a second engine chooser, a new toast with its own timer, or a change to a system setting (the contract's rules 3, 5, 9 and Fit rule 7).

## 7. Sources

Verification folders (each README names what was rendered or measured, the counts and what remains untested):

- `docs/verification/2026-10-06-ax-bridge/` (README, `axprobe.swift`, `run.sh`; arrives with #264)
- `docs/verification/2026-10-06-fit-timer-persona/` (on `main`)
- `docs/verification/2026-10-06-fit-models/` (arrives with #270, merged after this record's base)
- `docs/verification/2026-10-06-layout-faults/` (README only; arrives with #273, merged after this record's base)
- `docs/verification/2026-10-06-read-selection/` (arrives with #267)
- `docs/verification/2026-10-06-read-voice/` (on `main`)

Scripts and check modes:

- `scripts/check-accessibility-bridge.py` and `scripts/test-accessibility-bridge.py` (harness phase of `scripts/test.sh`; arrive with #264)
- `scripts/test-live-dictation.py`, `scripts/test-capture-persistence.py`, `scripts/test-reading-playback.py`, `scripts/test-read-selection-service.py` (the fixed-list harnesses)
- `scripts/check-surfaces.py` (registry), `scripts/test-stage.sh --ci` (StageKit), `scripts/verify-preview.sh`
- `LocalVoice --check-core`, `--check-insertion-boundary` (arrives with #265), `--check-live-dictation-delivery`, `--check-floating-toolbar`, `--check-reading`, `--check-reading-render`, `--check-reading-service`, `--check-neural-voice`, `--check-refinement`, `--check-readback`, `--check-capture-preview`, `--check-image-workspace`, `--measure-reading-latency`, `--render-surfaces`, `--render-reading-fixture`, `--render-live-voice`; `ToolbarGalleryRenderer`

Issues and PRs:

- Release gate and coordination: #7, #14, #17, #134, #137, #150, #164
- This batch: #264, #265, #267, #268, #269, #270, #273
- Deferred: #19, #63, #64, #130, #131, #140
- Earlier decisions this batch leans on: #211 (pill primary), #235 and #236 (1 October integration and review fixes), #240 (local models), #246 (live voice), #259 (2.4.1 bundle)

Contracts and records: [docs/workbench.md](../workbench.md) (Grammar and Fit), [docs/updating.md](../updating.md) (editions, migration, evidence states), [docs/utility-comparison.md](../utility-comparison.md) (agent access, Read baseline), [docs/live-voice.md](../live-voice.md) (insertion rules), [docs/design.md](../design.md) (bridge and voice catalogue sentences), [docs/releases/2026-10-05-workbench-2.4.1.md](../releases/2026-10-05-workbench-2.4.1.md).
