import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// React to my voice owns a live microphone, so these checks pin when it may
/// run: only while it is on and the persona it frames is showing, and never
/// after hide, End, Quit, a denied permission or a lost device. Fakes stand in
/// for the microphone, the permission prompt and saved preferences; the
/// analyzer and outline checks use synthetic sound and artwork.
final class PersonaVoiceTests {
    private final class Microphone: PersonaVoiceSource {
        var onFrames: (([PersonaVoiceFrame]) -> Void)?
        var onUnavailable: ((String) -> Void)?
        var onDevice: ((String?) -> Void)?
        var failure: Error?
        private(set) var running = false
        var deviceName: String? { running ? "Synthetic microphone" : nil }
        func start() throws { if let failure { throw failure }; running = true }
        func stop() { running = false }
    }
    private final class Microphones {
        var made: [Microphone] = []
        var failure: Error?
        var permission = PersonaVoiceAccess.Permission.allowed
        var requests: [(Bool) -> Void] = []
        var running: [Microphone] { made.filter(\.running) }
    }
    private final class Display: PersonaSessionDisplaying {
        var onPlacementChange: ((PersonaOverlayState) -> Void)?
        var onSelection: (() -> Void)?
        var frame: CGRect? = CGRect(x: 0, y: 0, width: 80, height: 80)
        var ring = false
        var heard: [PersonaVoiceFrame] = []
        func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState { state }
        func configure(image: NSImage, name: String, state: PersonaOverlayState) {}
        func hide() {}
        func shutdown() { ring = false }
        func setVoiceRing(_ on: Bool) { ring = on }
        func showVoice(_ frames: [PersonaVoiceFrame]) { heard += frames }
    }
    private final class Displays { var made: [Display] = [] }
    /// The remembered choice, in memory: no preference file is written (#128).
    private final class Choice { var saved = false }

    private func access(_ microphones: Microphones, _ defaults: Choice) -> PersonaVoiceAccess {
        PersonaVoiceAccess(permission: { microphones.permission },
                           requestPermission: { microphones.requests.append($0) },
                           makeSource: { let microphone = Microphone(); microphone.failure = microphones.failure; microphones.made.append(microphone); return microphone },
                           savedChoice: { defaults.saved }, saveChoice: { defaults.saved = $0 })
    }
    private func fixture(_ microphones: Microphones, _ defaults: Choice, _ displays: Displays) throws -> (URL, PersonaLibrary, UUID, [UUID]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaVoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let picture = root.appendingPathComponent("sample.png")
        guard let tiff = Self.badge().tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { throw PersonaError.unreadableImage }
        try data.write(to: picture)
        let library = PersonaLibrary(root: root, sessionPanelFactory: { let display = Display(); displays.made.append(display); return display },
                                     sessionHUDEnabled: false, voice: access(microphones, defaults))
        let persona = try library.addImage(picture, name: "Sample presenter")
        let group = try library.createGroup(name: "Sample group", members: [persona.id])
        let presenter = PersonaOverlayItem(personaID: persona.id, placement: PersonaOverlayState(x: 0.02, y: 0.02, width: 0.12, locked: true))
        let guest = PersonaOverlayItem(personaID: persona.id, placement: PersonaOverlayState(x: 0.98, y: 0.02, width: 0.12, locked: true))
        try library.saveGroupLayout(group, overlays: [presenter, guest], publicLabel: "Sample set")
        return (root, library, group, [presenter.id, guest.id])
    }

