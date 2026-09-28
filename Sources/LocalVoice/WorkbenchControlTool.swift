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
    /// The timer's transport, which tells a finished countdown from a paused one; `timerStarted`
    /// stays set after "Time is up" until the timer is reset.
    var timerTransport: TimerTransport = .idle
    var canRecordAgain = false
    var insertingPrompt = false
    var meetingRecording = false
    /// A StageKit screenshot handoff or a standalone Snap capture owns the screen.
    var screenshotting = false
    var snapBusy = false
    /// Dictated words wait for drawing to end before they are delivered (#211 F5).
    var waitingForDrawing = false

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
        case .delivering where waitingForDrawing: dictation = .waitingForDrawing
        case .transcribing, .cleaning, .delivering: dictation = .processing
        }
        return ToolbarLiveState(mode: mode, dictation: dictation, canRecordAgain: canRecordAgain,
            reading: rendering ? .preparing : playing ? .playing : paused ? .paused : .idle,
            narrating: narrating, capturingScreen: capturing || screenshotting,
            pendingNarration: pendingNarration, captureCount: captureCount ?? (hasSession ? 0 : nil),
            drawing: drawing, presenting: presenting,
            persona: overlaysPaused ? .sessionHidden : overlaySession ? .session : overlays ? .shown : .none,
            timer: Self.liveTimer(timerTransport),
            insertingPrompt: insertingPrompt, meetingRecording: meetingRecording,
            mayStart: WorkbenchControlTool(mode: mode).map(enabled) ?? false)
    }

    /// The timer as the next action and its fixtures see it: a finished countdown is finished,
    /// never paused (#205 review).
    static func liveTimer(_ transport: TimerTransport) -> ToolbarLiveState.Timer {
        switch transport {
        case .idle: return .none
        case .running: return .running
        case .paused: return .paused
        case .finished: return .finished
        }
    }

    /// The row's next action, from the same function as the toolbar's label.
    func nextAction(_ tool: WorkbenchControlTool) -> ToolbarNextAction? {
        tool.mode.map { ToolbarNextAction.resolve(live($0)) }
    }

    /// Persona's own next action, in the words the toolbar's Persona mode uses:
    /// Hide persona for one card, Hide personas for a prepared set, Show personas
    /// while that set is hidden, and Show persona when nothing is live. Home's
    /// Persona row and tile take their label and click from here (#134). They
    /// name Persona itself, so work in another capability never claims them.
    var personaAction: ToolbarNextAction {
        let own = live(.persona)
        return ToolbarNextAction.resolve(ToolbarLiveState(mode: .persona, persona: own.persona, mayStart: own.mayStart))
    }

    /// What the Persona action does, for its tooltip. It follows the same
    /// action, so a hidden set is never described as being hidden again.
    var personaDetail: String {
        switch personaAction.operation {
        case .pauseOverlays: return "Hide the set without ending it."
        case .resumeOverlays: return "Show the set again, as you arranged it."
        case .hidePersona: return "Hide the persona without ending the scene."
        default: return "Show a prepared persona. Organise cards in Workbench."
        }
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

/// Home's Persona row and tile (#134). Every live word, the tooltip and the
/// click come from the shared Persona action, so a hidden prepared set reads
/// Show personas on Home as it does on the toolbar and panel. Only the idle
/// tile keeps a description, as Home's other tiles do.
struct HomePersonaControl {
    let action: ToolbarNextAction
    let help: String
    init(_ state: WorkbenchControlState) { action = state.personaAction; help = state.personaDetail }
    /// The live strip's button.
    var rowTitle: String { action.title }
    /// The tile's second line.
    var tileVerb: String { action.operation == .start(.persona) ? "Show a card over your apps" : action.title }
    var operation: ToolbarOperation { action.operation }
    var isEnabled: Bool { action.isEnabled }
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
            timerRunning: stage.isTimerRunning, timerTransport: stage.timerTransport, canRecordAgain: model.canRecordAgain,
            insertingPrompt: model.promptInsertion.running, meetingRecording: model.meetings.isRecording,
            screenshotting: stage.isTakingScreenshot || snap?.isCapturing == true, snapBusy: snap?.disablesCaptureDoors == true,
            waitingForDrawing: model.waitingForDrawing)
    }
    /// What the owners say is going on, for the toolbar's compact rest (#134). Only each
    /// owner's structured state counts, recomputed whenever it is read and so at launch: never
    /// a library, an old transcript, a restored Snap & Talk session or a status string. Dismissing
    /// a result clears only that owner's own state, and so only its attention.
    func activity(snapAndTalkSequence: URL?) -> ToolbarActivity {
        var capture: ToolbarActivity.Capture?, level: Double?
        if model.phase == .recording { capture = .dictation; level = model.level }
        else if readback.isRecording { capture = .narration; level = readback.recordingLevel }
        else if model.meetings.isRecording { capture = .meeting }
        let dictationBusy: Bool
        switch model.phase {
        case .requesting, .transcribing, .cleaning, .cancelling: dictationBusy = true
        case .delivering: dictationBusy = !model.waitingForDrawing
        case .idle, .recording: dictationBusy = false
        }
        var live: [ToolbarActivity.Live] = []
        if stage.isDrawing { live.append(.drawing) }
        if stage.isPresenting { live.append(.presenting) }
        if stage.hasActivePersona && !stage.isPersonaSessionPaused { live.append(.persona) }
        let timer = Self.timerActivity(stage.timerTransport)
        if timer.live { live.append(.timer) }
        if model.promptInsertion.running { live.append(.inserting) }
        // A sequence started in this launch; a session restored at launch alone is idle.
        if let snapAndTalkSequence, readback.sessionURL?.standardizedFileURL == snapAndTalkSequence.standardizedFileURL {
            live.append(.snapAndTalk)
        }
        return ToolbarActivity(capture: capture, level: level, playback: model.playing,
            processing: dictationBusy || model.rendering || readback.isCapturing || readback.hasPendingTranscriptions
                || model.meetings.isStarting || model.meetings.isProcessing || snap?.isCapturing == true,
            // A delivery that did not finish needs the person until they copy it again or set it
            // aside, whether or not its receipt is still showing (#134 T5).
            failure: model.captureFailure != nil || model.readingFailure != nil || model.meetings.hasRecovery || model.unresolvedDelivery != nil,
            pendingDelivery: model.waitingForDrawing
                || (model.clipboardReceipt.isHUDVisible && model.clipboardReceipt.receipt?.isClipboardCurrent == true),
            unsavedCapture: snap?.draft != nil,
            paused: model.paused || timer.paused || stage.isPersonaSessionPaused,
            live: live,
            // The last ten seconds before a dictation or narration stops at its 5-minute limit (#134 T4).
            stopsSoon: (model.phase == .recording && model.elapsed >= 290) || (readback.isRecording && readback.recordingElapsed >= 290),
            // The dictation owner's own judgement of a microphone too quiet to use, for VoiceOver's value (#211 F7).
            quiet: capture == .dictation && model.isMicrophoneQuiet)
    }

    /// The break timer's part of the compact status: a running countdown is live work and a
    /// paused one is paused work. A finished one ("Time is up") is neither, although its
    /// session stays started until it is reset, so it never reads as paused.
    static func timerActivity(_ transport: TimerTransport) -> (live: Bool, paused: Bool) {
        switch transport {
        case .running: return (true, false)
        case .paused: return (false, true)
        case .idle, .finished: return (false, false)
        }
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
        // Without Screen Recording the Snap row still opens Snap, which explains and offers Paste and Import (#112).
        if tool == .snap, snap?.isBusy != true, snap?.screenAccessGranted == false {
            return "Screen Recording is off for Workbench. Snap shows how to allow it, or add an image you already have."
        }
        switch tool {
        case .dictate:
            if readback.blocksDictation { return "Finish Snap & Talk before dictating." }
            if !model.ready { return "Prepare speech in Workbench." }
            return model.preferences.cleanup.rawValue + " · " + (model.preferences.delivery == .clipboard ? "Copy text"
                : model.accessibilityGranted ? "Paste in a Mac field" : "Copy for ⌘V until automatic paste is approved")
        case .snap: return snap?.isBusy == true ? "Finish or cancel the current Snap first." : "Capture a region of the screen into Snap."
        case .snapAndTalk:
            if readback.isCapturing { return "Capturing the display under the pointer…" }
            if !readback.screenPermissionGranted && !readback.isRecording {
                return "Screen Recording is off for Workbench. Saved sessions and narration stay available; Snap & Talk shows how to allow it."
            }
            let count = readback.activeSections.count
            let captured = "\(count) " + (count == 1 ? "capture" : "captures")
            return readback.hasPendingTranscriptions ? captured + " · transcribing narration…" : readback.sessionURL == nil ? "Capture a screen, then explain it." : captured + " in this session"
        case .annotate: return stage.isDrawing ? stage.drawingToolTitle + " · Stop keeps your marks" : stage.drawingActivationTitle + " shortcut · click to draw"
        case .present: return stage.isPresenting ? "End the scene; it stays saved." : "Present your selected device scene."
        case .persona: return state.personaDetail
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
