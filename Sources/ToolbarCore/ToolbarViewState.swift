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
    /// One symbol per job, shared by the launcher, the chooser and the menu-bar
    /// panel, so the same job always looks the same wherever it appears.
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
    /// Gesture words are part of the hint, so a release is never described as a press.
    public static func actionHint(key: String, holdToStart: Bool = false, releaseToFinish: Bool = false) -> String {
        if releaseToFinish { return "Release " + key }
        return holdToStart ? "Hold " + key : key
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
    /// All seven tools, for the launcher's chooser: which one is chosen, which have live
    /// work, and their keys (#134).
    public var choices: [ToolbarToolChoice]
    public var accessoryTitle: String?
    /// The accessory fits on this display. When it does not, it waits in More instead.
    public var showsAccessory: Bool
    /// The selected tool's work is running.
    public var isBusy: Bool
    /// What the compact rest shows: its indicator and the words for it.
    public var status: ToolbarStatus

    public init(name: String, tier: ToolbarTier, anchor: ToolbarAnchor = .bottom,
                mode: ToolbarMode = .dictate, actionTitle: String? = nil,
                isActionEnabled: Bool = true, actionHint: String? = nil,
                choices: [ToolbarToolChoice]? = nil, isBusy: Bool = false,
                status: ToolbarStatus = .idle, showsAccessory: Bool = true) {
        self.name = name
        self.tier = tier
        self.anchor = anchor
        self.mode = mode
        self.actionTitle = actionTitle ?? mode.title
        self.isActionEnabled = isActionEnabled
        self.actionHint = actionHint
        self.choices = choices ?? ToolbarMode.allCases.map { ToolbarToolChoice(mode: $0, isSelected: $0 == mode) }
        self.accessoryTitle = mode == .present ? "Prompts" : nil
        self.showsAccessory = showsAccessory
        self.isBusy = isBusy
        self.status = status
    }

    /// The native hover hint and VoiceOver help share the action and its usable key.
    public var actionHelp: String {
        guard let hint = actionHint, !hint.isEmpty else { return actionTitle }
        return actionTitle + " · " + hint
    }

    /// The accessory as the revealed row shows it: nil when there is none or it waits in More.
    public var shownAccessory: String? { showsAccessory ? accessoryTitle : nil }
    /// Work is live in any tool: the launcher's one aggregate indicator.
    public var hasLiveWork: Bool { choices.contains(where: \.isLive) }
    /// The launcher's words: the chosen tool, then any other tool with live work.
    public var launcherDescription: String {
        let others = choices.filter { $0.isLive && $0.mode != mode }.map(\.mode.title)
        let own = isBusy ? "\(mode.title), running" : mode.title
        return others.isEmpty ? own : own + ". Also running: " + others.joined(separator: ", ")
    }
}
