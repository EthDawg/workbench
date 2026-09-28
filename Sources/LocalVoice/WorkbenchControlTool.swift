import AppKit
import SwiftUI
import StageKit
import ToolbarCore

/// The panel's rows, in moment order. Choosing controls never starts, stops or
/// replaces an independent activity.
enum WorkbenchControlTool: String, CaseIterable, Identifiable {
    case dictate, read, snap, snapAndTalk, annotate, present, persona, timer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dictate: return "Dictate"
        case .read: return "Read"
        case .snap: return "Snap"
        case .snapAndTalk: return "Snap & Talk"
        case .annotate: return "Draw"
        case .present: return "Present"
        case .persona: return "Persona"
        case .timer: return "Timer"
        }
    }
    var symbol: String {
        switch self {
        case .dictate: return "mic"
        case .read: return "speaker.wave.2"
        case .snap: return "viewfinder"
        case .snapAndTalk: return "rectangle.dashed.badge.record"
        case .annotate: return "pencil.tip"
        case .present: return "iphone"
        case .persona: return "person.crop.rectangle"
        case .timer: return "timer"
        }
    }
    /// The toolbar mode this row shares a next action with. Timer has none:
    /// it is a panel row and a Present option, never a toolbar mode.
    var mode: ToolbarMode? {
        switch self {
        case .dictate: return .dictate
        case .read: return .read
        case .snap: return .snap
        case .snapAndTalk: return .snapAndTalk
        case .annotate: return .draw
        case .present: return .present
        case .persona: return .persona
        case .timer: return nil
        }
    }
    init?(mode: ToolbarMode) {
        guard let tool = Self.allCases.first(where: { $0.mode == mode }) else { return nil }
        self = tool
    }
}

/// One frozen value of what is live, built once per render and shared by the
/// panel and the floating toolbar. Admission is separate from selection and
/// from the visual layout.
struct WorkbenchControlState {
    var phase: AppModel.Phase = .idle
    var ready = true
    var rendering = false
    var narrating = false
    var capturing = false
    var pendingNarration = false
    var hasSession = false
    var captureCount: Int?
    var drawing = false
    var presenting = false
    var mayDraw = true
    var mayPresent = true
    var playing = false
    var paused = false
    var overlays = false
    /// A prepared multiple-overlay set is running, shown or temporarily hidden.
    var overlaySession = false
    var overlaysPaused = false
    var timerStarted = false
    var timerRunning = false
    var canRecordAgain = false
    var insertingPrompt = false
    var meetingRecording = false
    /// A StageKit screenshot handoff or a standalone Snap capture owns the screen.
    var screenshotting = false
    var snapBusy = false

    func enabled(_ tool: WorkbenchControlTool) -> Bool {
        switch tool {
        case .dictate:
            return phase == .requesting || phase == .recording ||
                (phase == .idle && ready && !rendering && !narrating && !capturing && !pendingNarration)
        case .read: return true
        case .snap: return phase == .idle && !capturing && !narrating && !screenshotting && !snapBusy
        case .snapAndTalk: return narrating || (phase == .idle && !rendering && !capturing)
        case .annotate: return drawing || mayDraw
        case .present: return presenting || mayPresent
        case .persona: return overlays || mayPresent
        case .timer: return timerStarted || mayPresent
        }
    }

