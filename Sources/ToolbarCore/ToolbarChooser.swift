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
    public var id: ToolbarMode { mode }

    public init(mode: ToolbarMode, isSelected: Bool = false, isLive: Bool = false, key: String? = nil) {
        self.mode = mode; self.isSelected = isSelected; self.isLive = isLive; self.key = key
    }
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

    public mutating func latch(_ operation: ToolbarOperation) -> ToolbarPressLatch {
        ToolbarPressLatch(operation: operation, generation: observe(operation))
    }

    /// On mouse-up, with the operation the button would perform now.
    public mutating func admits(_ latch: ToolbarPressLatch, now operation: ToolbarOperation) -> Bool {
        observe(operation) == latch.generation && operation == latch.operation
    }
}
