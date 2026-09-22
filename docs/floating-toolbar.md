# The floating toolbar

This document owns the toolbar's behaviour. `Sources/ToolbarCore/ToolbarMachine.swift`
is the executable copy of it, and `Tests/ToolbarCoreTests` is the proof. When
the three disagree, the tests are right and the other two need fixing.

## What it is

A glyph at the edge of the screen. Point at it and one row appears: what this
tool does next, and the key that does it. Move away and the row goes.

```
resting      [ ◉ ]

revealed     [ ◉ ▾ ]  Dictate              ⌃⌥Space
             [ ◉ ▾ ]  Done drawing         Drawing
             [ ◉ ▾ ]  Capture next         3 captures
```

Three elements in the row, and every one of them is load-bearing. The glyph is
the menu. The button is the action. The trailing slot is the key you could have
pressed instead, or — while work is running — what the work is doing. Never both.

## What is not on it, and why

Each of these was on an earlier build. They are listed so they do not come back
one pull request at a time.

| Removed | Why |
| --- | --- |
| **Minimise button** | Moving the pointer away already does this. A second way to say it is a control that has to be laid out, animated, tested and explained, in the one tier where space is tightest. |
| **Expand button** | It existed to reach a third tier that existed to hold the minimise button. |
| **Pinned tier** | Keep open is a choice, not a different look. It is a tick in the menu, and it means the row does not collapse. Nothing else changes, so there is nothing else to design. |
| **Six-dot drag grip** | Press and drag anywhere on the toolbar that is not the button. Position is also in the menu. |
| **Detail line** | A third row to say what the button was about to do, under a button that already says it. |
| **Status and shortcut together** | Two trailing labels competing meant neither read as the answer. One slot, and what it holds depends on whether work is running. |
| **Icon-only tool selector strip** | Five icons the user has to learn before they can choose. Change tool is a menu with names and checkmarks. |
| **A second finish button** | Active work replaces the start action; Start and Stop are never both present. |

The test for anything new: **if the pointer, a keystroke or the menu already does
it, it is not a control.**

## Why the code is shaped this way

The toolbar was rebuilt several times and stayed buggy. The cause was not the
individual fixes, it was the shape:

- **Appearance was derived from six booleans on every read.** 64 combinations
  were legal and most were meaningless. `suppressHoverUntilExit` existed only to
  patch one of them — a collapse click springing back open because the pointer
  had not moved.
- **Two animation systems ran at once.** A hand-written spring interpolated the
  window frame on a 16 ms loop while SwiftUI ran its own transition on the
  content, and hover was hit-tested against the union of the two frames. The
  target you were aiming at was moving.
- **The tests measured timing.** They polled for up to three seconds for the
  window to settle and lived in `Sources`, compiled into the product.

## The three layers

| Layer | Owns | Depends on | Tested by |
| --- | --- | --- | --- |
| **Core** `Sources/ToolbarCore` | When to show which tier, and the remembered choice | Nothing. No AppKit, no clock, no window | `swift test`, instantly, with no sleeps |
| **Look** SwiftUI views | How each tier is drawn | One `ToolbarViewState` value | Snapshots of `ToolbarGallery.states`, light and dark |
| **Host** `CapturePanelController` | Windows, tracking areas, one timer, one animation | Core's effects | A handful of native checks: given an effect, the window lands here |

A change belongs to exactly one layer. If a change needs all three, it is three
changes.

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
| any | pointerSettled(inside:) | never reveals | `cancelGrace` or `startGrace` |

Unticking **Keep open** inside the open menu is the one worth walking through:
the preference is written immediately, the menu still holds the row up, and the
row fades when the menu closes. That is exactly what the minimise button did,
issued by the control that owns the idea.

### What the invariants guarantee

`ToolbarModelCheckTests` walks every state the toolbar can reach — 48 of a
possible 128 — and applies every event to each one. Four things can never happen:

1. **Stuck open.** Revealed, with nothing holding it, no pointer on it, not kept
   open and no timer running.
2. **A timer on a toolbar that is not revealed.**
3. **A countdown against a toolbar the user asked to keep open.**
4. **Keyboard focus on an invisible toolbar.**

It also proves `reduce` is pure and that a `show` effect is emitted exactly when
the tier changes.

## The host contract

The core cannot be right if the host feeds it fiction.

- **`pointerEntered` and `pointerLeft` come from one `NSTrackingArea` crossing
  and nothing else.** Never from polling the mouse location, and never from a
  frame change. The row is much wider than the glyph, so the frame moves out from
  under a stationary pointer every time it opens and closes; that is geometry,
  not a gesture.
- **Suspend crossings for the length of a frame animation**, then send exactly
  one `pointerSettled(inside:)` when the frame is final. That is the only
  reconciliation, and it can never reveal the toolbar.
- **One grace timer.** `startGrace` starts it, `cancelGrace` stops it, and it
  delivers exactly one `graceElapsed`. A late firing is safe — the core ignores
  it — so the host needs no generation counters.
- **One animation.** `NSAnimationContext` on the window frame. The content does
  not animate its own size at the same time.
- **The row grows inward from the docked edge**, so the glyph keeps its place on
  screen and a right-hand dock does not run off it. `ToolbarAnchor.growsLeftward`
  is the whole of that geometry.
- **Effects are instructions, not suggestions.** The host never reads the state
  to decide what to do.

## The look

`ToolbarGallery.states` is every state the toolbar may be seen in: both tiers at
all eight docks, each tool at each tier, unusable bindings, and work in progress
including the resting glyph while it runs. The look is reviewed from this list,
and the snapshot renderer iterates it, so a design regression arrives as an image
diff rather than a sentence in a report.

- **Resting says two things and no more:** which tool is selected, and whether
  work is running. It has no label, no capsule and no grip.
- **Revealed is one row.** The glyph keeps its place from the resting tier, so
  the row grows out of the glyph rather than replacing it.
- **Active work replaces the start action** and moves the status into the
  trailing slot, where the shortcut was.
- **An unusable binding never looks usable.** Off and failed read differently,
  and both read differently from an assigned key.
- **Sizes come from content.** No fixed point sizes: the toolbar has to survive
  accessibility text sizes and longer labels (see #87).
- **The trailing slot is a glance, not a sentence.** The longest it may ever say
  is `Shortcut unavailable`, and a test holds that budget. Two fixtures were
  already over it the first time the gallery was looked at.

Everything else lives in the glyph's menu: Change tool, this tool's own options,
Position, Keep open, Hide toolbar, Keyboard shortcuts and Settings. A menu costs
nothing at rest, which is why it is where a second control belongs.

## Adding a feature, or fixing a bug

1. Check it against **What is not on it** first. Most new controls are a second
   way to do something the pointer, a key or the menu already does.
2. Write the row in the table above, or change the one that is wrong.
3. Write the test in `ToolbarReducerTests`, named after the behaviour, not the
   mechanism. It must not sleep.
4. Make it pass in `ToolbarMachine.swift`. If the invariants or the state budget
   in `ToolbarModelCheckTests` fail, the behaviour is the problem, not the test.
5. If it changes what is on screen, add the state to `ToolbarGallery` and look at
   it in both themes before shipping.
6. Only then touch the host, and only for windows, timers and frames.

A change that needs a new field on `ToolbarState`, or a third tier, needs a
reason in the pull request. Five fields and two tiers is the budget, and the
state count in the model check is the alarm.
