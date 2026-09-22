/// The complete behaviour of the floating toolbar, with no AppKit, no windows,
/// no timers and no clock. Read this one file and you know what the toolbar does.
///
/// The previous implementation derived what to show from six booleans on every
/// read, so 64 combinations were legal and most were meaningless. Here exactly
/// one property is an output — `tier` — and it is only ever assigned by `reduce`.
/// Everything else records what the world is doing.

/// What the user can see.
public enum ToolbarTier: String, CaseIterable, Sendable {
    /// A quiet indicator. The only resting job is to be findable and clickable.
    case resting
    /// Revealed by the pointer, and taken away again when the pointer leaves.
    case peeking
    /// Kept open because the user asked for it, or because the keyboard is here.
    case pinned
}

/// A reason the toolbar must stay open although the pointer has gone.
///
/// A hold can only prevent a collapse; it never causes a reveal. Keyboard focus
/// is the single exception, written out in `reduce`, because focusing an
/// invisible pill is useless. Keeping the rule this narrow is what stops a drag
/// from resizing the very window being dragged.
public enum ToolbarHold: String, CaseIterable, Sendable {
    case menu, drag, keyboard
}

/// Something that happened. Events are facts, never intentions about appearance.
public enum ToolbarEvent: Equatable, Sendable {
    /// A real inward crossing of the toolbar's tracking area, and the only event
    /// that can reveal the toolbar by pointer. Never send it from a poll of the
    /// mouse location, and never from a frame change: a window shrinking out
    /// from under a stationary pointer is how a collapse used to spring open again.
    case pointerEntered
    /// A real outward crossing.
    case pointerLeft
    /// One reconciliation after the host finishes a frame animation, when the
    /// window may have moved out from under a pointer that never moved. It
    /// records where the pointer is and can never promote a tier.
    case pointerSettled(inside: Bool)
    /// The host's grace timer finished. A stale firing is ignored.
    case graceElapsed
    /// The resting indicator was clicked.
    case pillClicked
    /// The expand control on the revealed toolbar was clicked.
    case expandClicked
    /// Collapse, from the minimise button, the menu item or the Escape key.
    case collapseRequested
    case holdBegan(ToolbarHold)
    case holdEnded(ToolbarHold)
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
    /// Write the remembered open/closed choice to preferences.
    case persistPinned(Bool)
    /// Cancel any open menu tracking, end any drag and drop keyboard focus.
    case releaseHolds
}

public struct ToolbarState: Hashable, Sendable {
    /// The only output.
    public private(set) var tier: ToolbarTier
    public private(set) var holds: Set<ToolbarHold>
    public private(set) var pointerInside: Bool
    public private(set) var graceRunning: Bool
    /// The remembered "keep it open" choice. A temporary keyboard reveal never
    /// writes it, so tabbing through the toolbar cannot silently change a setting.
    public private(set) var pinnedPreference: Bool

    /// Launch state, read from preferences once.
    public init(pinnedPreference: Bool = false) {
        self.pinnedPreference = pinnedPreference
        tier = pinnedPreference ? .pinned : .resting
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
            guard next.tier == .peeking, next.holds.isEmpty, !next.pointerInside, !next.graceRunning else { return }
            next.graceRunning = true
            effects.append(.startGrace)
        }
        func releaseHolds() {
            guard !next.holds.isEmpty else { return }
            next.holds = []
            effects.append(.releaseHolds)
        }
        func remember(_ pinned: Bool) {
            guard next.pinnedPreference != pinned else { return }
            next.pinnedPreference = pinned
            effects.append(.persistPinned(pinned))
        }

        switch event {
        case .pointerEntered:
            next.pointerInside = true
            cancelGrace()
            if next.tier == .resting { show(.peeking) }

        case .pointerLeft:
            next.pointerInside = false
            startGraceIfAdrift()

        case .pointerSettled(let inside):
            next.pointerInside = inside
            if inside { cancelGrace() } else { startGraceIfAdrift() }

        case .graceElapsed:
            // A timer the host already cancelled, or one whose conditions changed
            // while it ran, decides nothing.
            guard next.graceRunning else { break }
            next.graceRunning = false
            guard next.tier == .peeking, next.holds.isEmpty, !next.pointerInside else { break }
            show(.resting)

        case .pillClicked, .expandClicked:
            cancelGrace()
            show(.pinned)
            remember(true)

        case .collapseRequested:
            // Collapse is itself a menu item, so the menu that issued it is still
            // tracking. Tearing every hold down is what makes the click stick.
            cancelGrace()
            releaseHolds()
            show(.resting)
            remember(false)

        case .holdBegan(let hold):
            next.holds.insert(hold)
            cancelGrace()
            if hold == .keyboard { show(.pinned) }

        case .holdEnded(let hold):
            next.holds.remove(hold)
            guard next.holds.isEmpty else { break }
            if next.tier == .pinned, !next.pinnedPreference {
                // A keyboard reveal ending. The pointer decides where it lands,
                // and the remembered choice is left exactly as the user set it.
                show(next.pointerInside ? .peeking : .resting)
            } else {
                startGraceIfAdrift()
            }

        case .surfaceLeftTools:
            cancelGrace()
            releaseHolds()
            next.pointerInside = false
            show(.resting)

        case .surfaceReturnedToTools:
            cancelGrace()
            releaseHolds()
            next.pointerInside = false
            show(next.pinnedPreference ? .pinned : .resting)
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
