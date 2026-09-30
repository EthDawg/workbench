import AppKit
import AVFoundation

/// The real new-section path with synthetic images and denied microphone before recorder
/// construction. No screen, audio device, live session, clipboard or permission prompt is used.
enum ReadbackCaptureChoiceChecks {
    @MainActor private final class Source: SnapImageSource {
        var settleDelay: UInt64 = 0
        var modes: [SnapCapture.Mode] = []
        var cancellations = 0
        var acquire: () throws -> Data? = { nil }
        func capture(_ mode: SnapCapture.Mode) async throws -> Data? {
            modes.append(mode)
            await Task.yield()
            return try acquire()
        }
        func cancel() { cancellations += 1 }
    }

    @MainActor static func run() async throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw ReadbackError.message("READBACK_CAPTURE_CHOICE_CHECK_FAILED: " + message) }
            passed += 1
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("Workbench-capture-choices-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fixture) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = bitmap.representation(using: .png, properties: [:])!

        for scenario in ["cancel", "permission", "late-denial", "close", "replace", "shutdown", "shutdown-settle", "task-cancel", "commit"] {
            let domain = "Workbench.CaptureChoices.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let directory = fixture.appendingPathComponent(scenario)
            let root = directory.appendingPathComponent("Session")
            _ = try ReadbackStore.create(at: root, title: "Synthetic capture choices")
            defaults.set([root.path], forKey: "readback.recentSessionPaths.v1")
            let source = Source()
            var microphone: AVAuthorizationStatus = .authorized
            var screenGranted = true, screenCalls = 0, saves = 0, hides = 0, restores = 0
            var denial: String?
            let model = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults)), defaults: defaults,
                captureDisplay: { screenCalls += 1; return ReadbackScreenshot(data: image, displayName: "Synthetic display", screenFrame: .zero) },
                skillPacks: ReadbackSkillPackStore(root: directory.appendingPathComponent("Packs")),
                screenAccess: .init(isGranted: { screenGranted }, request: { fatalError("No permission request in checks") }),
                captureSelection: source, microphoneAccess: { microphone })
            defer { model.shutdown() }
            model.mayBeginCapture = { denial }
            model.onHideForEditorCapture = { hides += 1 }
            model.onRestoreAfterEditorCapture = { restores += 1 }
            let store = SnapStore(root: directory.appendingPathComponent("Snaps"))
            model.onSaveCapturedSnap = { [weak model] bytes, title in
                saves += 1
                let item = try store.insert(originalPNG: bytes, width: 8, height: 6, title: title, source: .narrated)
                // Exercise the real save/import path, then refuse recorder construction.
                microphone = .denied; model?.refreshPermissionState()
                return SnapHandoffSnapshot(id: item.id, title: item.title, createdAt: item.createdAt,
                    originalPNG: bytes, renderedPNG: nil, note: "", tags: [])
            }
            let manifestURL = root.appendingPathComponent("session.json")
            var expected = try Data(contentsOf: manifestURL)
            source.acquire = { image }

            switch scenario {
            case "cancel":
                source.acquire = { nil }
                for mode in [SnapCapture.Mode.region, .window] { await model.captureNewSection(fromEditor: true, mode: mode) }
                try check(source.modes == [.region, .window] && hides == 2 && restores == 2, "selectors and editor restoration pair on Escape")
                try check(model.notice == nil, "Escape returns to ordinary controls without a failure")
            case "permission":
                screenGranted = false; model.refreshPermissionState()
                await model.captureNewSection(fromEditor: true, mode: .region)
                try check(source.modes.isEmpty && hides == 0, "permission refusal precedes capture and hiding")
            case "late-denial":
                source.acquire = { denial = "Synthetic input owner took over"; return image }
                await model.captureNewSection(fromEditor: true, mode: .window)
                try check(model.notice?.contains(denial!) == true, "late admission is checked before saving")
            case "close":
                source.acquire = { [weak model] in model?.closeSession(); return image }
                await model.captureNewSection(fromEditor: true, mode: .window)
                try check(model.sessionURL == nil && source.cancellations == 1, "closing cancels the owned selector and invalidates its result")
            case "replace":
                source.acquire = {
                    var changed = try ReadbackStore.load(from: root)
                    changed.id = UUID()
                    try ReadbackStore.save(changed, at: root)
                    expected = try Data(contentsOf: manifestURL)
                    return image
                }
                await model.captureNewSection(fromEditor: true, mode: .region)
                try check(model.notice?.contains("session folder changed") == true, "a replacement at the same path is rejected")
            case "shutdown":
                source.acquire = { [weak model] in model?.shutdown(); return image }
                await model.captureNewSection(fromEditor: true, mode: .window)
                try check(source.cancellations == 1, "shutdown cancels the selector and discards its late image")
            case "task-cancel":
                source.settleDelay = 1_000_000_000
                var task: Task<Void, Never>?
                model.onHideForEditorCapture = { hides += 1; task?.cancel() }
                task = Task { await model.captureNewSection(fromEditor: true, mode: .region) }
                await task?.value
                try check(source.modes.isEmpty && restores == 1, "cancellation during settling still restores the editor")
                model.onHideForEditorCapture = nil
            case "shutdown-settle":
                source.settleDelay = 1_000_000
                model.onHideForEditorCapture = { [weak model] in hides += 1; model?.shutdown() }
                await model.captureNewSection(fromEditor: true, mode: .region)
                try check(source.modes.isEmpty && restores == 1, "shutdown during settling never opens a selector afterwards")
            default:
                for mode in [SnapCapture.Mode.region, .window] {
                    microphone = .authorized; model.refreshPermissionState()
                    await model.captureNewSection(fromEditor: true, mode: mode)
                }
                microphone = .authorized; model.refreshPermissionState()
                await model.captureNewSection(fromEditor: true)
                try check(source.modes == [.region, .window] && screenCalls == 1, "Screen retains its original service; selections use Snap's selectors")
                try check(saves == 3 && model.activeSections.count == 3, "each chosen image enters History and exactly one session section")
                try check(model.activeSections[0].displayName.contains("Region") && model.activeSections[1].displayName.contains("Window"),
                    "source labels describe the selected image")
                for section in model.activeSections {
                    let saved = try Data(contentsOf: ReadbackStore.safeURL(root: root, relative: section.screenshot))
                    try check(saved == image && section.audio == nil && section.status == .needsNarration,
                        "the exact image survives microphone refusal and remains available for narration")
                }
            }
            try check(!model.isCapturing && !model.isRecording && !model.blocksDictation, "\(scenario) releases capture without starting a recorder")
            try check(hides == restores, "\(scenario) restores every hidden editor")
            if scenario != "commit" {
                let after = try Data(contentsOf: manifestURL)
                try check(after == expected && saves == 0, "\(scenario) preserves session bytes and saves no new Snap")
            }
            source.acquire = { nil }
        }
        print("READBACK_CAPTURE_CHOICE_CHECKS_OK: \(passed) checks")
    }
}
