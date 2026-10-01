# The floating toolbar

This document owns the toolbar's behaviour. `Sources/ToolbarCore/ToolbarMachine.swift`
is the executable copy of it, and `Tests/ToolbarCoreTests` is the proof. When
they disagree, resolve the intended behaviour against the product contract, then
update the table, implementation and regression together. A passing test is not
permission to preserve a bug.

## Role and content

**Capture where it matters.** When Snap is ready, the revealed row offers Region,
Window and Screen directly in place of its generic action. A prepared Snap & Talk
session offers the same three sources beside Review. They use the capsule's native
white icons, stable targets and hover hints; the hint explains whether selection
opens the Snap editor or begins narration. Only Region in Snap and Screen in Snap
& Talk claim the existing shortcut. Sources stay in Region, Window, Screen reading
order at either dock, and Tab reaches each before Review. An unprepared
session keeps its setup door. Active input replaces sources with its existing Stop,
Pause or Cancel. Admission is checked on both press and release, and a changed
session or operation invalidates a held capture click. Selection never changes a
shortcut default. Escape saves nothing and starts no microphone.

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
`workbench.toolbarMode.v1`. Timer is a panel row and part of Draw, not a mode; its chooser row offers the next step, Show or Hide timer and Stop timer.

**At rest the toolbar is a compact mark** (#134), whatever is running: idle,
recording, playing, paused, processing, drawing, presenting, a persona, a timer,
a Snap & Talk session, or a result waiting for the person. Its ordinary rest is a
quiet 48 × 8 handle in a fixed 48 × 28 target. Left and right edges turn this into
an 8 × 48 handle in a 28 × 48 target. It carries no selected-tool or
live-work icon: at this size the symbol adds little useful information, and one
symbol cannot describe concurrent work. Hover or click reveals the remembered
tool and its action. Only recording adds a red dot and voice trace in a 48 × 20 capsule inside the same target. All other collapsed states stay icon-free (see Status at rest). The resting window is exactly that target, and everything outside it passes clicks through. Work never
holds the row open, and a new failure or result never opens it either. Keep open
is the one explicit way to keep it up. Dictation, narration, reading and their
results keep the toolbar up even while Hide toolbar is on, at rest as the mark.

Hover, after the 120 ms dwell, or a click reveals the row. A click on the mark
only reveals it and takes the keyboard; it never starts or stops anything, and
the whole click is the mark's, so the row that appears under the pointer never
receives its mouse-up. A double-click that begins on the mark cannot start or
stop work either. A right-click opens toolbar settings, and a drag
moves the toolbar (see Placement).

**Recording, reading and their results in the same host** (#134 T4). The same
window, anchor and tiers carry dictation, narration and reading from start to
result; nothing swaps the floating window to a panel of its own. Live work is
the row: its next action is Stop, Stop narration, Pause or Resume reading, Cancel
request or Processing…, a separate slot carries the capture signal, and the chooser lists
what the work can do besides, under its capability's name: Cancel and Copy
now for a dictation, Cancel for a narration, Stop reading. Dictated words that
wait for drawing to end lead with Stop drawing, which delivers them, with Copy now
in the Dictate chooser row (#211). While drawing or a prompt insertion holds the next action, the chooser's
Read row also has reading's own next action: Cancel while it prepares, Pause
reading or Resume reading. A recording's elapsed
time is the Stop's tooltip and VoiceOver help, never its label, whose width would
tick; in the last ten seconds before the 5-minute limit, the accessible status names the limit without adding an icon. The Dictate page keeps the recording's
details.

A technical failure keeps its recovery view: dictation has its reason, Retry,
Record again or Open Workbench and Dismiss; a stopped reading has its reason,
Retry and Dismiss. These commands and their workspace doors also stay in the chooser. Dismiss keeps Read’s text and voice; Listen can render it again, while Retry belongs only to an existing failure. Saved failures do not put
warnings on the compact pill, the recording trace or Switch tool. A failure
waiting before input-consuming work began cannot replace that work's revealed
controls. Revealing, collapsing or choosing a tool does not acknowledge or retry
it. Keyboard entry reaches the launcher row; Escape returns to the app that had focus.

Delivery uses a brief, non-activating cue at the same place as No speech heard.
Confirmed insertion is quiet. A copied fallback shows its title and useful next
step for three seconds of unheld time. There is no word count, Review button, pin,
dismiss button, placement menu or visible countdown. Hover or VoiceOver focus can
hold the cue for reading. After it ends, the next hover reveals the toolbar.
The clipboard shelf and History retain the words and any unresolved delivery;
ending the cue never discards them. An uncertain paste asks the person to check
the destination before trying again and never suggests another automatic paste.

A row held open by Keep open alone can show a technical failure once its pointer,
menu, chooser, keyboard and placement holds have ended. Active input work keeps
its controls. A delivery cue never becomes a pending toolbar result and cannot
resurface as a warning or replace the row on a later hover.

The routine no-speech cue keeps its own view at the toolbar's place for under two
seconds, held by hover or VoiceOver, then the mark again (#156).

**The coaching card** (#134 T5) shows above what the toolbar shows with a 12-point
gap, or below it when the display has no room above, centred on the resting mark and
never expanding the row or moving the mark. It fades in over 160 ms, at once with
Reduce Motion. It is its own panel, sized to the
card, so the gap passes clicks through. The host allows it
(`FeedbackCoachModel.canPresent`) only while the toolbar is on screen and the card
would cover no permission prompt, no Workbench window in front, none of the
toolbar's popovers and no result's controls open in its place; reports
`didPresent` once it has been on screen for a display pass; drops a card it cannot
show, so its lesson is not spent and the attempt gets its ordinary no-speech cue; removes it on a screen capture and when a
narration starts; and fades it out in 160 ms, or at once with Reduce Motion.

Revealed, the toolbar is a black 40-point capsule: `[tool ▾] [action icon]`
plus only applicable contextual controls. There is no overflow button. Right-hand
corners reverse the physical row; side edges stack upright controls launcher first.
At standard text the ordinary row is 96 points, 136 with one contextual control,
and 176 with two. The launcher has a 48-point target; actions have 36-point targets,
4-point gaps and 8 points of far-end padding. Capture sources and the recording
signal use their existing measured slots. White symbols and inset hover backgrounds
keep targets steady. Larger text scales the controls. If the full contextual group
does not fit the display less 24 points, it is omitted together; its real workspace
and menu-bar homes remain reachable through the chooser. Top and bottom rows grow
around their centre, side columns vertically, and corners inward. The docked edge
stays eight points inside the usable screen. Hints and accessible names carry full
commands, current Persona labels, counts and the exact Stop, Pause or Resume.

The next action is the label for where you are in the journey, from one pure
function of what is live (`ToolbarNextAction`) with a fixed priority: what is
consuming your input now (inserting, dictating, capturing, narrating, drawing,
reading) whatever the mode, then the selected mode's own step or ending
(`Capture next · 3`, `Stop & transcribe`, `End presentation`, `Hide personas`),
then its start verb. Another mode's ending never claims the label: presenting
while Draw is the mode reads `Draw`, the accessible value names live work, and
the Present chooser row offers `End presentation`. Two identical screens never
read differently, and the label never ends anything but what it names. The
button latches its operation and that operation's generation as it goes down,
and acts when it comes up only if both still hold: a Stop that completes while
it is pressed is discarded, never turned into a new start. The hover hint shows
a key only for an operation that key performs: Present's key does not stop an
insertion, Dictate's key does not stop a meeting, and the persona key does not
pause a prepared set. The read-only hover hint and VoiceOver help name the current action
followed by its usable shortcut, for example `Draw · Hold ⌥D` or
`Stop · Release ⌥Space`. Hold and Release reflect the actual capture or drawing
session. A mouse-latched hold drawing, another drawing tool, or an unprepared
Snap & Talk session omits a key that would perform a different action. Disabled
and failed bindings are omitted. There is no competing whole-row tooltip. Hints
share one rail centred on the entire row, above it when there is room and below
at the top of the screen. Side columns use an inboard rail beside the whole column;
its vertical centre and edge nearest the toolbar stay fixed. Space for the longest hint determines the rail's
position, so moving between short and long hints cannot shift its centre or
change sides. The compact mark has no separate native tooltip. Hints are
click-through and close on actions, moves, resizing and collapse.

`ToolbarModeFollower` in the host watches every owner and makes a capability
the mode the moment it goes from not live to live, whichever door started it;
if several start in one tick, Present wins, then Persona. The launch snapshot is
not a start, so a restored Snap & Talk session does not move the mode.

**The launcher** always shows the same four-tile `square.grid.2x2.fill` icon,
with the accessible name and hover hint **Switch tool**. It stays identical for
all seven tools, recording and waiting results. The current tool's icon belongs
to its action and chooser row. The launcher retains its 48-point target, position,
hover response and keyboard behaviour. A click, Space, Return or Down opens the
chooser. Its accessible value names the current tool and concurrent work.
Recording has its own signal beside the launcher.

**The chooser** has seven fixed tool headers, in order: Dictate, Read, Snap,
Snap & Talk, Draw, Present and Persona. At standard text it is 320 points wide with
36-point headers. Each has its symbol, exact name, current-tool checkmark, labelled
running dot and assigned key. Choosing a header changes only the remembered tool;
it never starts or stops work, overwrites a draft or changes saved preparation.
Up/Down and typeahead move the highlight, Return chooses and Escape closes. A
refresh preserves the highlighted identity. The footer opens the selected tool’s
existing workspace; hovering another header never retargets that button.

Each live or recoverable tool has its own visible, named commands immediately
under its header. Dictate keeps Stop/Cancel, Copy now, saved-recording review and
recovery, and unresolved-delivery review/copy/dismiss. Read keeps Cancel, Pause,
Resume, Stop and its applicable failure recovery. Snap reviews the retained draft;
Snap & Talk finishes/cancels the current narration and reviews its current session.
Draw stops drawing. Present ends the live scene or stops an insertion. Persona
hides, resumes or ends the live copy/set. Independent Meetings and Timer appear
below the seven tools only while they have work or recovery; they never become
additional modes. Each has its own transport and real workspace route where one
exists. Commands recheck the exact operation identity on release. Replacing work,
or changing a command and changing it back while held, invalidates the old press;
unrelated jobs and timer ticks do not. An asynchronous Meeting Stop checks again
when its task starts.

Tab/Shift-Tab visit each native command button and the workspace footer, then
return to the tool list, with Full Keyboard Access on or off. Commands are separate
VoiceOver buttons. At larger text on narrow screens, commands use one column;
a short display scrolls the chooser and keeps keyboard targets visible. It opens
beside the launcher, fits within eight points of the display edge, and closes on
choice, Escape, outside click or focus leaving.

**Every former overflow action has an existing owner.** Frequent actions stay on
the pill; concurrent work and recovery stay in the chooser; preparation and live
adjustments stay in their workspace and capability’s menu-bar Options. Present’s
live controls bind the running snapshot even while another saved scene is selected.
They include window/full-screen, source and connection recovery, device proportions
and applicable motion controls. Apple-app handoffs remain in the connection guide
and release capture before opening the chosen app. Saved Prompts… and Switch to
Browser Tab… have explicit Present workspace controls. Persona’s workspace has
live-copy Appearance, size, position, lock, replace/update, visibility, add/remove,
front/back and explicit layout saving; saved library selection cannot silently
replace the shown artwork. Read-only preparation never disables a live control.

Settings › General owns Keep open and Position…, using the existing toolbar
preference and placement owner. The existing visibility switch stays there too.
Right-click on the pill is an optional shortcut to Position…, Keep open, Hide
toolbar and Settings…. It contains no tool actions and is not required to discover
any capability. Hide leaves independent jobs running; Window’s existing Show and
Focus commands recover the toolbar. Native menus freeze their items before tracking.

The primary keeps one stable icon target through action changes. The icon comes
from the exact latched operation: Stop, Pause, Play, Hide or the start capability.
A noninteractive text panel uses one stable position above the row, below
at a top edge, and names the hovered or focused action with its usable key and any capture count.
It ignores clicks and never takes focus. A 180 ms dwell avoids flashes; an 80 ms
exit grace bridges adjacent buttons. The first hint fades in over 120 ms; later
words replace it without moving the panel's centre or its edge nearest the row.
Menus, actions, movement, collapse and detach dismiss it immediately. Reduce
Motion presents the text without fading. Disabled or unassigned shortcut
combinations are omitted; the toolbar has no shortcut editor. Keep open is an
explicit persistent preference.

**Contextual controls.** Snap & Talk has Review while its session is open;
Draw has Tools; Present has Prompts, plus View while a presentation is live. View
contains only the current presentation’s applicable source, motion and window
controls. End stays the primary/chooser action, and Apple handoffs stay in the
connection guide. Persona always has Choose Persona, because the live camera is
one of its sources beside the saved cards (1 October): the picker lists the cards
(the shown or kept card's frozen candidates, or the saved cards when nothing is
live) and then Camera. Choosing Camera is the explicit Start camera and the shown
card stays up until the first frame; choosing a card ends a live camera and shows
that card. Restricted camera access leaves Camera disabled. A running prepared set
has Choose Set instead. Next Persona or Next set appears when more than one frozen
choice exists and advances once without opening a menu; it never cycles into the
camera. The picker uses frozen public labels and every choice checks again that
Persona is as it was drawn. One-item sets have no inert Next. Failure preserves the
shown artwork and exposes its notice through the chooser and picker. Dictate, Read and Snap have no settings accessory.
Review and Next act directly; Tools, Prompts, View and Persona selection open their
focused menus/picker. Space, Return, Enter or Down open admitted menus. The full
contextual group hides together when it cannot fit; the chooser’s workspace door
and menu-bar Options retain every adjustment.

**One popover at a time.** The chooser, toolbar context menu, the accessory's picker and
Position… close one another, and hover never opens any of them. Each holds the
row open while it is up, as a native menu does, and a crossing between the row
and it is one interaction.

**Focus.** Keyboard entry gives the launcher the keyboard. Tab then moves to the
next action, applicable contextual controls and back to the launcher, and Shift-Tab goes the
other way, in that order at every dock, the mirrored right-hand row included; a
control that is absent or disabled is passed over. The row moves
the focus itself (`ToolbarKeyCycle`), so the cycle is the same whether Full
Keyboard Access is on or off: AppKit's own key-view loop leaves buttons out while
it is off (#223). The chooser, the Prompts picker and Position… take the keyboard
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
there is no second animation clock or asynchronous size observer. The quiet
handle follows its edge: horizontal at top, bottom, corners and free positions,
vertical at the sides. Its orientation stays fixed during dragging; the guide
previews the destination shape and accessory fit, committed on release. A turn
uses the same frame clock, and recording signals stay within the changing target.
White glyphs fade in together
during the final fifth, after each target fits, and disappear before the closing
edge reaches them. Controls accept clicks only when the row has reached its full
size. Hints stay hidden through resizing, collapse and dragging.
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
Persona groupings do not create another store. The Prompts accessory and Present’s
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

`WorkbenchControlContext.activity` projects current activity from operation
owners into `ToolbarStatus`. Saved recovery, undelivered history and clipboard
ownership do not become live activity. This projection never changes the tier,
keyboard focus or collapse deadline.

| State | Collapsed appearance |
| --- | --- |
| Recording | Red recording dot and the recording owner's voice waveform in the compact target. No warning or timer icons. |
| All other states | Neutral 48 × 8 handle, or 8 × 48 at a side edge. No tool, warning, clipboard, pause or processing icons. |

The recording trace is a waveform of seven rounded bars, tallest in the middle and
thinning out to each side (Ethan, 1 October 2026; it replaces the three still lobes
of 28 September). A syllable swells from the middle outward, as tall as the
recorder's level; in silence the bars rest as a row of dots and nothing moves on its
own. It retains its input response and its Reduce Motion (one still waveform that
only brightens) and Increase Contrast behaviour. Expanded, it occupies a separate slot;
Switch tool remains the same four-tile icon. Accessible status can describe live
recording, playback, processing and paused work. Recovery commands stay with their
owners and in the chooser; preserving a failed recording never decorates another tool.

## Placement

The toolbar goes where you put it. A press on the compact mark, launcher,
primary action or empty chrome becomes a move after four points. The contextual menu controls and the
accessory keep their normal button behaviour. During dragging, a quiet guide
outlines the display's usable edges and highlights the exact landing frame.
The same geometry chooses the guide and the released position.

A window edge within sixteen points of a guide attaches there. This works along
the whole top, bottom, left or right edge, including a release beyond the usable
screen. Nearby corners and edge centres attract within the same distance. Along
an edge, the toolbar keeps its display identity and position as a fraction of that
edge, so a display resolution change preserves the placement. A release in the interior stays free.
Dragging chooses the display under the pointer.

Top and bottom rows expand equally left and right; left and right columns expand
equally up and down. Attached outer edges keep an eight-point inset at rest and
revealed. Corners keep a horizontal row that grows inward; free rows remain
horizontal and expand around their centre. The final frame stays on the usable
screen; near a corner it may need clamping along its edge. The compact target is
48 × 28 horizontally or 28 × 48 vertically, with a crisp eight-point idle capsule
and almost transparent hit padding. The chooser, Saved Prompts, Position panel
and native options open inboard of a side column, leaving its actions reachable. The
tools window has no native shadow. A recording, result or cue uses this same
position. Position floating toolbar… on Dictate opens the existing placement
control beside it.

Position… in Settings or the toolbar context menu opens one compact control with the eight docks and
Reset position, which docks at bottom centre. It is the keyboard and precise way
in, beside dragging: arrow keys move between docks, Return or Space moves the
toolbar there, and Escape closes. The control takes the keyboard without making
Workbench the active app. Opened from the toolbar's keyboard focus, a choice,
Reset or Escape gives the keyboard back to the toolbar, so a second Escape returns
to the field it came from; opened by pointer, it takes the keyboard nowhere. A
drag or a menu on the toolbar closes it.

The choice persists through `CapturePanelController`: a named dock or a free
position in `capturePanelLauncher.v1`. An edge attachment adds `edge`, `fraction`
and `displayID` to that existing record. The absolute centre and legacy direction
remain alongside it for older builds. The glyph-edge
record and compact origin/size are still written for downgrade compatibility.
An older build's later move wins when its glyph-edge copy changes. Earlier saves
retain their resting mark's place and use the new centred expansion in free
space. Named docks retain their display in `capturePanelDockDisplay.v1`, with a
copy of the legacy anchor and frame so a later move by an older build still wins.
Display removal recovers a reachable frame while retaining the saved
position. The four-point drag threshold and sixteen-point snap distance match
the other floating controls; the toolbar owns its continuous edge attachment.

## The three layers

| Layer | Owns | Depends on | Tested by |
| --- | --- | --- | --- |
| **Core** `Sources/ToolbarCore` | When to show which tier, the remembered choice, the next action for what is live (`ToolbarNextAction`), the compact status (`ToolbarStatus`), the chooser's keyboard (`ToolbarChooserState`) and the press latch (`ToolbarActionGeneration`) | Nothing. No AppKit, no clock, no window | `swift test`, instantly, with no sleeps; `ToolbarNextActionTests` walks the whole live-state product |
| **Look** `ToolbarKit/ToolbarRow`, `ToolbarChooserView` | How each tier is drawn: the compact mark and its status, the launcher row with its contextual controls, and the chooser | One `ToolbarViewState` value | Native layout tests and snapshots of `ToolbarGallery.states` and `.choosers`, light/dark and larger text |
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
a waiting result never keeps the row up; the mark remains available, with a
visible signal when needed.

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
- **One animation.** `ToolbarWindowMotion` updates origin and size together on
  one cancellable frame clock over 160 ms. An interrupted motion begins at the
  actual visible frame. Reduce Motion moves directly to the final frame. The
  content does not animate its own size at the same time.
- **Hover intent belongs to its geometry.** Suspending tracking for a resize,
  drag or surface change cancels the pending reveal dwell. Only the host's final
  pointer reconciliation may reveal at the new geometry; an old dwell cannot
  shorten a later entry. If AppKit misses an exit, the next real entry starts a
  fresh dwell rather than leaving the pill unresponsive.
- **One reference point, one growth policy.** `ToolbarGeometry` centres expansion
  along an edge and pins the outside edge. Side attachments are vertical; corners
  are horizontal and grow inward. Free rows expand around both axes of their centre.
  SwiftUI alignment, clipping, native window motion, hints and dragging use the
  same policy. A mode change sizes around that reference, and a free position
  remains free. Edge fractions belong to the placement owner.
- **The window is the row's size.** `FloatingToolbar` reports the row with
  `onGeometryChange`. Before sizing the tools, the host lays the row out
  (`layoutSubtreeIfNeeded`), so the report for the tier, mode and labels about to
  show arrives first. A reveal, a count crossing 9→10 or a mode switch goes
  straight to the right frame, and a drag keeps its window until release. At rest
  the window is the compact mark's 48 × 28 or 28 × 48 target; at full size it is the measured row.
  Reports carry their orientation and content kind, so stale rows and horizontal
  result cards cannot overwrite each other's measurements. Preview and release
  share accessory fitting for the destination axis. Do not
  measure with a preference written from a background
  `GeometryReader`: once the row held conditional content, that report never
  arrived, and every window kept a seed size (#152).
- **Effects are instructions, not suggestions.** The host never reads the state
  to decide what to do.

## The look and acceptance

The compact mark is the placement reference. The row opens symmetrically in the
interior and at top/bottom docks, and inward at a side or corner. Scaled native
icons and readable hints support larger type; the launcher retains a 48-point target. At
rest only recording draws a signal; revealed, the accessible value says
work is live somewhere and the chooser's labelled dots say where. Changing status
must not substitute a different menu-bar brand icon. The capsule stays opaque in every appearance. Reduce Motion removes the frame animation and holds the voice trace
still; the trace follows Increase Contrast itself, and its recording dot stays
red, distinct from the voice colour.

`ToolbarGallery.states` supplies both tiers at every anchor, every mode with its
key, active work in its own mode and in another (Dictate selected, Draw busy),
capture counts, active presentation/personas, prompt insertion, each tool's
contextual controls (Persona cycling, hidden artwork and a right-hand dock) and every compact
status; `ToolbarGallery.choosers` supplies the chooser with and without live
work. The renderer uses the production `ToolbarRow` and `ToolbarChooserView`,
including the compact mark, the launcher and the accessory, in both themes and
standard/larger type.

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
both tiers at every anchor, each mode, active work in and out of its mode, each
tool's accessory, every compact status and the chooser, light/dark appearance and
standard/larger type. `ToolbarKitTests` checks intrinsic
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
display and near an edge, and reads the placement reference after an update, a reveal
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
bottom centre (#134 T4). Dictating and transcribing must rest as the 48 × 28 mark on
the resting reference with their statuses; a technical failure keeps recovery in its own view and survives a collapse; a receipt is a brief cue without commands, and one that arrives while the row is open must wait, a kept-open row too
while a hold is on it, until it lets go; the no-speech cue must show at the
toolbar's place and give way to the mark; a Stop pressed through the recording's
completion must start nothing; and the coaching card must sit 12 points above the
mark, or below it at a top dock, centred on the resting reference, with nothing of the
toolbar's in the gap and the mark unmoved. Each fails the run. Then, with the
toolbar's keyboard hold standing in for the keyboard, which the gallery never takes:
keyboard entry must keep the launcher row, whose Switch tool button takes focus;
Escape must leave without discarding saved recovery. A copied cue must contain
no buttons and vanish after its own lifetime. Repeated hover after expiry must
show tools, with no warning left behind. The same checks apply at side docks.
Older technical failures remain available while a reading or recording keeps
its own controls. A new failure still offers its owner's recovery actions.

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
Menu activation requires admission from the active tools session; a stale contextual menu button cannot open a menu over a recording HUD. Menu dismissal reconciles both the pointer gate and reducer. The drag event loop
exits on cancellation or app deactivation and always releases its hold.
`ToolbarTaskClock(delay:)` exposes the single 450 ms default for measured tuning.
`StageKit/WorkbenchPalette` owns the one Mac accent definition; Voice, StageKit,
the toolbar's recording trace and the gallery consume it. The toolbar receives the colour
as a value and remains independent of application models. Native pixel tests
check both appearances. The old boolean interaction
model, global/local mouse monitors, spring loop, three fixed toolbar sizes and
426-line in-product polling harness have been removed.

A bug report needs only: selected mode, what was live, action taken, expected
result, actual result, anchor and whether Keep open was enabled. Add the smallest reproducing
sequence to the existing tests. Do not create another toolbar backlog.

The current candidate and native limits are recorded in
[the overflow-removal verification](verification/2026-09-30-pill-actions.md).
The earlier [menu refinement verification](verification/2026-09-24-menu-refinement.md) remains historical evidence.
The [earlier toolbar verification](verification/2026-09-23-durable-toolbar.md)
remains historical evidence for its own source revision.

Settings can change **Keep open** while the toolbar is hidden or suspended. The same preference is saved without revealing the toolbar or interrupting active work; the next normal return to the tools surface uses that choice.
