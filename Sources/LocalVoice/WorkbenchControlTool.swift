import AppKit
import SwiftUI
import StageKit
import ToolbarCore

/// The panel's rows, in moment order. Choosing controls never starts, stops or
/// replaces an independent activity.
enum WorkbenchControlTool: String, CaseIterable, Identifiable {
    case dictate, snap, snapAndTalk, annotate, present, persona, timer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dictate: return "Dictate"
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
        case .snap: return "viewfinder"
        case .snapAndTalk: return "rectangle.dashed.badge.record"
        case .annotate: return "pencil.tip"
        case .present: return "iphone"
        case .persona: return "person.crop.rectangle"
        case .timer: return "timer"
        }
    }
    /// The toolbar mode for this capability. Timer has none:
    /// it is a panel row and part of Draw, never a toolbar mode.
    var mode: ToolbarMode? {
        switch self {
        case .dictate: return .dictate
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
    /// Meeting capture and processing keep the shared audio admission closed.
    var meetingBusy = false
    var narrating = false
    var capturing = false
    var pendingNarration = false
    var hasSession = false
    var captureCount: Int?
    var drawing = false
    var presenting = false
    var mayDraw = true
    var mayPresent = true
    var overlays = false
    /// A prepared multiple-overlay set is running, shown or temporarily hidden.
    var overlaySession = false
    var overlaysPaused = false
    var personaCamera: StageKitController.PersonaCameraPhase = .off
    var personaCameraMayResume = true
    var personaIdentity: UUID?
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

    /// Admission for new work. Existing work keeps its own ending even while
    /// another owner refuses a new start.
    private func mayStart(_ tool: WorkbenchControlTool) -> Bool {
        switch tool {
        case .dictate:
            return phase == .idle && ready && !narrating && !capturing && !pendingNarration && !meetingBusy
        case .snap: return phase == .idle && !capturing && !narrating && !screenshotting && !snapBusy
        case .snapAndTalk: return phase == .idle && !capturing && !screenshotting && !meetingBusy
        case .annotate: return mayDraw
        case .persona: return mayPresent && personaCameraMayResume
        case .present, .timer: return mayPresent
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
        let persona: ToolbarLiveState.Persona
        switch personaCamera {
        case .off: persona = overlaysPaused ? .sessionHidden : overlaySession ? .session : overlays ? .shown : .none
        case .starting: persona = .cameraStarting
        case .live: persona = .cameraShown
        case .hidden: persona = .cameraHidden
        case .failed: persona = .cameraFailed
        }
        return ToolbarLiveState(mode: mode, dictation: dictation, canRecordAgain: canRecordAgain,
            narrating: narrating, capturingScreen: capturing || screenshotting,
            pendingNarration: pendingNarration, captureCount: captureCount ?? (hasSession ? 0 : nil),
            drawing: drawing, presenting: presenting,
            persona: persona,
            timer: Self.liveTimer(timerTransport),
            insertingPrompt: insertingPrompt, meetingRecording: meetingRecording,
            mayStart: WorkbenchControlTool(mode: mode).map(mayStart) ?? false)
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
        guard let mode = tool.mode else { return nil }
        let own = ownLive(mode)
        var action = ToolbarNextAction.resolve(own)
        if action.operation == .captureNext || action.operation == .resumeOverlays { action.isEnabled = own.mayStart }
        return action
    }

    func enabled(_ tool: WorkbenchControlTool) -> Bool {
        if tool == .timer { return timerStarted || mayStart(tool) }
        return nextAction(tool)?.isEnabled == true
    }

    /// The symbol stays with its row; the accent identifies its own live work.
    func active(_ tool: WorkbenchControlTool) -> Bool {
        if tool == .timer { return timerStarted }
        return tool.mode.map { ownLive($0).isLive($0) } ?? false
    }

    /// Home's Persona controls use the same own-capability projection as the
    /// menu: another input operation cannot claim its Hide or Show action.
    var personaAction: ToolbarNextAction { nextAction(.persona)! }

    /// What the Persona action does, for its tooltip. It follows the same
    /// action, so a hidden set is never described as being hidden again.
    var personaDetail: String {
        switch personaAction.operation {
        case .pauseOverlays: return "Hide the set without ending it."
        case .resumeOverlays: return mayPresent ? "Show the set again, as you arranged it." : "Finish the current input operation before showing the set again."
        case .hidePersona: return "Hide the persona without ending the scene."
        case .cancelPersonaCamera: return "Cancel the camera request."
        case .hidePersonaCamera: return "Hide the bubble and release the camera."
        case .showPersonaCamera: return "Start the camera again and show the bubble where you placed it."
        case .retryPersonaCamera: return personaCameraMayResume ? "Try starting the camera again." : "Camera access is restricted on this Mac. Open Persona to show saved artwork."
        default: return "Show a prepared persona. Organise cards in Workbench."
        }
    }

    /// Each row acts only on the capability it names. Timer keeps its own
    /// transport because it is not a toolbar mode.
    func rowAction(_ tool: WorkbenchControlTool) -> WorkbenchRowAction {
        if tool == .timer { return timerStarted ? .stopTimer : .startTimer }
        return .operation(nextAction(tool)!.operation)
    }

    /// Only this capability's state enters a menu row. The toolbar still sees
    /// all live work and retains its global next-action priority. Admission
    /// still includes the other owners, so an incompatible start stays disabled.
    private func ownLive(_ mode: ToolbarMode) -> ToolbarLiveState {
        let all = live(mode)
        var own = ToolbarLiveState(mode: mode, mayStart: all.mayStart)
        switch mode {
        case .dictate:
            // Delivery may be waiting for another owner (such as drawing). The
            // Dictate row waits; only that owner's own row offers its ending.
            own.dictation = phase == .delivering ? .processing : all.dictation
            own.meetingRecording = all.meetingRecording
            own.canRecordAgain = all.canRecordAgain
        case .snap: break
        case .snapAndTalk:
            own.narrating = all.narrating; own.capturingScreen = capturing
            own.pendingNarration = all.pendingNarration; own.captureCount = all.captureCount
        case .draw: own.drawing = all.drawing
        case .present: own.presenting = all.presenting
        case .persona: own.persona = all.persona
        }
        return own
    }

    /// Re-read the owners when a rendered button commits. A completed Stop,
    /// Hide or End must never resolve again into a fresh start.
    func admits(_ rendered: WorkbenchRowAction, for tool: WorkbenchControlTool, personaIdentity expected: UUID? = nil) -> Bool {
        enabled(tool) && rowAction(tool) == rendered
            && (tool != .persona || expected == nil || personaIdentity == expected)
    }

    /// Idle rows keep their capability name; active rows name their own action.
    func actionTitle(_ tool: WorkbenchControlTool) -> String {
        switch rowAction(tool) {
        case .startTimer: return "Timer"
        case .stopTimer: return "Stop timer"
        case .operation(.start): return tool.title
        case .operation: return nextAction(tool)!.title
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
    let personaIdentity: UUID?
    /// Hidden and failed camera visits still have a useful resume or recovery action.
    let isCurrentWork: Bool
    init(_ state: WorkbenchControlState) {
        action = state.personaAction; help = state.personaDetail; personaIdentity = state.personaIdentity
        isCurrentWork = state.overlays || state.overlaySession || state.personaCamera != .off
    }
    /// The live strip's button.
    var rowTitle: String { action.title }
    /// The tile's second line.
    var tileVerb: String { action.operation == .start(.persona) ? "Show a card over your apps" : action.title }
    var operation: ToolbarOperation { action.operation }
    var isEnabled: Bool { action.isEnabled }
    func isAdmitted(in state: WorkbenchControlState) -> Bool {
        isEnabled && state.admits(.operation(operation), for: .persona, personaIdentity: personaIdentity)
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
        WorkbenchControlState(phase: model.phase, ready: model.ready, meetingBusy: model.meetings.isBusy,
            narrating: readback.isRecording, capturing: readback.isCapturing,
            pendingNarration: readback.hasPendingTranscriptions, hasSession: readback.sessionURL != nil,
            captureCount: readback.sessionURL == nil ? nil : readback.activeSections.count,
            drawing: stage.isDrawing, presenting: stage.isPresenting,
            mayDraw: stage.mayBeginDrawing?() ?? stage.mayBeginInteraction?() ?? true,
            mayPresent: stage.mayBeginInteraction?() ?? true,
            overlays: stage.hasActivePersona, overlaySession: stage.hasActivePersonaSession,
            overlaysPaused: stage.isPersonaSessionPaused, personaCamera: stage.personaCameraPhase,
            personaCameraMayResume: stage.personaCameraMayResume, personaIdentity: stage.personaSessionIdentity, timerStarted: stage.hasTimerSession,
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
        return ToolbarActivity(capture: capture, level: level,
            processing: dictationBusy || readback.isCapturing || readback.hasPendingTranscriptions
                || model.meetings.isStarting || model.meetings.isProcessing || snap?.isCapturing == true,
            // Saved recovery and clipboard records remain with their owners. They are not
            // live activity and must not follow the person into another tool's toolbar.
            pendingDelivery: model.waitingForDrawing,
            paused: timer.paused || stage.isPersonaSessionPaused,
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
    func detail(_ tool: WorkbenchControlTool, state: WorkbenchControlState? = nil) -> String {
        let state = state ?? self.state
        switch state.rowAction(tool) {
        case .operation(.cancelDictationRequest): return "Cancel the pending microphone request."
        case .operation(.stopDictation): return "Stop recording and keep the captured speech."
        case .operation(.stopMeetingTranscription): return "Stop the meeting recording and keep its captured audio."
        case .operation(.finishNarration): return "Stop narration and keep this capture."
        case .operation(.wait):
            return tool == .dictate ? "Wait for the current dictation to finish." : "Wait for this screen capture to finish."
        default: break
        }
        // Without Screen Recording the Snap row still opens Snap, which explains and offers Paste and Import (#112).
        if tool == .snap, snap?.isBusy != true, snap?.screenAccessGranted == false {
            return "Screen Recording is off for Workbench. Snap shows how to allow it, or add an image you already have."
        }
        switch tool {
        case .dictate:
            if state.meetingBusy { return "Finish the meeting recording or transcription before dictating." }
            if readback.blocksDictation { return "Finish Snap & Talk before dictating." }
            // The one readiness line: a setup's progress, or why it stopped, then where to act.
            if !model.ready { return model.modelMessage + (model.preparing ? "" : " · Settings › Models") }
            return model.preferences.cleanup.rawValue + " · " + (model.preferences.delivery == .clipboard ? "Copy text"
                : model.accessibilityGranted ? "Paste in a Mac field" : "Copy for ⌘V until Accessibility is allowed")
        case .snap: return snap?.isBusy == true ? "Finish or cancel the current Snap first." : "Capture a region of the screen into Snap."
        case .snapAndTalk:
            if !state.enabled(tool) { return "Finish the current dictation, meeting or screen capture before capturing again." }
            if readback.isCapturing { return "Capturing the display under the pointer…" }
            if !readback.screenPermissionGranted && !readback.isRecording {
                return "Screen Recording is off for Workbench. Saved sessions and narration stay available; Snap & Talk shows how to allow it."
            }
            let count = readback.activeSections.count
            let captured = "\(count) " + (count == 1 ? "capture" : "captures")
            return readback.hasPendingTranscriptions ? captured + " · transcribing narration…" : readback.sessionURL == nil ? "Capture a screen, then explain it." : captured + " in this session"
        case .annotate: return state.drawing ? stage.drawingToolTitle + " · Stop keeps your marks" : stage.drawingActivationTitle + " shortcut · click to draw"
        case .present: return state.presenting ? "End the scene; it stays saved." : "Present your selected device scene."
        case .persona: return state.personaDetail
        case .timer: return state.timerStarted ? stage.timerStateDetail : "Start your saved timer."
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
        return labels.joined(separator: " · ")
    }
}