    func testVoiceRingListensOnlyWhileOnAndItsPersonaShows() throws {
        let defaults = Choice()
        let microphones = Microphones(), displays = Displays()
        let (root, library, group, overlays) = try fixture(microphones, defaults, displays)
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(library.voiceAvailable)
        XCTAssertFalse(library.voiceRing, "React to my voice starts off")
        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
        XCTAssertTrue(microphones.made.isEmpty, "Showing a persona never opens the microphone by itself")
        XCTAssertFalse(displays.made.contains(where: \.ring))

        library.setVoiceRing(true)
        XCTAssertEqual(microphones.running.count, 1)
        XCTAssertEqual(library.voiceDevice, "Synthetic microphone")
        XCTAssertEqual(library.voiceStatus, "Listening · Synthetic microphone")
        XCTAssertTrue(defaults.saved, "The choice is remembered")
        XCTAssertEqual(displays.made.map(\.ring), [true, false], "The ring frames the selected overlay only")
        microphones.running.first?.onFrames?([PersonaVoiceFrame(level: 0.7, bands: [0.7, 0.6, 0.4, 0.3, 0.2, 0.1], speaking: true, seconds: 0.02)])
        XCTAssertEqual(displays.made[0].heard.count, 1)
        XCTAssertTrue(displays.made[1].heard.isEmpty, "Only the framed overlay hears the voice")

        // Choosing another overlay passes the voice to it.
        library.performOverlayAction(.selectInstance(overlays[1]))
        XCTAssertEqual(displays.made.map(\.ring), [false, true])
        XCTAssertEqual(microphones.running.count, 1, "Passing the ring keeps one microphone")
        microphones.running.first?.onFrames?([PersonaVoiceFrame(level: 0.5, bands: [0.5, 0.4, 0.3, 0.2, 0.1, 0.1], speaking: true, seconds: 0.02)])
        XCTAssertEqual(displays.made[1].heard.count, 1)

        // A hidden selection has no ring and no microphone.
        library.performOverlayAction(.visible(overlays[1], false))
        XCTAssertTrue(microphones.running.isEmpty, "Hiding the framed overlay stops the microphone")
        XCTAssertFalse(displays.made.contains(where: \.ring))
        library.performOverlayAction(.visible(overlays[1], true))
        XCTAssertEqual(microphones.running.count, 1)

        library.pauseOverlaySession()
        XCTAssertTrue(microphones.running.isEmpty, "Hide all stops the microphone")
        try library.resumeOverlaySession()
        XCTAssertEqual(microphones.running.count, 1, "Showing again resumes the ring that is still on")

        library.setVoiceRing(false)
        XCTAssertTrue(microphones.running.isEmpty, "Turning it off stops the microphone at once")
        XCTAssertFalse(displays.made.contains(where: \.ring))
        XCTAssertTrue(library.voiceDevice == nil)
        XCTAssertFalse(defaults.saved)

        library.setVoiceRing(true)
        XCTAssertEqual(microphones.running.count, 1)
        library.endOverlaySession()
        XCTAssertTrue(microphones.running.isEmpty, "End stops the microphone")
        XCTAssertTrue(library.voiceRing, "Ending keeps the choice for next time")
        XCTAssertEqual(library.voiceStatus, "Listens while a persona shows")

        let reopened = PersonaLibrary(root: root, sessionPanelFactory: { Display() }, sessionHUDEnabled: false, voice: access(microphones, defaults))
        XCTAssertTrue(reopened.voiceRing, "The choice survives a restart")
        reopened.shutdown()
        let withoutVoice = PersonaLibrary(root: root, sessionPanelFactory: { Display() }, sessionHUDEnabled: false)
        XCTAssertFalse(withoutVoice.voiceAvailable || withoutVoice.voiceRing, "Libraries without the app's microphone have no switch")
        withoutVoice.setVoiceRing(true)
        XCTAssertFalse(withoutVoice.voiceRing)
        withoutVoice.shutdown()

        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
        XCTAssertEqual(microphones.running.count, 1, "A remembered ring starts with the next set")
        XCTAssertTrue(displays.made.suffix(2).first?.ring == true, "It is placed with its ring from the start")
        library.shutdown()
        XCTAssertTrue(microphones.running.isEmpty, "Quit stops the microphone")
    }

    func testVoiceRingAsksWhilePreparingAndStopsWhenTheMicrophoneIsUnavailable() throws {
        let defaults = Choice()
        let microphones = Microphones(), displays = Displays()
        let (root, library, group, _) = try fixture(microphones, defaults, displays)
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }

        // Nothing is showing: turning it on asks now, not later in front of an audience.
        microphones.permission = .undecided
        library.setVoiceRing(true)
        XCTAssertEqual(microphones.requests.count, 1, "macOS is asked when the presenter turns it on")
        XCTAssertEqual(library.voiceStatus, "Waiting for microphone access")
        library.setVoiceRing(true)
        XCTAssertEqual(microphones.requests.count, 1, "Only one question at a time")
        microphones.permission = .denied
        microphones.requests.removeFirst()(false)
        XCTAssertFalse(library.voiceRing, "A refusal turns it back off")
        XCTAssertTrue(library.notice?.contains("microphone access") == true)
        XCTAssertTrue(microphones.made.isEmpty)