    /// The live state as the toolbar's next action sees it, for one mode.
    func live(_ mode: ToolbarMode) -> ToolbarLiveState {
        let dictation: ToolbarLiveState.Dictation
        switch phase {
        case .idle: dictation = .idle
        case .requesting: dictation = .requesting
        case .recording: dictation = .recording
        case .cancelling: dictation = .cancelling
        case .transcribing, .cleaning, .delivering: dictation = .processing
        }
        return ToolbarLiveState(mode: mode, dictation: dictation, canRecordAgain: canRecordAgain,
            reading: rendering ? .preparing : playing ? .playing : paused ? .paused : .idle,
            narrating: narrating, capturingScreen: capturing || screenshotting,
            pendingNarration: pendingNarration, captureCount: captureCount ?? (hasSession ? 0 : nil),
            drawing: drawing, presenting: presenting,
            persona: overlaysPaused ? .sessionHidden : overlaySession ? .session : overlays ? .shown : .none,
            timer: timerStarted ? (timerRunning ? .running : .paused) : .none,
            insertingPrompt: insertingPrompt, meetingRecording: meetingRecording,
            mayStart: WorkbenchControlTool(mode: mode).map(enabled) ?? false)
    }

    /// The row's next action, from the same function as the toolbar's label.
    func nextAction(_ tool: WorkbenchControlTool) -> ToolbarNextAction? {
        tool.mode.map { ToolbarNextAction.resolve(live($0)) }
    }

    /// What a click on the row does: the same operation its label names, so
    /// input-consuming work claims every row's click as it claims its label.
    /// Read stops rather than pausing here (pause and resume live on the Read
    /// page). Timer is not a mode: once nothing global claims the row it keeps
    /// its own start and stop.
    func rowAction(_ tool: WorkbenchControlTool) -> WorkbenchRowAction {
        switch tool {
        case .timer:
            // Snap has no ending of its own, so its next action is exactly the
            // global claim, or a start once nothing is consuming input.
            let global = ToolbarNextAction.resolve(live(.snap)).operation
            if case .start = global { return timerStarted ? .stopTimer : .startTimer }
            return .operation(global)
        case .read:
            switch ToolbarNextAction.resolve(live(.read)).operation {
            case .pauseReading, .resumeReading: return .operation(.stopReading)
            case let operation: return .operation(operation)
            }
        default:
            return .operation(ToolbarNextAction.resolve(live(tool.mode ?? .snap)).operation)
        }
    }

    /// What the row says: its capability's name when the click starts it, and
    /// otherwise the words for exactly the operation the click performs.
    func actionTitle(_ tool: WorkbenchControlTool) -> String {
        switch rowAction(tool) {
        case .startTimer: return "Timer"
        case .stopTimer: return "Stop timer"
        case .operation(.start): return tool.title
        case .operation(let operation): return ToolbarNextAction.title(operation, live: live(tool.mode ?? .snap))
        }
    }
}

enum WorkbenchDrawingAdmission {
    static func allows(phase: AppModel.Phase, suspended: Bool, capturingScreen: Bool, terminating: Bool) -> Bool {
        !suspended && !capturingScreen && !terminating && phase != .delivering && phase != .cancelling
    }
}

