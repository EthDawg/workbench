import Foundation

@MainActor
enum WorkbenchControlChecks {
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("Contextual controls: " + name) }
            count += 1
        }
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
        print("WORKBENCH_CONTROL_CHECKS_OK: \(count) checks passed")
    }
}