        library.setVoiceRing(true)
        XCTAssertFalse(library.voiceRing, "Still refused: it stays off and explains")
        XCTAssertTrue(microphones.requests.isEmpty, "A settled refusal is not asked again")

        microphones.permission = .undecided
        library.setVoiceRing(true)
        microphones.permission = .allowed
        microphones.requests.removeFirst()(true)
        XCTAssertTrue(library.voiceRing)
        XCTAssertTrue(microphones.made.isEmpty, "Allowed, but nothing is showing yet")
        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
        XCTAssertEqual(microphones.running.count, 1)

        microphones.running.first?.onUnavailable?("Synthetic device loss.")
        XCTAssertFalse(library.voiceRing)
        XCTAssertTrue(microphones.running.isEmpty, "A lost device leaves no microphone running")
        XCTAssertEqual(library.notice, "Synthetic device loss.")
        XCTAssertFalse(displays.made.contains(where: \.ring))

        microphones.failure = PersonaVoiceError.unavailable("No microphone input is available.")
        library.setVoiceRing(true)
        XCTAssertFalse(library.voiceRing, "A microphone that cannot start turns it off")
        XCTAssertEqual(library.notice, "React to my voice stopped: No microphone input is available.")
    }

    func testSingleFloatingPersonaIsPlacedWithRoomForItsRing() throws {
        let defaults = Choice()
        let microphones = Microphones(), displays = Displays()
        let (root, library, _, _) = try fixture(microphones, defaults, displays)
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
        guard case .success = library.showOverlay() else { XCTAssertTrue(false, "The persona shows"); return }
        XCTAssertTrue(microphones.made.isEmpty)
        library.setVoiceRing(true)
        XCTAssertEqual(microphones.running.count, 1)
        library.hideOverlay()
        XCTAssertTrue(microphones.running.isEmpty, "Hiding the floating persona stops the microphone")
        _ = library.showOverlay()
        XCTAssertEqual(microphones.running.count, 1)
        library.toggleQuickPersona()
        XCTAssertTrue(microphones.running.isEmpty, "The persona key hides it and stops listening")
    }

    func testPlacementKeepsArtworkSizeAndTheRingOnScreen() {
        let available = CGRect(x: 0, y: 25, width: 1512, height: 920)
        let placement = PersonaPlacement(image: "persona.png", x: 0.98, y: 0.02, width: 0.16)
        let placed = PersonaGeometry.rect(placement, imageSize: CGSize(width: 480, height: 600), in: available.size)
        XCTAssertEqual(PersonaOverlayController.placedFrame(placed, insets: NSEdgeInsetsZero, x: 0.98, y: 0.02, in: available),
                       placed.offsetBy(dx: available.minX, dy: available.minY), "Off, placement is exactly as before")
        let geometry = PersonaVoiceRingGeometry(outline: .roundedRect(CGRect(x: 0, y: 0, width: 1, height: 1.25), radius: 0.06),
                                                artwork: CGRect(origin: .zero, size: placed.size))
        let insets = geometry.outsets
        XCTAssertGreaterThan(insets.left, geometry.reach, "The ring reaches beyond a full-bleed card")
        for (x, y) in [(0.0, 0.0), (0.98, 0.02), (0.5, 0.5), (1.0, 1.0)] {
            let frame = PersonaOverlayController.placedFrame(placed, insets: insets, x: x, y: y, in: available)
            XCTAssertTrue(available.insetBy(dx: -0.5, dy: -0.5).contains(frame), "The ring stays on screen at \(x), \(y)")
            XCTAssertEqual(Double(frame.width - insets.left - insets.right), Double(placed.width), accuracy: 0.001)
            XCTAssertEqual(Double(frame.height - insets.top - insets.bottom), Double(placed.height), accuracy: 0.001)
        }
        // Centred artwork does not move when its ring appears.
        let middle = PersonaGeometry.rect(PersonaPlacement(image: "persona.png", x: 0.5, y: 0.5, width: 0.16), imageSize: CGSize(width: 480, height: 600), in: available.size)
        let centred = PersonaOverlayController.placedFrame(middle, insets: insets, x: 0.5, y: 0.5, in: available)
        XCTAssertEqual(Double(centred.minX + insets.left), Double(middle.minX + available.minX), accuracy: 0.51)
        XCTAssertEqual(Double(centred.minY + insets.bottom), Double(middle.minY + available.minY), accuracy: 0.51)
    }

    // MARK: Sound

    /// Deterministic white noise and a voiced tone with harmonics, shaped into
    /// syllables with short gaps and a breath every two seconds.
    private struct Voice {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        mutating func noise() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(state % 20_001) / 10_000 - 1
        }
        static func amplitude(_ decibels: Float) -> Float { pow(10, decibels / 20) }
        mutating func render(seconds: Double, rate: Double, speech: Float?, noise: Float, pitch: Double = 140,
                             syllables: Bool = true) -> (samples: [Float], voiced: [Bool]) {
            let count = Int(seconds * rate)
            var samples = [Float](repeating: 0, count: count), voiced = [Bool](repeating: false, count: count)
            // White noise from ±1 uniform has RMS 1/√3; a harmonic stack is normalised below.
            let noiseScale = Self.amplitude(noise) * Float(3).squareRoot()
            let harmonics = (1...12).map { 1 / Float($0) }
            let stackRMS = (harmonics.reduce(0) { $0 + $1 * $1 } / 2).squareRoot()
            for index in 0..<count {
                let time = Double(index) / rate
                let inBreath = syllables && time.truncatingRemainder(dividingBy: 2) > 1.6
                let inGap = syllables && time.truncatingRemainder(dividingBy: 0.25) > 0.18
                var value = self.noise() * noiseScale
                if let speech, !inBreath, !inGap {
                    var tone: Float = 0
                    for (number, weight) in harmonics.enumerated() {
                        tone += weight * Float(sin(2 * .pi * pitch * Double(number + 1) * time))
                    }
                    value += tone / stackRMS * Self.amplitude(speech)
                    voiced[index] = true
                }
                samples[index] = value
            }
            return (samples, voiced)
        }
    }
    private func analyze(_ samples: [Float], rate: Double, buffer: Int = 4_800) -> [PersonaVoiceFrame] {
        let analyzer = PersonaVoiceAnalyzer(sampleRate: rate)
        var frames: [PersonaVoiceFrame] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + buffer)
            frames += samples[start..<end].withUnsafeBufferPointer { analyzer.process($0) }
            start = end
        }
        return frames
    }
    private func mean(_ values: [Float]) -> Float { values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count) }

    func testAnalyzerFillsTheRingForQuietAndLoudMicrophonesButNotForTheRoom() {
        let rate = 48_000.0
        for (speech, noise, name) in [(Float(-24), Float(-58), "built-in"), (-44, -72, "quiet"), (-12, -50, "headset")] {
            var voice = Voice()
            let (samples, voiced) = voice.render(seconds: 6, rate: rate, speech: speech, noise: noise)
            let frames = analyze(samples, rate: rate)
            let chunk = Int(frames[0].seconds * rate)
            var talking: [Float] = [], breathing: [Float] = [], speakingInGaps = 0, gaps = 0
            for (index, frame) in frames.enumerated() where Double(index) * frame.seconds > 1 {
                let span = voiced[(index * chunk)..<min(voiced.count, (index + 1) * chunk)]
                let time = Double(index) * frame.seconds
                if span.allSatisfy({ $0 }) { talking.append(frame.level) }
                if (1.7...1.96).contains(time.truncatingRemainder(dividingBy: 2)) { breathing.append(frame.level) }
                if !span.contains(true), time.truncatingRemainder(dividingBy: 2) < 1.5 { gaps += 1; if frame.speaking { speakingInGaps += 1 } }
            }
            XCTAssertGreaterThan(mean(talking), 0.55, "\(name) microphone: speech fills the ring (\(mean(talking)))")
            XCTAssertTrue((breathing.max() ?? 1) < 0.12, "\(name) microphone: a breath lets it rest (\(breathing.max() ?? 1))")
            XCTAssertEqual(speakingInGaps, gaps, "\(name) microphone: short gaps between syllables stay speaking")
        }
        XCTAssertEqual(PersonaVoiceAnalyzer(sampleRate: 48_000).chunk, 1_024)
        XCTAssertEqual(PersonaVoiceAnalyzer(sampleRate: 16_000).chunk, 256)
    }

    func testAnalyzerLearnsTheRoomAndIgnoresStartupSilence() {
        let rate = 44_100.0
        var voice = Voice()
        // A device that starts with exact zeros, then a steady room.
        var samples = [Float](repeating: 0, count: Int(0.5 * rate))
        samples += voice.render(seconds: 4, rate: rate, speech: nil, noise: -60).samples
        let settled = analyze(samples, rate: rate).enumerated().filter { Double($0.offset) * $0.element.seconds > 1.2 }.map(\.element)
        XCTAssertTrue(settled.allSatisfy { $0.level < 0.08 && !$0.speaking }, "Room noise alone never moves the ring")

        // A fan switched on: the ring settles again within seconds.
        var room = voice.render(seconds: 3, rate: rate, speech: nil, noise: -66).samples
        room += voice.render(seconds: 9, rate: rate, speech: nil, noise: -46).samples
        let frames = analyze(room, rate: rate)
        let late = frames.enumerated().filter { Double($0.offset) * $0.element.seconds > 9 }.map(\.element.level)
        XCTAssertTrue((late.max() ?? 1) < 0.08, "A louder room is learned (\(late.max() ?? 1))")
    }

    func testAnalyzerBandsFollowPitch() {
        let rate = 48_000.0
        func bands(_ frequency: Double) -> [Float] {
            var voice = Voice()
            var samples = voice.render(seconds: 1.5, rate: rate, speech: nil, noise: -70).samples
            samples += (0..<Int(rate)).map { Float(sin(2 * .pi * frequency * Double($0) / rate)) * Voice.amplitude(-20) }
            let frames = analyze(samples, rate: rate)
            return frames[frames.count - 5].bands
        }
        let low = bands(150), high = bands(5_500)
        XCTAssertEqual(low.firstIndex(of: low.max()!), 0, "A low voice lights the low bands")
        XCTAssertEqual(high.firstIndex(of: high.max()!), 5, "An 's' lights the high bands")
        XCTAssertTrue(low.allSatisfy { $0 <= 1 && $0 >= 0 } && high.allSatisfy { $0 <= 1 && $0 >= 0 })
    }

    // MARK: Artwork

    /// A round badge like a presenter's headshot: a hat breaking out of the top
    /// and a label pill across the bottom, on transparency.
    static func badge() -> NSImage {
        NSImage(size: CGSize(width: 280, height: 280), flipped: false) { _ in
            NSColor(srgbRed: 0.93, green: 0.76, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 40, y: 50, width: 200, height: 200)).fill()
            NSColor(srgbRed: 0.1, green: 0.2, blue: 0.2, alpha: 1).setStroke()
            let rim = NSBezierPath(ovalIn: CGRect(x: 40, y: 50, width: 200, height: 200)); rim.lineWidth = 6; rim.stroke()
            NSColor(white: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 100, y: 222, width: 80, height: 52), xRadius: 26, yRadius: 26).fill()
            NSColor(srgbRed: 0.35, green: 0.4, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 95, y: 55, width: 90, height: 120)).fill()
            NSColor(srgbRed: 0.93, green: 0.76, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 35, y: 8, width: 210, height: 46), xRadius: 23, yRadius: 23).fill()
            return true
        }
    }
    private func bitmap(_ image: NSImage) -> CGImage { image.cgImage(forProposedRect: nil, context: nil, hints: nil)! }

    func testOutlineFollowsARoundBadgeACardAndAPhoto() throws {
        guard case .circle(let center, let radius) = PersonaVoiceOutline.analyze(bitmap(Self.badge())).outline else {
            XCTAssertTrue(false, "A round badge gets a circle"); return
        }
        XCTAssertEqual(Double(center.x), 0.5, accuracy: 0.02)
        XCTAssertEqual(Double(center.y), 150.0 / 280, accuracy: 0.02)
        XCTAssertEqual(Double(radius), 100.0 / 280, accuracy: 0.02)

        let card = try PersonaCardRenderer.image(portrait: Self.badge(), style: PersonaCardStyle(label: "Care lead"))
        guard case .roundedRect(let box, let corner) = PersonaVoiceOutline.analyze(bitmap(card)).outline else {
            XCTAssertTrue(false, "A card gets its rounded rectangle"); return
        }
        XCTAssertEqual(Double(box.width), 1, accuracy: 0.02)
        XCTAssertEqual(Double(box.height), 1.25, accuracy: 0.02)
        XCTAssertEqual(Double(corner), 28.0 / 480, accuracy: 0.025)

        let photo = NSImage(size: CGSize(width: 400, height: 300), flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)!.draw(in: rect, angle: 30); return true
        }
        XCTAssertEqual(PersonaVoiceOutline.analyze(bitmap(photo)).outline, .roundedRect(CGRect(x: 0, y: 0, width: 1, height: 0.75), radius: 0))

        // A cut-out head and shoulders is not a badge: its small head must not win.
        let cutout = NSImage(size: CGSize(width: 300, height: 360), flipped: false) { _ in
            NSColor(srgbRed: 0.3, green: 0.3, blue: 0.5, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 105, y: 210, width: 90, height: 110)).fill()
            NSBezierPath(roundedRect: CGRect(x: 20, y: 0, width: 260, height: 190), xRadius: 90, yRadius: 90).fill()
            return true
        }
        guard case .roundedRect = PersonaVoiceOutline.analyze(bitmap(cutout)).outline else {
            XCTAssertTrue(false, "A cut-out gets the rounded box of its visible pixels"); return
        }
    }

    func testRingColourComesFromTheArtwork() {
        func hue(_ color: NSColor) -> Double {
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return Double(hue) * 360
        }
        let yellow = PersonaVoiceOutline.analyze(bitmap(Self.badge())).tint
        XCTAssertEqual(hue(yellow), 43, accuracy: 8)
        let grey = NSImage(size: CGSize(width: 120, height: 120), flipped: false) { rect in NSColor(white: 0.45, alpha: 1).setFill(); rect.fill(); return true }
        XCTAssertEqual(PersonaVoiceOutline.analyze(bitmap(grey)).tint, PersonaVoiceOutline.fallbackTint, "Colourless artwork gets Workbench mint")
        var brightness: CGFloat = 0, hueValue: CGFloat = 0, saturation: CGFloat = 0, alpha: CGFloat = 0
        let dark = NSImage(size: CGSize(width: 120, height: 120), flipped: false) { rect in
            NSColor(srgbRed: 0.08, green: 0.38, blue: 0.31, alpha: 1).setFill(); rect.fill(); return true
        }
        PersonaVoiceOutline.analyze(bitmap(dark)).tint.getHue(&hueValue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        XCTAssertGreaterThan(brightness, 0.8, "A dark card colour is brightened to read on screen")
    }

    func testRingGeometryScalesWithTheArtwork() {
        let small = PersonaVoiceRingGeometry(outline: .circle(center: CGPoint(x: 0.5, y: 0.5), radius: 0.5), artwork: CGRect(x: 0, y: 0, width: 120, height: 120))
        let large = PersonaVoiceRingGeometry(outline: .circle(center: CGPoint(x: 0.5, y: 0.5), radius: 0.5), artwork: CGRect(x: 0, y: 0, width: 480, height: 480))
        XCTAssertTrue((36...120).contains(small.anchors.count) && (36...120).contains(large.anchors.count))
        XCTAssertGreaterThan(large.reach, small.reach)
        XCTAssertTrue(small.anchors.allSatisfy { hypot($0.point.x - 60, $0.point.y - 60) > 60 }, "Bars start outside the artwork")
        XCTAssertEqual(Double(small.outsets.left), Double(small.outsets.right), accuracy: 1)
        XCTAssertEqual(Double(small.outsets.top), Double(small.outsets.bottom), accuracy: 1)
        // A badge circle inside its picture needs less room than a full-bleed card.
        let badge = PersonaVoiceRingGeometry(outline: .circle(center: CGPoint(x: 0.5, y: 0.536), radius: 0.357), artwork: CGRect(x: 0, y: 0, width: 240, height: 240))
        let card = PersonaVoiceRingGeometry(outline: .roundedRect(CGRect(x: 0, y: 0, width: 1, height: 1), radius: 0.06), artwork: CGRect(x: 0, y: 0, width: 240, height: 240))
        XCTAssertGreaterThan(card.outsets.left, badge.outsets.left)
        let corners = card.anchors.filter { abs($0.normal.dx) > 0.3 && abs($0.normal.dy) > 0.3 }
        XCTAssertGreaterThan(corners.count, 0, "Corners are turned, not left bare")
    }

    /// Set WORKBENCH_LAYOUT_EVIDENCE to write synthetic renders of the ring.
    func testOffscreenVoiceRingRenders() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let card = try PersonaCardRenderer.image(portrait: Self.badge(), style: PersonaCardStyle(label: "Care lead"))
        for (name, artwork) in [("badge", Self.badge()), ("card", card)] {
            for (label, level) in [("quiet", Float(0)), ("speaking", 0.55), ("loud", 1)] {
                let stage = try Stage(artwork)
                let frame = PersonaVoiceFrame(level: level, bands: [level, level * 0.8, level * 0.55, level * 0.4, level * 0.3, level * 0.2], speaking: level > 0, seconds: 0.02)
                for _ in 0..<60 { stage.ring.enqueue([frame]); stage.ring.advance(by: 1.0 / 60) }
                try png(stage.snapshot(), to: directory.appendingPathComponent("voice-ring-\(name)-\(label).png"))
            }
            try animate(artwork, to: directory.appendingPathComponent("voice-ring-\(name)-speech.gif"))
        }
        // The Persona page's switch while it listens, with synthetic artwork.
        let microphones = Microphones(), displays = Displays()
        let (root, library, _, _) = try fixture(microphones, Choice(), displays)
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
        library.usesSharedControls = true
        _ = library.showOverlay()
        library.setVoiceRing(true)
        try MainActor.assumeIsolated {
            for (label, size) in [("narrow", CGSize(width: 620, height: 650)), ("normal", CGSize(width: 834, height: 730))] {
                let hosting = NSHostingView(rootView: PersonaLibraryView(library: library, mode: .workspace).frame(width: size.width, height: size.height))
                let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = hosting
                defer { window.close() }
                hosting.frame = CGRect(origin: .zero, size: size)
                for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw PersonaError.unreadableImage }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { throw PersonaError.unreadableImage }
                try png(image, to: directory.appendingPathComponent("persona-page-voice-\(label).png"))
            }
        }
    }
    /// Synthetic artwork and its ring over half a light slide, half a dark editor.
    private final class Stage {
        let ring = PersonaVoiceRingLayer()
        let image: CGImage
        let canvas: CGSize
        let artworkRect: CGRect
        init(_ artwork: NSImage) throws {
            guard let image = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PersonaError.unreadableImage }
            self.image = image
            let analysis = PersonaVoiceOutline.analyze(image)
            let size = CGSize(width: 240, height: 240 * artwork.size.height / artwork.size.width)
            let insets = PersonaVoiceRingGeometry(outline: analysis.outline, artwork: CGRect(origin: .zero, size: size)).outsets
            canvas = CGSize(width: size.width + insets.left + insets.right + 40, height: size.height + insets.top + insets.bottom + 40)
            artworkRect = CGRect(x: insets.left + 20, y: insets.bottom + 20, width: size.width, height: size.height)
            ring.reduceMotion = false; ring.increaseContrast = false
            ring.frame = CGRect(origin: .zero, size: canvas); ring.contentsScale = 2
            ring.tint = analysis.tint
            ring.geometry = PersonaVoiceRingGeometry(outline: analysis.outline, artwork: artworkRect)
            ring.layoutIfNeeded()
        }
        func snapshot(scale: Int = 2) throws -> CGImage {
            guard let context = CGContext(data: nil, width: Int(canvas.width) * scale, height: Int(canvas.height) * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw PersonaError.unreadableImage }
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: canvas.width / 2, height: canvas.height))
            context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); context.fill(CGRect(x: canvas.width / 2, y: 0, width: canvas.width / 2, height: canvas.height))
            ring.render(in: context)
            context.draw(image, in: artworkRect)
            guard let result = context.makeImage() else { throw PersonaError.unreadableImage }
            return result
        }
    }
    private func png(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw PersonaError.unreadableImage }
        try data.write(to: url)
        print("Offscreen voice ring: " + url.path)
    }
    /// Synthetic speech through the real analyzer, sampled at 20 frames a
    /// second, about what a meeting app sends of a shared screen.
    private func animate(_ artwork: NSImage, to url: URL) throws {
        let rate = 48_000.0
        var voice = Voice()
        let frames = analyze(voice.render(seconds: 4, rate: rate, speech: -24, noise: -58).samples, rate: rate)
        let stage = try Stage(artwork)
        let count = 64
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw PersonaError.unreadableImage }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var heard = 0, elapsed = 0.0
        for index in 0..<count {
            let time = Double(index) / 20
            var batch: [PersonaVoiceFrame] = []
            while heard < frames.count, elapsed < time { batch.append(frames[heard]); elapsed += frames[heard].seconds; heard += 1 }
            if !batch.isEmpty { stage.ring.enqueue(batch) }
            for _ in 0..<3 { stage.ring.advance(by: 1.0 / 60) }
            CGImageDestinationAddImage(gif, try stage.snapshot(scale: 1), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 20]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { throw PersonaError.unreadableImage }
        print("Offscreen voice ring: " + url.path)
    }
}
