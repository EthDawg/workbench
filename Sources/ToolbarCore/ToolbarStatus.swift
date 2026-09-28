/// What the compact rest shows (#134). At rest the toolbar is one small mark in every
/// state; this is the only thing about it that changes with the work. One status, derived
/// from the operation owners through the host's projection, `ToolbarActivity`. It decides
/// the indicator and its accessible description and nothing else: never the tier, focus or
/// the collapse deadline. Nothing here is stored, so it is recomputed from the owners at launch.

/// Everything the owners say is going on, frozen. The host fills it; nothing here observes.
/// A library selection, an old transcript, a restored Snap & Talk session or editable text
/// alone is not activity, and no field is ever inferred from a status or error string.
public struct ToolbarActivity: Hashable, Sendable {
    /// What is recording through the microphone.
    public enum Capture: String, CaseIterable, Hashable, Sendable { case dictation, narration, meeting }
    /// Work that runs on its own and shows the capability's symbol.
    public enum Live: String, CaseIterable, Hashable, Sendable { case drawing, presenting, persona, timer, inserting, snapAndTalk }

    public var capture: Capture?
    /// The capturing owner's own latest level sample, 0 to 1; nil when it has none.
    public var level: Double?
    /// Reading aloud.
    public var playback: Bool
    /// Transcribing, tidying, delivering, cancelling, preparing audio or finishing a capture.
    public var processing: Bool
    /// A recoverable failure that is still unresolved.
    public var failure: Bool
    /// A result that was made but not yet delivered, such as text waiting on the clipboard.
    public var pendingDelivery: Bool
    /// A capture that needs Save or Cancel.
    public var unsavedCapture: Bool
    /// Paused work, and a hidden arrangement that can be shown again.
    public var paused: Bool
    /// Other live work, in `Live.allCases` order.
    public var live: [Live]

    public init(capture: Capture? = nil, level: Double? = nil, playback: Bool = false, processing: Bool = false,
                failure: Bool = false, pendingDelivery: Bool = false, unsavedCapture: Bool = false,
                paused: Bool = false, live: [Live] = []) {
        self.capture = capture; self.level = level; self.playback = playback; self.processing = processing
        self.failure = failure; self.pendingDelivery = pendingDelivery; self.unsavedCapture = unsavedCapture
        self.paused = paused; self.live = Live.allCases.filter(live.contains)
    }

    public static let idle = ToolbarActivity()
}

public extension ToolbarActivity.Live {
    /// The capability symbol the mark shows for this work, shared with the rest of the toolbar.
    var symbol: String {
        switch self {
        case .drawing: return ToolbarMode.draw.symbol
        case .presenting, .inserting: return ToolbarMode.present.symbol
        case .persona: return ToolbarMode.persona.symbol
        case .timer: return "timer"
        case .snapAndTalk: return ToolbarMode.snapAndTalk.symbol
        }
    }
    var words: String {
        switch self {
        case .drawing: return "Drawing"
        case .presenting: return "Presenting"
        case .persona: return "Persona showing"
        case .timer: return "Timer running"
        case .inserting: return "Inserting a prompt"
        case .snapAndTalk: return "Snap & Talk session open"
        }
    }
}

public struct ToolbarStatus: Equatable, Sendable {
    /// One shape each, so shape and words carry the meaning and colour never does alone.
    public enum Indicator: Equatable, Sendable {
        case idle
        /// A recording dot with the owner's level, or a still level outline without one.
        case capture
        case playback, processing, failure, pendingDelivery, unsavedCapture, paused
        /// The capability's own symbol.
        case live(ToolbarActivity.Live)
    }

    public var indicator: Indicator
    /// Recording goes on while another job needs attention: the recording signal stays and a
    /// small warning badge joins it inside the same target.
    public var attentionBadge: Bool
    public var level: Double?
    /// Every state the mark stands for, in words, for VoiceOver and the tooltip.
    public var description: String

    public init(indicator: Indicator = .idle, attentionBadge: Bool = false, level: Double? = nil, description: String = "Nothing running") {
        self.indicator = indicator; self.attentionBadge = attentionBadge; self.level = level; self.description = description
    }

    public static let idle = ToolbarStatus()

    /// The fixed priority: capture and playback, processing, failure, a pending result or
    /// capture, paused work, other live work, idle.
    public static func resolve(_ activity: ToolbarActivity) -> ToolbarStatus {
        let indicator: Indicator
        if activity.capture != nil { indicator = .capture }
        else if activity.playback { indicator = .playback }
        else if activity.processing { indicator = .processing }
        else if activity.failure { indicator = .failure }
        else if activity.pendingDelivery { indicator = .pendingDelivery }
        else if activity.unsavedCapture { indicator = .unsavedCapture }
        else if activity.paused { indicator = .paused }
        else if let live = activity.live.first { indicator = .live(live) }
        else { indicator = .idle }
        let attention = activity.failure || activity.pendingDelivery || activity.unsavedCapture
        return ToolbarStatus(indicator: indicator, attentionBadge: indicator == .capture && attention,
                             level: indicator == .capture ? activity.level.map { min(1, max(0, $0)) } : nil,
                             description: describe(activity))
    }

    /// Named in the same priority order. No transcript or result content is ever included.
    static func describe(_ activity: ToolbarActivity) -> String {
        var parts: [String] = []
        switch activity.capture {
        case .dictation?: parts.append("Recording dictation")
        case .narration?: parts.append("Recording narration")
        case .meeting?: parts.append("Recording a meeting")
        case nil: break
        }
        if activity.playback { parts.append("Reading aloud") }
        if activity.processing { parts.append("Processing") }
        if activity.failure { parts.append("Needs attention") }
        if activity.pendingDelivery { parts.append("Result waiting to be delivered") }
        if activity.unsavedCapture { parts.append("Unsaved capture") }
        if activity.paused { parts.append("Paused") }
        parts += activity.live.map(\.words)
        return parts.isEmpty ? "Nothing running" : parts.joined(separator: ", ")
    }

    /// Whether VoiceOver should hear about a change: a new indicator or badge, never a level.
    public func announces(after previous: ToolbarStatus) -> Bool {
        indicator != previous.indicator || attentionBadge != previous.attentionBadge
    }
}
