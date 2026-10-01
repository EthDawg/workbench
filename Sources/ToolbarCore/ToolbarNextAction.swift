/// What is live right now, frozen. The host builds one of these per render from
/// the operation owners; nothing here observes anything. Every field is a
/// finite value so a test can walk the whole product.
public struct ToolbarLiveState: Hashable, Sendable {
    /// `waitingForDrawing`: the words are ready and wait for drawing to end before they are
    /// delivered, or for Copy now (#211 F5).
    public enum Dictation: CaseIterable, Sendable { case idle, requesting, recording, processing, cancelling, waitingForDrawing }
    public enum Reading: CaseIterable, Sendable { case idle, preparing, playing, paused }
    public enum Persona: CaseIterable, Sendable { case none, shown, session, sessionHidden, cameraStarting, cameraShown, cameraHidden, cameraFailed }
    public enum Timer: CaseIterable, Sendable { case none, running, paused, finished }

    public var mode: ToolbarMode
    public var dictation: Dictation
    public var canRecordAgain: Bool
    public var reading: Reading
    /// Snap & Talk is recording narration.
    public var narrating: Bool
    /// Any screen capture is in flight; the toolbar is hidden for it.
    public var capturingScreen: Bool
    /// Snap & Talk narration is still being transcribed and saved.
    public var pendingNarration: Bool
    /// Captures in the open Snap & Talk session, or nil with no session.
    public var captureCount: Int?
    public var drawing: Bool
    public var presenting: Bool
    public var persona: Persona
    /// Recorded for the chooser's live dot only. The timer never claims the label.
    public var timer: Timer
    public var insertingPrompt: Bool
    public var meetingRecording: Bool
    /// The selected mode may start now. Admission stays with the owners.
    public var mayStart: Bool

    public init(mode: ToolbarMode, dictation: Dictation = .idle, canRecordAgain: Bool = false,
                reading: Reading = .idle, narrating: Bool = false, capturingScreen: Bool = false,
                pendingNarration: Bool = false, captureCount: Int? = nil, drawing: Bool = false,
                presenting: Bool = false, persona: Persona = .none, timer: Timer = .none,
                insertingPrompt: Bool = false, meetingRecording: Bool = false, mayStart: Bool = true) {
        self.mode = mode; self.dictation = dictation; self.canRecordAgain = canRecordAgain
        self.reading = reading; self.narrating = narrating; self.capturingScreen = capturingScreen
        self.pendingNarration = pendingNarration; self.captureCount = captureCount
        self.drawing = drawing; self.presenting = presenting; self.persona = persona; self.timer = timer
        self.insertingPrompt = insertingPrompt; self.meetingRecording = meetingRecording; self.mayStart = mayStart
    }

    /// Input-consuming work is live: an insertion, dictation, a screen capture, narration, drawing
    /// or a reading preparing, playing or paused. It claims the next action whatever tool is chosen
    /// and holds back the result that was waiting when it began (#220, #222). The chosen tool's own
    /// sessions, a presentation, personas, Snap & Talk between captures or a meeting transcription,
    /// hold nothing back: a result is revealed over them as before (#134 T4).
    public var consumesInput: Bool {
        insertingPrompt || dictation != .idle || capturingScreen || narrating || drawing || reading != .idle
    }

    /// Whether a mode's own capability is running, whichever mode is selected.
    /// The chooser's rows and the launcher's aggregate indicator use it.
    public func isLive(_ mode: ToolbarMode) -> Bool {
        switch mode {
        case .dictate: return dictation != .idle || meetingRecording
        case .read: return reading != .idle
        case .snap: return false
        case .snapAndTalk: return narrating || pendingNarration
        case .draw: return drawing
        case .present: return presenting || insertingPrompt
        case .persona: return persona != .none
        }
    }
}

/// The one thing the next action does. The host maps each case to the owner
/// that already does it; the toolbar never ends anything but what it names.
public enum ToolbarOperation: Hashable, Sendable {
    case stopInserting, cancelDictationRequest, stopDictation
    case finishNarration, finishDrawing
    case pauseReading, resumeReading, cancelReading
    /// Never the toolbar's label (reading pauses there); the panel's Read row
    /// stops instead, and dispatches through the same owner switch.
    case stopReading
    case hidePersona, pauseOverlays, resumeOverlays
    case cancelPersonaCamera, hidePersonaCamera, showPersonaCamera, retryPersonaCamera
    case captureNext, stopMeetingTranscription, endPresentation
    case start(ToolbarMode)
    /// Nothing to do but wait; the label says why and is disabled.
    case wait

