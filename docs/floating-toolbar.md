# The floating toolbar

This document owns the toolbar's behaviour. `Sources/ToolbarCore/ToolbarMachine.swift`
is the executable copy of it, and `Tests/ToolbarCoreTests` is the proof. When
they disagree, resolve the intended behaviour against the product contract, then
update the table, implementation and regression together. A passing test is not
permission to preserve a bug.

## Role and content

The floating toolbar is the shared live control surface for Snap & Talk, Draw,
Present and Persona Overlay. Desktop pages own preparation and saved libraries.
The compact menu-bar panel owns quick utilities, adjustments and shortcut editing.
Dictate and Read expose only their compact active controls here.

**The mode follows you.** A mode is one capability or named workflow: Dictate,
Read, Snap, Snap & Talk, Draw, Present or Persona. Starting anything from any
door (a key, a panel row, Home, an app menu, the toolbar itself) makes it the
mode; ending leaves the mode where it was. Before anything has ever been started
the seed is Dictate, because it works in every app with only the microphone. The
choice persists across relaunch under `workbench.toolbarMode.v1`. Timer is a
panel row and a Present option, not a mode.

At rest the toolbar is one element, `[mode glyph][next action]`. The label is
the next action for where you are in the journey, from one pure function of what
is live (`ToolbarNextAction`) with a fixed priority: what is consuming your input
now (inserting, dictating, capturing, narrating, drawing, reading) whatever the
mode, then the selected mode's own step or ending (`Capture next · 3`,
`Stop transcribing`, `End presentation`, `Hide personas`), then its start verb.
Another mode's ending never claims the label: presenting while Draw is the mode
reads `Draw`, the Present chip's dot says the scene is live, and the glyph menu
offers `End presentation`. Two identical screens never read differently, and the
label never ends anything but what it names. Click the label to do it, click or
right-click the glyph for the menu, drag anywhere to move. Work running in the
selected mode is a dot on the glyph. The hover hint shows a key only for an
operation that key performs: Present's key does not stop an insertion, Dictate's
key does not stop a meeting, and the persona key does not pause a prepared set.
A hint names the key that starts the capability; that same key also stops it
only in toggle activation (the pen key ends drawing only when the pen is the
active tool and Draw is set to toggle).

`ToolbarModeFollower` in the host watches every owner and makes a capability
the mode the moment it goes from not live to live, whichever door started it;
if several start in one tick, Present wins, then Persona. The launch snapshot is
not a start, so a restored Snap & Talk session does not move the mode.

Hover reveals the row: the same element in the same place, then a divider, the
other modes as chips, and the mode's accessory. A chip's hover text says its
name and key; a click switches; hover never opens anything. A chip's dot says
that mode's work is live while another mode is selected. The primary keeps the
width of the widest label any mode would show for the current live state, so a
mode switch never moves the chips under the pointer, idle or mid-session. The row holds no information-only text: the assigned key and
any count are the action's hover hint. Snap & Talk keeps its session capture
count in the label between captures and while saving. Present has a Prompts
picker beside its action. Disabled or unassigned shortcut combinations are
omitted; the toolbar has no shortcut editor. Keep open is an explicit persistent
preference.

The glyph menu is the mode's own options plus four constant items: the next
action with its key, then only the current mode's items, then cross-mode finish
items (`Stop drawing`, `End presentation`, `Hide persona`/`Hide personas`/
`Show personas`, `Stop transcribing`) when that work runs in another mode,
then Position, Keep open, Hide toolbar and Settings. There is no Change tool.
Dictate, Read and Snap are start and stop on this surface, so each carries one
door to its page and nothing else, named as `Open Dictate…`, `Open Read…` and
`Open Snap…`. Snap & Talk offers its review. Draw holds the
drawing menu inline. Present holds the presentation items inline, Saved Prompts…
and Switch to Browser Tab; source, reconnect, proportions, motion, window
placement, native-app handoff and End remain reachable there. Persona holds the
persona menu inline: the frozen session's public labels, size, position, lock,
add/remove, visibility, explicit layout saving and End. Mac colour selection
updates the same drawing settings from either entry point. Native menus snapshot
their content before tracking rather than rebuilding under the pointer.

Saved Prompts reads the existing Saved Resources library. Favourite, Product and
Persona groupings do not create another store. The Prompts accessory and the
glyph menu's Saved Prompts… open one picker: a search field, favourites and then
every other prompt once, and one optional Product or Persona filter that narrows
the list without a submenu. It is a transient panel of at most 420 points, kept
16 points inside the display near either edge, above a bottom dock and below a
top one. Long names wrap to two lines or truncate and keep their full accessible
text. It takes keyboard focus without activating Workbench, holds the row open
as a native menu does, and closes on Escape, a click outside, a second click on
Prompts or a choice; ↑ ↓ and Return choose. A choice acts only after the picker
has gone, as a menu item's action runs after tracking.

