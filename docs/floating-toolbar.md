# The floating toolbar

This document owns the toolbar's behaviour. `Sources/ToolbarCore/ToolbarMachine.swift`
is the executable copy of it, and `Tests/ToolbarCoreTests` is the proof. When
they disagree, resolve the intended behaviour against the product contract, then
update the table, implementation and regression together. A passing test is not
permission to preserve a bug.

## Role and content

The floating toolbar is the shared live control surface for Snap & Talk, Draw,
Present and Persona Overlay, and it carries dictation, narration and reading
too (#134 T4). Desktop pages own preparation and saved libraries. The compact
menu-bar panel owns quick utilities, adjustments and shortcut editing. Dictate
and Read start, stop, pause and resume here; their options stay in Workbench.

**The mode follows you.** A mode, which the launcher calls the tool, is one
capability or named workflow: Dictate, Read, Snap, Snap & Talk, Draw, Present or
Persona. Starting anything from any door (a key, a panel row, Home, an app menu,
the toolbar itself) makes it the mode; ending leaves the mode where it was.
Before anything has ever been started the seed is Dictate, because it works in
every app with only the microphone. The choice persists across relaunch under
`workbench.toolbarMode.v1`. Timer is a panel row and a Present option, not a mode.

**At rest the toolbar is a compact mark** (#134), whatever is running: idle,
recording, playing, paused, processing, drawing, presenting, a persona, a timer,
a Snap & Talk session, or a result waiting for the person. It is a 48 × 20
capsule in a fixed 48 × 28 target. At idle it remembers the selected tool with
that tool's neutral SF Symbol; live work, processing and attention take priority
(see Status at rest). Colour identifies actual activity: a selected Present icon
stays neutral until a presentation runs. The resting window is
exactly that target, and everything outside it passes clicks through. Work never
holds the row open, and a new failure or result never opens it either. Keep open
is the one explicit way to keep it up. Dictation, narration, reading and their
results keep the toolbar up even while Hide toolbar is on, at rest as the mark.

Hover, after the 120 ms dwell, or a click reveals the row. A click on the mark
only reveals it and takes the keyboard; it never starts or stops anything, and
the whole click is the mark's, so the row that appears under the pointer never
receives its mouse-up. A double-click that begins on the mark cannot start or
stop work either. A right-click opens the current tool's options, and a drag
moves the toolbar (see Placement).

**Recording, reading and their results in the same host** (#134 T4). The same
window, anchor and tiers carry dictation, narration and reading from start to
result; nothing swaps the floating window to a panel of its own. Live work is
the row: its next action is Stop, Stop narration, Pause or Resume reading, Cancel
request or Processing…, the launcher carries the capture signal, and More opens
with what the work can do besides, under its capability's name: Cancel and Copy
now for a dictation, Cancel for a narration, Stop reading. Dictated words that
wait for drawing to end lead with Stop drawing, which delivers them, with Copy now
in More (#211). While drawing or a prompt insertion holds the next action, More's
Read section also has reading's own next action: Cancel while it prepares, Pause
reading or Resume reading. A recording's elapsed
time is the Stop's tooltip and VoiceOver help, never its label, whose width would
tick; in the last ten seconds before the 5-minute limit a timer badge joins the
capture signal and VoiceOver hears it once. The Dictate page keeps the recording's
details.

A result keeps its own view: the dictation that needs attention with its reason,
Retry, Record again or Open Workbench and dismiss; the reading that stopped with its
reason, Retry and dismiss; and the clipboard receipt with Review, its pin and the ×
whose ring counts its own eight seconds (four after a confirmed paste), held by the
pointer or the pin. At rest a result is only the mark's warning or clipboard status.
The pointer's reveal, a dwell or a click on the mark, shows the result's view in
place of the row, grown inward from the same centre; a result that arrives while the
row is open waits for the next reveal rather than replacing the row under the
pointer. Keyboard entry, Window › Focus floating toolbar, reveals the launcher row
instead, with the launcher focused and keeping the result's status, the mark's glyph
as a badge on the tool's symbol and its words in VoiceOver's value, and More opens
with the result's own section: its title, a failure's reason, and Copy again, Retry,
Record again, Open Workbench, Review and Dismiss as its view offers them (#211).
Record again, there and in its view, only ever starts a recording: one begun since,
by the shortcut say, is left alone. A result's view takes the keyboard on its first
command when the keyboard comes to it, and Escape leaves from it as from the row. At
a right-hand dock a result grows leftward from the mark, so each result is mirrored
there: its words, and a dictation result's drag handle, sit over the mark the
pointer came from, and its commands and Position at the far end, while VoiceOver
reads it in the same order. Revealing, collapsing or choosing a tool never
acknowledges, dismisses or retries it. This is the chosen reading of the contract,
which prefers recovery commands in More and warns against squeezing an editor into
the row: a failure's reason and a receipt's text are content, not only commands, and
the receipt's ring needs its view.

One exception, also chosen: a row held open by Keep open alone shows a new result in
its place, as the dictation panel did, because Keep open is the person's choice of
persistent controls and there is no rest to show the status on. It does so only
while no pointer is on the toolbar and nothing holds it, no menu, chooser, keyboard
or Position… included; until then the result waits as a status. A kept-open row that
comes back after a capture or Hide toolbar makes the same checks once the pointer
has been found again, and Position… closing hands the keyboard back before anything
is swapped (#211). It never activates Workbench, takes the keyboard or moves the
anchor, and it grows from the same centre. A delivery that did not finish stays
after its receipt has gone (#134 T5): the mark keeps its warning, and More opens
with the result's own title, Copy again where it cannot lead to a second insertion,
and Dismiss.

The routine no-speech cue keeps its own view at the toolbar's place for under two
seconds, held by hover or VoiceOver, then the mark again (#156).

**The coaching card** (#134 T5) shows above what the toolbar shows with a 12-point
gap, or below it when the display has no room above, centred on the launcher and
never expanding the row or moving the mark. It fades in over 160 ms, at once with
Reduce Motion. It is its own panel, sized to the
card, so the gap passes clicks through. The host allows it
(`FeedbackCoachModel.canPresent`) only while the toolbar is on screen and the card
would cover no permission prompt, no Workbench window in front, none of the
toolbar's popovers and no result's controls open in its place; reports
`didPresent` once it has been on screen for a display pass; drops a card it cannot
show, so its lesson is not spent and the attempt gets its ordinary no-speech cue; removes it on a screen capture and when a
narration starts; and fades it out in 160 ms, or at once with Reduce Motion.

Revealed, the toolbar is a 40-point capsule: `[tool ▾] [next action]
[accessory] [⋯]`, reversed on a right-hand anchor. At standard text its minimum
width is 160 points, or 252 with an accessory. The launcher's 48-point target sits
flush with the capsule's end, then 4-point gaps between the next action, the
88-point accessory and the 32-point More, and 8 points of padding at the far end
only. The action fits its current wording with 12 points of horizontal inset on
each side and a 64-point minimum target; it keeps its 32-point height. Padding at the launcher's end would move the shared centre 32
points in and grow the row toward the display's edge. Longer labels and larger
text grow the row; an essential action is never shrunk or truncated. When the accessory does
not fit the display less 24 points, it waits in More. The launcher and the
compact mark share one fixed centre on screen, and the row grows inward from it.

The next action is the label for where you are in the journey, from one pure
function of what is live (`ToolbarNextAction`) with a fixed priority: what is
consuming your input now (inserting, dictating, capturing, narrating, drawing,
reading) whatever the mode, then the selected mode's own step or ending
(`Capture next · 3`, `Stop transcribing`, `End presentation`, `Hide personas`),
then its start verb. Another mode's ending never claims the label: presenting
while Draw is the mode reads `Draw`, the launcher's dot says work is live, and
More offers `End presentation` under Active work. Two identical screens never
read differently, and the label never ends anything but what it names. The
button latches its operation and that operation's generation as it goes down,
and acts when it comes up only if both still hold: a Stop that completes while
it is pressed is discarded, never turned into a new start. The hover hint shows
a key only for an operation that key performs: Present's key does not stop an
insertion, Dictate's key does not stop a meeting, and the persona key does not
pause a prepared set. Native hover text and VoiceOver help name the visible action
followed by its usable shortcut, for example `Draw · Hold ⌥D` or
`Stop · Release ⌥Space`. Hold and Release reflect the actual capture or drawing
session. A mouse-latched hold drawing, another drawing tool, or an unprepared
Snap & Talk session omits a key that would perform a different action. Disabled
and failed bindings are omitted. There is no competing whole-row tooltip.

`ToolbarModeFollower` in the host watches every owner and makes a capability
the mode the moment it goes from not live to live, whichever door started it;
if several start in one tick, Present wins, then Persona. The launch snapshot is
not a start, so a restored Snap & Talk session does not move the mode.

**The launcher** shows the current tool's symbol with a chevron. The symbol is
shared with the menu bar, desktop navigation and chooser; no separate icon asset
set is introduced. Its centre stays fixed through reveal, and the chevron appears
beside it. A cog is reserved for Settings: the tool and chevron make choosing a
tool visible here. More stays at the inward end, with the hint `Options for Draw`
(or the selected tool's name). A click, Space,
Return or Down opens the chooser. When work is live in any tool, the launcher
carries one small dot, and its accessible description names the current tool
and any other running work ("Dictate. Also running: Draw").

**The chooser** is one flat list of the seven tools, in panel order: Dictate,
Read, Snap, Snap & Talk, Draw, Present and Persona. It is 280 points wide with
36-point rows, and each row has the tool's symbol, its exact name, a checkmark on
the current tool, a labelled dot when that tool's work is running and its
assigned key. There is no search, grouping or nesting for seven fixed items.
Up and Down move, Return chooses, Escape closes without a change and typing jumps
to a tool by name, as a native menu does; hovering a row highlights it and only a
click chooses. Choosing changes only the remembered tool: it never records,
pastes, stops an independent job, changes a persona's frozen artwork or
overwrites a draft, and the next action can still read Stop for input that is
live. Late changes while it is open keep the highlight on the same tool, and
Return chooses that tool, never whatever row now sits where it was. It opens
beside the launcher, on the side with more room, aligned with the launcher's
outer edge and kept 8 points inside the display; it scrolls only when the
display is shorter than the list.

**More** (`⋯`) holds the current tool's options, then an Active work section,
then Position…, Keep open, Hide toolbar and Settings…. Active work reaches
everything the compact mark can show from whichever tool is chosen, with existing
commands worded as their own tool words them (`ToolbarActiveWork`): `Stop drawing`,
`End presentation`, `Hide persona`/`Hide personas`/`Show personas` and
`Stop transcribing` for work running in another tool; `Transcribe meeting or
call…` for a meeting recording saved for retry, from every tool, since Dictate's
own options hold only its page; `Open Snap…` for an unsaved Snap capture; and the
break timer's next transport as the timer names it, `Pause timer`,
`Resume timer` or `Restart timer`, since Timer is not a tool. The next action is the row's own button
and is not repeated there, and there is no Change tool: the launcher is the one
way to another tool. Dictate, Read and Snap are start and stop on this surface,
so each carries one door to its page and nothing else, named as
`Open Dictate…`, `Open Read…` and `Open Snap…`. Snap & Talk offers its review.
Draw holds the drawing menu inline. Present holds the presentation items inline,
Saved Prompts… and Switch to Browser Tab; source, reconnect, proportions, motion,
window placement, native-app handoff and End remain reachable there. Persona
holds the persona menu inline: the frozen session's public labels, size,
position, lock, add/remove, visibility, explicit layout saving and End. Mac
colour selection updates the same drawing settings from either entry point.
Native menus snapshot their content before tracking rather than rebuilding under
the pointer.

The primary starts at the width its current action needs. During one open
interaction it may grow for a longer action, but never shrinks when a shorter
label replaces it. Collapse resets that width floor. This avoids empty space
reserved for unrelated tools while keeping nearby targets steady after a Stop
becomes a start verb. The row holds no information-only text:
the assigned key and any count are the action's hover hint. Snap & Talk keeps its
session capture count in the label between captures and while saving. Present's
accessory is Prompts. Disabled or unassigned shortcut combinations are omitted;
the toolbar has no shortcut editor. Keep open is an explicit persistent
preference.

**One popover at a time.** The chooser, More, the accessory's picker and
Position… close one another, and hover never opens any of them. Each holds the
row open while it is up, as a native menu does, and a crossing between the row
and it is one interaction.

**Focus.** The chooser, the Prompts picker and Position… take the keyboard
without making Workbench the active app, and each keeps the field that was in
front before it took the keyboard. A choice returns the keyboard to the launcher;
the first Escape closes the picker and the second leaves keyboard interaction. A
click elsewhere or Command-Tab closes it and leaves the keyboard with whatever
was chosen; it never reactivates the app that was in front before. Leaving
keyboard interaction gives the keyboard back to the earlier field only while the
toolbar still has the keyboard and that app is still running.

**Motion.** A reveal waits for a 120 ms dwell and a collapse for a 450 ms grace;
the frame changes in one 160 ms ease-out animation with no bounce, and the side
the row grows toward never changes during an interaction. The visible capsule,
mask and content read the host's current layout bounds during that animation;
there is no second animation clock or asynchronous size observer. The tool symbol
keeps its centre while the capsule opens around it. Controls fade in only after
their entire labels fit, and fade away before closing can cut through them. The
launcher remains anchored even while the host is smaller than its content.
Reduce Motion changes the frame and content at once and holds the voice trace still.

Hide toolbar hides the tools in every mode, including while drawing, presenting or
showing personas. It is the same persistent choice as the Floating toolbar switch in
the menu-bar panel's header and in Settings › General › Appearance, and the Window
menu's Show or Hide floating toolbar, so it survives relaunch; the surface gallery
changes it from each of these four doors and checks that the others agree. The work
carries on: hiding never clears marks, ends a scene, hides persona artwork or stops
a timer, and each keeps its key and its menu-bar panel row. Window → Show floating
toolbar, Window → Focus floating toolbar and Settings bring the tools back with the
current mode and live state. A prompt insertion keeps the tools until it ends,
because its Stop is there. Recording, processing, narration and reading keep their
own controls whatever the choice (`FloatingToolbarSurface.resolve`, checked by
`--check-floating-toolbar`).

Saved Prompts reads the existing Library. Favourite, Product and
Persona groupings do not create another store. The Prompts accessory and More's
Saved Prompts… open one picker: a search field, favourites and then
every other prompt once, and one optional Product or Persona filter that narrows
the list without a submenu. It is a transient panel of at most 420 points, kept
16 points inside the display near either edge, above a bottom dock and below a
top one. Long names wrap to two lines or truncate and keep their full accessible
text. It takes keyboard focus without activating Workbench, holds the row open
as a native menu does, and closes on Escape, a click outside, a second click on
Prompts or a choice; ↑ ↓ and Return choose. A choice acts only after the picker
has gone, as a menu item's action runs after tracking, and typing waits, for about
a second at most, until the frozen app is in front with the frozen field focused.
The picker's panel is sized from its content's `onGeometryChange` report, never
from a background `GeometryReader` preference (#152).

The original field, value and UTF-16 selection are captured before the picker
opens. Supported fields receive confirmed literal chunks; other readable fields
get one guarded paste labelled as such. Without Accessibility approval, or with
no readable field, the action is Copy prompt: one copy of the exact text and the
Copied, Paste with ⌘V. receipt, with no paste or Accessibility write. The last
delivery is one line naming its destination, with Details for the full reason.
Escape, Stop, changed focus/selection/value and shortcut editing cancel
insertion. No partial write is replayed and no submit key is sent.

## Status at rest

One typed projection, `ToolbarStatus`, says what the compact mark shows. The host
resolves it from what the operation owners report (`WorkbenchControlContext.activity`),
recomputed at launch, never stored and never read from a status or error string.
It decides the indicator and its accessible description and nothing else: never
the tier, the keyboard or the collapse deadline. A library selection, an old
transcript, a restored Snap & Talk session or editable text alone is idle. The
highest priority wins: capture or playback, then processing, a failure, a pending
result or unsaved capture, paused work, other live work, and idle. A delivery that
did not finish is a failure until the person copies it again or sets it aside.

| Status | The mark shows |
| --- | --- |
| Capture | The shared voice trace (#209): a red recording dot and a short trace of three shallow lobes in the voice colour, from the recording owner's own level through the shared envelope; a thin still line in silence or with no level (a meeting), and a still shape with Reduce Motion. Its badges, each 7 points and both when both apply (#211): a timer beside the trace in the last ten seconds before the 5-minute limit, and a warning on the capsule's corner, like a badge on an icon, for another job that needs attention. Revealed, the launcher carries the same signal in place of its symbol |
| Playback | A speaker |
| Processing | An ellipsis |
| Failure | A warning triangle |
| Pending delivery | A clipboard |
| Unsaved capture | A pencil |
| Paused | Pause bars |
| Other live work | That work's capability symbol |
| Idle | The selected tool's neutral SF Symbol inside the 48 × 20 capsule |

A recording that goes on while another job needs attention keeps the recording
signal and adds a small warning badge inside the same target, and its
description names both ("Recording dictation, Needs attention"), the time limit
too when it comes. Shape and words carry each state; colour never does alone.
VoiceOver's value for the mark and the launcher adds the level in words, Quiet,
Receiving sound or Low microphone level once the dictation owner judges the
microphone too quiet, and never announces it. VoiceOver announces each meaningful
change once: a new indicator, a badge, or new words for the state, so a failure
or waiting result that arrives under processing or playback is heard though the
indicator keeps its priority. Never a level, and never any transcript or result
content. A finished break timer ("Time is up") is neither live nor paused, although
its session stays started until it is reset.

## Placement

The toolbar goes where you put it (#163). A press on the compact mark, the
launcher, the next action or the row's empty chrome becomes a move after 4
points; below that it is a click, and the click does what it always does. More
and the accessory are ordinary controls and never start a move. While you drag,
the eight named docks show as guides. The one within 16 points of the launcher's
slot is highlighted, and releasing there docks the toolbar. Releasing anywhere
else leaves it right there, kept whole inside the visible display it covers most.

The position is the launcher's centre, which the compact mark shares (#134). A
docked launcher sits at the centre of its dock's 48 × 40 slot, the shared
floating-control geometry 16 points in from the display's edges, and the row
grows inward from it. A free row grows toward the middle of the display it was
released on, so near an edge it expands inward. That side is decided once, on
release, and kept with the position. So revealing, collapsing, choosing another
tool or a live label that widens the row never moves the launcher, and nothing
but a new placement turns the row round. The toolbar sizes to its content and
has no resize handles. A recording, a result or the cue is the same toolbar at the
same position, so dragging it moves that one position (#134 T4). Position
floating toolbar… on the Dictate page opens Position… at the toolbar.

Position… in More opens one compact control with the eight docks and
Reset position, which docks at bottom centre. It is the keyboard and precise way
in, beside dragging: arrow keys move between docks, Return or Space moves the
toolbar there, and Escape closes. The control takes the keyboard without making
Workbench the active app. Opened from the toolbar's keyboard focus, a choice,
Reset or Escape gives the keyboard back to the toolbar, so a second Escape returns
to the field it came from; opened by pointer, it takes the keyboard nowhere. A
drag or a menu on the toolbar closes it.

The choice persists through `CapturePanelController`: a dock by name, or a free
position (`ToolbarFreePosition`) as the launcher's centre and side
(`capturePanelLauncher.v1`). #163's record of a glyph edge, centre and side, and
the compact mark's origin and size, are written beside it for an earlier build.
Earlier saves come back where they were left: #163's glyph edge becomes the
launcher centre 18 points inside it, and a save with only a resting element's
origin and size gets its side decided once, where it was left. When the glyph
copy no longer matches the launcher record, an earlier build has moved the
toolbar since, and that move wins. A migrated save is written back in this
build's terms at once. The compact rest adds no preference of its own. The
position survives collapse and reveal, every
update and relaunch. If its display is removed, the toolbar comes back whole on
the display in use; the saved position is kept, so it returns when that display
does. The drag threshold, snap distance and recovery are StageKit's
`FloatingControlPlacement`, for Persona overlays to share with their own
per-copy state.

## The three layers

| Layer | Owns | Depends on | Tested by |
| --- | --- | --- | --- |
| **Core** `Sources/ToolbarCore` | When to show which tier, the remembered choice, the next action for what is live (`ToolbarNextAction`), the compact status (`ToolbarStatus`), the chooser's keyboard (`ToolbarChooserState`) and the press latch (`ToolbarActionGeneration`) | Nothing. No AppKit, no clock, no window | `swift test`, instantly, with no sleeps; `ToolbarNextActionTests` walks the whole live-state product |
| **Look** `ToolbarKit/ToolbarRow`, `ToolbarChooserView` | How each tier is drawn: the compact mark and its status, the launcher row with its accessory and More, and the chooser | One `ToolbarViewState` value | Native layout tests and snapshots of `ToolbarGallery.states` and `.choosers`, light/dark and larger text |
| **Host** `ToolbarKit` + `CapturePanelController` + `FloatingToolbar` | Tracking with its reveal debounce, one cancellable deadline, one native animation; the mode, the frozen live state, app surface and saved position | Core effects, existing operation owners | `ToolbarKitTests` and isolated app acceptance |

A change belongs to exactly one layer. If a change needs all three, it is three
changes. The mode is not a reducer field: it lives in the view state and the
host, and `tier` is still assigned only by `reduce`.

## The behaviour

One rule removes most of the old bugs: **`tier` is assigned, never derived.** The
other four fields record what the world is doing — where the pointer is, what is
holding the row up, whether a timer is running, and what the user chose. Only
`reduce` writes `tier`.

A second rule: **a hold can only prevent a collapse, never cause a reveal.** That
is why dragging the compact mark does not resize the window you are dragging.
Keyboard focus is the one written-out exception, because focusing a toolbar that
shows no controls is useless. Work is not a hold: a recording, a presentation or
a waiting result never keeps the row up; it shows on the mark instead.

`keepsOpen` is a hold that outlives the session. That is the whole of it.

The choice uses `floatingToolbarKeepOpen.v2`, defaulting to off on upgrade.
The old `floatingToolbarExpanded.v1` is left untouched and ignored: clicking
the former pill wrote it, so it does not establish an explicit choice to keep
this new row open. Once chosen in the menu, the new preference survives relaunch.

### The table

| Tier | Event | Next | Effects |
| --- | --- | --- | --- |
| resting | pointerEntered | revealed | `show(.revealed)` |
| resting | holdBegan(.keyboard) | revealed | `show(.revealed)` — no `persistKeepOpen` |
| resting | holdBegan(.menu / .drag) | resting | — |
| revealed | pointerLeft, unheld and not kept open | revealed | `startGrace` |
| revealed | pointerEntered | revealed | `cancelGrace` |
| revealed | holdBegan(any) | revealed | `cancelGrace` |
| revealed | holdEnded, last hold, pointer away | revealed | `startGrace` |
| revealed | holdEnded, last hold, pointer on it | revealed | — |
| revealed | graceElapsed, still unheld and away | resting | `show(.resting)` |
| revealed | graceElapsed, anything changed | unchanged | — |
| any | keepOpenChanged(true) | revealed | `persistKeepOpen(true)`, `cancelGrace` |
| revealed | keepOpenChanged(false) | revealed | `persistKeepOpen(false)`, then `startGrace` once nothing else holds it |
| any | surfaceLeftTools | resting | `releaseHolds`, `show(.resting)` — the remembered choice is kept |
| any | surfaceReturnedToTools | by the remembered choice | `show(…)` |
| resting | pointerEntered after the surface returns | revealed | `show(.revealed)` |

Unticking **Keep open** inside the open menu is the one worth walking through:
the preference is written immediately, the menu still holds the row up, and the
row fades when the menu closes. That is exactly what the minimise button did,
issued by the control that owns the idea.

### What the invariants guarantee

`ToolbarModelCheckTests` walks every state the toolbar can reach — 40 of a
possible 128 — and applies every event to each one. Five things can never happen:

1. **Stuck open.** Revealed, with nothing holding it, no pointer on it, not kept
   open and no timer running.
2. **Stuck closed.** Resting while the pointer is on it. Nothing on the toolbar
   dismisses it any more, so a pointer resting on it always means the row should
   be up; the state is unrepresentable rather than merely avoided.
3. **A timer on a toolbar that is not revealed.**
4. **A countdown against a toolbar the user asked to keep open.**
5. **Keyboard focus on an invisible toolbar.**

It also proves `reduce` is pure, that a `show` effect is emitted exactly when the
tier changes, and that `show` is always last in its batch.

## The host contract

The core cannot be right if the host feeds it fiction.

- **A crossing is a crossing.** `pointerEntered` and `pointerLeft` come from one
  `NSTrackingArea`, and the host filters the synthetic ones: the row is much
  wider than the compact mark, so its frame moves out from under a stationary
  pointer every time it opens and closes, and that is geometry, not a gesture.
- **Entry into a resting toolbar is debounced 120 ms; exits and settles are
  immediate.** A pointer passing across the compact mark on its way somewhere
  else must not spring the row. `ToolbarTrackingView` holds the entry for
  `revealDelay` and delivers it only if the pointer is still inside; an exit
  before then cancels it and delivers nothing, because the core never learned of
  the entry. Entries into an already revealed row are immediate. The reducer and
  its state budget are untouched: it still sees one crossing.
- **Suspend crossings while the frame animates, then reconcile once** by sending
  the event that matches where the pointer actually is. Do the same when menu
  tracking ends and dragging finishes, because they can swallow the owning window's exit, and when the tools
  surface comes back, because AppKit cannot deliver a crossing to a pointer that
  never moved. Both events are idempotent, so agreeing with the core costs
  nothing. There is deliberately no third, non-revealing reconciliation event:
  one of those is what made the toolbar sit closed under a pointer that was on it.
- **Every hold needs a guaranteed release.** Menu tracking ending, the window
  resigning key, and mouse-up or a cancelled drag each have to deliver their
  `holdEnded`. A hold the host forgets to release is a row that never closes, and
  it is the one failure the reducer cannot protect you from. Release holds on
  app deactivation and on a screen-parameter change.
- **`show` is always the last effect in a batch**, so a host may resize inside
  the effect loop: a crossing AppKit delivers synchronously from that resize
  cannot invalidate an effect still waiting to run.
- **One grace timer.** `startGrace` starts it, `cancelGrace` stops it, and it
  delivers exactly one `graceElapsed`. The production Task exits on cancellation
  and checks cancellation before delivery on the main actor. A callback from a
  cancelled deadline must never be delivered into a later deadline.
- **One animation.** `NSAnimationContext` on the window frame. The content does
  not animate its own size at the same time.
- **Hover intent belongs to its geometry.** Suspending tracking for a resize,
  drag or surface change cancels the pending reveal dwell. Only the host's final
  pointer reconciliation may reveal at the new geometry; an old dwell cannot
  shorten a later entry. If AppKit misses an exit, the next real entry starts a
  fresh dwell rather than leaving the pill unresponsive.
- **The row grows inward from the launcher's centre**, which the compact mark
  shares, so nothing under a pointer on it moves as the row opens, widens or
  closes, and a right-hand dock does not run off the display.
  `ToolbarGeometry.frame(size:position:screen:)` puts the window's growth edge 24
  points from that centre for any width: the mark's own edge at rest, and the end
  of the launcher's fixed 48-point target when revealed.
  `ToolbarAnchor.growsLeftward` gives a dock's side; a free position
  (`ToolbarPosition.free`) grows toward the side decided when it was released and
  draws its row for that side (`CaptureHUDControls.rowAnchor`). An update compares
  the window with the frame of the position the toolbar actually has, so it never
  pulls a free toolbar back to a dock.
- **The window is the row's size.** `FloatingToolbar` reports the row with
  `onGeometryChange`. Before sizing the tools, the host lays the row out
  (`layoutSubtreeIfNeeded`), so the report for the tier, mode and labels about to
  show arrives first. A reveal, a count crossing 9→10 or a mode switch goes
  straight to the right frame, and a drag keeps its window until release. At rest
  the window is the compact mark's fixed 48 × 28, so no dock ever centres on a
  measured width and an open row is never re-centred under the pointer. Do not
  measure with a preference written from a background
  `GeometryReader`: once the row held conditional content, that report never
  arrived, and every window kept a seed size (#152).
- **Effects are instructions, not suggestions.** The host never reads the state
  to decide what to do.

## The look and acceptance

The compact mark and the launcher keep one centre on screen while the row grows
inward from it. Content-sized text and native controls support larger type, and
the launcher's target stays 48 points wide at every size so that centre holds. At
rest the status glyph says what is running; revealed, the launcher's one dot says
work is live somewhere and the chooser's labelled dots say where. Changing status
must not substitute a different menu-bar brand icon. Reduce Transparency uses
opaque fills. Reduce Motion removes the frame animation and holds the voice trace
still; the trace follows Increase Contrast itself, and its recording dot stays
red, distinct from the voice colour.

`ToolbarGallery.states` supplies both tiers at every anchor, every mode with its
key, active work in its own mode and in another (Dictate selected, Draw busy),
capture counts, active presentation/personas, prompt insertion and every compact
status; `ToolbarGallery.choosers` supplies the chooser with and without live
work. The renderer uses the production `ToolbarRow` and `ToolbarChooserView`,
including the compact mark, the launcher and the Prompts button, in both themes
and standard/larger type.

Core transition tests, native layout tests and rendered fixtures establish only
the behavior they exercise. They do not prove native pointer behavior. Before
claiming a hover fix, reproduce the failure and record the native sequence. Test
repeated entry/exit, menu dismissal, content-width changes and a stationary pointer
during resize at all eight anchors and at free positions on both halves of the
display, including screen edges and Reduce Motion. A click and a double-click on
the compact mark, a click just outside its 48 × 28 target, the chooser's keyboard
and focus return with a real field in front, and VoiceOver's announcements each
need the same native evidence. Explicitly report any input-tool or hardware limit. Multi-display dragging and meeting receiver
visibility require their own evidence.

When changing the interaction model, update the state table and targeted
regressions. A passing legacy test does not justify preserving a broken experience.

## Run and review

```sh
# Reducer, production timer adapter, geometry and native layout/window checks.
swift test --disable-sandbox --filter Toolbar

# Render the actual production row, without launching Workbench or reading its data.
swift run --disable-sandbox ToolbarGalleryRenderer test-results/toolbar
```

The gallery generates individual fixtures and four overview sheets. It covers
both tiers at every anchor, each mode, active work in and out of its mode, every
compact status and the chooser, light/dark appearance and standard/larger type. `ToolbarKitTests` checks intrinsic
sizes and longer labels; the committed overview sheets in
[assets/floating-toolbar](assets/floating-toolbar) provide PR image diffs. CI
retains the full gallery as an artifact. These are real native views, not HTML
approximations. Visual acceptance still requires inspecting the images.

The surface gallery (`LocalVoice --render-surfaces`) adds the host: it drives the
production `CapturePanelController` offscreen for every mode at rest and revealed,
then switches between Dictate and Present with the row open, a width change that
reaches the host only through the row's own report, then shows Present at the
right-hand dock, revealed and at rest, and the compact mark while a synthetic
meeting records. It flags a window smaller than
its row, the check the renderer above cannot make because it sizes its own window
to the row. The host pins seed sizes until the row
reports (`CaptureHUDControls.reportSize`), so a report that never arrives leaves the
row and its corners clipped (#152). The flags appear in the gallery's index and log.
A size problem fails the run once the index is written: a row the host never heard,
a window smaller than its row, or a window that is not the size the host prefers.
A row that did not settle into its tier, which a real pointer over the invisible
panel can cause in a local run, is reported and its sizes are not compared; the
gallery's other flags are reported without failing it too. A Mac with no display
renders no host states and has nothing to fail.

The gallery also releases the same host at free positions on each half of the
display and near a dock, and reads the launcher's centre after an update, a reveal
and a collapse, while choosing Present widens the row (released just left of the
middle and on the right half), in a new host as after a relaunch, in new hosts
reading each earlier build's save and a later move by one, at the right-hand dock,
after Reset position, and at rest while a synthetic meeting records, where the
mark must stay 48 × 28 and show the recording. It opens the production chooser
panel invisibly from the bottom-right and top-left docks at larger text and from
bottom centre, and fails if it leaves the display, loses its width, scrolls with
room to spare or covers the launcher. A toolbar that does not rest where it was
put fails the run. It renders Position… and the chooser in both themes.

The same host then carries dictation, its processing and its results, docked at
bottom centre (#134 T4). Dictating and transcribing must rest as the 48 × 28 mark
on the launcher's centre with their statuses; a new failure or receipt must change
only the mark's status, reveal its own controls grown from the same centre, and
survive a collapse, and one that arrives while the row is open must wait, a kept-open
row too while a hold is on it, until it lets go; the
no-speech cue must show at the toolbar's place and give way to the mark; a Stop
pressed through the recording's completion must start nothing; and the coaching
card must sit 12 points above the mark, or below it at a top dock, centred on the
launcher, with nothing of the toolbar's in the gap and the mark unmoved. Each
fails the run. Then, with the toolbar's keyboard hold standing in for the
keyboard, which the gallery never takes: keyboard entry onto a waiting receipt
must keep the launcher row, whose launcher takes the focus, and Escape must leave
without dismissing the receipt, from the receipt's own controls too; Position…
closing onto a receipt waiting on a kept-open row must leave the launcher row with
the keyboard back; and at the right-hand dock no action of a dictation failure,
the receipt or a stopped reading may sit over the mark the pointer came from, by the
frames each view reports for its actions (#211). The floating shots render the no-speech cue, the reading that
stopped, the receipt with its ring and the coaching card.
`ToolbarPlacementTests` covers the 4-point threshold, the 16-point snap zone,
inward growth, a width change that must not move the launcher or turn the row
round, earlier saves, clamping and recovery. `--check-floating-toolbar` checks the
chooser's placement and focus rules and every earlier save's migration without a
window.

The gallery opens the Saved Prompts picker's production panel,
`PromptPickerController`, the same way: invisible, ignoring the pointer, with no
keyboard focus and no click monitors. It narrows the list to one row, adds a status
line and its Details, then shows every prompt again. A panel that is not the size
its content wants within the display, or that never heard its content's size,
fails the run, as a toolbar window does. A picker that closes during the check is
reported only.

`CaptureHUDControls` bridges the row's measured size and the core's effects into
the existing app panel. `ToolbarSession` owns the one deadline and persisted
Keep open choice. `ToolbarTrackingView` owns the one tracking area and the
120 ms reveal debounce (`ToolbarTrackingView.revealDelay`). `FloatingToolbar`
freezes the live state once per render and maps each `ToolbarOperation` to the
owner that already does it.
`ToolbarWindowMotion` owns the frame animation; ending it before a drag is synchronous.
Menu activation requires admission from the active tools session; a stale More button cannot open a menu over a recording HUD. Menu dismissal reconciles both the pointer gate and reducer. The drag event loop
exits on cancellation or app deactivation and always releases its hold.
`ToolbarTaskClock(delay:)` exposes the single 450 ms default for measured tuning.
`StageKit/WorkbenchPalette` owns the one Mac accent definition; Voice, StageKit,
the toolbar's launcher, dot and status glyphs and the gallery all consume it. The toolbar receives the colour
as a value and remains independent of application models. Native pixel tests
check both appearances. The old boolean interaction
model, global/local mouse monitors, spring loop, three fixed toolbar sizes and
426-line in-product polling harness have been removed.

A bug report needs only: selected mode, what was live, action taken, expected
result, actual result, anchor and whether Keep open was enabled. Add the smallest reproducing
sequence to the existing tests. Do not create another toolbar backlog.

The current candidate and native limits are recorded in
[the menu refinement verification](verification/2026-09-24-menu-refinement.md).
The [earlier toolbar verification](verification/2026-09-23-durable-toolbar.md)
remains historical evidence for its own source revision.
