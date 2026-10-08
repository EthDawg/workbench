# The Workbench window

This is the owning contract for the Workbench window: what it is for, when it shows, how its pages are built and what Home does. [floating-toolbar.md](floating-toolbar.md) does the same for the toolbar. The [product contract](workbench.md) still owns names, the Grammar and the three surfaces; [the focused Mac foundation](mac-foundation.md) still owns scope and journey acceptance. Where this file and an older Home description disagree, this file's dated decisions win.

Decided 7 October 2026 at Ethan's direction: “the surface area should actually be relevant, not just linked to tools that you can access via the menu”, with a permissions panel, a meeting recap and a set of assets made with the app. The record and later slices are tracked on [#7](https://github.com/Ship-Work/workbench/issues/7).

## What the window is for

The menu-bar panel starts and stops things in a second. The floating toolbar carries live controls while you work. **The window is where you prepare, review and set up.** It never needs to be open for a tool to work.

Home holds only what the app shows nowhere else in that form. Everything else is one click away in the sidebar or History. In order:

1. **What's running?** Current work, with each live thing's own Stop or End.
2. **Where do I start?** Only while someone has never dictated: the first-dictation guide.
3. **What did I make that I'll come back to?** Your meetings, ready to copy and follow up; your Snap & Talk decks, ready to open or continue. Dictations and Snaps are passing captures; they stay in History.
4. **What can Workbench use on this Mac?** Permissions, with what each is for and what still works without it.
5. **Which keys are worth learning?** Your keys: the one-hand layout and the next three to practise.

**Home shows state and results, never a list of tools.** The sidebar is the list of tools. A button on Home sits beside the thing it acts on: a meeting's Copy transcript, a deck's Open deck, a permission's Set up…, a key’s Practice.

## When the window shows

| Event | The window |
| --- | --- |
| First launch ever | Opens on Home. The Permissions panel is the setup; nothing is asked until the person presses Set up…. |
| Launch at login (Settings › General › Open Workbench at login) | **Stays closed.** The menu-bar icon and toolbar are ready; the Dock, the panel's Open Workbench and ⌘0 open the window. If macOS does not mark the launch as a login launch, the window opens as before. A pack link always opens it. |
| Any other launch (Finder, Spotlight, Dock, after an update) | Opens on Home. |
| Dock click, or Window › Open Workbench (⌘0), while running | Comes forward on the page it was showing. The menu-bar panel's Open Workbench opens Home, the overview, as its footer door always has. |
| Close (⌘W) | Hides. Tools keep running from the menu bar and toolbar; the Dock icon stays. Quit (⌘Q) stops app-owned work after the existing quit checks. |
| Minimize (⌘M) | Standard Mac minimise. |
| Size and position | Restored from the last time, per edition (frame name `WorkbenchWindow`). Only the very first opening centres it. |
| Work in progress | Brings the window forward only where a result needs it there: a Snap draft, unsaved Snap & Talk narration at quit, a speech model that must be prepared, an update offer, or a page the person explicitly asked for from the panel, toolbar or a shortcut. Nothing new opens it uninvited. |

## Page kit

Every page uses the same few parts, so a page built by any person or agent looks like the others. The tokens live in `WorkbenchPageStyle.swift`.

**Header.** `WorkbenchPageHeader(route, summary:)`: the page's name from the page record, one sentence saying what the page is for, and at most two trailing secondary buttons that lead somewhere else (another place, or the tool's own options). Home's header is its greeting and Me photo.

**One primary action per phase.** `.borderedProminent` in the accent, beside the content it affects; Dictate's round microphone is the one hero control. Stop, End and Copy stay reachable before any optional setup.

**Cards.** `WorkbenchTile(title, symbol:)`: 12 pt corners, 16 pt inside, the control surface with a hairline border, a section title with its symbol in the accent and an optional trailing status or door. A card is never itself a button.

