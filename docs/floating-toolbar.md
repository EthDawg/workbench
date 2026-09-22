# The floating toolbar

This document owns the toolbar's behaviour. `Sources/ToolbarCore/ToolbarMachine.swift`
is the executable copy of it, and `Tests/ToolbarCoreTests` is the proof. When
the three disagree, the tests are right and the other two need fixing.

## Why this exists

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
  window to settle, drove the real controller with synthetic pointer samples,
  and replaced the production wiring before running. They were flaky and they
  did not test what shipped.

Every bug report in that period — jitter, ghost hover, a menu that collapsed
under the pointer, a drag that resized itself — is one of those three.

## The three layers

| Layer | Owns | Depends on | Tested by |
| --- | --- | --- | --- |
| **Core** `Sources/ToolbarCore` | When to show what, and the remembered choice | Nothing. No AppKit, no clock, no window | `swift test`, instantly, with no sleeps |
| **Look** SwiftUI views | How each state is drawn | One `ToolbarViewState` value | Snapshots of `ToolbarGallery.states`, light and dark |
| **Host** `CapturePanelController` | Windows, tracking areas, one timer, one animation | Core's effects | A handful of native checks: given an effect, the window lands here |

A change belongs to exactly one layer. If a change needs all three, it is three
changes.

## The behaviour

Three tiers. **Resting** is a quiet indicator. **Peeking** is revealed by the
pointer and taken away when it leaves. **Pinned** is kept open because the user
asked, or because the keyboard is here.

One rule that removes most of the old bugs: **`tier` is assigned, never derived.**
The other four fields record what the world is doing — where the pointer is,
what is holding the toolbar open, whether a timer is running, and what the user
chose last. Only `reduce` writes `tier`.

A second rule: **a hold can only prevent a collapse, never cause a reveal.**
That is why dragging the resting indicator does not resize the window you are
dragging. Keyboard focus is the one written-out exception, because focusing an
invisible indicator is useless.

### The table

| Tier | Event | Next tier | Effects |
| --- | --- | --- | --- |
| resting | pointerEntered | peeking | `show(.peeking)` |
| resting | holdBegan(.keyboard) | pinned | `show(.pinned)` — no `persistPinned` |
| resting | holdBegan(.menu / .drag) | resting | — |
| resting | pillClicked / expandClicked | pinned | `show(.pinned)`, `persistPinned(true)` |
| peeking | pointerLeft, no holds | peeking | `startGrace` |
| peeking | pointerEntered | peeking | `cancelGrace` |
| peeking | holdBegan(any) | peeking | `cancelGrace` |
| peeking | holdEnded, last hold, pointer away | peeking | `startGrace` |
| peeking | holdEnded, last hold, pointer on it | peeking | — |
| peeking | graceElapsed, still unheld and pointer away | resting | `show(.resting)` |
| peeking | graceElapsed, anything changed | unchanged | — |
| peeking | pillClicked / expandClicked | pinned | `show(.pinned)`, `persistPinned(true)` |
| pinned | pointerLeft | pinned | — |
| pinned | collapseRequested | resting | `releaseHolds`, `show(.resting)`, `persistPinned(false)` |
| pinned | holdEnded, last hold, pin not remembered | peeking or resting, by pointer | `show(…)` |
| pinned | holdEnded, last hold, pin remembered | pinned | — |
| any | surfaceLeftTools | resting | `releaseHolds`, `show(.resting)` — the remembered pin is kept |
| any | surfaceReturnedToTools | pinned or resting, by the remembered pin | `show(…)` |
| any | pointerSettled(inside:) | never promotes | `cancelGrace` or `startGrace` |

### What the invariants guarantee

`ToolbarModelCheckTests` walks every state the toolbar can reach — 62 of a
possible 384 — and applies every event to each one. Four things can never happen:

1. **Stuck open.** Revealed, with nothing holding it, no pointer on it and no
   timer running.
2. **A timer on a toolbar that is not revealed.**
3. **Keyboard focus on an invisible toolbar.**
4. **Pinned by accident** — open with no hold, without the user having chosen it.

It also proves `reduce` is pure and that a `show` effect is emitted exactly when
the tier changes.

## The host contract

The core cannot be right if the host feeds it fiction.

- **`pointerEntered` and `pointerLeft` come from one `NSTrackingArea` crossing
  and nothing else.** Never from polling the mouse location, and never from a
  frame change. A window shrinking out from under a stationary pointer is not a
  gesture, and treating it as one is what made a collapse click spring open.
- **Suspend crossings for the length of a frame animation**, then send exactly
  one `pointerSettled(inside:)` when the frame is final. That is the only
  reconciliation, and it can never reveal the toolbar.
- **One grace timer.** `startGrace` starts it, `cancelGrace` stops it, and it
  delivers exactly one `graceElapsed`. A late firing is safe — the core ignores
  it — so the host does not need generation counters.
- **One animation.** `NSAnimationContext` on the window frame. The content does
  not animate its own size at the same time.
- **Effects are instructions, not suggestions.** The host never reads the state
  to decide what to do.

## The gallery

`ToolbarGallery.states` is every state the toolbar may be seen in: three tiers at
all eight docks, each tool at each tier, unusable bindings, and work in progress.
The look is reviewed from this list, and the snapshot renderer iterates it, so a
design regression arrives as an image diff rather than a sentence in a report.

Design rules the gallery enforces:

- **The tiers reveal more of the same thing; they never switch to a different
  thing.** Resting shows the tool's glyph. Peeking adds its primary action and
  the real shortcut. Pinned adds that tool's secondary controls. A control that
  appears in one tier keeps its meaning and its position in the next.
- **Active work replaces the start action**, rather than adding a second button
  next to it.
- **An unusable binding never looks usable.** Off and failed read differently,
  and both read differently from an assigned key.
- **Sizes come from content.** No fixed point sizes: the toolbar must survive
  accessibility text sizes and longer labels (see #87).

## Adding a feature, or fixing a bug

1. Write the row in the table above, or change the one that is wrong.
2. Write the test in `ToolbarReducerTests`, named after the behaviour, not the
   mechanism. It must not sleep.
3. Make it pass in `ToolbarMachine.swift`. If the invariants or the state budget
   in `ToolbarModelCheckTests` fail, the behaviour is the problem, not the test.
4. If it changes what is on screen, add the state to `ToolbarGallery` and look at
   it in both themes before shipping.
5. Only then touch the host, and only for windows, timers and frames.

A change that needs a new field on `ToolbarState` needs a reason in the pull
request. Five fields is the budget, and the state count in the model check is
the alarm.
