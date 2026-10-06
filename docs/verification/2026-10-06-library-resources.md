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
