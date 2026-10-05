import Foundation

/// The toolbar's status (#134). Its complete words remain available at rest, while
/// the look chooses which states need a visible compact signal. One status, derived
/// from the operation owners through the host's projection, `ToolbarActivity`. It decides
/// the indicator and its accessible description and nothing else: never the tier, focus or
/// the collapse deadline. Nothing here is stored, so it is recomputed from the owners at launch.

/// Everything the owners say is going on, frozen. The host fills it; nothing here observes.
/// A library selection, an old transcript, a restored Snap & Talk session or editable text
/// alone is not activity, and no field is ever inferred from a status or error string.
public struct ToolbarActivity: Hashable, Sendable {
    /// What is recording through the microphone.
    public enum Capture: String, CaseIterable, Hashable, Sendable { case dictation, narration, meeting }
    /// A capture keeps its identity while paused or reconnecting, but neither state claims
    /// that the microphone is receiving audio. Both retain the ordinary compact hit target.
    public enum CaptureTransport: String, CaseIterable, Hashable, Sendable { case recording, paused, reconnecting }
    /// Other live work, named in the complete accessible status and revealed controls.
    public enum Live: String, CaseIterable, Hashable, Sendable { case drawing, presenting, persona, timer, inserting, snapAndTalk }

    public var capture: Capture?
    public var captureTransport: CaptureTransport
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
    /// The capture stops by itself at its time limit within the last seconds (#134 T4).
    public var stopsSoon: Bool
    /// The capturing owner judges its microphone too quiet to use, after a stretch of near silence.
    public var quiet: Bool

    public init(capture: Capture? = nil, level: Double? = nil, playback: Bool = false, processing: Bool = false,
                failure: Bool = false, pendingDelivery: Bool = false, unsavedCapture: Bool = false,
                paused: Bool = false, live: [Live] = [], stopsSoon: Bool = false, quiet: Bool = false,
                captureTransport: CaptureTransport = .recording) {
        self.capture = capture; self.level = level; self.playback = playback; self.processing = processing
        self.captureTransport = captureTransport
        self.failure = failure; self.pendingDelivery = pendingDelivery; self.unsavedCapture = unsavedCapture
        self.paused = paused; self.live = Live.allCases.filter(live.contains); self.stopsSoon = stopsSoon
        self.quiet = quiet
    }

    public static let idle = ToolbarActivity()
}

public extension ToolbarActivity.Live {
    /// The canonical capability symbol, shared with the revealed toolbar.
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
    /// The highest-priority state; the view may keep ordinary live work visually quiet.
    public enum Indicator: Equatable, Sendable {
        case idle
        /// A recording dot with the owner's level, or a still level outline without one.
        case capture
        case playback, processing, failure, pendingDelivery, unsavedCapture, paused
        /// Ordinary live work; its words remain available even when the mark is quiet.
        case live(ToolbarActivity.Live)
    }

    public var indicator: Indicator
    /// Recording goes on while another job needs attention: the recording signal stays and a
    /// small warning badge joins it inside the same target.
    public var attentionBadge: Bool
    /// The recording stops by itself at its time limit in the last seconds: a timer badge.
    public var stopsSoonBadge: Bool
    public var level: Double?
    /// The capture's microphone has been too quiet to use for a while, in the owner's judgement.
    public var quiet: Bool
    /// Every state the mark stands for, in words, for VoiceOver and the tooltip.
    public var description: String

    public init(indicator: Indicator = .idle, attentionBadge: Bool = false, stopsSoonBadge: Bool = false, level: Double? = nil,
                quiet: Bool = false, description: String = "Nothing running") {
        self.indicator = indicator; self.attentionBadge = attentionBadge; self.stopsSoonBadge = stopsSoonBadge
        self.level = level; self.quiet = quiet; self.description = description
    }

    /// The badges beside the capture signal, in their order: the time-limit timer, then the
    /// warning for another job that needs attention. Both show when both apply (#211 F4).
    public enum Badge: Hashable, Sendable { case stopsSoon, attention }
    public var badges: [Badge] {
        (stopsSoonBadge ? [.stopsSoon] : []) + (attentionBadge ? [.attention] : [])
    }

    /// The capture's level in words, for VoiceOver's value and never announced (#211 F7): Low
    /// microphone level once the owner judges it too quiet, otherwise Quiet or Receiving sound.
    /// Nil without a level sample, as for a meeting.
    public var levelWords: String? {
        guard indicator == .capture, let level else { return nil }
        if quiet { return "Low microphone level" }
        return level < 0.05 ? "Quiet" : "Receiving sound"
    }
    /// What VoiceOver reads as the mark's value: every state in words, then the level's.
    public var spokenValue: String { levelWords.map { description + ". " + $0 } ?? description }

    public static let idle = ToolbarStatus()

    /// The fixed priority: capture and playback, processing, failure, a pending result or
    /// capture, paused work, other live work, idle.
    public static func resolve(_ activity: ToolbarActivity) -> ToolbarStatus {
        let indicator: Indicator
        if activity.capture != nil && activity.captureTransport == .recording { indicator = .capture }
        else if activity.playback { indicator = .playback }
        else if activity.processing || activity.capture != nil && activity.captureTransport == .reconnecting { indicator = .processing }
        else if activity.failure { indicator = .failure }
        else if activity.pendingDelivery { indicator = .pendingDelivery }
        else if activity.unsavedCapture { indicator = .unsavedCapture }
        else if activity.paused || activity.capture != nil && activity.captureTransport == .paused { indicator = .paused }
        else if let live = activity.live.first { indicator = .live(live) }
        else { indicator = .idle }
        let attention = activity.failure || activity.pendingDelivery || activity.unsavedCapture
        return ToolbarStatus(indicator: indicator, attentionBadge: indicator == .capture && attention,
                             stopsSoonBadge: indicator == .capture && activity.stopsSoon,
                             level: indicator == .capture ? activity.level.map { min(1, max(0, $0)) } : nil,
                             quiet: indicator == .capture && activity.quiet,
                             description: describe(activity))
    }

    /// Named in the same priority order. No transcript or result content is ever included.
    static func describe(_ activity: ToolbarActivity) -> String {
        var parts: [String] = []
        if let capture = activity.capture {
            switch activity.captureTransport {
            case .recording:
                parts.append(capture == .meeting ? "Recording a meeting" : "Recording " + capture.rawValue)
            case .paused:
                parts.append(capture.rawValue.capitalized + " paused")
            case .reconnecting:
                parts.append("Reconnecting " + capture.rawValue + " audio")
            }
        }
        if activity.capture != nil && activity.captureTransport == .recording && activity.stopsSoon {
            parts.append("Stops at the 5-minute limit in a few seconds")
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

    /// Whether VoiceOver should hear about a change: a new indicator, badge or state in words,
    /// never a level or how quiet it is, which the words leave out. So a failure, a pending
    /// result or an unsaved capture arriving under processing or playback is heard, though the
    /// indicator stays, and so is the time-limit warning, once, when it appears.
    public func announces(after previous: ToolbarStatus) -> Bool {
        indicator != previous.indicator || attentionBadge != previous.attentionBadge || description != previous.description
    }
}
