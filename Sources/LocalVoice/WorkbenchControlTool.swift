import AppKit
import SwiftUI
import StageKit

/// Choosing controls never starts, stops or replaces an independent activity.
enum WorkbenchControlTool: String, CaseIterable, Identifiable {
    case dictate, read, snap, annotate, present, persona, timer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dictate: return "Dictate"
        case .snap: return "Snap & Talk"
        case .annotate: return "Draw"
        case .present: return "Present"
        case .read: return "Read"
        case .persona: return "Persona Overlay"
        case .timer: return "Timer"
        }
    }
    var shortTitle: String { self == .snap ? "Snap" : title }
    var symbol: String {
        switch self {
        case .dictate: return "mic"
        case .snap: return "rectangle.and.pencil.and.ellipsis"
        case .annotate: return "pencil.tip"
        case .present: return "iphone"
        case .read: return "speaker.wave.2"
        case .persona: return "person.crop.rectangle"
        case .timer: return "timer"
        }
    }
    var page: String {
        switch self {
        case .snap: return "readback"
        case .read: return "speak"
        case .persona, .timer: return "present"
        default: return rawValue
        }
    }
}

/// Action admission is separate from selection and from the visual layout.
struct WorkbenchControlState {
    var phase: AppModel.Phase = .idle
    var ready = true
    var rendering = false
    var narrating = false
    var capturing = false
    var pendingNarration = false
    var hasSession = false
    var drawing = false
    var presenting = false
    var mayDraw = true
    var mayPresent = true
    var playing = false
    var paused = false
    var overlays = false
    var timerRunning = false

    func enabled(_ tool: WorkbenchControlTool) -> Bool {
        switch tool {
        case .dictate:
            return phase == .requesting || phase == .recording ||
                (phase == .idle && ready && !rendering && !narrating && !capturing && !pendingNarration)
        case .snap: return narrating || (phase == .idle && !rendering && !capturing)
        case .annotate: return drawing || mayDraw
        case .present: return presenting || mayPresent
        case .read: return true
        case .persona: return overlays || mayPresent
        case .timer: return timerRunning || mayPresent
        }
    }
    func actionTitle(_ tool: WorkbenchControlTool) -> String {
        switch tool {
        case .dictate:
            switch phase {
            case .requesting: return "Cancel request"
            case .recording: return "Finish dictation"
            case .idle: return "Start dictation"
            case .cancelling: return "Cancelling…"
            default: return "Processing…"
            }
        case .snap: return narrating ? "Finish narration" : capturing ? "Capturing…" : hasSession ? "Capture next" : "Set up session"
        case .annotate: return drawing ? "Done drawing" : "Draw on screen"
        case .present: return presenting ? "End scene" : "Start scene"
        case .persona: return overlays ? "End Overlays" : "Show Persona"
        case .timer: return timerRunning ? "Show or hide timer" : "Start Timer"
        case .read: return rendering ? "Cancel generation" : playing ? "Pause reading" : paused ? "Resume reading" : "Open reading"
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
    var state: WorkbenchControlState {
        WorkbenchControlState(phase: model.phase, ready: model.ready, rendering: model.rendering,
            narrating: readback.isRecording, capturing: readback.isCapturing,
            pendingNarration: readback.hasPendingTranscriptions, hasSession: readback.sessionURL != nil,
            drawing: stage.isDrawing, presenting: stage.isPresenting,
            mayDraw: stage.mayBeginDrawing?() ?? stage.mayBeginInteraction?() ?? true,
            mayPresent: stage.mayBeginInteraction?() ?? true, playing: model.playing, paused: model.paused,
            overlays: stage.hasActivePersona, timerRunning: stage.isTimerRunning)
    }
    func shortcut(_ tool: WorkbenchControlTool) -> String? {
        switch tool {
        case .dictate: return voiceShortcut(1)
        case .snap: return voiceShortcut(5)
        case .read: return voiceShortcut(6)
        case .present: return voiceShortcut(7)
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
        case .snap: return "voice.5"
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
        case .snap:
            if readback.isCapturing { return "Capturing the display under the pointer…" }
            let count = readback.activeSections.count
            let captured = "\(count) " + (count == 1 ? "capture" : "captures")
            return readback.hasPendingTranscriptions ? captured + " · transcribing narration…" : readback.sessionURL == nil ? "Capture a screen, then explain it." : captured + " in this session"
        case .annotate: return stage.isDrawing ? stage.drawingToolTitle + " · Done keeps your marks" : stage.drawingActivationTitle + " shortcut · click to draw"
        case .present: return stage.isPresenting ? "Scene stays live while you use other tools." : "Present your selected device scene."
        case .persona: return stage.hasActivePersona ? "Adjust the current overlays without ending the device scene." : "Show a prepared persona. Organise cards in Workbench."
        case .timer: return stage.isTimerRunning ? stage.timerText : "Start your saved timer."
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