**Cards without a title.** `.workbenchCard(outlined:)`: the tile's padding, surface and hairline for a page's own card; `outlined` marks the row a door revealed. `WorkbenchTile` is built on it.

**Notes.** `WorkbenchNote(text, tone:)`: a sentence about a problem or a state, in primary words that wrap and can be selected, with the tone on the symbol only. Problems and cautions use the triangle. A problem with actions (Dictate's and Meetings' banners, the dictionary conflict, Snap's access card, the report composer's problem) is a `workbenchCard()` holding the note with its buttons beside or beneath it; there is no tinted banner, so a problem looks the same on every page. StageKit, which cannot see this kit, keeps internal twins (`WorkbenchLinkStyle`, `PersonaNote`, `PhoneLinkStatus.tone`).

**Status.** `WorkbenchStatusBadge(text, tone:)`: a symbol and a few words on one line, with the circle symbols. Done is the accent; attention is orange; neutral is secondary. Orange only asks for attention; red is for recording and removal.

**Empty states.** `WorkbenchEmptyState(symbol:title:detail:)`: what will appear here, why it is useful, and the one next step. Left-aligned inside a card; a whole empty page centres it.

**Spacing and type.** 24 pt page padding, 16 pt between sections, 22 pt semibold page titles, 13 pt semibold section titles, 13 pt body. Text styles only, so larger text grows them.

**Rules every page follows** (agreed with the page review, 7 Oct): every `Workbench.surface` container carries the hairline border, because the window and control backgrounds are the same colour on macOS 26; orange and red never colour text, only the symbol beside primary text (`WorkbenchStatusBadge`); text styles rather than fixed point sizes wherever a label is not a fixed-size key or glyph; Workbench.accent rather than `Color.accentColor`, which resolves to system blue; `…` only on a button that opens a dialog, sheet or another step.

**Links.** `.buttonStyle(.workbenchLink)`: a text door in Workbench's accent. `.buttonStyle(.link)` and a plain `Link` draw system blue on macOS whatever the tint, beside mint buttons.

**Section summaries.** A page with sections says what the shown section is for in its header, above the switcher (`WorkbenchHome.sectionSummaries`), as every other page does; the section's own view does not repeat it.