    /// The live command's glyph, rather than the chosen tool's glyph. A recording in any
    /// tool shows Stop, and a paused reading shows Play. The words remain its accessible name.
    public var symbol: String {
        switch self {
        case .stopInserting, .stopDictation, .finishNarration, .finishDrawing,
             .stopReading, .stopMeetingTranscription, .endPresentation: return "stop.fill"
        case .cancelDictationRequest, .cancelReading, .cancelPersonaCamera: return "xmark"
        case .pauseReading: return "pause.fill"
        case .resumeReading: return "play.fill"
        case .hidePersona, .pauseOverlays, .hidePersonaCamera: return "eye.slash"
        case .resumeOverlays, .showPersonaCamera: return "eye"
        case .retryPersonaCamera: return "arrow.clockwise"
        case .captureNext: return "viewfinder"
        case .wait: return "hourglass"
        case .start(let mode): return mode == .dictate ? "mic.fill" : mode.symbol
        }
    }

    /// The capability the operation belongs to, for its symbol.
    public var mode: ToolbarMode? {
        switch self {
        case .cancelDictationRequest, .stopDictation, .stopMeetingTranscription: return .dictate
        case .pauseReading, .resumeReading, .cancelReading, .stopReading: return .read
        case .finishNarration, .captureNext: return .snapAndTalk
        case .finishDrawing: return .draw
        case .stopInserting, .endPresentation: return .present
        case .hidePersona, .pauseOverlays, .resumeOverlays, .cancelPersonaCamera, .hidePersonaCamera, .showPersonaCamera, .retryPersonaCamera: return .persona
        case .start(let mode): return mode
        case .wait: return nil
        }
    }

    /// The capability whose assigned key performs exactly this operation, or
    /// nil when no key does: Present's key does not stop an insertion, Dictate's
    /// key does not stop a meeting transcription, and Persona's key refuses to
    /// pause or resume a prepared set. Only these earn a key in the hint.
    public var keyMode: ToolbarMode? {
        switch self {
        case .stopInserting, .stopMeetingTranscription, .pauseOverlays, .resumeOverlays, .stopReading, .wait: return nil
        default: return mode
        }
    }
}

/// The label under the pointer at rest, and what clicking it does. One pure
/// function of the live state, with a fixed priority so two identical screens
/// never read differently: what is consuming your input now, then the cheapest
/// to undo, then the mode's own session steps and endings, then its start verb.
/// Work that runs in another mode never claims the label; its chooser row says
/// it is live and its chooser row offers its finish item.
public struct ToolbarNextAction: Equatable, Sendable {
    public var title: String
    public var symbol: String
    public var operation: ToolbarOperation
    public var isEnabled: Bool
    /// A count worth knowing beside the key, such as saving captures.
    public var detail: String?

    /// Stop keeps what it made; Cancel discards; Hide and Show keep; End ends.
    public static let titleBudget = 24

    public static func resolve(_ live: ToolbarLiveState) -> ToolbarNextAction {
        let operation = self.operation(for: live)
        let enabled: Bool
        switch operation {
        case .wait: enabled = false
        case .start, .captureNext, .showPersonaCamera, .retryPersonaCamera: enabled = live.mayStart
        default: enabled = true
        }
        var detail: String?
        if live.mode == .snapAndTalk, let count = live.captureCount, case .start = operation {
            detail = "\(count) " + (count == 1 ? "capture" : "captures")
        }
        if case .captureNext = operation, live.pendingNarration { detail = "saving" }
        return ToolbarNextAction(title: title(operation, live: live), symbol: operation.symbol,
                                 operation: operation, isEnabled: enabled, detail: detail)
    }

    /// The hover hint: any detail, then the assigned key of the operation's capability.
    public func hint(key: String?) -> String? {
        let parts = [detail, key].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }


