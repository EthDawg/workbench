import AVFoundation
import Foundation

/// Held platform replies exercise the production owner without TCC, capture,
/// transcription, installed apps or non-temporary preferences.
enum ReadbackCaptureAccessChecks {
    @MainActor static func run() async throws {
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw ReadbackError.message("READBACK_CAPTURE_ACCESS_CHECK_FAILED: " + message) }
            passed += 1
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("Workbench-capture-access-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fixture) }
        for scenario in ["grant", "denial", "screen-revoked", "cancel", "task-cancel", "close", "switch", "same-session-return", "shutdown", "check", "check-unchanged-notice", "settings-return"] {
            let root = fixture.appendingPathComponent(scenario)
            let domain = root.appendingPathComponent("Preferences").path
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let session = root.appendingPathComponent("Session")
            _ = try ReadbackStore.create(at: session, title: "Synthetic access")
            let original = try Data(contentsOf: session.appendingPathComponent("session.json"))
            defaults.set([session.path], forKey: "readback.recentSessionPaths.v1")
            var microphone: AVAuthorizationStatus = .notDetermined
            var screen = false, screenRequests = 0, micRequests = 0, captures = 0
            var reply: CheckedContinuation<Bool, Never>?
            let model = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults)), defaults: defaults,
                captureDisplay: { captures += 1; throw ReadbackError.message("Capture must remain idle") },
                transcribeAudio: { _ in throw ReadbackError.message("Recognition must remain idle") },
                skillPacks: ReadbackSkillPackStore(root: root.appendingPathComponent("Packs")),
                screenAccess: .init(isGranted: { screen }, request: { screenRequests += 1; screen = true; return true }),
                microphoneAccess: { microphone }, requestMicrophoneAccess: {
                    micRequests += 1
                    return await withCheckedContinuation { reply = $0 }
                })
            defer { model.shutdown() }
            await model.preflightPermissions()
            try check(screenRequests == 0 && micRequests == 0 && !model.permissionsReady, "\(scenario): opening and checking never request access")
            let task = Task { await model.requestCaptureAccess() }
            for _ in 0..<100 where reply == nil { await Task.yield() }
            guard let held = reply else { task.cancel(); throw ReadbackError.message("Permission reply was not held") }
            // Release before any assertion can throw and leak the continuation.
            let wasPending = model.isRequestingCaptureAccess
            let pendingMessage = model.captureAccessMessage
            await model.requestCaptureAccess()
            switch scenario {
            case "cancel": model.cancelCaptureAccess()
            case "task-cancel": task.cancel()
            case "close": model.closeSession()
            case "switch": _ = try model.createSession(at: root.appendingPathComponent("Other"), title: "Other synthetic session")
            case "same-session-return": model.closeSession(); model.openRecent(session); await Task.yield()
            case "shutdown": model.shutdown()
            case "check", "check-unchanged-notice": await model.preflightPermissions()
            case "settings-return": microphone = .restricted; model.returnedToWorkbench()
            default: break
            }
            let expectedScreen = model.screenPermissionGranted, expectedMic = model.microphonePermission
            let unchangedNotice = model.notice
            if scenario != "check-unchanged-notice" { model.notice = "Newer visit feedback" }
            microphone = scenario == "denial" ? .denied : .authorized
            if scenario == "screen-revoked" { screen = false }
            held.resume(returning: microphone == .authorized); reply = nil
            await task.value
            try check(wasPending && !model.isRequestingCaptureAccess && screenRequests == 1 && micRequests == 1, "\(scenario): one platform request, no duplicate, slot settles")
            if scenario == "grant" {
                try check(model.permissionsReady && model.notice == nil, "current explicit grant publishes readiness")
            } else if scenario == "denial" {
                try check(model.microphonePermission == .denied && model.notice == model.permissionsProblem, "current denial retains truthful typed recovery")
            } else if scenario == "screen-revoked" {
                try check(!model.screenPermissionGranted && !model.permissionsReady && model.notice == model.permissionsProblem, "current completion rereads screen access rather than publishing a pre-await grant")
            } else if scenario == "check-unchanged-notice" {
                try check(model.notice == unchangedNotice && model.notice != pendingMessage
                    && model.captureAccessMessage != pendingMessage && model.captureAccessMessage == model.permissionsProblem
                    && model.microphonePermission == expectedMic && model.screenPermissionGranted == expectedScreen,
                          "Check during pending access never persists waiting wording after the rejected reply settles")
            } else {
                try check(model.screenPermissionGranted == expectedScreen && model.microphonePermission == expectedMic && model.notice == "Newer visit feedback", "\(scenario): held old reply cannot publish into a later visit")
            }
            try check(captures == 0 && !model.isRecording && !model.isCapturing && !model.hasPendingTranscriptions, "\(scenario): access completion starts no work")
            let after = try Data(contentsOf: session.appendingPathComponent("session.json"))
            try check(after == original, "\(scenario): original session bytes remain unchanged")
            await model.preflightPermissions()
            try check(model.permissionsReady == (microphone == .authorized && screen) && micRequests == 1, "\(scenario): explicit passive recheck observes current access without a second request")
        }
        print("READBACK_CAPTURE_ACCESS_CHECKS_OK: \(passed) checks")
    }
}
