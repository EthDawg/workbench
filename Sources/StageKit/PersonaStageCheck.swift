import AppKit
import AVFoundation
import ScreenCaptureKit
import VoiceAppearance

/// React to my voice as the window server draws it, for maintainers. Launch the signed app
/// through LaunchServices so macOS applies its own Screen Recording permission:
///
///     open -n -W -a "Workbench Preview.app" --args --persona-check NEW_FOLDER
///
/// It shows the one floating persona slot twice, through the same owner the app uses: My
/// Profile, a synthetic photo drawn as a Circle, and Live Camera, the camera bubble's own
/// window with a synthetic picture in the camera's place. The voice is synthetic too: frames
/// a speaking voice would make, handed to the ring with no microphone opened. Each window is
/// read back through ScreenCaptureKit, as an audience would see it, and measured: the ring's
/// pixels around the picture, at rest and while speaking, and the picture itself. An
/// offscreen `layer.render` of the same window is measured beside it, because that render can
/// show a layer the window never draws (7 October 2026: Present's phone). The receipt and the
/// captures are written to NEW_FOLDER. It uses a disposable library and changes no saved
/// choice, preference or persona.
public enum PersonaStageCheck {
    @MainActor public static func run(output: URL) async throws -> String {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw PersonaError.changedOnDisk }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaStageCheck-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let check = Run(root: root, output: output)
        defer { check.library.shutdown() }
        try await check.perform()
        let data = try JSONSerialization.data(withJSONObject: check.receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("receipt.json"))
        let summary = check.summary.joined(separator: "\n")
        try summary.write(to: output.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        guard check.failures.isEmpty else { throw PersonaVoiceError.unavailable("persona check failed: " + check.failures.joined(separator: "; ")) }
        return summary
    }

    /// A microphone that never opens: the check hands its frames to the ring itself.
    final class SyntheticVoice: PersonaVoiceSource {
        var onFrames: (([PersonaVoiceFrame]) -> Void)?
        var onUnavailable: ((String) -> Void)?
        var onDevice: ((String?) -> Void)?
        private(set) var running = false
        var deviceName: String? { running ? "Synthetic voice" : nil }
        func start() throws { running = true }
        func stop() { running = false }
    }