The original field, value and UTF-16 selection are captured before the picker
opens. Supported fields receive confirmed literal chunks; other readable fields
get one guarded paste labelled as such. Without Accessibility approval, or with
no readable field, the action is Copy prompt: one copy of the exact text and the
Copied, Paste with ⌘V. receipt, with no paste or Accessibility write. The last
delivery is one line naming its destination, with Details for the full reason.
Escape, Stop, changed focus/selection/value and shortcut editing cancel
insertion. No partial write is replayed and no submit key is sent.

## The three layers

| Layer | Owns | Depends on | Tested by |
| --- | --- | --- | --- |
| **Core** `Sources/ToolbarCore` | When to show which tier, the remembered choice, and the next action for what is live (`ToolbarNextAction`) | Nothing. No AppKit, no clock, no window | `swift test`, instantly, with no sleeps; `ToolbarNextActionTests` walks the whole live-state product |
| **Look** `ToolbarKit/ToolbarRow` | How each tier is drawn: the resting element, the strip, the accessory | One `ToolbarViewState` value | Native layout tests and snapshots of `ToolbarGallery.states`, light/dark and larger text |
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
is why dragging the resting glyph does not resize the window you are dragging.
Keyboard focus is the one written-out exception, because focusing an invisible
glyph is useless.

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
  wider than the resting element, so its frame moves out from under a stationary
  pointer every time it opens and closes, and that is geometry, not a gesture.
- **Entry into a resting toolbar is debounced 120 ms; exits and settles are
  immediate.** A pointer passing across the resting element on its way somewhere
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
- **The row grows inward from the docked edge**, so the resting element keeps
  its place on screen and a right-hand dock does not run off it.
  `ToolbarAnchor.growsLeftward` is the whole of that geometry; `ToolbarGeometry`
  centres the top and bottom docks on the measured resting width.
- **Effects are instructions, not suggestions.** The host never reads the state
  to decide what to do.

## The look and acceptance

The resting element keeps its screen position while the row grows inward from
its dock. A scaled hit area, content-sized text and native controls support
larger type. Resting activity is a small dot on the glyph, and a chip's dot says
that mode's work is live; changing status must not substitute a different
menu-bar brand icon. Reduce Transparency uses an opaque background. Reduce Motion
removes the frame animation.

`ToolbarGallery.states` supplies both tiers at every anchor, every mode with its
key, active work in its own mode and in another (Dictate selected, Draw busy),
capture counts, active presentation/personas and prompt insertion. The renderer
uses the production `ToolbarRow`, including its strip and Prompts button, in both
themes and standard/larger type.

Core transition tests, native layout tests and rendered fixtures establish only
the behavior they exercise. They do not prove native pointer behavior. Before
claiming a hover fix, reproduce the failure and record the native sequence. Test
repeated entry/exit, menu dismissal, content-width changes and a stationary pointer
during resize at all eight anchors, including screen edges and Reduce Motion.
Explicitly report any input-tool or hardware limit. Multi-display dragging and
meeting receiver visibility require their own evidence.

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
both tiers at every anchor, each mode, active work in and out of its mode,
light/dark appearance and standard/larger type. `ToolbarKitTests` checks intrinsic
sizes and longer labels; the committed overview sheets in
[assets/floating-toolbar](assets/floating-toolbar) provide PR image diffs. CI
retains the full gallery as an artifact. These are real native views, not HTML
approximations. Visual acceptance still requires inspecting the images.

`CaptureHUDControls` bridges the row's measured size and the core's effects into
the existing app panel. `ToolbarSession` owns the one deadline and persisted
Keep open choice. `ToolbarTrackingView` owns the one tracking area and the
120 ms reveal debounce (`ToolbarTrackingView.revealDelay`). `FloatingToolbar`
freezes the live state once per render and maps each `ToolbarOperation` to the
owner that already does it.
`ToolbarWindowMotion` owns the frame animation; ending it before a drag is synchronous.
Menu activation requires admission from the active tools session; a stale glyph cannot open a menu over a recording HUD. Menu dismissal reconciles both the pointer gate and reducer. The drag event loop
exits on cancellation or app deactivation and always releases its hold.
`ToolbarTaskClock(delay:)` exposes the single 450 ms default for measured tuning.
`StageKit/WorkbenchPalette` owns the one Mac accent definition; Voice, StageKit,
the toolbar glyph/dot and gallery all consume it. The toolbar receives the colour
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
