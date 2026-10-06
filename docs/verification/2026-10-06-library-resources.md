# Library Resources: source and synthetic evidence

Foundation A2.1, implementing the Resources portion of [the Library consolidation specification](../mac-foundation.md#build-ready-library-and-surface-consolidation). Source revision: `d1eb15f09b7874d358e848e79dd80ff8b3bcd2e1`, frozen 7 October after checks begun on 6 October. Base: independently reviewed combined foundation `dec1f343413b9c3ce68583e81863e6c9278ec0df`. Specification correction `9262d80d76f1ef68f3b851ad47b70fcd71ed5094` is based directly on PR297 head `792cdbe498ce71f26e801c9756c3d5b9fd7344e0`; local merge `9de5814` incorporates that corrected lineage.

This is source and offscreen render evidence, not installed acceptance. Packs is the next separate A2 slice. Photo/cloud retirement and conditional recovery remain E's work; the retained From iPhone section in these renders is not a completed clean-app claim.

## Implemented boundary

Resources now uses neutral labels and puts search, favourites and the selected resource's useful action first. Files show a filename and short folder, with full path, Copy path and Change file under File details. Missing files offer Locate file as their primary action. Choosing a replacement only prepares a draft; Save commits it. Cancel, stale records and access failures leave the original reference and files intact. Remove confirms the named Library record and rejects an obsolete changed-record snapshot.

Creating a prompt uses complete text or refuses the existing 50,000-character limit before opening an editor. Nothing is silently truncated. Clipboard and Dictate-text entry share this admission. Persistent storage failures have a separate write hold and Library details, so successful Copy or dismissing an action error cannot conceal an unreadable or externally replaced saved Library.

The retired `speak` route now lands on Resources without starting work. This is new A2 behavior; H previously fell back to Dictate. Visual inspection caught a first attempt that highlighted Library while embedded ContentView still showed Dictate. Both now consult the central resolver; the gallery requires their actual content pixels to match while a synthetic recording keeps its transcript and enabled Finish action.

Local saved browser metadata, original files and bookmarks retain their existing owners. Ordinary portable import/export still strips `browserTarget` and machine access bookmarks. G's separate saved-browser-settings export remains an inert recovery action. No new resource schema, store, browser admission, provider or permission request was introduced.

## Page-local control inventory

This inventory includes sheet fields, native panel choices and hidden keyboard actions; it is broader than the entry-point registry. Unchanged controls are included to make the review boundary explicit.

| Control | Decision and owner | Admission / lifecycle |
| --- | --- | --- |
| Resources section; Library sidebar/menu/shortcut | Keep, `WorkbenchHome` destination record | Navigation only. The old `speak` alias resolves the same visible content. Packs/From iPhone are unchanged here. |
| Saved Prompts… | Keep A1's Library-only picker, `PromptPickerController` | Opens with no inferred external target. Exact Copy and truthful failure remain with Library; no automatic submit. |
| Picker search, Category → All prompts / Product / Persona, prompt rows, Copy prompt | Keep existing picker owner | Favourites first, each prompt once, frozen picker records; arrows/Return choose the highlighted prompt, Escape/outside/choice closes. |
| Picker Open Library… / Show all prompts; last-result Details / Hide details; Stop inserting | Keep existing empty/filter/status recovery | Empty picker returns to Library, no-match clears filters, Details retains its attempt. Stop belongs to the separately guarded insertion owner; Library's nil-target invocation only copies. |
| Add → New prompt, New link, Add local file… | Keep, `DemoLibraryModel` | Editor draft first; explicit Save. Held storage/import review blocks new writes. File chooser Cancel writes nothing. |
| Add → Save clipboard as prompt…; Save Dictate transcript as prompt… | Keep/clarify, same prompt admission | Full text; Dictate action disabled when empty. Oversized text is refused with file guidance. Clipboard is read only after the chosen action. |
| Search resources; Favorites only; resource rows; split-view divider | Keep existing query/selection owner | Current filtered selection owns Return; no new persistence. Changing filters cannot invoke a previously rendered primary action on another record. |
| No match → Clear filters | Keep | Clears query/favourites only. No selection shows a quiet instruction. |
| Fresh Library → Add a prompt / Add a file… / Add a link | Keep useful first-use aliases | Same editor/chooser owner. Unreadable storage shows recovery instead of an editable empty Library. |
| Hidden ⌘F / ⌘N / ⇧⌘S; Return from search/list | Keep existing aliases, strengthen focus guard | Draft/import/removal, attached sheets, key/main window, marked text, editing, modifiers and repeat policies retain admission. Native IME/focus timing remains an acceptance gate. |
| Copy prompt; Open link / Open in default browser; Copy link | Keep selected-resource actions | Exact full prompt copy; explicit ordinary browser opening. Legacy bindings stay local and explain paused switching. |
| Open file / Locate file… | Refine primary action, existing file owner | Missing/unreadable references offer explicit choice. Replacement stays a draft until Save; write hold disables replacement, not safe use of readable resources. |
| Quick Look; Show in Finder | Keep direct secondary actions | Existing supported-type checks and security-access lease lifecycle. Executable files cannot be launched. |
| File details → full path / Copy path / Change file… | Move secondary material into disclosure | Full path remains selectable/copyable. Change appears for available files and uses the same review transaction. |
| Use in Present… / Use in Persona… | Keep existing image preparation | Supported selected image only; immutable snapshot and existing editor. Cancel does not save, present or show artwork. No Present/photo implementation changes. |
| Favorite resource / Remove favorite; Edit; Remove resource | Keep selection-scoped mutations | Write hold disables them. Removal names its frozen record, offers Cancel and never deletes its external file; stale changed records are rejected. |
| Editor Name, Product optional, Persona optional, Prompt TextEditor / Link URL / file reference, Notes optional, Favorite | Keep existing fields, clarify labels | Complete content is reviewed. Metadata/schema unchanged. Validation explains limits; native text selection and Cmd-C remain native. |
| Editor Save / Cancel | Keep transaction owner | Save commits only validated input and closes on success. Cancel discards draft. Failure retains the draft; persistent storage hold shows Library details. |
| More → Import library… / Export library… | Keep portable exchange | Import review precedes mutation. Export explains its references and excluded media/access grants/browser bindings; no bundled-media or filtered-subset claim. |
| Import row selection; Keep mine / Use incoming; Review again; Apply import / Keep library; Cancel | Keep existing import owner | Default Keep mine, complete comparison, atomic chosen changes. Failed save retains choices; changed storage requires review again. Cancel writes nothing. |
| More → Export saved browser settings… | Keep G's conditional recovery | Visible only with retained settings, inert export only. No switching setup, browser listener or import/re-enable path. |
| Dismiss library error; result notice | Keep action feedback separate | Dismisses only the action error. Cannot remove persistent storage failure/write hold. |
| Storage failure → Library details / Show saved library | Refine persistent recovery, same saved store | Preserves unreadable/newer bytes. Reopen after resolving the file; applicable exports/readable-resource actions remain available. |
| Read preservation → Details / Retry saving Read text / Show original saved state | Keep H's conditional recovery unchanged | Original source retained, exact Library file, separate completion receipt and no resurrection. Empty profiles show no recovery. |

`DemoLibraryView` is now a controls root in the surface scanner, including its editor. The registry has 587 entries, up from 541 on the combined base; most additions record previously unscanned existing local controls. This is not 46 new product actions. TextEditor and native chooser behavior are also covered above even though they are not registry entry points.

## Passed checks

All inputs were synthetic: isolated saved stores, preferences, clipboard/open callbacks, file choosers and existing offscreen gallery homes. No installed app, private data, provider job, download, cloud operation or permission change was used.

| Command | Result |
| --- | --- |
| `swift build -c release --product LocalVoice --disable-automatic-resolution` | Release build passed. |
| `.build/release/LocalVoice --check-core` | Passed, including 20 new Resources owner checks, 45 prompt-picker checks, 19 insertion checks, 221 shared control checks and 106 page checks. |
| `python3 scripts/test-library-recall.py` | 31 checks; real extracted Library owner and destination record, injected opening/chooser, Return/IME/selection boundaries. |
| `python3 scripts/test-library-recall.py --import-review` | 37 checks; Keep mine/Use incoming, cancellation, failure/retry, concurrent writes and portable sanitization. |
| `python3 scripts/test-library-recall.py --image-reuse` | 30 checks; existing image export, exact bytes, preparation and partial-result boundaries retained. |
| `.build/release/LocalVoice --check-read-retirement` | 43 checks; exact large legacy text, two model reloads, incomplete/corrupt/full-library recovery and deliberate deletion without resurrection retained. |
| `python3 scripts/test-read-retirement.py` | Four source-boundary tests; safe alias does not restore TTS/Service/shortcut/runtime admission. |
| `python3 scripts/check-surfaces.py`; `python3 scripts/test-check-surfaces.py` | 587 entries; 58 scanner tests passed. |
| `WORKBENCH_RESOURCES_GALLERY_ONLY=1 .build/release/LocalVoice --render-surfaces .build/library-resources-gallery` | 20 light/dark production views at the minimum 1050 × 730 content size, five existing catalogue entries, zero flags. Actual old-route content matches Resources and active Finish remains available. |
| `git diff --check` | Passed. |

Detailed logs are local `.build/library-resources-*.log`; all 20 renders and the gallery report are under `.build/library-resources-gallery`. Representative reviewed renders:

- [Fresh Resources](2026-10-06-library-resources/empty-light.png)
- [Complete prompt](2026-10-06-library-resources/prompt-light.png)
- [Available file](2026-10-06-library-resources/file-light.png)
- [Missing file](2026-10-06-library-resources/missing-light.png)
- [Persistent storage hold](2026-10-06-library-resources/storage-held-dark.png)
- [Old route displays Resources](2026-10-06-library-resources/retired-route-dark.png)

## Remaining acceptance

The signed candidate still needs native keyboard-only recall, IME composition, focus return with real editors/import sheets, actual clipboard Copy, Locate Cancel/Save and denied/moved-file access, Quick Look closing/reopening, VoiceOver and larger text. Offscreen renders and injected tests do not establish those results. Active presentation/Persona hardware and end-to-end update behavior were not exercised. Existing shared control checks cover Stop/End admission, while this gallery specifically checks a synthetic dictation's Finish during route navigation.

This slice does not validate Packs use/update/cancel/file-to-Library return or E's photo retirement/recovery. Those remain separate implementation and integrated acceptance work before the broader foundation can be declared complete.

## Independent review repair, 7 October

Source `3b20030bd61de45cbda30e2b487ad495a3042959` resolves a persistent-feedback gap found in independent review. Import Apply and Review again previously kept observed saved-store changes/read/decode failures only in the import sheet's error. Cancel could hide that error and leave Resources looking editable; the existing byte comparison still prevented the demonstrated overwrite.

Those observed faults now use the existing persistent storage hold. Cancel and successful Copy retain its warning and retained readable resources. Review again remains usable while held and clears the hold only after the current saved Library has decoded and its new comparison is ready. Import choices reset for the new comparison, incoming content survives, and a deliberate Apply can succeed. Invalid incoming choices and ordinary failed writes remain retryable without a storage hold. After Cancel, resolving the file and reopening Workbench reloads it normally.

The production import harness now passes **54 checks** (17 additional cases), including changed/corrupt/unreadable store → Apply → failed Review again where applicable → Cancel → successful Copy; held writes; successful reload; and same-review repair followed by Apply. Compiling the previous frozen `d1eb15f` Library owner with these new checks in a temporary fixture fails exactly at the changed-store Apply/Cancel/Copy persistence assertion. No working source was changed for that counterfactual run. Logs: `.build/library-resources-import.log` and `.build/library-resources-import-regression.log`.

The exact repair release build passed in 105.39 seconds and the core checks passed. Logs: `.build/library-resources-repair-build.log` and `.build/library-resources-repair-core.log`. No controls or layout changed; the existing storage-hold render shows the retained recovery surface. Native acceptance and the remaining A2/E boundaries above remain unchanged.

## Parent integration

Integration `23ffac0` carries the accepted `3b20030` implementation/evidence lineage into the branch containing current merged dependencies and the completed A1/C/H native records. The app sources, package manifests and affected harnesses are byte-identical to accepted `0edd219`; the remaining delta is documentation, including the already merged release README guidance. Parent inspection confirmed the scoped diff, three representative production renders, all 587 registry entries and a clean diff check. The independently reviewed repair's release/core/import results therefore remain the relevant source evidence; no new native claim is made for Resources before its next signed installation.


## Signed native acceptance, 7 October

The sole Preview installer verified actual Copy build details on **Workbench Preview 2.4.1 (20261006161900)**, clean source `3cb7efff04fbf5132bb52ebcde3ea64d5d356c4e`, local development, macOS 26.5.1 (25F80). Archive SHA256: `313577532952ac5970cbb0243f57f68e2a97480e043a203988571c2bd6fe350f`. The lead then used this installed candidate with uniquely owned synthetic material; this supersedes only the specific outstanding native checks listed below, not the complete acceptance boundary above.

- **Save and full Copy:** a 124-byte prompt containing Unicode, blank lines and a final newline was entered through Add → New prompt and saved. Copy pasted the exact saved text into TextEdit. After navigating away/back, selected-row Return replaced a distinct clipboard sentinel with the same complete prompt. Both receiving-app files and the saved record matched SHA256 `75cdd464ffa45784feb76c19922a52280bc79878ed4e4cda0052ad7c062d2fbb`.
- **Locate and cancellation:** making only an owned scratch file unavailable changed its primary action to Locate and disabled unusable Quick Look/Finder actions. Cancelling the chooser, then choosing a replacement and cancelling the editor, each left the exact persisted reference unchanged.
- **Explicit replacement:** choosing the replacement again and pressing Save retained the same resource UUID and metadata while adopting the replacement. Open launched the correct file in TextEdit; Quick Look displayed its complete synthetic text, and Escape returned to Resources. The visible filename/full-path detail agreed with the committed reference.
- **Pack return:** exact Pack export → selected Resources → Open, followed by removing the source Pack without breaking the personal file/reference, passed in the same candidate. [The Packs record](2026-10-07-library-packs.md#signed-native-acceptance-7-october) describes the fixture, observed actions and limits.

All three owned Library test rows and the synthetic Pack were removed through normal UI. The original seven resources and saved-state fields matched the private baseline after normal Quit. Existing Pack payload bytes stayed exact; automatic-update restoration and receipt changes are explained in the Packs record. Preview was relaunched and left idle on Home. Private baselines, exact receiving-app files, fingerprints and a partial observation record stay local; no private record or screenshot was published.

These are bounded native observations, with every whole L1–L4 journey still unclaimed and `publicationReady: false`. Full keyboard-only traversal, IME composition, held-key behavior, VoiceOver/larger text, access denial, repeated Quick Look lifecycle, actual independent live work, and production update acceptance remain unverified. No privacy reset, model download, provider job or public publication occurred.

## Library control reconciliation, 7 October

This is the bounded Library portion of foundation L4, checked against accepted source `746d85f13e17c4ee1fcfcd6ea467a10816b5b74b` (including J). It joins the existing page-local inventories; it is not whole-app control or native accessibility acceptance. All 94 Library view/picker registry IDs map to the retained controls below; the wider registry has 628 entries at this checkpoint.

| Registry prefix | Count | Owning inventory / disposition |
| --- | ---: | --- |
| `LocalVoice.DemoLibraryView.` | 51 | Keep/refine Resources and editor controls in this record's page-local inventory: types, filters, full content, file recovery, editing, import/export and conditional preservation. Native TextEditor and chooser affordances are described there as well. |
| `LocalVoice.PackLibraryView.` | 34 | Keep/refine in the [Packs inventory](2026-10-07-library-packs.md#page-local-control-inventory): installed content, account/add/update, use-to-owner, file/reference return, recovery, removal and appearance. |
| `LocalVoice.PromptPicker.` | 8 | Keep under Library: open Library, selected prompt action, prompt rows, delivery details, clear filters, category/default and conditional cancellation. Seven stale `belongsTo: present` values are corrected; no registry ID, action or shared cancellation behavior is removed. The production opener uses Copy-only context. |
| `LocalVoice.LibraryPromptButton.` | 1 | Move/keep Saved Prompts with Library, as delivered by A1. No external field is inferred and no Accessibility request is initiated by opening it. |

External entries and runtime paths are included in the same disposition:

| Entry / alias | Decision, state owner and effect |
| --- | --- |
| Dictate → More → Save prompt | Keep the page-local entry. `AppModel.savePrompt` rejects empty words, opens Library and starts its existing prompt draft. Saving or cancelling remains the Library editor's transaction. |
| History / Snap & Talk → Save image to Library… | Keep explicit selected-image export and its ordinary Library reference. The existing image-reuse owner preserves unrelated drafts; destination Cancel does not create a reference. These invoke the Resources owner rather than creating a second library. |
| Snap & Talk settings → Manage packs… | Keep navigation to Library's Packs section; navigation starts no assistant or capture. |
| Sidebar Library; Window → Library / ⌘L; global shortcut id 3 | Keep one Library destination and its search focus request. The source resolves to `AppModel.showLibrary`; native keyboard/focus behavior remains limited to the observations already recorded. |
| Copied-prompt receipt → Review | Keep return to Library via the existing clipboard receipt source kind. It does not insert again or rerun a task. |
| `speak` / `readback` / `packs` routes | Redirect retired `speak` to Resources; keep `readback` as the existing Snap & Talk identifier; keep `packs` as Library's section. Historical identifiers do not reopen Read. |
| `workbench://packs/add?source=…` and `workbench-preview://packs/add?source=…` | Keep the strict source parser. Accepted input sets a pending source and navigates to Packs, including a link received before window creation. It prefills the Add form and does not install. |
| Packs launch / activation / six-hour update check | Keep the existing automatic-update preference and operation owner. It requires an enabled preference, existing login, idle operation and elapsed interval. Navigation/prefill and this separately admitted update activity are distinct. The signed Library test restored the enabled preference and observed only existing receipt rewrites, as recorded above. |
| Retired Read/browser shortcuts id 4/id 6, Read Service and browser host | Remove/pause as specified in the [Read retirement](2026-10-06-read-retirement.md) and [browser pause](2026-10-06-browser-pause/README.md) evidence. Keep their conditional recovery and original data. |
| `photos`, From iPhone section, Home arrival cue and photo settings | **Pending E.** Current accepted source still exposes these normal doors; draft #286 does not establish conditional downloaded-file/pending-operation recovery. Do not mark them removed or L3/L4 complete. |

The structured handbook's obsolete promise that Present contains Saved Prompts is corrected to Library ownership, matching [A1](2026-10-06-foundation-ownership.md) and the production opener. Its older hardware/layout evidence retains its original revision and limits. This addendum does not claim registered controls were all physically exercised: full keyboard/IME/held-key, VoiceOver, minimum-window behavior and actual retained toggles remain distinct acceptance work. Other tools' page-local/dynamic/native controls require their owning foundation slices before final whole-app L4 reconciliation.

The related first-download surface follow-up adds the known approximate 450 MB size beside Home’s direct Parakeet download choice (isolated source `11b17e8`, integrated as `c1a7357`). It uses the existing caption hierarchy and appears only while that download choice is offered; it adds no control or preference. The speech lifecycle and signed `746d85f` candidate are unchanged by this caption. Registry validation still finds 628 entries; the three existing handbook rendering/contract tests pass. The updated Home render is checked separately before this follow-up is accepted.
