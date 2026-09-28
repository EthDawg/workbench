import AppKit
import StageKit
import ToolbarCore

extension FloatingControlAnchor {
    var toolbarAnchor: ToolbarAnchor {
        switch self {
        case .topLeft: return .topLeft
        case .top: return .top
        case .topRight: return .topRight
        case .left: return .left
        case .right: return .right
        case .bottomLeft: return .bottomLeft
        case .bottom: return .bottom
        case .bottomRight: return .bottomRight
        }
    }
}

/// What More's Active work section offers (#134): for each thing the compact mark can show
/// that the chosen tool gives no way back to, its finish, resume or door, worded as its own
/// tool words it. Nothing here is a new command; each item runs an existing one.
enum ToolbarActiveWork: Equatable {
    case stopDrawing, endPresentation
    /// Hide persona, Hide personas or Show personas, as Persona's own label reads.
    case persona(String)
    case stopTranscribing
    /// A meeting recording saved for retry: the page that recovers it.
    case meetingRecovery
    /// A Snap capture that needs Save or Cancel: the Snap editor.
    case snapDraft
    /// The break timer's next transport: Pause, Resume or Restart.
    case timer(TimerTransport)

    struct Facts {
        var mode: ToolbarMode
        var nextAction: ToolbarOperation
        var drawing = false
        var presenting = false
        var persona: ToolbarLiveState.Persona = .none
        var meetingRecording = false
        var meetingRecovery = false
        var snapDraft = false
        var timer: TimerTransport = .idle
    }

    static func items(_ facts: Facts) -> [ToolbarActiveWork] {
        var items: [ToolbarActiveWork] = []
        if facts.drawing && facts.mode != .draw && facts.nextAction != .finishDrawing { items.append(.stopDrawing) }
        if facts.presenting && facts.mode != .present { items.append(.endPresentation) }
        if facts.persona != .none && facts.mode != .persona {
            items.append(.persona(facts.persona == .session ? "Hide personas" : facts.persona == .sessionHidden ? "Show personas" : "Hide persona"))
        }
        if facts.meetingRecording && facts.mode != .dictate { items.append(.stopTranscribing) }
        // Dictate's own options hold only its page, so the recovery is offered in every tool.
        if facts.meetingRecovery && !facts.meetingRecording { items.append(.meetingRecovery) }
        if facts.snapDraft && facts.mode != .snap { items.append(.snapDraft) }
        // Timer is not a tool, so its transport is offered whichever tool is chosen.
        if facts.timer != .idle { items.append(.timer(facts.timer)) }
        return items
    }
}

/// Reading's commands in More (#211 F6): its own next action, Cancel while preparing, Pause
/// reading or Resume reading, whenever another job holds the row's primary, such as drawing or
/// a prompt insertion; and Stop reading while it plays or is paused.
enum ToolbarReadingCommands {
    static func operations(primary: ToolbarOperation, reading: ToolbarLiveState.Reading) -> [ToolbarOperation] {
        var operations: [ToolbarOperation] = []
        let own: ToolbarOperation?
        switch reading {
        case .preparing: own = .cancelReading
        case .playing: own = .pauseReading
        case .paused: own = .resumeReading
        case .idle: own = nil
        }
        if let own, own != primary { operations.append(own) }
        if reading == .playing || reading == .paused { operations.append(.stopReading) }
        return operations
    }
}

/// The accessories' own menus (#134 part B).
@MainActor
enum ToolbarAccessoryMenus {
    /// Circle, Card or Original for exactly the live copy selected as the menu opens, a hidden one
    /// included, as that copy's Appearance menu offers them. Choosing changes only that copy's look:
    /// never the saved persona, another copy or the library's selection (#169, #170).
    static func appearance(_ stage: StageKitController) -> NSMenu {
        appearance(copy: stage.selectedPersonaCopy, current: stage.personaShape(of:), choose: { stage.setPersonaShape($0, for: $1) })
    }

    /// The same for any copy. `copy` is taken when the menu opens, so a selection that changes
    /// while it is open never redirects the choice, and no copy means an empty menu.
    static func appearance<Copy>(copy: Copy?, current: (Copy) -> StageKitController.PersonaShape?,
                                 choose: @escaping (StageKitController.PersonaShape, Copy) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Appearance"); menu.autoenablesItems = false
        guard let copy else { return menu }
        let now = current(copy)
        for shape in StageKitController.PersonaShape.allCases {
            menu.addItem(ToolbarMenuAction(shape.title, checked: shape == now) { choose(shape, copy) })
        }
        return menu
    }

    /// Whether More must hold Appearance itself: the row has no room for the accessory, a copy is
    /// selected, and Persona's own menu, inlined in More, has no Circle, Card and Original for it.
    /// A shown card's and a set's menus have them under Appearance; a hidden card's does not.
    static func moreNeedsAppearance(_ more: NSMenu, accessoryFits: Bool, hasCopy: Bool) -> Bool {
        let shapes = StageKitController.PersonaShape.allCases.map(\.title)
        return !accessoryFits && hasCopy && !more.items.contains { $0.submenu?.items.map(\.title) == shapes }
    }
}

/// Each item retains its action for the duration of native menu tracking.
final class ToolbarMenuAction: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(performAction), keyEquivalent: "")
        target = self; state = checked ? .on : .off; isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func performAction() { run() }
}
