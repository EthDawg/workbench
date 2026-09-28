import Foundation
import ToolbarCore

@MainActor
enum WorkbenchControlChecks {
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("Contextual controls: " + name) }
            count += 1
        }
        try check(WorkbenchControlTool.allCases.map(\.title) == ["Dictate", "Read", "Snap & Talk", "Draw", "Present", "Persona Overlay", "Timer"], "shared controls retain their fixed order; standalone Snap is a separate navigation row")
        var saved = VoicePreferences()
        saved.dictationShortcut.keyCode = 42
        saved.readbackShortcut = VoiceShortcut(keyCode: 18, enabled: false)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacy.removeValue(forKey: "readingShortcut"); legacy.removeValue(forKey: "presentationShortcut")
        let migrated = try JSONDecoder().decode(VoicePreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(migrated.dictationShortcut == saved.dictationShortcut && migrated.shortcut(5) == saved.shortcut(5), "adding utility shortcuts preserves existing and disabled bindings")
        try check(!migrated.shortcut(6).enabled && migrated.shortcut(7) == VoicePreferences.defaultPresentationShortcut, "Read stays opt-in and Present starts on its presenter key")
        saved.setShortcut(VoiceShortcut(keyCode: 20), for: 6); saved.setShortcut(VoiceShortcut(keyCode: 21), for: 7)
        let restored = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(saved))
        try check(restored.shortcut(6) == saved.shortcut(6) && restored.shortcut(7) == saved.shortcut(7), "opt-in utility shortcut assignments survive reload")
        try check(ToolbarModeFollower.modeToSelect(previous: [], current: [.draw]) == .draw, "a capability going live becomes the toolbar mode")
        try check(ToolbarModeFollower.modeToSelect(previous: [.draw], current: [.draw]) == nil, "already-live work does not move the mode")
        try check(ToolbarModeFollower.modeToSelect(previous: [.draw, .present], current: [.draw]) == nil, "ending leaves the mode where it was")
        try check(ToolbarModeFollower.modeToSelect(previous: [.draw], current: [.draw, .present]) == .present, "a Present door pressed in Draw mode starts a presentation and moves the mode to Present")
        try check(ToolbarNextAction.resolve(ToolbarLiveState(mode: .present, drawing: true, presenting: true)).title == "Stop drawing"
                  && ToolbarNextAction.resolve(ToolbarLiveState(mode: .present, presenting: true)).title == "End presentation", "after that start the resting label reads End presentation once drawing has stopped")
        try check(ToolbarNextAction.resolve(ToolbarLiveState(mode: .draw, presenting: true)).title == "Draw"
                  && ToolbarNextAction.switcher(for: ToolbarLiveState(mode: .draw, presenting: true)).contains { $0.mode == .present && $0.isBusy },
                  "switching to Draw by chip during a live scene keeps Draw as the label and lights the Present chip")
        try check(ToolbarModeFollower.modeToSelect(previous: [], current: [.draw, .persona, .present]) == .present, "several starts in one tick: Present before Persona before the rest")
        try check(ToolbarModeFollower.modeToSelect(previous: [.present], current: [.present, .persona, .dictate]) == .persona, "Persona outranks the rest once Present is already live")
        try check(ToolbarModeFollower.liveModes(dictating: false, reading: false, narrating: false, drawing: false, presenting: false, persona: false, snapping: false).isEmpty, "a restored session at launch is not a start")
        try check(FloatingToolbarSurface.resolve(enabled: false, capturingScreen: false, dictation: false, narration: false, reading: true) == .reading, "active reading has compact controls even with idle toolbar disabled")
        try check(FloatingToolbarSurface.resolve(enabled: true, capturingScreen: true, dictation: false, narration: false, reading: true) == .hidden, "capture hides reading controls too")
        var state = WorkbenchControlState()
        state.presenting = true; state.drawing = true; state.phase = .recording
        try check(state.enabled(.dictate) && state.enabled(.annotate) && state.enabled(.present),
                  "all three running activities retain their own finish controls")
        state.ready = false; state.rendering = true; state.narrating = true
        state.mayDraw = false; state.mayPresent = false
        try check(state.enabled(.dictate) && state.enabled(.annotate) && state.enabled(.present) && state.enabled(.snapAndTalk),
                  "finish actions remain available when new work is disallowed")
        state.phase = .requesting
        try check(state.enabled(.dictate) && state.actionTitle(.dictate) == "Cancel request", "microphone permission requests remain cancellable")
        state.phase = .idle; state.drawing = false; state.presenting = false; state.narrating = false
        try check(!state.enabled(.dictate) && !state.enabled(.annotate) && !state.enabled(.present) && !state.enabled(.snapAndTalk),
                  "idle starts respect availability")
        state = WorkbenchControlState(); state.pendingNarration = true
        try check(!state.enabled(.dictate) && state.enabled(.snapAndTalk), "ordinary dictation waits for the narration queue while another capture can queue")
        state.capturing = true
        try check(!state.enabled(.snapAndTalk), "screen capture cannot be re-entered")
        state = WorkbenchControlState(); state.hasSession = true
        try check(state.actionTitle(.snapAndTalk) == "Capture next", "an existing session continues instead of starting another")
        state = WorkbenchControlState(); state.overlays = true
        try check(state.actionTitle(.persona) == "Hide Persona", "one floating card is hidden by the main Persona action")
        state.overlaySession = true
        try check(state.actionTitle(.persona) == "Hide All Temporarily", "a prepared set's main action names the pause it performs, not an end")
        state.overlaysPaused = true
        try check(state.actionTitle(.persona) == "Show Again", "a temporarily hidden set offers to show again")
        state = WorkbenchControlState(); state.timerStarted = true
        try check(state.actionTitle(.timer) == "Show or hide timer", "a paused or finished timer keeps its existing-session action")
        state.timerStarted = false
        try check(state.actionTitle(.timer) == "Start Timer", "a reset timer offers a new start")
        for phase in [AppModel.Phase.idle, .requesting, .recording, .transcribing, .cleaning] {
            try check(WorkbenchDrawingAdmission.allows(phase: phase, suspended: false, capturingScreen: false, terminating: false),
                      "annotation can coexist with \(phase.rawValue)")
        }
        for phase in [AppModel.Phase.delivering, .cancelling] {
            try check(!WorkbenchDrawingAdmission.allows(phase: phase, suspended: false, capturingScreen: false, terminating: false),
                      "annotation cannot steal input during \(phase.rawValue)")
        }
        try check(!WorkbenchDrawingAdmission.allows(phase: .recording, suspended: true, capturingScreen: false, terminating: false), "shortcut practice retains input")
        try check(!WorkbenchDrawingAdmission.allows(phase: .recording, suspended: false, capturingScreen: true, terminating: false), "screen capture retains input")
        try check(!WorkbenchDrawingAdmission.allows(phase: .recording, suspended: false, capturingScreen: false, terminating: true), "shutdown cannot start drawing")
        let gate = DrawingDeliveryGate()
        func waitUntilPending() async throws {
            for _ in 0..<100 where !gate.isWaiting { await Task.yield() }
            try check(gate.isWaiting, "delivery waits without occupying the main thread")
        }
        let resume = Task { try await gate.wait() }
        try await waitUntilPending()
        gate.resolve(.resume)
        try check(try await resume.value == .resume && !gate.isWaiting, "ending annotation releases exactly one delivery")
        gate.resolve(.resume)
        let copy = Task { try await gate.wait() }
        try await waitUntilPending(); gate.resolve(.copy)
        try check(try await copy.value == .copy, "copy now bypasses paste without stopping drawing")
        let cancel = Task { try await gate.wait() }
        try await waitUntilPending(); cancel.cancel()
        do { _ = try await cancel.value; throw VoiceError.message("Cancelled delivery resumed") }
        catch is CancellationError { try check(!gate.isWaiting, "cancellation releases its continuation") }
        try await PromptInsertionChecks.run()
        print("WORKBENCH_CONTROL_CHECKS_OK: \(count) checks passed")
    }
}
