/// The flat tool chooser (#134). The launcher opens one list of the seven tools; choosing one
/// changes only the remembered tool. It never records, pastes, stops a job or changes a draft.

/// One row: a tool, whether it is the chosen one, whether its work is live, and its key.
public struct ToolbarToolChoice: Equatable, Hashable, Sendable, Identifiable {
    public var mode: ToolbarMode
    public var isSelected: Bool
    /// That tool's work is running, whichever tool is chosen.
    public var isLive: Bool
    /// The assigned key, or nil when it is off or failed.
    public var key: String?
    /// Commands belong to this activity, never to the selected toolbar mode.
    public var actions: [ToolbarChooserAction] = []
    public var detail: String? = nil
    public var id: ToolbarMode { mode }

    public init(mode: ToolbarMode, isSelected: Bool = false, isLive: Bool = false, key: String? = nil) {
        self.mode = mode; self.isSelected = isSelected; self.isLive = isLive; self.key = key
    }
}

/// A frozen, explicitly named command. The identity includes the owner's state so a
/// stale Pause, Stop or recovery command cannot act on newer work.
public struct ToolbarChooserAction: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var identity: String
    public init(_ id: String, _ title: String, identity: String = "") {
        self.id = id; self.title = title; self.identity = identity
    }
}

/// Meetings and Timer are independent jobs, not additional toolbar modes.
public struct ToolbarChooserActivity: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var symbol: String
    public var detail: String?
    public var actions: [ToolbarChooserAction]
    public init(id: String, title: String, symbol: String, detail: String? = nil, actions: [ToolbarChooserAction]) {
        self.id = id; self.title = title; self.symbol = symbol; self.detail = detail; self.actions = actions
    }
}

public struct ToolbarChooserActivities: Equatable, Sendable {
    public var rows: [ToolbarChooserActivity]
    public init(_ rows: [ToolbarChooserActivity] = []) { self.rows = rows }
}

/// The chooser's keyboard state, with no view: Up and Down move the highlight, typing jumps
/// to the tool whose name starts with what was typed, as native menus do, and Return commits
/// the highlighted tool by identity. Live updates keep the highlight on the same tool.
public struct ToolbarChooserState: Equatable, Sendable {
    public private(set) var choices: [ToolbarToolChoice]
    public private(set) var highlighted: ToolbarMode
    private var typed = ""
    private var typedAt: Double = -.infinity
    /// Typing more within this many seconds extends the name being matched.
    public static let typeAheadWindow = 1.0

    public init(choices: [ToolbarToolChoice]) {
        self.choices = choices
        highlighted = choices.first(where: \.isSelected)?.mode ?? choices.first?.mode ?? .dictate
    }

    /// New live facts for the same tools. The highlight follows the tool, never the row index.
    public mutating func refresh(_ choices: [ToolbarToolChoice]) {
        self.choices = choices
        if !choices.contains(where: { $0.mode == highlighted }) {
            highlighted = choices.first(where: \.isSelected)?.mode ?? choices.first?.mode ?? highlighted
        }
    }

    /// Up is -1 and Down is +1. The highlight stops at the ends, as a menu's does.
    public mutating func move(_ step: Int) {
        guard let index = choices.firstIndex(where: { $0.mode == highlighted }), !choices.isEmpty else { return }
        highlighted = choices[min(max(0, index + step), choices.count - 1)].mode
        typed = ""
    }

    public mutating func highlight(_ mode: ToolbarMode) {
        if choices.contains(where: { $0.mode == mode }) { highlighted = mode }
    }

    /// Type-ahead: the first tool whose name starts with the typed text, case-insensitively.
    /// Typing within the window extends the text; text no tool starts with leaves the
    /// highlight where it is, as a menu does, until a pause starts the text again.
    public mutating func type(_ text: String, at time: Double) {
        let text = text.lowercased()
        guard !text.isEmpty else { return }
        typed = time - typedAt <= Self.typeAheadWindow ? typed + text : text
        typedAt = time
        if let match = firstMatch(typed) { highlighted = match }
    }

    private func firstMatch(_ prefix: String) -> ToolbarMode? {
        choices.first { $0.mode.title.lowercased().hasPrefix(prefix) }?.mode
    }

    /// The tool Return commits.
    public var committed: ToolbarMode { highlighted }
}

/// A press on the next action (#134). The operation and its generation are latched on
/// mouse-down, and the press acts on mouse-up only if both still hold. So a Stop that
/// completes while the button is held is discarded rather than resolving to a new Start.
public struct ToolbarPressLatch: Equatable, Sendable {
    public let operation: ToolbarOperation
    public let generation: Int
}

/// Counts every change of the next action's operation that the host observes, so a press can
/// tell whether what it pressed is still what the button does, even if the operation changed
/// and came back while it was held.
public struct ToolbarActionGeneration: Equatable, Sendable {
    public private(set) var operation: ToolbarOperation?
    public private(set) var generation = 0
    public init() {}

    /// Record the operation the host now shows; returns the current generation.
    @discardableResult
    public mutating func observe(_ operation: ToolbarOperation) -> Int {
        if operation != self.operation { self.operation = operation; generation += 1 }
        return generation
    }

    /// Latches the operation as the button goes down, but only if it is what the button showed at
    /// its last redraw. A change since then was never seen, such as a Stop that completed just
    /// before the press, so the press does nothing rather than act on a label nobody read.
    public func latch(_ operation: ToolbarOperation) -> ToolbarPressLatch? {
        guard operation == self.operation else { return nil }
        return ToolbarPressLatch(operation: operation, generation: generation)
    }

    /// On mouse-up, with the operation the button would perform now.
    public mutating func admits(_ latch: ToolbarPressLatch, now operation: ToolbarOperation) -> Bool {
        observe(operation) == latch.generation && operation == latch.operation
    }
}

/// One press of the next action, from mouse-down to mouse-up (#134). The host tells it each
/// operation the button shows as it redraws; a press latches what the button showed and acts on
/// mouse-up only if the same operation, in the same generation, is still the next action.
public final class ToolbarPressGate {
    public private(set) var generation = ToolbarActionGeneration()
    public init() {}

    /// The operation the button shows at a redraw.
    public func shown(_ operation: ToolbarOperation) { generation.observe(operation) }

    /// Mouse-down: what to do if the press ends as a click, or nil when there is nothing to do.
    /// `resolve` reads the next action from the owners each time it is called.
    public func press(_ resolve: @escaping () -> ToolbarNextAction,
                      perform: @escaping (ToolbarOperation) -> Void) -> (() -> Void)? {
        let down = resolve()
        guard down.isEnabled, let latch = generation.latch(down.operation) else { return nil }
        return { [weak self] in
            guard let self else { return }
            let up = resolve()
            guard up.isEnabled, self.generation.admits(latch, now: up.operation) else { return }
            perform(up.operation)
        }
    }
}