@MainActor
struct WorkbenchControlContext {
    let model: AppModel
    let readback: ReadbackModel
    let stage: StageKitController
    var snap: SnapModel? = nil
    var state: WorkbenchControlState {
        WorkbenchControlState(phase: model.phase, ready: model.ready, rendering: model.rendering,
            narrating: readback.isRecording, capturing: readback.isCapturing,
            pendingNarration: readback.hasPendingTranscriptions, hasSession: readback.sessionURL != nil,
            captureCount: readback.sessionURL == nil ? nil : readback.activeSections.count,
            drawing: stage.isDrawing, presenting: stage.isPresenting,
            mayDraw: stage.mayBeginDrawing?() ?? stage.mayBeginInteraction?() ?? true,
            mayPresent: stage.mayBeginInteraction?() ?? true, playing: model.playing, paused: model.paused,
            overlays: stage.hasActivePersona, overlaySession: stage.hasActivePersonaSession,
            overlaysPaused: stage.isPersonaSessionPaused, timerStarted: stage.hasTimerSession,
            timerRunning: stage.isTimerRunning, canRecordAgain: model.canRecordAgain,
            insertingPrompt: model.promptInsertion.running, meetingRecording: model.meetings.isRecording,
            screenshotting: stage.isTakingScreenshot || snap?.isCapturing == true, snapBusy: snap?.disablesCaptureDoors == true)
    }
    func shortcut(_ tool: WorkbenchControlTool) -> String? {
        switch tool {
        case .dictate: return voiceShortcut(1)
        case .snapAndTalk: return voiceShortcut(5)
        case .read: return voiceShortcut(6)
        case .present: return voiceShortcut(7)
        case .snap: return voiceShortcut(8)
        case .persona: return stageShortcut("personaToggle")
        case .timer: return stageShortcut("timer")
        case .annotate:
            guard let shortcut = stage.shortcutDescriptors.first(where: { $0.id == "pen" }) else { return "Shortcut unavailable" }
            return !shortcut.enabled ? "Shortcut off" : shortcut.error != nil ? "Shortcut unavailable" : shortcut.keyLabel
        }
    }
    func stageShortcut(_ id: String) -> String? {
        guard let shortcut = stage.shortcutDescriptors.first(where: { $0.id == id }) else { return nil }
        return !shortcut.enabled ? "Shortcut off" : shortcut.error != nil ? "Shortcut unavailable" : shortcut.keyLabel
    }
    func shortcutID(_ tool: WorkbenchControlTool) -> String {
        switch tool {
        case .dictate: return "voice.1"
        case .read: return "voice.6"
        case .snap: return "voice.8"
        case .snapAndTalk: return "voice.5"
        case .annotate: return "stage.pen"
        case .present: return "voice.7"
        case .persona: return "stage.personaToggle"
        case .timer: return "stage.timer"
        }
    }
    func voiceShortcut(_ id: UInt32) -> String {
        FloatingToolbar.shortcutLabel(model.preferences.shortcut(id), failure: model.shortcutFailures[id])
    }
    func detail(_ tool: WorkbenchControlTool) -> String {
        switch tool {
        case .dictate:
            if readback.blocksDictation { return "Finish Snap & Talk before dictating." }
            if !model.ready { return "Prepare speech in Workbench." }
            return model.preferences.cleanup.rawValue + " · " + (model.preferences.delivery == .paste ? "Paste in a Mac field" : "Copy text")
        case .snap: return snap?.isBusy == true ? "Finish or cancel the current Snap first." : "Capture a region of the screen into Snap."
        case .snapAndTalk:
            if readback.isCapturing { return "Capturing the display under the pointer…" }
            let count = readback.activeSections.count
            let captured = "\(count) " + (count == 1 ? "capture" : "captures")
            return readback.hasPendingTranscriptions ? captured + " · transcribing narration…" : readback.sessionURL == nil ? "Capture a screen, then explain it." : captured + " in this session"
        case .annotate: return stage.isDrawing ? stage.drawingToolTitle + " · Stop keeps your marks" : stage.drawingActivationTitle + " shortcut · click to draw"
        case .present: return stage.isPresenting ? "End the scene; it stays saved." : "Present your selected device scene."
        case .persona: return stage.hasActivePersona ? "Hide the persona without ending the scene." : "Show a prepared persona. Organise cards in Workbench."
        case .timer: return stage.hasTimerSession ? stage.timerText : "Start your saved timer."
        case .read: return model.rendering ? "Preparing audio…" : model.playing ? "Reading aloud" : model.paused ? "Reading paused" : "Listen to text from Workbench."
        }
    }
    var activitySummary: String {
        var labels: [String] = []
        if stage.isPresenting { labels.append("Presenting") }
        if stage.isDrawing { labels.append("Drawing") }
        if readback.isRecording { labels.append("Narrating") }
        else if readback.hasPendingTranscriptions { labels.append("Transcribing narration") }
        if model.phase == .recording { labels.append("Dictating") }
        else if model.phase != .idle { labels.append(model.waitingForDrawing ? "Text ready" : "Processing speech") }
        if model.playing { labels.append("Reading") }
        return labels.joined(separator: " · ")
    }
}