**Words.** One name per thing (the Grammar's Names). A button that opens something needing another step ends in …. A status describes what actually happened.

## Home

```
┌ greeting · Me ───────────────────────────────────────────────────────┐
│ Current work (while something runs) · First dictation (until used)   │
├──────────────────────────────┬───────────────────────────────────────┤
│ Your meetings                │ Permissions (while open)              │
│ Your decks                   │   — or, once folded —                 │
│                              │ Your keys · Permissions (one line)    │
├──────────────────────────────┴───────────────────────────────────────┤
│ Your keys, wide (while Permissions is open)                          │
└──────────────────────────────────────────────────────────────────────┘
```

From 760 points of content width Home uses two columns; narrower, or at larger text, one column in the same order. `HomeJourney` owns the order and the layout; `HomeJourneyChecks` holds both. The greeting says “Welcome!” until someone has dictated and “Welcome back!” after.

**Current work.** Each live thing with its own Stop or End. Dictating and narrating show a red record symbol and their elapsed time, as the toolbar's dot does. A meeting that is recording or finishing shows here only, never again in Your meetings.

**Your meetings.** Meetings and calls only, newest first, up to three. History has no meetings-only view, and the Meetings page forgets its last result when Workbench quits. The newest is open: its saved names (Meeting · person · company), date and length, a note the recording kept (such as a source that sent no audio), and its first lines. Once a follow-up has been made from it, the follow-up's own opening lines replace the transcript's, so the tile is a recap of what came of the meeting. **Copy transcript** copies the complete current text through the same owner as Meetings' Copy transcript and confirms “Copied transcript” beside it for four seconds, as Meetings does. **Review transcript** opens it in History. **Prepare follow-up…** opens the same reviewed handoff Meetings opens, and becomes **Open follow-up** once one exists. The two earlier meetings are one line each. The tile reads History only when History or its details change, never on a recording's clock.

**Your decks.** Snap & Talk sessions with at least one screen or a deck, newest first, up to three, from Snap & Talk's own recent list and the session folders, reread whenever Workbench comes back to the front (when an assistant has just written a deck in another app). A finished deck otherwise lives only in whatever folder the person chose. The newest is open: its first screen (a picture that opens as a picture), name, screen count and, when its `outputs/` folder holds a `.pptx`, `.key` (file or package) or `.pdf`, “Deck ready” with the date; the file's name is in the help. **Open deck** opens it in its app; **Open in Snap & Talk** uses the same switch as Sessions…, so busy and unsaved-edit admission applies; **Show in Finder** reveals it. Until the person has a session, the **sample deck** stands in: its cover, “A 6-slide tour of Workbench. Decks you build in Snap & Talk appear here.”, Open (the PDF in Quick Look) and Make your own. After that it stays one link away in the tile's header. The sample is a tour of Workbench designed and rendered from `scripts/samples` with real, synthetic-data screens of the app (`bash scripts/samples/render.sh`, `--screens` to refresh them from the gallery). It was not made through Snap & Talk and its labels say nothing about how it was made.

**Permissions.** One row per approval Workbench uses, by macOS's own name for its list (Microphone, Accessibility, Screen Recording or, from macOS 15, Screen & System Audio Recording, Camera) and Call audio, with what each is for and, until it is allowed, what still works without it. Accessibility's purpose leads with **Automatic paste**, the feature's own name, so someone looking for it finds the permission.

- Looking never asks. Every status is a passive read (`MacPermissionReader`); macOS's request appears only from that row's **Set up…** (never a custom “Allow”: the person allows it in macOS's own request, per Apple's Privacy guidance), through the owner its tool already uses (`MacPermissionStep`). Accessibility and Screen Recording share one route (`AccessibilitySetup`): the first press asks macOS and, if no request takes focus within 1.5 s, opens Settings; later presses ask again, so a list cleared by a reset or a − can show Workbench, then open Settings. Neither row rereads until Workbench is back in front, so nothing turns orange while macOS's own request is on screen.
- Only distinctions macOS reports, plus one fact about the account: **Allowed**; **Not asked yet** (Microphone and Camera, where macOS says so); **Not set up** (a yes/no check with no record that this edition asked; it may have been refused before Workbench kept count, so it never claims “not asked”; one Home saw allowed earlier in the run reads Off); **Off**; **Needs an administrator** (Accessibility) or **May need an administrator** (Screen Recording, which IT can let standard users switch on) when the account is not in the admin group (`mbr_check_membership`, gid 80, read each time); **Managed**.
- **Call audio** has no passive check, and macOS answers a refused tap with silence rather than an error. It reads **Checked on your next call** until Meetings hears real sound from the call app (**Allowed on your last call**, neutral) or Core Audio refuses (**Off on your last call**, with “Changed it? Meetings checks again on your next call.”). A recording that ends without hearing the app forgets an earlier Allowed, which a switch-off may have made stale, and never writes a refusal from silence. Change… on an allowed call audio forgets the answer too. Its quiet Open System Settings… is there before Meetings knows, for someone an earlier version already asked.
- **Change…** on an allowed row opens its switch in System Settings: macOS doesn't let an app revoke its own approval. Its help says when macOS applies a change (Microphone, Camera and call audio may stay with Workbench until it quits; Screen Recording changes when it reopens), that an organisation's Accessibility or Screen Recording approval may not be listed, and that on a standard account switching those off also needs an administrator.
- **Orange means off, and the person can switch it on.** Not asked yet, not set up and needing an administrator are information; green means macOS reports it allowed now. The summary says what it can know: “1 off”, “Needs an administrator” (or “May need an administrator” when only Screen Recording does), “Last paste only copied” (no ⌘V key, or the paste couldn't start) or “Last paste unconfirmed”, “3 to set up”, “1 managed”, “All set” (everything checkable now is allowed; call audio is known only from a call) or, below macOS 14.2, “All allowed”. Status text stays in the primary colour; only the symbol is orange, for contrast.
- The panel opens until everything is allowed or the person chooses **Done for now** (saved with what was off then). Folded, it is one line: when not everything is allowed, every row by its status; otherwise All set or everything allowed; then the last paste if it didn't land, and Show details. Only something that turns off after folding opens it again, so an approval IT controls, or one the person chose to leave off, never nags.
- Accessibility can read Allowed while automatic paste still fails. The row keeps its check and says why the last ⌘V paste didn't land (`AutomaticPasteProblem`, this run only): a layout with no ⌘V key, a paste Workbench couldn't see arrive, or (on the row only, never the summary, because Finder's desktop or a page nearly always has something focused) no text field found where something non-secure had focus. Live dictation neither records nor clears it; it isn't shown while delivery is Copy to clipboard, and Set up… or Change… on Accessibility clears it. A result only copied for want of Accessibility says so once per run (“Automatic paste needs Accessibility: see Home › Permissions.”), never after every capture. Dictate's options and Home's first dictation share one sentence on who can switch it on (`MacAccount.automaticPasteApproval`); the menu-bar panel's options say "Copies for ⌘V until Accessibility is allowed".
- **Copy permission details** copies one plain text for an IT team: what to allow by macOS version (PPPC for 14–26 and 27, App Settings on supervised 27), this edition's bundle ID, team and code requirement, and what this Mac reports. It holds no words or files; it names the app the last paste went to. The IT kit with ready-made profiles is [docs/it](it/README.md).
- Rows reread when Home appears and whenever Workbench comes back to the front.
- **It is never a gate.** Every tool keeps its own contextual request and its useful remainder ([mac-foundation § Permissions follow the action](mac-foundation.md#permissions-follow-the-action-and-remain-recoverable)).

**Your keys.** Workbench's shortcuts are presenter-first: Option plus a letter under the left hand, so the right hand stays on the mouse ([Interaction rules](workbench.md#interaction-rules)). The menu bar shows each row's key; Settings › Keyboard lists and edits every shortcut. Neither shows the layout or builds the habit. The tile:

- draws the left hand's fifteen keys by position, so any layout's own letters appear, each working Option shortcut on its key, ticked once learned;
- opens **Practice** or **Change…** from a click on any assigned key (the Keyboard coach's own three-press practice and recording, with its conflict check and macOS registration probe);
- offers a key for a core tool that ships without one (Snap: **Put Snap on ⌥G**, or the next free left-hand key; never ⌥E, an accent key);
- lists the next three to learn, killer features first (Dictate ⌥V, Draw ⌥D, Snap & Talk ⌥C, then Clear, Arrow, Present and the rest), each with how it is pressed and Practice;
- counts a key as learned once it is practised **or pressed for real**, for the exact keys it was learned on, so someone who already uses ⌥V daily is never told to learn it and a rebound key is a new habit (`workbench.keys.practised.v2`, written only by the app);
- disables Practice and Change while anything records, because both pause Workbench's shortcuts, Stop among them; Escape, leaving Home or Workbench losing focus ends them;
- and opens Settings › Keyboard from **Open Keyboard…**. Shortcuts that are off or in conflict are left off the map and the list.

## Page plan

Each page moves to the kit in its own small PR, rendered in the surface gallery, with this table updated. A page owned by another open issue waits for that owner.

| Page | Target | Status |
| --- | --- | --- |
| Home | As above | Done in the first desktop PR (five iterations and two independent reviews) |
| Window behaviour | Login launch, remembered frame, ⌘M | Done in the first desktop PR; native login check owed |
| Sidebar and footer | 24 pt icon column at 14 pt symbols, group labels at 11 pt semibold, selection by tint alone; the update note at most two lines so no page row is cut; the footer one line (“Stable 2.4.1”, or “Local build”) | Done in the chrome PR |
| Dictate | Already the reference layout: header with Import audio… and Settings…, hero microphone, transcript, Copy text | Done in the Voice pages PR: kit cards, header summary, Copy text prominent (⌘↩); Your dictionary and Models with it |
| Meetings | Start recording and Copy transcript as the phase's prominent action; card to `WorkbenchTile` radius and padding; drop the 960-point cap | Done in the Voice pages PR, with readiness that follows the speech model |
| Snap | Literal padding to tokens; empty state to `WorkbenchEmptyState` with Region as the one prominent capture | Cards aligned at the top, one access card shared with Snap & Talk (neutral while nothing is off), notes not orange text, done in the Screen pages PR; its centred empty state and capture cards still use literal sizes |
| Snap & Talk | Empty state to `WorkbenchEmptyState` with New session… prominent; header's extra bottom padding removed | Done in the Screen pages PR: capture strip on the page column, Transcription stopped instead of Needs attention, Cancel confirms after 10 s; pointer pass owed |
| Draw (StageKit) | StageKit cannot see the page tokens: move them into the shared `Workbench` namespace, then use `WorkbenchPageHeader` and the kit's card, badge and prominent action | Cards, one name per tool (Pointer, Whiteboard), text styles and the Timer word set done in the Screen pages PR with StageKit's own hairline; the token move is still next |
| Present | Owned by #276 / #285 | Done in the Present PR; at release its links took the accent, a phone failure the kit’s triangle in orange (on the page, the help sheet and Home’s live row), and the frame overlay lost its own prominent button so Present stays the one. Hand and logo notes, the scene notice and the empty states are still to move |
| Persona | Frozen beyond kit tokens (mac-foundation §1) | Tokens and defects done in the Saved pages PR: one first-run empty state, groups hidden until something is saved, one Done |
| History | Row radius to the kit; one prominent Hand off… in the selection footer | Done in the Saved pages PR (rows, one date, Transcript review); pointer pass owed |
| Library | Resources and Packs empty states and radii to the kit; From iPhone retires with #286 | Resources and Packs done in the Saved pages PR; From iPhone removed with #286, its route opening Resources |
| Settings | Every section is the same stack of kit cards at one width (`Workbench.settingsWidth`): General's subjects each a card, Models' two views and Connections carded, Keyboard's list and detail in one card with its summary in the header; Keyboard lists what is on first in Your keys' order, then Off · N; Workbench's accent, not system blue | Done in the chrome PR (stacked on the first); login approval in the first |

## Working on a page

1. Read this file, the [Grammar](workbench.md#grammar) and the page's owning issue. Check open PRs for the same files; one writer at a time for `WorkbenchHome.swift`.
2. Use the kit. A new radius, colour, padding or card style is a kit change made here first, not a one-off.
3. Render the page: `WORKBENCH_DESKTOP_GALLERY_ONLY=1 .build/debug/LocalVoice --render-surfaces DIR` (Home alone: `WORKBENCH_HOME_GALLERY_ONLY=1`). Look at light, dark, the minimum window and larger text before asking for review.
4. Run `python3 scripts/check-surfaces.py`. Classify every new or moved entry by hand in `docs/surfaces.json`; keep the file's order (do not commit a whole-file reorder from `--update`).
5. Update this file's page plan and any contract line the change makes untrue.

## Decisions

| Idea | Source | Decision | Why | What would change it |
| --- | --- | --- | --- | --- |
| Permissions panel on Home | Ethan, 6 Oct (setup screenshots he supplied) and 7 Oct | Built, as above | Asked twice. People need to know what Workbench can use and what they are missing; the panel keeps every rule of mac-foundation's permission section: passive reads, request only from a deliberate Set up…, honest states, no gate. It supersedes that brief's “no readiness dashboard or setup checklist” lines for Home. | An uncoached comprehension check where someone believes Home must be completed first, or a managed Mac where a status reads misleadingly. |
| Sample deck says what it is | Independent reviews, 7 Oct | Labels say “a tour of Workbench”; screens re-shot (a four-screen Snap & Talk walkthrough with narration, Dictate with automatic paste set up); persona and render artefacts removed | The first version claimed to be “made with Snap & Talk”; it was not, and its look is not what the neutral deck skill produces. | A real Snap & Talk handoff of these screens through the app, kept as the sample; then the labels can say so. |
| Permissions: orange only for Off; Done for now | Independent reviews, 7 Oct | Built | A new Mac showed four orange badges for ever and pushed Your keys below the fold; “not asked yet” is information because each tool asks on first use. Ethan's encouragement stays: the panel opens until the person chooses Done for now. | People choose Done for now and later miss a permission they needed; then reopen the panel on a tool's first refusal. |
| Your keys: learned by use, set step, Snap suggestion | Ethan, 7 Oct; independent review | Built | Habit means discovery, setting and muscle memory; real use is the best evidence of a habit; Snap ships without a key. | People ignore the suggestion; then drop it rather than add more. |
| Remove Recent work from Home | Ethan, 7 Oct (“dictate… is just an ephemeral capture”) | Removed | It was History's first five, mostly dictations nobody returns to. Home keeps only what lives nowhere else in that form. | People open History mainly to re-copy their last dictation; then a one-line “last dictation” with Copy earns a place. |
| Your meetings, not just the last meeting | This record, from Ethan's meeting recap ask | Built: three meetings and the newest one's follow-up | History has no meetings-only view and the Meetings page forgets its result on quit; a meeting and its follow-up belong together. | A Meetings filter in History, which would make the earlier rows redundant. |
| Your decks from Snap & Talk sessions | This record, from Ethan's assets ask | Built | A finished deck lives only in a chosen folder; the Snap page already shows Snaps, so Home shows decks instead. | Snap & Talk gains its own deck gallery. |
| Your keys | Ethan, 7 Oct; #77 (learn three useful actions) | Built, reusing the Keyboard coach | The one-hand layout is the design; nothing showed it, and practice was buried in Settings › Keyboard. Progress persists so the tile moves on. | Practice is rarely used after the first three; then fold the tile to the map alone. |
| Remove Home's four tool cards | Ethan, 7 Oct | Removed | The sidebar already lists every tool one click away; Home's space goes to the person's own work and this Mac's state. Doors stay beside the content they act on. | First-time users failing to find a tool from Home in a comprehension check. |
| Bundled sample deck | Ethan, 7 Oct | Built (`Resources/Samples`, ≤ 3 MB) | Shows newcomers what Workbench does, in its own screens, before they have made anything. It is an example, not promotion: read-only, outside History, and gone from view once the person has a deck of their own. | The product changes what a slide shows (re-render with `scripts/samples/render.sh --screens`), or the bundle budget needs the space. |
| Quiet launch at login | Ethan, 7 Oct (“when it opens, when it doesn't”) | Built, fail-safe | A login launch should not put a window in front of someone starting their day; the tools are in the menu bar. | A native check showing macOS does not mark `SMAppService` login launches; then remember whether the window was open at quit instead. |
| Remembered window frame, ⌘M | This record | Built | Standard Mac behaviour that was missing. | None expected. |
| First-close tip pointing at the menu-bar icon | This record | Not now | Needs a once-only lesson anchored to the status item; the icon is visible and the Dock reopens the window. | Someone loses Workbench after closing its window. |
| Reopen to the last page after relaunch | This record | Not now | Home now carries current work and results, so it is the right landing page. | People repeatedly navigate to the same page after each launch. |
| Permissions on work Macs, removal and automatic paste | Ethan, 8 Oct (“give or remove permission… a variety of production environments… my work computer doesn't let the auto paste work”); audit of 98 findings, 95 verified; a peer review and a diff review | Built: Needs an administrator, Not set up, Change…, fold by what was off, call audio from what Meetings heard, the last paste problem, a once-per-run copy reason, one who-can-switch-it-on sentence, Copy permission details, the IT kit, ⌘V by keyboard layout | The 7 Oct revisit trigger fired: on a standard account the rows read Off and sent people to a switch asking for an administrator's password, nothing told IT what to allow, and a permanent orange panel nagged where only IT could act. Automatic paste never worked on Ethan's work Mac and nothing said it was a permission. ⌘V used the US key position, so Dvorak sent ⌘K and Turkish F sent ⌘C. | A native check on a standard account or a managed Mac that reads differently; macOS 27 renaming the list or anchor. |
| Gate automatic paste on Post Event | Peer review, 8 Oct | Not now; reported in Copy permission details and allowed in the IT kit | `CGPreflightPostEventAccess` may reflect access as of launch, so gating on it could block paste after a fresh grant until relaunch. One Accessibility switch drives paste on every Mac observed. | A measurement that it is live after a fresh grant, or a Mac where Accessibility is allowed and ⌘V is refused. |
| Diagnose Secure Input | Audit and peer review, 8 Oct | Dropped | Measured on macOS 26.5.1: ⌘V posted to the field's process arrived in 8 of 8 runs while Secure Input was on, and `kCGSSessionSecureInputPID` names the wrong process. | Paste failures that correlate with Secure Input on another macOS. |
| Localised list names in “Open Privacy & Security › …” | Audit, 8 Oct | Not now | Workbench is English-only; on a German or Japanese Mac the fallback names a list that reads differently (the link itself still opens it). | Workbench is localised, or a non-English Mac reports a dead end. |
| `tccutil reset` to repair a stale entry | Peer review, 8 Oct | Not now | It returns the approval to not asked without root, but hasn't been tried on a standard account or macOS 27; the Off help says to click + instead. | A stale-signature report that + doesn't fix. |
| Copy permission details | Ethan, 8 Oct; peer review | Built, person-started | docs/bug-reporting.md keeps environment dumps and Accessibility queries out of Report a problem. This text is different: the person presses Copy, reads it and chooses where it goes; it holds no words or files, and names only the app the last paste went to. Ethan can veto it. | Someone pastes it somewhere they didn't mean to, or IT needs a field it lacks. |
| Identity freeze | Peer review, 8 Oct | Recorded | Every IT profile and every existing approval pins team GHVAAH9P5Z (an individual Developer ID) and the bundle ID. Moving to an organisation team or renaming the bundle silently breaks all of them. | The rename or organisation-team discussion: plan new profiles and a re-approval note before switching. |
| Accessibility read on macOS 27 | AltTab d630d872a, 26 Sep 2026 | Not now; the Off row says “If it's already on there, quit and reopen” | On 27 the in-process `AXIsProcessTrusted` can keep its old value after a toggle; AltTab's fix is private SPI. | A native check on 27 showing Off after a grant; then measure a reread off the main thread or after a delay. |
| Report a problem's Accessibility field | Peer review, 8 Oct | Not now | It reads the cached `model.accessibilityGranted`, which can disagree with the panel until the next activation. | A report whose Accessibility value contradicts the panel. |
| Meetings: say when a call's other side was silent throughout | Diff review, 8 Oct | Not now (2.5.1) | A refused System Audio Recording delivers silence, so a whole call with a silent app side is the only hint; a broken tap is silent too, so it could only be a hedged line beside Audio Recording Settings…, never a record. | A report of a call recorded with only one side. |
| One name for call audio's switch | Diff review, 8 Oct | Not now | Home says Call audio and names macOS's list; Meetings' button says Audio Recording Settings…. | The next Meetings page change. |
| Read administrator membership off the main thread | Re-review, 8 Oct | Not now | Three directory calls per redraw take about 0.1 ms here, unmeasured on a directory-bound Mac off its network. | A slow Home on a work Mac; then read once per activation, off the main thread. |
| The ⌘V-only flag in the capture harness | Re-review, 8 Oct | Not now | test-capture-persistence stubs noteAutomaticPaste, so viaPaste is checked only by reading AppModel. | A change to how transcribe chooses live dictation or ⌘V. |
| Folded line order | Re-review, 8 Oct | Not now | It follows the rows' order; leading with what needs action would read better. | Someone misses an Off row in the folded line. |
| Shorter standard-account Accessibility row | Re-review, 8 Oct | Not now | Ten caption lines when Workbench is already listed. | The native check on a standard account finds it too long to read. |
| Done for now's record pruned outside Home | Diff review, 8 Oct | Not now | The record of what was off is pruned when Home reads; something switched on and off again without a Home visit doesn't reopen the panel. | Someone misses an approval that turned off twice between Home visits. |
| Call audio refusal after switching it on | QA review, 8 Oct | Not now | After Open System Settings… on “Off on your last call”, the row stays orange until the next call, with “Changed it? Meetings checks again on your next call.” Forgetting on that click instead turned the panel green when nothing changed (re-review, 8 Oct). Done for now folds it. | Someone switches it on and is misled by the orange row; then forget on return from Settings only if Meetings' next start succeeds. |
| Login item and Files & Folders rows in Permissions | Permissions inventory, 7 Oct; QA review, 8 Oct | Not now | Open at login is a preference in Settings › General. Files & Folders (Desktop, Documents) serves Snap's Import Desktop screenshots… and reopening Snap & Talk sessions saved there; macOS asks in context, it has no passive check, and the IT kit can pre-allow both. | Either becomes a primary path, or someone's saved session won't reopen after declining macOS's folder request. |

## Later platform changes

Recorded from the page review's research so the next person does not rediscover them. Tiles stay opaque content, never Liquid Glass (Apple keeps glass to the navigation layer). The sidebar is a custom view; keep it behind one boundary so it can become a `NavigationSplitView` sidebar if macOS 26/27's floating glass sidebar is wanted. `HomeJourney.sections` stays data, so tiles can later be hidden or reordered. Put `containerBackground(_:for: .window)` (macOS 15) and concentric corner shapes (macOS 26) behind `#available`. Tile models are value types, so a desktop widget could reuse them.

## Native checks owed

On a signed Preview, by the integration owner or Ethan: each Set up… on a Mac that has not been asked (microphone and camera prompts; Accessibility's prompt then Settings; Screen Recording's prompt then Settings and a reopen); rows updating on return from System Settings; a managed or restricted approval; login launch staying closed after a real log-out and log-in, with the Dock opening the window; the frame restored after relaunch, on a second display and after that display is removed; ⌘M; Copy transcript from Home pasted into another app; the sample deck and its slides opening; VoiceOver and keyboard order through the tiles; Practice, Change… and Put Snap on ⌥G with a real keyboard, and a real ⌥V press ticking Dictate; Open deck after an assistant writes a `.pptx` and a `.key`; a meeting with a missing-audio note; the `Privacy_AudioCapture` link on macOS 14 and 15. Permissions on a work Mac (8 Oct): a standard account (Needs an administrator, the admin sheet, Copy permission details), an MDM-managed Mac with the IT kit's profile on macOS 26 and 27, Change… then turning a microphone off with Later, Don't Allow on Meetings' call-audio request never making Home read Allowed (note whether the call ended silent or Off), call audio switched off and on again without a relaunch (this decides Change…'s “until it quits”), and automatic paste with a Dvorak layout. Launch checks through LaunchServices (`open -n`): a process started from a shell, or from `tart exec` in a Cirrus image whose guest agent holds Accessibility, PostEvent and Screen Recording, inherits its parent's approvals. CI builds only on macOS 26; to cover 14, build there and run the binary on 14.
