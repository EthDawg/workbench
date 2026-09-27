/// The frozen value a toolbar view renders. Views observe this and nothing else.
///
/// The old toolbar view observed four separate objects and recomputed its labels
/// mid-render, so a design change meant reasoning about live app state. With one
/// value the look is reviewed as a gallery of fixtures, and a regression arrives
/// as an image diff instead of a claim in a report.

/// One capability or named workflow the toolbar can be in. The mode follows the
/// journey: starting anything from any door makes it the mode, and ending leaves
/// the mode where it was. Timer is not a mode; it stays a panel row.
public enum ToolbarMode: String, CaseIterable, Sendable {
    case dictate, read, snap, snapAndTalk, draw, present, persona

    public var title: String {
        switch self {
        case .dictate: return "Dictate"
        case .read: return "Read"
        case .snap: return "Snap"
        case .snapAndTalk: return "Snap & Talk"
        case .draw: return "Draw"
        case .present: return "Present"
        case .persona: return "Persona"
        }
    }
    /// One symbol per job, shared by the resting glyph, the mode strip and the
    /// menu-bar panel, so the same job always looks the same wherever it appears.
    public var symbol: String {
        switch self {
        case .dictate: return "mic"
        case .read: return "speaker.wave.2"
        case .snap: return "viewfinder"
        case .snapAndTalk: return "rectangle.dashed.badge.record"
        case .draw: return "pencil.tip"
        case .present: return "iphone"
        case .persona: return "person.crop.rectangle"
        }
    }
    /// The Workbench page this mode's preparation lives on.
    public var page: String {
        switch self {
        case .dictate: return "dictate"
        case .read: return "speak"
        case .snap: return "snap"
        case .snapAndTalk: return "readback"
        case .draw: return "annotate"
        case .present: return "present"
        case .persona: return "personas"
        }
    }
    /// Filename-safe and lower case, because these become snapshot filenames on
    /// a case-insensitive disk.
    public var slug: String { self == .snapAndTalk ? "snap-and-talk" : rawValue }
}

/// A binding is only ever offered as usable when it actually is. Off and failed
/// bindings read differently on purpose; this moved out of the view so the
/// honesty rule has a test instead of a comment.
public enum ToolbarShortcut: Equatable, Sendable {
    case assigned(String)
    case off
    case unavailable

    public var label: String {
        switch self {
        case .assigned(let keys): return keys
        case .off: return "Shortcut off"
        case .unavailable: return "Shortcut unavailable"
        }
    }
    public var isUsable: Bool {
        if case .assigned = self { return true }
        return false
    }
    /// The key as a hover hint. An off or failed binding is omitted rather than
    /// shown as text nobody can act on.
    public var hintKey: String? {
        if case .assigned(let keys) = self { return keys }
        return nil
    }
}

public enum ToolbarAnchor: String, CaseIterable, Sendable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    public var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .top: return "Top centre"
        case .topRight: return "Top right"
        case .left: return "Left centre"
        case .right: return "Right centre"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom centre"
        case .bottomRight: return "Bottom right"
        }
    }
    /// The revealed row grows inward from the docked edge, so a dock on the
    /// right grows leftward and the resting element keeps its place on screen.
    /// This is the whole of the side-dock geometry; the old build special-cased
    /// a tall pill and a taller hover frame to keep a decorative capsule fully visible.
    public var growsLeftward: Bool { self == .topRight || self == .right || self == .bottomRight }

    public var slug: String {
        switch self {
        case .topLeft: return "top-left"
        case .top: return "top"
        case .topRight: return "top-right"
        case .left: return "left"
        case .right: return "right"
        case .bottomLeft: return "bottom-left"
        case .bottom: return "bottom"
        case .bottomRight: return "bottom-right"
        }
    }
}

/// One chip in the revealed row's mode strip: a mode that is not selected.
public struct ToolbarModeChip: Equatable, Sendable {
    public var mode: ToolbarMode
    /// That mode's capability is live right now, whichever mode is selected.
    public var isBusy: Bool
    public var isEnabled: Bool
    /// The assigned key, shown in the chip's hover text beside its name.
    public var key: String?

    public init(mode: ToolbarMode, isBusy: Bool = false, isEnabled: Bool = true, key: String? = nil) {
        self.mode = mode; self.isBusy = isBusy; self.isEnabled = isEnabled; self.key = key
    }
}

public struct ToolbarViewState: Equatable, Sendable {
    /// Stable across runs: the gallery label, and the snapshot filename.
    public var name: String
    public var tier: ToolbarTier
    public var anchor: ToolbarAnchor
    public var mode: ToolbarMode
    /// What the one button says: the next action for where you are in the
    /// journey. Active work replaces the start action rather than adding a
    /// finish button beside it.
    public var actionTitle: String
    public var isActionEnabled: Bool
    /// The assigned key and any count, shown on hover over the action. The row
    /// holds no information-only text.
    public var actionHint: String?
    /// The other modes, in the strip beside the action once the row is revealed.
    public var switcher: [ToolbarModeChip]
    public var accessoryTitle: String?
    /// The selected mode's work is running. The resting glyph says so; that is
    /// the only thing it says beyond being findable.
    public var isBusy: Bool

    public init(name: String, tier: ToolbarTier, anchor: ToolbarAnchor = .bottom,
                mode: ToolbarMode = .dictate, actionTitle: String? = nil,
                isActionEnabled: Bool = true, actionHint: String? = nil,
                switcher: [ToolbarModeChip]? = nil, isBusy: Bool = false) {
        self.name = name
        self.tier = tier
        self.anchor = anchor
        self.mode = mode
        self.actionTitle = actionTitle ?? mode.title
        self.isActionEnabled = isActionEnabled
        self.actionHint = actionHint
        self.switcher = switcher ?? ToolbarMode.allCases.filter { $0 != mode }.map { ToolbarModeChip(mode: $0) }
        self.accessoryTitle = mode == .present ? "Prompts" : nil
        self.isBusy = isBusy
    }
}