    /// The seven tools for the chooser (#134): the chosen one checked, each lit when its
    /// capability is live, with its key.
    public static func choices(for live: ToolbarLiveState, key: (ToolbarMode) -> String? = { _ in nil }) -> [ToolbarToolChoice] {
        ToolbarMode.allCases.map {
            ToolbarToolChoice(mode: $0, isSelected: $0 == live.mode, isLive: live.isLive($0), key: key($0))
        }
    }

    /// Every verb a mode can start with, for the wording budget.
    public static let idleVerbs: [String] = ["Record again", "Capture"] + ToolbarMode.allCases.map {
        title(.start($0), live: ToolbarLiveState(mode: $0))
    }

    static func operation(for live: ToolbarLiveState) -> ToolbarOperation {
        // Input-consuming work is global: whichever mode is selected, this is
        // what a click must address first.
        if live.insertingPrompt { return .stopInserting }
        switch live.dictation {
        case .requesting: return .cancelDictationRequest
        case .recording: return .stopDictation
        // Words waiting for drawing to end: stopping drawing is what delivers them, and the Dictate chooser row has
        // Copy now (#211 F5). Drawing that has already ended is a moment's processing.
        case .waitingForDrawing where live.drawing: return .finishDrawing
        // Processing consumes nothing: only Dictate waits on it. Another tool keeps its own
        // action, and the chooser's Dictate row keeps the dictation's commands.
        case .processing, .cancelling, .waitingForDrawing:
            if live.mode == .dictate { return .wait }
        case .idle: break
        }
        if live.capturingScreen { return .wait }
        if live.narrating { return .finishNarration }
        if live.drawing { return .finishDrawing }
        switch live.reading {
        case .preparing: return .cancelReading
        case .playing: return .pauseReading
        // A paused reading consumes nothing and has no timeout: it leads only in Read, so it
        // never hides another tool's start, such as Snap's sources. The chooser's Read row resumes it.
        case .paused where live.mode == .read: return .resumeReading
        case .paused, .idle: break
        }
        // From here the label belongs to the selected mode alone.
        switch live.mode {
        case .persona:
            switch live.persona {
            case .session: return .pauseOverlays
            case .sessionHidden: return .resumeOverlays
            case .shown: return .hidePersona
            case .cameraStarting: return .cancelPersonaCamera
            case .cameraShown: return .hidePersonaCamera
            case .cameraHidden: return .showPersonaCamera
            case .cameraFailed: return .retryPersonaCamera
            case .none: break
            }
        case .snapAndTalk:
            if live.captureCount != nil { return .captureNext }
        case .dictate:
            if live.meetingRecording { return .stopMeetingTranscription }
        case .present:
            if live.presenting { return .endPresentation }
        case .read, .snap, .draw: break
        }
        return .start(live.mode)
    }

    /// The words for an operation. Stop keeps what it made; Cancel discards.
    public static func title(_ operation: ToolbarOperation, live: ToolbarLiveState) -> String {
        switch operation {
        case .stopInserting: return "Stop inserting"
        case .cancelDictationRequest: return "Cancel request"
        case .stopDictation: return "Stop"
        case .finishNarration: return "Stop narration"
        case .finishDrawing: return "Stop drawing"
        case .cancelReading: return "Cancel"
        case .pauseReading: return "Pause reading"
        case .resumeReading: return "Resume reading"
        case .stopReading: return "Stop reading"
        case .pauseOverlays: return "Hide personas"
        case .resumeOverlays: return "Show personas"
        case .hidePersona: return "Hide persona"
        case .cancelPersonaCamera: return "Cancel"
        case .hidePersonaCamera: return "Hide camera"
        case .showPersonaCamera: return "Show camera again"
        case .retryPersonaCamera: return "Try again"
        case .captureNext: return "Capture next · \(live.captureCount ?? 0)"
        case .stopMeetingTranscription: return "Stop & transcribe"
        case .endPresentation: return "End presentation"
        case .wait: return live.dictation == .cancelling ? "Cancelling…" : live.dictation == .processing || live.dictation == .waitingForDrawing ? "Processing…" : "Capturing…"
        case .start(let mode):
            switch mode {
            case .dictate: return live.canRecordAgain ? "Record again" : "Dictate"
            case .read: return "Read"
            case .snap: return "Snap"
            case .snapAndTalk: return "Snap & Talk"
            case .draw: return "Draw"
            case .present: return "Present"
            case .persona: return "Show persona"
            }
        }
    }
}
