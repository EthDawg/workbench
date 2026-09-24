/// The complete behaviour of the floating toolbar, with no AppKit, no windows,
/// no timers and no clock. Read this one file and you know what the toolbar does.
///
/// Two tiers, because hover is the mechanism. A control that does what moving
/// the pointer already does is a second way to say the same thing, so there is
/// no minimise button, no expand button and no third tier for them to act on.
///
/// Because nothing on the toolbar dismisses it any more, a pointer resting on
/// it always means the row should be up. That is why there is no separate
/// non-revealing reconciliation event: `resting` while the pointer is inside is
/// not a state the toolbar is allowed to be in, and the model check proves it
/// cannot happen.

/// What the user can see. There is no state between these two.
public enum ToolbarTier: String, CaseIterable, Sendable {
    /// One glyph. Its whole job is to be findable and to say whether work is running.
    case resting
    /// One row: what this tool does next, and the key that does it.
    case revealed
}

/// A reason the toolbar must stay revealed although the pointer has gone.
///
/// A hold can only prevent a collapse; it never causes a reveal. Keyboard focus
/// is the single exception, written out in `reduce`, because focusing an
/// invisible glyph is useless. Keeping the rule this narrow is what stops a drag
/// from resizing the very window being dragged.
public enum ToolbarHold: String, CaseIterable, Sendable {
    case menu, drag, keyboard
}

/// Something that happened. Events are facts, never intentions about appearance.
public enum ToolbarEvent: Equatable, Sendable {
    /// The pointer is on the toolbar. Normally a real tracking-area crossing;
    /// also how the host reconciles after a frame animation, after menu tracking
    /// ends, and when the tools surface comes back, because AppKit cannot
    /// deliver a crossing to a pointer that never moved. Idempotent, so
    /// reconciling costs nothing when it agrees with what the core already knew.
    case pointerEntered
    /// The pointer is not on the toolbar. Equally idempotent, and equally the
    /// reconciliation event.
    case pointerLeft
    /// The host's grace timer finished. A stale firing is ignored.
    case graceElapsed
    case holdBegan(ToolbarHold)
    case holdEnded(ToolbarHold)
    /// Keep open was ticked or unticked in the toolbar's own menu. Unticking it
    /// is what a minimise button used to be for, in the place that owns the idea.
    case keepOpenChanged(Bool)
    /// Dictation, narration or screenshot acquisition took the window away.
    case surfaceLeftTools
    /// The tools surface is back; the remembered choice decides what is shown.
    case surfaceReturnedToTools
}

/// What the host must do. The host never reads the state to decide these.
public enum ToolbarEffect: Equatable, Sendable {
    /// Resize and redraw for this tier. Idempotent: emitted only on a change.
    case show(ToolbarTier)
    /// Start the single grace timer, which must deliver exactly one `graceElapsed`.
    case startGrace
    case cancelGrace
    /// Write the remembered keep-open choice to preferences.
    case persistKeepOpen(Bool)
    /// Cancel any open menu tracking, end any drag and drop keyboard focus.
    case releaseHolds
}

public struct ToolbarState: Hashable, Sendable {
    /// The only output.
    public private(set) var tier: ToolbarTier
    public private(set) var holds: Set<ToolbarHold>
    public private(set) var pointerInside: Bool
    public private(set) var graceRunning: Bool
    /// The remembered choice to leave the row up. It behaves like a hold that
    /// outlives the session, which is why there is no separate pinned tier.
    public private(set) var keepsOpen: Bool

    /// Launch state, read from preferences once.
    public init(keepsOpen: Bool = false) {
        self.keepsOpen = keepsOpen
        tier = keepsOpen ? .revealed : .resting
        holds = []
        pointerInside = false
        graceRunning = false
    }

    /// The whole specification. Every row of the table in docs/floating-toolbar.md
    /// is one case here and one test in ToolbarReducerTests.
    public static func reduce(_ state: ToolbarState, _ event: ToolbarEvent) -> (ToolbarState, [ToolbarEffect]) {
        var next = state
        var effects: [ToolbarEffect] = []

        func show(_ tier: ToolbarTier) {
            guard next.tier != tier else { return }
            next.tier = tier
            effects.append(.show(tier))
        }
        func cancelGrace() {
            guard next.graceRunning else { return }
            next.graceRunning = false
            effects.append(.cancelGrace)
        }
        /// Revealed, with nothing holding it and no pointer on it, is the one
        /// state that must never be allowed to persist.
        func startGraceIfAdrift() {
            guard next.tier == .revealed, next.holds.isEmpty, !next.pointerInside,
                  !next.keepsOpen, !next.graceRunning else { return }
            next.graceRunning = true
            effects.append(.startGrace)
        }
        func releaseHolds() {
            guard !next.holds.isEmpty else { return }
            next.holds = []
            effects.append(.releaseHolds)
        }

        switch event {
        case .pointerEntered:
            next.pointerInside = true
            cancelGrace()
            show(.revealed)

        case .pointerLeft:
            next.pointerInside = false
            startGraceIfAdrift()

        case .graceElapsed:
            // A timer the host already cancelled, or one whose conditions changed
            // while it ran, decides nothing.
            guard next.graceRunning else { break }
            next.graceRunning = false
            guard next.tier == .revealed, next.holds.isEmpty,
                  !next.pointerInside, !next.keepsOpen else { break }
            show(.resting)

        case .holdBegan(let hold):
            next.holds.insert(hold)
            cancelGrace()
            if hold == .keyboard { show(.revealed) }

        case .holdEnded(let hold):
            next.holds.remove(hold)
            guard next.holds.isEmpty else { break }
            startGraceIfAdrift()

        case .keepOpenChanged(let on):
            guard next.keepsOpen != on else { break }
            next.keepsOpen = on
            effects.append(.persistKeepOpen(on))
            // Unticking it inside the menu leaves the menu holding the row up;
            // it fades when the menu closes, which is the behaviour you expect.
            if on { cancelGrace(); show(.revealed) } else { startGraceIfAdrift() }

        case .surfaceLeftTools:
            cancelGrace()
            releaseHolds()
            next.pointerInside = false
            show(.resting)

        case .surfaceReturnedToTools:
            cancelGrace()
            releaseHolds()
            next.pointerInside = false
            show(next.keepsOpen ? .revealed : .resting)
        }
        return (next, effects)
    }

    /// Convenience for a host that owns one long-lived state value.
    @discardableResult
    public mutating func apply(_ event: ToolbarEvent) -> [ToolbarEffect] {
        let (next, effects) = ToolbarState.reduce(self, event)
        self = next
        return effects
    }
}
