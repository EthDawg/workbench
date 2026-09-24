/// The frozen value a toolbar view renders. Views observe this and nothing else.
///
/// The old toolbar view observed four separate objects and recomputed its labels
/// mid-render, so a design change meant reasoning about live app state. With one
/// value the look is reviewed as a gallery of fixtures, and a regression arrives
/// as an image diff instead of a claim in a report.

public enum ToolbarTool: String, CaseIterable, Sendable {
    case dictate, snapAndTalk, annotate, present, persona, read, timer

    public var title: String {
        switch self {
        case .dictate: return "Dictate"
        case .snapAndTalk: return "Snap & Talk"
        case .annotate: return "Draw"
        case .present: return "Present"
        case .read: return "Read"
        case .persona: return "Persona Overlay"
        case .timer: return "Timer"
        }
    }
    /// One symbol per job, shared by the resting glyph, the revealed row and the
    /// menu-bar panel, so the same job always looks the same wherever it appears.
    public var symbol: String {
        switch self {
        case .dictate: return "mic"
        case .snapAndTalk: return "rectangle.dashed.badge.record"
        case .annotate: return "pencil.tip"
        case .present: return "iphone"
        case .read: return "speaker.wave.2"
        case .persona: return "person.crop.rectangle"
        case .timer: return "timer"
        }
    }
    /// The settings page this tool's options open, from the toolbar's own menu.
    public var page: String {
        switch self {
        case .dictate: return "dictate"
        case .snapAndTalk: return "readback"
        case .annotate: return "annotate"
        case .present: return "present"
        case .read: return "speak"
        case .persona, .timer: return "present"
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
}

/// Contextual status and assigned keys. Session counts remain useful between
/// captures; unavailable bindings are not rendered as toolbar controls.
public enum ToolbarTrailing: Equatable, Sendable {
    case shortcut(ToolbarShortcut)
    case status(String)

    public var text: String {
        switch self {
        case .shortcut(let shortcut): return shortcut.label
        case .status(let status): return status
        }
    }
    /// True where the text names something the user cannot act on.
    public var readsAsUnavailable: Bool {
        if case .shortcut(let shortcut) = self { return !shortcut.isUsable }
        return false
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
    /// right grows leftward and the glyph keeps its place on screen. This is the
    /// whole of the side-dock geometry; the old build special-cased a tall pill
    /// and a taller hover frame to keep a decorative capsule fully visible.
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

public struct ToolbarViewState: Equatable, Sendable {
    /// Stable across runs: the gallery label, and the snapshot filename.
    public var name: String
    public var tier: ToolbarTier
    public var anchor: ToolbarAnchor
    public var tool: ToolbarTool
    /// What the one button says. Active work replaces the start action rather
    /// than adding a finish button beside it.
    public var actionTitle: String
    public var isActionEnabled: Bool
    public var trailing: ToolbarTrailing
    public var accessoryTitle: String?
    /// Work is running. The resting glyph says so; that is the only thing it
    /// says beyond being findable.
    public var isBusy: Bool

    public init(name: String, tier: ToolbarTier, anchor: ToolbarAnchor = .bottom,
                tool: ToolbarTool = .dictate, actionTitle: String? = nil,
                isActionEnabled: Bool = true,
                trailing: ToolbarTrailing = .shortcut(.assigned("⌃⌥Space")),
                isBusy: Bool = false, accessoryTitle: String? = nil) {
        self.name = name
        self.tier = tier
        self.anchor = anchor
        self.tool = tool
        self.actionTitle = actionTitle ?? tool.title
        self.isActionEnabled = isActionEnabled
        self.trailing = trailing
        // Opt-in: the live state decides whether the row carries an accessory.
        self.accessoryTitle = accessoryTitle
        self.isBusy = isBusy
    }
}
