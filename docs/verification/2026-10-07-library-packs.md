# Library Packs: source and synthetic evidence

Foundation A2.2 implements the Packs portion of [the corrected Library consolidation specification](../mac-foundation.md#packs-earns-its-place-by-getting-content-into-a-job). Frozen source: `d7f7a2a98250ddb0b745dc1587fca5664038256e`, 7 October 2026. Base: accepted A2.1 `0edd219daa8c090fc5a84c90176a6a6269355eb3`; integration base `22b3a2d` differs only in earlier documentation and release records. Independent review begins from this exact source commit; this record does not imply its acceptance.

This is source and offscreen production-view evidence, not installed acceptance. The retained From iPhone section belongs to E's separate retirement/recovery work; its presence in these screenshots is not a completed clean-app claim.

## Implemented boundary

Installed content precedes Add and account maintenance and stays usable offline or during an unrelated operation. A deep link only prefills Add. Device sign-in retains explicit Copy code/open, cancellation and expiry recovery. Each suspension validates its operation identity before opening the browser, publishing a code, saving credentials or changing completion state. Late replies from cancelled attempts cannot replace a newer attempt.

Skills use their declared input. Dual-input skills require a local Transcripts or Snap & Talk choice. Snap & Talk's actual capture/transcription/unsaved-narration owner refuses conflicting preparation; existing session snapshots stay unchanged. Scenes and personas keep their existing personal-copy import and selection-only owners; no Show or Present action is added.

Saving a resource verifies the chosen file, creates its ordinary Library reference and selects Resources for Open file. Cancel exports nothing. A failed reference retains the export, intended UUID and exact size/digest. Retry cannot re-export or adopt changed bytes. Explicit retry can review held Library storage in the same owner, then add only the reference; missing/corrupt storage and pending editor/import work remain intact. The temporary recovery context is not a new persisted store. After quitting, the chosen original remains available for Resources → Add local file.

PackStore's existing immutable releases, staging, complete payload validation and atomic activation remain unchanged. A cancelled operation reports that an already-completed atomic change may remain and reloads the actual installed store. Remove and Disconnect stay distinct. Neither deletes personal copies or session snapshots. Appearance and its existing Reset/automatic-update preferences retain their original storage.

## Page-local control inventory

| Control / state | Decision and owner | Admission / lifecycle |
| --- | --- | --- |
| Library → Packs; sidebar, section and menu aliases | Keep existing route | Opening refreshes local installed content only. No connection or install starts. |
| Empty Add a pack…; installed Add a pack… | Keep one contextual entry per state | Opens the same local Add form; ordinary tools need no account or pack. |
| Repository field; Return; Add pack; Done | Keep existing source parser and install owner | Deep link prefills only. Add requires a connection and idle operation. Done closes local setup, not a download. |
| Connect GitHub / Reconnect; code selection; Copy code and open GitHub; Cancel | Keep existing device authorization | Explicit connection starts it. Clipboard/open errors are factual. Cancel retires the operation before late challenge/account callbacks. Expired code leaves no active challenge or credential. |
| Pack owner setup; repository link; Open source and contribute | Keep explicit external links | No browser launch merely from opening the page. The account/App access requirement remains visible in Add. |
| Pack settings; Disconnect; Keep packs up to date automatically | Keep, secondary to content | Same stored preference. Disconnect affects the account only. The timer/update owner is unchanged. |
| Pack actions menu; Check for updates; progress; Cancel | Keep existing PackStore transaction | Mutation buttons block conflicting pack mutations, not content use. Affected-pack progress/error stays on its card; first-install/global progress remains visible. |
| Use skill; Use with transcripts; Use with Snap & Talk; Cancel | Refine existing preparation | A dual-input entry cannot silently choose. Single-input entries use only their declaration. The selected tool starts nothing; Snap & Talk refuses busy/unsaved state. |
| Add scene; Add persona | Keep existing import owners | Personal copies become selected in Present/Persona; no Show/Present. Source updates/removal do not change them. |
| Save resource…; native Save Resource destination / Replace / Cancel | Close existing disk-only action | File bytes are verified before the Library commit. Only success returns to selected Resources. The native chosen-original replacement decision remains explicit in NSSavePanel. |
| Saved file details; Add saved file to Library; Show saved file; Keep file only | Contextual recovery of that export | Details retains its location. Retry verifies exact bytes and the same UUID, reviews valid current held Library storage only without pending edits/import review, and never opens a second export panel. Keep file only leaves original and any already committed reference unchanged. |
| Resources Open file after success | Existing ordinary file owner | Nothing is opened automatically. Existing Locate/Quick Look/Show in Finder behavior is unchanged. |
| Remove pack…; Remove pack; Cancel | Keep confirmation | Removes only owned downloads. Confirmation closes on cancellation; personal copies and sessions remain. Resources removal is a separate page-local confirmation and cannot be active on the Packs retry route. |
| Workspace appearance; Use workspace appearance; Reset | Keep, secondary disclosure | Same brand identity/preference; Reset clears appearance, not content or account. |
| Installed-file repair error | Persistent per affected card | Unverified entries are unavailable; unrelated notices cannot hide the card's repair explanation. |

The surface scanner now includes the production Packs view and its dynamic entry action. It records 34 Packs controls, including previously unscanned existing controls, while preserving all 587 preceding entries and their order. This is not 34 new product actions. Native code selection and save-panel choices are included above although not separate registry entries.

## Verification

All checks use synthetic stores, isolated preferences and injected repository/credential/browser callbacks. No installed app, private records, real provider, repository download, permission change or external account was used.

| Command | Result |
| --- | --- |
| `swift build -c release --product LocalVoice --disable-automatic-resolution` | Exact frozen source passed in 108.20 seconds; existing deprecation warnings remain. |
| `.build/release/LocalVoice --check-readback-pack` | 32 retained session/pack checks plus 32 new production-owner checks. |
| `.build/release/LocalVoice --check-readback` | 276 checks across saved sessions, admission, capture choice, availability, recovery, immutable pack snapshots and ordering. |
| `.build/release/LocalVoice --check-core` | Passed, including 221 shared control checks, 106 page checks, 45 prompt-picker checks, 20 Resources checks and retained Library/Quick Look, insertion and feedback checks. |
| `swift test --disable-sandbox --disable-automatic-resolution --filter PrivatePackKitTests` | 18 tests passed: auth/transport, source/path validation, atomic activation, interrupted update, prior-version retention, incompatible release, tampering, and the new invalid replacement check. |
| `python3 scripts/test-library-recall.py --import-review` | 54 retained production-owner import checks passed after adding the explicit reference-retry reload. |
| `python3 scripts/check-surfaces.py`; `python3 scripts/test-check-surfaces.py` | 621 registered entries; 58 scanner tests passed. All preceding registry entries retain their order. |
| `WORKBENCH_PACKS_GALLERY_ONLY=1 .build/release/LocalVoice --render-surfaces .build/library-packs-final-gallery` | 12 light/dark production renders at 1050 × 730 content size; 3 existing catalogue entries, zero flags. |
| `git diff --check` | Passed before source freeze. |

Local detailed logs use `.build/library-packs-` with suffixes `build.log`, `checks.log`, `readback.log`, `core.log`, `package-tests.log`, `import.log`, `surfaces.log`, `scanner-tests.log` and `gallery.log`. They are local verification artifacts, not user data or public account evidence.

The new owner checks execute real PackStore installation/loading, then prove offline use without credential saves/browser launches, explicit dual-input admission, actual in-flight capture and unsaved narration refusal, retained immutable session bytes, deep-link prefill, Disconnect/Reset separation, exact file/reference success, Save Cancel and write failures, missing/changed file refusal, and pack removal without deleting personal work. Controlled delayed challenge/account replies exercise cancel → new attempt → old reply, including no stale browser launch or credential save, expiry and one successful current authorization.

The same-owner recovery regression starts with a successful resource, changes saved Library bytes externally, then attempts a second resource export. Its original is written, the reference commit refuses the newer store and the Library holds writes. The same Library object then refuses retry while an editor draft is present, while its file is missing, and while its file is corrupt, retaining readable records and the exact pending export identity. A separate active import review likewise cannot be discarded by retry. After restoring a valid current Library, same-sized changed export bytes still refuse recovery. Restoring the exact export permits one reference with the retained UUID, preserves the newer saved record, clears the hold, selects the file and increments neither export count nor chooser count. A separate new Library object is not used to bypass the production hold.

The atomic-update regression downloads a same-sized incorrect replacement into the actual PackStore. It verifies that `active.json` remains byte-identical, the prior version and complete original payload remain usable, and an already-frozen skill remains at its previous version. Existing cancellation and incompatible/mutable-release checks also pass. No PackStore production code changed.

## Render inventory and review

Both themes render these actual production states: fresh empty Packs, explicit Add prefill, pending device code, verified installed content while disconnected, refused offline update with content still usable, and saved-file/reference recovery. The gallery injects the existing Packs owner into WorkbenchHome so it never reads real credentials, contacts GitHub or opens a browser. Layout/text were visually reviewed at minimum width; controls remain readable and recovery shows a filename before collapsed full-path details.

Representative renders from the original source, with the recovery instruction updated by the copy correction recorded below:

- [Fresh Packs](2026-10-07-library-packs/empty-light.png)
- [Explicit Add](2026-10-07-library-packs/add-dark.png)
- [Device code and cancellation](2026-10-07-library-packs/device-code-light.png)
- [Offline installed content](2026-10-07-library-packs/offline-light.png)
- [Refused update preserves content](2026-10-07-library-packs/update-refused-light.png)
- [Saved-file reference recovery, current instruction](2026-10-07-library-packs/reference-retry-contextual-dark.png)

The dynamic skill choice, pack action/removal menus, expanded appearance settings and native save-panel interactions have source/owner checks and registry coverage; the offscreen pass does not claim their native presentation or focus behavior.

## Remaining native acceptance

Still required on the exact signed candidate: keyboard-only focus/Return and the dual-input confirmation, VoiceOver, real GitHub code/copy/browser/expiry/cancel behavior, actual file chooser Cancel/Replace/access denial, successful file-to-Library/Open return, scene/Persona copy selection without Show, and real update cancellation/offline access. The synthetic checks establish owner and transaction behavior, not those OS/account/receiver results. An external account may need its existing GitHub App repository grant; no setup bypass is introduced.

## Independent-review repair: initially unheld stale references

Repair source `d5db791d012cd776ef7b432b7e6cc39425bc6e48` follows the original source/evidence above. Independent review found that explicit Retry reloaded current Library storage only when `savingDisabled` was already set. A reference commit could succeed and final readback fail, leaving the intended UUID in the cache without a hold. If saved storage was subsequently restored without that reference, Retry kept trusting the stale cached UUID; missing or corrupt saved storage likewise failed without establishing the persistent Library hold.

Explicit Retry now always calls the existing current-store review before consulting a cached reference. It still verifies the pinned export first, refuses active editor/import work, and uses the same intended UUID. The existing services seam delegates final reference readback to the same `DemoLibraryStore.load()` in production. Synthetic checks inject only the precise post-commit readback boundary, avoiding timing races or a new store.

Ten additional cases begin with the real Library save succeeding, then restore a valid earlier store, remove the store, or corrupt it immediately before readback. Each verifies an initially unheld cache containing the committed UUID. Valid-store retry preserves active editor text and import choices until explicitly cleared; missing/corrupt retry establishes a persistent hold while preserving cached readable records and exact exported bytes. After valid storage is restored, the same owner creates exactly one reference with the original UUID, keeps the existing saved resource, selects the exported file and changes neither the chooser nor export counts. No second Library model bypasses the observed state.

The exact repair release build passed in 111.80 seconds. `--check-readback-pack` passed 32 retained checks and 42 Packs-owner checks. `git diff --check` passed. Logs are `.build/library-packs-retry-build.log` and `.build/library-packs-retry-checks.log`. No view/control or PackStore code changed; the original render inventory and separate native limits above remain applicable. The repair is frozen for independent review, not recorded as installed acceptance.

## Contextual recovery instruction

Source `0d90d973326d174cb5d9c464ffd8f2192042f7b4` corrects one instruction found in visual review. Packs previously propagated Library's general “Reopen Workbench” guidance, despite holding a temporary saved-file retry that could finish in place. At the known Library review, held-write and failed-save points, Packs now uses the existing typed `savingDisabled` state to explain that the file is saved, Library needs review, and **Add saved file to Library** reviews current saved contents and retries. The unchanged persistent diagnostic remains in Resources → Library details. No string replacement, global Resources wording change, new control, state or store was added.

The catch-all error path remains unchanged. File verification, pending drafts/imports and final readback retain their specific explanations rather than being mapped to a generic storage message merely because a hold exists. The owner check verifies the contextual instruction and retained Library diagnostic; existing assertions now also check those specific failure explanations.

The exact release build passed in 104.43 seconds. `--check-readback-pack` passed 32 retained checks plus 43 Packs-owner checks. The synthetic production gallery passed 12 renders, three catalogue entries and zero flags. Both affected minimum-width renders were inspected: [light](2026-10-07-library-packs/reference-retry-contextual-light.png) and [dark](2026-10-07-library-packs/reference-retry-contextual-dark.png). The message and retry controls are readable, without the contradictory restart instruction. These supersede the original recovery render's wording; the original image remains historical evidence. Logs use `.build/library-packs-copy-{build,checks,gallery}.log`; the full render set is `.build/library-packs-copy-gallery`. Native acceptance remains separate.