    /// The camera's place, with a synthetic picture: the session's own preview layer type,
    /// filled with a colour no ring uses, and a first frame announced at once.
    final class SyntheticCamera: ProfileCameraCapturing {
        let previewLayer = AVCaptureVideoPreviewLayer()
        private(set) var starts = 0, stops = 0
        init() { previewLayer.backgroundColor = PersonaStageCheck.cameraColour }
        func start(sourceID: String?, receive: @escaping @MainActor (ProfileCameraEvent) -> Void) {
            starts += 1
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    receive(.sources([ProfileCameraSource(id: "synthetic", name: "Synthetic camera")], selected: "synthetic"))
                    receive(.frame)
                }
            }
        }
        func takePhoto(completion: @escaping @MainActor (Result<NSImage, ProfileCameraIssue>) -> Void) {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(.failure(.unavailable)) } }
        }
        func stop() { stops += 1 }
    }

    /// The stand-in camera picture: a blue no voice colour preset is near.
    static let cameraColour = CGColor(srgbRed: 0.18, green: 0.32, blue: 0.86, alpha: 1)

    /// One speaking moment, as the analyser hands it over: a usual voice with a vowel's bands.
    static func speakingFrame() -> PersonaVoiceFrame {
        PersonaVoiceFrame(level: 0.6, speaking: true, seconds: 0.02, decibels: -22, energy: 0.85,
                          bands: VoiceSpectrum.vowel(0.95).map(Float.init))
    }

    /// What one read-back shows: the ring's pixels outside the picture, where they stand
    /// around it, how far out they reach, and how much of the picture's own circle shows.
    struct Measure {
        var ring = 0
        var quadrants = 0
        var reach: Double = 0
        var picture = 0
        var pictureShare: Double = 0
        var width = 0, height = 0
        var line: String {
            "ring \(ring) px in \(quadrants)/4 quadrants, reaching \(Int(reach.rounded())) px past the picture; picture \(Int((pictureShare * 100).rounded()))% of its circle (\(width)×\(height) px)"
        }
        var dictionary: [String: Any] {
            ["ringPixels": ring, "quadrants": quadrants, "reachPixels": reach, "picturePixels": picture,
             "pictureShare": pictureShare, "width": width, "height": height]
        }
    }

    /// Classifies every pixel: the ring is the voice colour or its rim (green over red and
    /// blue, for the usual mint), the picture is the synthetic photo's warm colours or the
    /// camera's blue. The picture's circle is found from its own pixels.
    static func measure(_ image: CGImage, picture isPicture: (Double, Double, Double) -> Bool) -> Measure {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        var result = Measure(); result.width = width; result.height = height
        var ring: [(Double, Double)] = [], sumX = 0.0, sumY = 0.0
        for y in 0..<height {
            for x in 0..<width {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), colour.alphaComponent > 0.08 else { continue }
                let red = Double(colour.redComponent), green = Double(colour.greenComponent), blue = Double(colour.blueComponent)
                if colour.alphaComponent > 0.5 && isPicture(red, green, blue) {
                    result.picture += 1; sumX += Double(x); sumY += Double(y)
                } else if green > 0.02 && green > red * 1.4 && green > blue * 1.08 {
                    ring.append((Double(x), Double(y)))
                }
            }
        }
        guard result.picture > 0 else { result.ring = ring.count; return result }
        let centre = (sumX / Double(result.picture), sumY / Double(result.picture))
        // The picture is a circle: its radius from its area.
        let radius = (Double(result.picture) / Double.pi).squareRoot()
        var quadrants = Set<Int>()
        for point in ring {
            let dx = point.0 - centre.0, dy = point.1 - centre.1
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance > radius * 0.95 else { continue }
            result.ring += 1
            result.reach = max(result.reach, distance - radius)
            quadrants.insert((dx >= 0 ? 1 : 0) + (dy >= 0 ? 2 : 0))
        }
        result.quadrants = quadrants.count
        // How much of the circle the picture fills: the rest is covered or missing.
        var inside = 0, filled = 0
        let step = max(1, Int(radius / 24))
        for y in stride(from: Int(centre.1 - radius * 0.9), through: Int(centre.1 + radius * 0.9), by: step) {
            for x in stride(from: Int(centre.0 - radius * 0.9), through: Int(centre.0 + radius * 0.9), by: step) {
                let dx = Double(x) - centre.0, dy = Double(y) - centre.1
                guard dx * dx + dy * dy <= radius * radius * 0.81, x >= 0, y >= 0, x < width, y < height else { continue }
                inside += 1
                if let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), colour.alphaComponent > 0.5,
                   isPicture(Double(colour.redComponent), Double(colour.greenComponent), Double(colour.blueComponent)) { filled += 1 }
            }
        }
        result.pictureShare = inside > 0 ? Double(filled) / Double(inside) : 0
        return result
    }

    static func warm(_ red: Double, _ green: Double, _ blue: Double) -> Bool { red > green * 1.15 && red > blue * 1.4 }
    static func blue(_ red: Double, _ green: Double, _ blue: Double) -> Bool { blue > red * 1.4 && blue > green * 1.2 }

    /// A synthetic portrait in warm colours: background, face and hair. No personal artwork.
    static func portrait() -> NSImage {
        NSImage(size: CGSize(width: 600, height: 600), flipped: false) { rect in
            NSColor(srgbRed: 0.95, green: 0.55, blue: 0.2, alpha: 1).setFill(); rect.fill()
            NSColor(srgbRed: 0.42, green: 0.22, blue: 0.12, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 170, y: 40, width: 260, height: 420)).fill()
            NSColor(srgbRed: 0.86, green: 0.6, blue: 0.45, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 205, y: 200, width: 190, height: 230)).fill()
            return true
        }
    }

    @MainActor final class Run {
        let library: PersonaLibrary
        let camera: PersonaLiveCamera
        let capture = SyntheticCamera()
        let output: URL
        let root: URL
        var voices: [SyntheticVoice] = []
        var receipt: [String: Any] = [:]
        var summary: [String] = []
        var failures: [String] = []
        private var talking: Timer?

        init(root: URL, output: URL) {
            self.root = root; self.output = output
            let capture = capture
            camera = PersonaLiveCamera(capture: { capture }, authorize: { $0(.authorized) }, schedule: { _, _ in {} },
                                       list: { PersonaCameraList(devices: [PersonaCameraDevice(id: "synthetic", name: "Synthetic camera", inUseByAnotherApp: false)],
                                                                 preferredID: "synthetic") })
            var made: [SyntheticVoice] = []
            let access = PersonaVoiceAccess(permission: { .allowed }, requestPermission: { $0(true) },
                                            makeSource: { let voice = SyntheticVoice(); made.append(voice); return voice },
                                            savedChoice: { false }, saveChoice: { _ in })
            library = PersonaLibrary(root: root.appendingPathComponent("library"), sessionHUDEnabled: false, voice: access, camera: camera)
            library.usesSharedControls = true
            voiceSources = { made }
        }
        /// Every synthetic microphone the library opened, read live.
        private var voiceSources: () -> [SyntheticVoice] = { [] }
        var listening: SyntheticVoice? { voiceSources().last { $0.running } }

        func expect(_ passed: Bool, _ message: String) {
            summary.append((passed ? "PASS " : "FAIL ") + message)
            if !passed { failures.append(message) }
        }
        func note(_ message: String) { summary.append("NOTE " + message) }
        func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        /// A voice for `seconds`: one frame every 20 ms, as the microphone tap hands them over.
        func speak() {
            talking?.invalidate()
            talking = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.listening?.onFrames?([PersonaStageCheck.speakingFrame()]) }
            }
        }
        func silence() { talking?.invalidate(); talking = nil }

        /// The visible persona windows, largest first: the slot's card or bubble, never its handles.
        func personaWindow() -> NSWindow? {
            NSApp.windows.filter { $0.title == "Workbench persona" && $0.isVisible && $0.alphaValue > 0.5 }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }

        func perform() async throws {
            let photo = root.appendingPathComponent("synthetic-profile.png")
            guard let tiff = PersonaStageCheck.portrait().tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw PersonaError.unreadableImage }
            try png.write(to: photo)
            let profile = try library.addImage(photo, name: "Synthetic profile")
            library.setShape(.circle, for: profile.id)
            library.setVoiceRing(true)
            expect(library.voiceRing, "React to my voice is on (synthetic microphone, nothing opened)")
            receipt["voiceColour"] = [library.voiceColor.r, library.voiceColor.g, library.voiceColor.b]

            // My Profile: the photo as the one floating card.
            library.selectedID = profile.id
            guard case .success = library.showOverlay() else { throw PersonaError.unreadableImage }
            await wait(0.6)
            try await examine("photo", name: "My Profile", picture: PersonaStageCheck.warm)

            // Live Camera: the bubble's own window, with the synthetic picture in the camera's place.
            library.startCamera()
            await wait(0.8)
            expect(camera.isLive, "Live Camera is showing its synthetic picture")
            try await examine("camera", name: "Live Camera", picture: PersonaStageCheck.blue)

            // Back to the photo the way the pill does it, from its Choose Persona picker while
            // Live Camera shows: the photo is My Profile, or the first card before that name.
            let picker = library.makeToolbarPickerMenu()
            receipt["pickerWithCamera"] = picker.items.map(\.title)
            if let item = picker.items.first(where: { $0.title == "My Profile" }) ?? picker.items.first(where: { $0.title == "Persona 1" }),
               let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
                await wait(0.8)
                expect(!camera.isActive && library.artworkVisible, "choosing the photo in the picker ends Live Camera and shows the photo")
                try await examine("switch", name: "My Profile after Live Camera", picture: PersonaStageCheck.warm)
            } else { expect(false, "the picker offers the photo while Live Camera shows (\(picker.items.map(\.title)))") }
            library.endCamera()
            await wait(0.3)
        }

        /// Reads one source's window back at rest and while speaking, and measures both.
        func examine(_ key: String, name: String, picture: @escaping (Double, Double, Double) -> Bool) async throws {
            guard let window = personaWindow() else {
                expect(false, "\(name): a persona window is on screen"); return
            }
            receipt[key + "Window"] = ["width": window.frame.width, "height": window.frame.height]
            expect(listening != nil, "\(name): the ring listens while it shows (a synthetic microphone is open)")
            let rest = try await readBack(window, name: key + "-rest")
            let offscreenRest = offscreen(window, name: key + "-rest-offscreen")
            speak()
            await wait(0.6)
            let speaking = try await readBack(window, name: key + "-speaking")
            let offscreenSpeaking = offscreen(window, name: key + "-speaking-offscreen")
            silence()
            let restMeasure = rest.map { PersonaStageCheck.measure($0, picture: picture) }
            let speakingMeasure = speaking.map { PersonaStageCheck.measure($0, picture: picture) }
            func value(_ measure: Measure?, _ missing: String) -> Any { measure.map { $0.dictionary as Any } ?? missing }
            receipt[key] = [
                "rest": value(restMeasure, "not measured"), "speaking": value(speakingMeasure, "not measured"),
                "offscreenRest": value(offscreenRest.map { PersonaStageCheck.measure($0, picture: picture) }, "not rendered"),
                "offscreenSpeaking": value(offscreenSpeaking.map { PersonaStageCheck.measure($0, picture: picture) }, "not rendered")]
            guard let restMeasure, let speakingMeasure else {
                expect(false, "\(name): the window could be read back through ScreenCaptureKit (Screen Recording)"); return
            }
            expect(restMeasure.pictureShare > 0.9, "\(name): the picture shows in the real window (\(Int((restMeasure.pictureShare * 100).rounded()))% of its circle)")
            expect(restMeasure.ring > 50 && restMeasure.quadrants == 4, "\(name): the resting ring of dots surrounds the picture in the real window — " + restMeasure.line)
            expect(speakingMeasure.ring > restMeasure.ring && speakingMeasure.reach > restMeasure.reach + 4,
                   "\(name): a voice raises the dots into bars in the real window — " + speakingMeasure.line)
            if let offscreenSpeaking {
                note("\(name) offscreen layer.render while speaking: " + PersonaStageCheck.measure(offscreenSpeaking, picture: picture).line)
            }
        }

        /// The window as the window server composites it, through ScreenCaptureKit.
        func readBack(_ window: NSWindow, name: String) async throws -> CGImage? {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let shared = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    note("\(name): the window was not visible to ScreenCaptureKit"); return nil
                }
                let filter = SCContentFilter(desktopIndependentWindow: shared)
                let configuration = SCStreamConfiguration()
                let scale = window.backingScaleFactor
                configuration.width = Int(window.frame.width * scale); configuration.height = Int(window.frame.height * scale)
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                save(image, name)
                return image
            } catch {
                note("\(name): not read back (\((error as NSError).domain) \((error as NSError).code))")
                return nil
            }
        }

        /// The same window's layers rendered offscreen, which can draw what the window does not.
        func offscreen(_ window: NSWindow, name: String) -> CGImage? {
            guard let layer = window.contentView?.layer else { return nil }
            let scale = window.backingScaleFactor, size = layer.bounds.size
            guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            guard let image = context.makeImage() else { return nil }
            save(image, name)
            return image
        }

        func save(_ image: CGImage, _ name: String) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: output.appendingPathComponent(name + ".png"))
        }
    }
}
