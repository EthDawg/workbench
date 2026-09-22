/// The frozen value a toolbar view renders. Views observe this and nothing else.
///
/// The previous toolbar view observed four separate objects and recomputed its
/// labels mid-render, so a design change meant reasoning about live app state.
/// With one value the look can be reviewed as a gallery of fixtures, and a
/// regression shows up as an image diff instead of a prose claim.

public enum ToolbarTool: String, CaseIterable, Sendable {
    case dictate, snapAndTalk, annotate, present, read

    public var title: String {
        switch self {
        case .dictate: return "Dictate"
        case .snapAndTalk: return "Snap & Talk"
        case .annotate: return "Draw"
        case .present: return "Present"
        case .read: return "Read aloud"
        }
    }
    /// One symbol per tool, shared by the resting indicator, the revealed row,
    /// the menu-bar panel and the gallery, so the same job always looks the same.
    public var symbol: String {
        switch self {
        case .dictate: return "mic"
        case .snapAndTalk: return "rectangle.dashed.badge.record"
        case .annotate: return "pencil.tip"
        case .present: return "iphone"
        case .read: return "speaker.wave.2"
        }
    }
    /// Filename-safe and lower case, because these become snapshot filenames on
    /// a case-insensitive disk.
    public var slug: String {
        self == .snapAndTalk ? "snap-and-talk" : rawValue
    }
    /// The settings page this tool's secondary controls open.
    public var page: String {
        switch self {
        case .dictate: return "dictate"
        case .snapAndTalk: return "readback"
        case .annotate: return "annotate"
        case .present: return "present"
        case .read: return "speak"
        }
    }
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
    /// Side docks stand the resting indicator on end so the whole target stays
    /// on screen; every other dock lays it flat.
    public var isVertical: Bool { self == .left || self == .right }
}

public struct ToolbarViewState: Equatable, Sendable {
    /// Stable across runs: the gallery label, and the snapshot filename.
    public var name: String
    public var tier: ToolbarTier
    public var anchor: ToolbarAnchor
    public var tool: ToolbarTool
    /// What the primary button says right now. Active work replaces Start with
    /// its own finish action rather than adding a second button beside it.
    public var actionTitle: String
    public var isActionEnabled: Bool
    public var shortcut: ToolbarShortcut
    /// One short line of truthful status. Never the only way to understand state.
    public var status: String
    /// The secondary line on the pinned tier: what the next action will do.
    public var detail: String

    public init(name: String, tier: ToolbarTier, anchor: ToolbarAnchor = .bottom,
                tool: ToolbarTool = .dictate, actionTitle: String? = nil,
                isActionEnabled: Bool = true, shortcut: ToolbarShortcut = .assigned("⌃⌥Space"),
                status: String = "Ready", detail: String = "Light · Paste in a Mac field") {
        self.name = name
        self.tier = tier
        self.anchor = anchor
        self.tool = tool
        self.actionTitle = actionTitle ?? tool.title
        self.isActionEnabled = isActionEnabled
        self.shortcut = shortcut
        self.status = status
        self.detail = detail
    }
}
