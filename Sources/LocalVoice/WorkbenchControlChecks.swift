import Foundation

@MainActor
enum WorkbenchControlChecks {
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("Contextual controls: " + name) }
            count += 1
        }
        try check(WorkbenchControlTool.allCases.map(\.title) == ["Dictate", "Read", "Snap & Talk", "Draw", "Present", "Persona Overlay", "Timer"], "seven primary menu labels retain their fixed order")
        var saved = VoicePreferences()
        saved.dictationShortcut.keyCode = 42
        saved.readbackShortcut = VoiceShortcut(keyCode: 18, enabled: false)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacy.removeValue(forKey: "readingShortcut"); legacy.removeValue(forKey: "presentationShortcut")
        let migrated = try JSONDecoder().decode(VoicePreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(migrated.dictationShortcut == saved.dictationShortcut && migrated.shortcut(5) == saved.shortcut(5), "adding utility shortcuts preserves existing and disabled bindings")
        try check(!migrated.shortcut(6).enabled && !migrated.shortcut(7).enabled, "Read and Present add no enabled default bindings")
        saved.setShortcut(VoiceShortcut(keyCode: 20), for: 6); saved.setShortcut(VoiceShortcut(keyCode: 21), for: 7)
        let restored = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(saved))
        try check(restored.shortcut(6) == saved.shortcut(6) && restored.shortcut(7) == saved.shortcut(7), "opt-in utility shortcut assignments survive reload")
        try check(FloatingToolbarSurface.resolve(enabled: false, capturingScreen: false, dictation: false, narration: false, reading: true) == .reading, "active reading has compact controls even with idle toolbar disabled")
        try check(FloatingToolbarSurface.resolve(enabled: true, capturingScreen: true, dictation: false, narration: false, reading: true) == .hidden, "capture hides reading controls too")
        var state = WorkbenchControlState()
        state.presenting = true; state.drawing = true; state.phase = .recording
        try check(state.enabled(.dictate) && state.enabled(.annotate) && state.enabled(.present),
                  "all three running activities retain their own finish controls")
        state.ready = false; state.rendering = true; state.narrating = true
        state.mayDraw = false; state.mayPresent = false
        try check(state.enabled(.dictate) && state.enabled(.annotate) && state.enabled(.present) && state.enabled(.snap),
                  "finish actions remain available when new work is disallowed")
        state.phase = .requesting
        try check(state.enabled(.dictate) && state.actionTitle(.dictate) == "Cancel request", "microphone permission requests remain cancellable")
        state.phase = .idle; state.drawing = false; state.presenting = false; state.narrating = false
        try check(!state.enabled(.dictate) && !state.enabled(.annotate) && !state.enabled(.present) && !state.enabled(.snap),
                  "idle starts respect availability")
        state = WorkbenchControlState(); state.pendingNarration = true
        try check(!state.enabled(.dictate) && state.enabled(.snap), "ordinary dictation waits for the narration queue while another capture can queue")
        state.capturing = true
        try check(!state.enabled(.snap), "screen capture cannot be re-entered")
        state = WorkbenchControlState(); state.hasSession = true
        try check(state.actionTitle(.snap) == "Capture next", "an existing session continues instead of starting another")
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
