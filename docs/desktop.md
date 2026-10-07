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
| Dock click or Open Workbench while running | Comes forward on the page it was showing. |
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

**Notes.** `WorkbenchNote(text, tone:)`: a sentence about a problem or a state, in primary words that wrap and can be selected, with the tone on the symbol only. Problems and cautions use the triangle.

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

**Permissions.** One row per approval Workbench uses, by macOS's own name for its list (Microphone, Accessibility, Screen Recording or, from macOS 15, Screen & System Audio Recording, Camera) and Call audio, with what each is for and, until it is allowed, what still works without it.

- Looking never asks. Every status is a passive read (`MacPermissionReader`); macOS's request appears only from that row's **Set up…** (never a custom “Allow”: the person allows it in macOS's own request, per Apple's Privacy guidance), through the owner its tool already uses. Screen Recording's request is recorded wherever it is made (Home, Snap or Snap & Talk); if macOS shows nothing, Settings opens a moment later, so Set up… is never a dead click.
- Only distinctions macOS reports: Allowed, Not asked yet, Off, Managed, and Asked on first call for call audio, which has no passive check and no list until Meetings first asks, so it offers no Settings button.
- **Orange means off.** Not asked yet is information: the tool asks when first used. The summary says what it can know: “1 off”, “3 not asked yet”, “1 managed” or, only when true, “All allowed”. Status text stays in the primary colour; only the symbol is orange, for contrast.
- The panel opens while something is off, or while something is still to set up and the person has not chosen **Done for now** (saved). Folded, it is one line naming what is allowed, with Show details. Something turning off opens it again.
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
| Dictate | Already the reference layout: header with Import audio… and Settings…, hero microphone, transcript, Copy text | Kit tokens only |
| Meetings | Start recording and Copy transcript as the phase's prominent action; card to `WorkbenchTile` radius and padding; drop the 960-point cap | Next |
| Snap | Literal padding to tokens; empty state to `WorkbenchEmptyState` with Region as the one prominent capture | Next |
| Snap & Talk | Empty state to `WorkbenchEmptyState` with New session… prominent; header's extra bottom padding removed | Next |
| Draw (StageKit) | StageKit cannot see the page tokens: move them into the shared `Workbench` namespace, then use `WorkbenchPageHeader` and the kit's card, badge and prominent action | Next, needs the token move first |
| Present | Owned by #276 / #285 | After #285 lands |
| Persona | Frozen beyond kit tokens (mac-foundation §1) | Tokens only |
| History | Row radius to the kit; one prominent Hand off… in the selection footer | Later |
| Library | Resources and Packs empty states and radii to the kit; From iPhone retires with #286 | After #286 |
| Settings | Sections titled with `WorkbenchSectionTitle`; founder card to `WorkbenchTile`; Open Workbench at login explains macOS's approval | Login approval done in the first desktop PR; rest next |

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
| Login item and Files & Folders rows in Permissions | Permissions inventory, 7 Oct | Not now | Open at login is a preference in Settings › General; Desktop folder access serves only Snap's Import Desktop screenshots… and has no passive check. | Either becomes a primary path. |

## Later platform changes

Recorded from the page review's research so the next person does not rediscover them. Tiles stay opaque content, never Liquid Glass (Apple keeps glass to the navigation layer). The sidebar is a custom view; keep it behind one boundary so it can become a `NavigationSplitView` sidebar if macOS 26/27's floating glass sidebar is wanted. `HomeJourney.sections` stays data, so tiles can later be hidden or reordered. Put `containerBackground(_:for: .window)` (macOS 15) and concentric corner shapes (macOS 26) behind `#available`. Tile models are value types, so a desktop widget could reuse them.

## Native checks owed

On a signed Preview, by the integration owner or Ethan: each Set up… on a Mac that has not been asked (microphone and camera prompts; Accessibility's prompt then Settings; Screen Recording's prompt then Settings and a reopen); rows updating on return from System Settings; a managed or restricted approval; login launch staying closed after a real log-out and log-in, with the Dock opening the window; the frame restored after relaunch, on a second display and after that display is removed; ⌘M; Copy transcript from Home pasted into another app; the sample deck and its slides opening; VoiceOver and keyboard order through the tiles; Practice, Change… and Put Snap on ⌥G with a real keyboard, and a real ⌥V press ticking Dictate; Open deck after an assistant writes a `.pptx` and a `.key`; a meeting with a missing-audio note; the `Privacy_AudioCapture` link on macOS 14 and 15.
