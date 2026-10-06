import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import VoiceAppearance

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
        /// Microphone Settings… presses, which here open nothing.
        var settingsOpened = 0
    }
    private final class Display: PersonaSessionDisplaying {
        var onPlacementChange: ((PersonaOverlayState) -> Void)?
        var onSelection: (() -> Void)?
        var frame: CGRect? = CGRect(x: 0, y: 0, width: 80, height: 80)
        var ring = false
        var color: InkColor?
        var heard: [PersonaVoiceFrame] = []
        func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState { state }
        func configure(image: NSImage, name: String, state: PersonaOverlayState) {}
        func hide() {}
        func shutdown() { ring = false }
        func setVoiceRing(_ on: Bool) { ring = on }
        func setVoiceColor(_ color: InkColor) { self.color = color }
        func showVoice(_ frames: [PersonaVoiceFrame]) { heard += frames }
    }
    private final class Displays { var made: [Display] = [] }
    /// The remembered choice, in memory: no preference file is written (#128).
    private final class Choice { var saved = false; var color: InkColor? }

    private func access(_ microphones: Microphones, _ defaults: Choice) -> PersonaVoiceAccess {
        PersonaVoiceAccess(permission: { microphones.permission },
                           requestPermission: { microphones.requests.append($0) },
                           makeSource: { let microphone = Microphone(); microphone.failure = microphones.failure; microphones.made.append(microphone); return microphone },
                           savedChoice: { defaults.saved }, saveChoice: { defaults.saved = $0 },
                           savedColor: { defaults.color }, saveColor: { defaults.color = $0 },
                           openMicrophoneSettings: { microphones.settingsOpened += 1 })
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
        microphones.running.first?.onFrames?([PersonaVoiceFrame(level: 0.7, speaking: true, seconds: 0.02)])
        XCTAssertEqual(displays.made[0].heard.count, 1)
        XCTAssertTrue(displays.made[1].heard.isEmpty, "Only the framed overlay hears the voice")

        // Choosing another overlay passes the voice to it.
        library.performOverlayAction(.selectInstance(overlays[1]))
        XCTAssertEqual(displays.made.map(\.ring), [false, true])
        XCTAssertEqual(microphones.running.count, 1, "Passing the ring keeps one microphone")
        microphones.running.first?.onFrames?([PersonaVoiceFrame(level: 0.5, speaking: true, seconds: 0.02)])
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
        // Dictate's words for the same refusal, and its door (#134 Fit rule 2).
        XCTAssertEqual(library.notice, "Microphone access is off. Open System Settings › Privacy & Security › Microphone and allow Workbench.")
        XCTAssertEqual(library.voiceRefusal, library.notice, "The refusal shows beside the switch with Microphone Settings…")
        XCTAssertTrue(microphones.made.isEmpty)

        library.setVoiceRing(true)
        XCTAssertFalse(library.voiceRing, "Still refused: it stays off and explains")
        XCTAssertTrue(microphones.requests.isEmpty, "A settled refusal is not asked again")
        XCTAssertEqual(microphones.settingsOpened, 0, "Nothing opens System Settings by itself")
        library.openMicrophoneSettings()
        XCTAssertEqual(microphones.settingsOpened, 1, "Microphone Settings… opens Privacy & Security › Microphone")

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
        XCTAssertTrue(library.voiceRefusal == nil, "Only the microphone refusal gets the System Settings door, never another problem")
    }

    /// The shown card's menu and the pill's Persona Options carry the refusal under the switch
    /// with Microphone Settings…, which opens Privacy & Security › Microphone; another problem
    /// and an allowed microphone leave the switch alone (#134 Fit rule 2, one word set).
    func testRefusedMicrophoneOffersMicrophoneSettingsInTheLiveMenus() throws {
        let defaults = Choice()
        let microphones = Microphones(), displays = Displays()
        let (root, library, _, _) = try fixture(microphones, defaults, displays)
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
        func titles() -> [String] { library.makeControlsMenu().items.map(\.title) }
        func choose(_ title: String) {
            guard let item = library.makeControlsMenu().items.first(where: { $0.title == title }), let action = item.action else { return }
            _ = (item.target as AnyObject?)?.perform(action, with: item)
        }
        guard case .success = library.showOverlay() else { XCTAssertTrue(false, "The persona shows"); return }
        let switchTitle = "React to My Voice · Uses Microphone", door = "Microphone Settings…"
        XCTAssertTrue(titles().contains(switchTitle))
        XCTAssertFalse(titles().contains(door), "An allowed microphone offers no settings door")

        microphones.permission = .denied
        choose(switchTitle)
        XCTAssertFalse(library.voiceRing, "The switch stays off")
        let items = titles()
        guard let at = items.firstIndex(of: switchTitle) else { XCTAssertTrue(false, "The switch stays in the menu: \(items)"); return }
        XCTAssertEqual(Array(items.dropFirst(at + 1).prefix(2)), [library.notice ?? "", door],
                       "The reason and Microphone Settings… sit under the switch: \(items)")
        XCTAssertTrue(library.makeControlsMenu().items.first { $0.title == library.notice }?.isEnabled == false, "The reason is a note")
        choose(door)
        XCTAssertEqual(microphones.settingsOpened, 1, "Microphone Settings… opens Privacy & Security › Microphone")
        XCTAssertFalse(library.voiceRing, "and changes nothing else")

        // The toolbar's picker shows cards, never the refusal; the panel row's notice opens the page.
        XCTAssertFalse(library.makeToolbarPickerMenu().items.contains { $0.title == door })

        microphones.permission = .allowed
        choose(switchTitle)
        XCTAssertTrue(library.voiceRing, "Allowed again, the switch turns on")
        XCTAssertTrue(library.voiceRefusal == nil)
        XCTAssertFalse(titles().contains(door), "The door goes with the refusal")
        XCTAssertEqual(microphones.settingsOpened, 1)
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
        XCTAssertGreaterThan(insets.left, geometry.gap + geometry.barWidth + geometry.barReach, "The ring's tallest bar has room beyond a full-bleed card")
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

    func testAnalyzerHearsQuietAndLoudMicrophonesAlikeButNotTheRoom() {
        let rate = 48_000.0
        for (speech, noise, name) in [(Float(-24), Float(-58), "built-in"), (-44, -72, "quiet"), (-12, -50, "headset")] {
            var voice = Voice()
            let (samples, voiced) = voice.render(seconds: 6, rate: rate, speech: speech, noise: noise)
            let frames = analyze(samples, rate: rate)
            let chunk = Int(frames[0].seconds * rate)
            var talking: [Float] = [], resting: [PersonaVoiceFrame] = [], speakingInGaps = 0, gaps = 0, silentTalk = 0
            for (index, frame) in frames.enumerated() {
                let span = voiced[(index * chunk)..<min(voiced.count, (index + 1) * chunk)]
                let time = Double(index) * frame.seconds
                if span.allSatisfy({ $0 }) { talking.append(frame.level); if !frame.speaking { silentTalk += 1 } }
                // Well into each breath, after the hold that bridges words.
                if (1.84...1.96).contains(time.truncatingRemainder(dividingBy: 2)) { resting.append(frame) }
                if !span.contains(true), time.truncatingRemainder(dividingBy: 2) < 1.5, time > 0.3 { gaps += 1; if frame.speaking { speakingInGaps += 1 } }
            }
            XCTAssertEqual(silentTalk, 0, "\(name) microphone: every voiced frame is heard, from the first syllable")
            XCTAssertTrue((0.3...0.8).contains(mean(talking)), "\(name) microphone: a usual voice sits near the middle (\(mean(talking)))")
            XCTAssertTrue(resting.allSatisfy { !$0.speaking && $0.level == 0 }, "\(name) microphone: a breath lets it rest")
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
        let analyzer = PersonaVoiceAnalyzer(sampleRate: rate)
        let frames = samples.withUnsafeBufferPointer { analyzer.process($0) }
        XCTAssertTrue(frames.allSatisfy { $0.level == 0 && !$0.speaking }, "Room noise alone never lights the outline")
        XCTAssertEqual(Double(analyzer.noiseFloor), -60, accuracy: 3)

        // A fan switched on: learned within a second or two, and never taken for a voice.
        var room = voice.render(seconds: 3, rate: rate, speech: nil, noise: -66).samples
        room += voice.render(seconds: 9, rate: rate, speech: nil, noise: -46).samples
        let fan = PersonaVoiceAnalyzer(sampleRate: rate)
        var heard: [PersonaVoiceFrame] = [], floors: [Float] = []
        var start = 0
        while start < room.count {
            let end = min(room.count, start + 4_410)
            heard += room[start..<end].withUnsafeBufferPointer { fan.process($0) }
            floors.append(fan.noiseFloor); start = end
        }
        XCTAssertFalse(heard.contains { $0.speaking }, "A fan is not a voice")
        XCTAssertEqual(Double(floors[50]), -46, accuracy: 3)
    }

    /// Pitch is what makes a voice: a voiced tone counts, noise and clicks do not.
    func testAnalyzerRecognisesAVoiceByItsPitch() {
        let rate = 48_000.0
        func pitch(_ samples: [Float]) -> Float {
            let analyzer = PersonaVoiceAnalyzer(sampleRate: rate)
            _ = samples.withUnsafeBufferPointer { analyzer.process($0) }
            return analyzer.periodicity
        }
        var voice = Voice()
        let spoken = voice.render(seconds: 0.2, rate: rate, speech: -24, noise: -70, syllables: false).samples
        let hiss = voice.render(seconds: 0.2, rate: rate, speech: nil, noise: -30).samples
        let high = (0..<Int(0.2 * rate)).map { Float(sin(2 * .pi * 230 * Double($0) / rate)) * 0.1 }
        XCTAssertGreaterThan(pitch(spoken), 0.9, "A man's voiced vowel repeats clearly")
        XCTAssertGreaterThan(pitch(high), 0.9, "So does a higher voice")
        XCTAssertTrue(pitch(hiss) < 0.5, "Hiss does not repeat")
        var click = voice.render(seconds: 0.2, rate: rate, speech: nil, noise: -70).samples
        for index in 0..<200 { click[8_600 + index] += Float(exp(-Double(index) / 40)) * 0.5 }
        XCTAssertTrue(pitch(click) < 0.5, "A click is not a voice")
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
        guard case .circle(let center, let radius) = PersonaArtworkOutline.analyze(bitmap(Self.badge())) else {
            XCTAssertTrue(false, "A round badge gets a circle"); return
        }
        XCTAssertEqual(Double(center.x), 0.5, accuracy: 0.02)
        XCTAssertEqual(Double(center.y), 150.0 / 280, accuracy: 0.02)
        XCTAssertEqual(Double(radius), 100.0 / 280, accuracy: 0.02)

        let card = try PersonaCardRenderer.image(portrait: Self.badge(), style: PersonaCardStyle(label: "Care lead"))
        guard case .roundedRect(let box, let corner) = PersonaArtworkOutline.analyze(bitmap(card)) else {
            XCTAssertTrue(false, "A card gets its rounded rectangle"); return
        }
        XCTAssertEqual(Double(box.width), 1, accuracy: 0.02)
        XCTAssertEqual(Double(box.height), 1.25, accuracy: 0.02)
        XCTAssertEqual(Double(corner), 28.0 / 480, accuracy: 0.025)

        let photo = NSImage(size: CGSize(width: 400, height: 300), flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)!.draw(in: rect, angle: 30); return true
        }
        XCTAssertEqual(PersonaArtworkOutline.analyze(bitmap(photo)), .roundedRect(CGRect(x: 0, y: 0, width: 1, height: 0.75), radius: 0))

        // A cut-out head and shoulders is not a badge: its small head must not win.
        let cutout = NSImage(size: CGSize(width: 300, height: 360), flipped: false) { _ in
            NSColor(srgbRed: 0.3, green: 0.3, blue: 0.5, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 105, y: 210, width: 90, height: 110)).fill()
            NSBezierPath(roundedRect: CGRect(x: 20, y: 0, width: 260, height: 190), xRadius: 90, yRadius: 90).fill()
            return true
        }
        guard case .roundedRect = PersonaArtworkOutline.analyze(bitmap(cutout)) else {
            XCTAssertTrue(false, "A cut-out gets the rounded box of its visible pixels"); return
        }
    }

    /// One voice colour: Workbench's accent as the appearance shows it, whatever
    /// the artwork's colours, with a rim of the accent as the opposite appearance
    /// shows it, so the line reads on light and dark content.
    /// The ring is the colour the presenter chose, mint to begin with,
    /// whatever the artwork, and the choice is remembered and reaches every
    /// overlay without touching the microphone.
    func testRingIsTheChosenColourWhateverTheArtwork() throws {
        func rgb(_ color: CGColor) -> [Double] {
            (color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? []).prefix(3).map { (Double($0) * 1000).rounded() / 1000 }
        }
        let mint = VoiceStyle.overlayColors(chosen: InkColor.mint.nsColor.cgColor)
        XCTAssertEqual(rgb(mint.line), [0.24, 0.89, 0.66], "Mint draws as mint")
        XCTAssertTrue(rgb(mint.rim).max()! < 0.3, "A light colour gets a dark rim of its own hue (\(rgb(mint.rim)))")
        let black = VoiceStyle.overlayColors(chosen: InkColor.black.nsColor.cgColor)
        XCTAssertTrue(rgb(black.rim).min()! > 0.75, "A dark colour gets a light rim (\(rgb(black.rim)))")
        // The artwork's own colours never choose the ring's.
        let controller = PersonaOverlayController(pointer: PersonaTestPointer())
        defer { controller.shutdown() }
        controller.setVoiceRing(true)
        func ring() -> PersonaVoiceRingLayer? { controller.window?.contentView?.layer?.sublayers?.compactMap({ $0 as? PersonaVoiceRingLayer }).first }
        for artwork in [Self.badge(), NSImage(size: CGSize(width: 120, height: 120), flipped: false) { rect in NSColor.systemPurple.setFill(); rect.fill(); return true }] {
            _ = controller.show(image: artwork, name: "Synthetic persona", state: PersonaOverlayState(x: 0.5, y: 0.5, width: 0.1))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            guard let ring = ring() else { XCTAssertTrue(false, "The ring layer is there"); return }
            XCTAssertEqual(rgb(ring.colors.line), rgb(mint.line), "Every persona's ring starts mint")
        }
        controller.setVoiceColor(.coral)
        XCTAssertEqual(ring().map { rgb($0.colors.line) } ?? [], [1, 0.29, 0.31], "A chosen colour reaches the shown ring at once")

        // The library remembers the choice and hands it to every overlay of a set.
        let defaults = Choice(), microphones = Microphones(), displays = Displays()
        let (root, library, group, _) = try fixture(microphones, defaults, displays)
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(library.voiceColor, .mint)
        library.setVoiceColor(.violet)
        XCTAssertEqual(defaults.color, .violet, "The choice is remembered")
        XCTAssertTrue(microphones.made.isEmpty, "Choosing a colour never opens the microphone")
        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
        XCTAssertTrue(!displays.made.isEmpty && displays.made.allSatisfy { $0.color == .violet }, "Every overlay in a set gets the chosen colour")
        library.setVoiceColor(.blue)
        XCTAssertTrue(displays.made.allSatisfy { $0.color == .blue }, "A new choice reaches a running set")
        let again = PersonaLibrary(root: root, sessionPanelFactory: { Display() }, sessionHUDEnabled: false, voice: access(microphones, defaults))
        defer { again.shutdown() }
        XCTAssertEqual(again.voiceColor, .blue, "The next launch starts with it")
    }

    func testRingGeometryHugsTheArtworkAndScalesWithIt() {
        let small = PersonaVoiceRingGeometry(outline: .circle(center: CGPoint(x: 0.5, y: 0.5), radius: 0.5), artwork: CGRect(x: 0, y: 0, width: 120, height: 120))
        let large = PersonaVoiceRingGeometry(outline: .circle(center: CGPoint(x: 0.5, y: 0.5), radius: 0.5), artwork: CGRect(x: 0, y: 0, width: 480, height: 480))
        XCTAssertTrue(large.barWidth > small.barWidth && large.barReach > small.barReach, "A larger persona gets bolder dots and taller bars")
        XCTAssertTrue([small, large].allSatisfy { (2...3.5).contains($0.barWidth) && $0.barReach <= 34 }, "Dots stay fine and bars bounded at any size")
        for geometry in [small, large] {
            // The dots share the edge exactly: no seam where the ring closes.
            let around = geometry.outline.perimeter(outset: geometry.foot).length
            XCTAssertEqual(Double(geometry.barPitch * CGFloat(geometry.barCount)), Double(around), accuracy: 0.001)
            XCTAssertTrue(geometry.barPitch >= geometry.barWidth * 2, "Dots stand clear of each other (\(geometry.barPitch))")
        }
        // At rest the dots keep a clear gap from the artwork, and nothing reaches toward it.
        let resting = small.ring(nil).copy(strokingWithWidth: small.barWidth, lineCap: .round, lineJoin: .round, miterLimit: 10).boundingBoxOfPath
        XCTAssertEqual(Double(resting.width / 2), Double(60 + small.gap + small.barWidth), accuracy: 0.1)
        // The loudest voice: every bar at its full reach still fits the room the window makes.
        var loudest = VoiceSpectrum()
        loudest.receive([[Double](repeating: 1, count: loudest.count)], spacing: 0, at: 0)
        for step in 1...12 { loudest.advance(to: Double(step) / 60) }
        let tallest = small.ring(loudest).copy(strokingWithWidth: small.barWidth + 2 * PersonaVoiceRingGeometry.rimWidth(increaseContrast: true),
                                               lineCap: .round, lineJoin: .round, miterLimit: 10).boundingBoxOfPath
        let room = CGRect(x: -small.outsets.left, y: -small.outsets.bottom, width: 120 + small.outsets.left + small.outsets.right, height: 120 + small.outsets.top + small.outsets.bottom)
        XCTAssertTrue(room.contains(tallest), "Nothing is clipped at the loudest (\(tallest) in \(room))")
        XCTAssertGreaterThan(Double(tallest.width), Double(resting.width + small.barReach), "Bars reach outward")
        let inner = (0..<small.barCount).map { bar in small.outline.perimeter(outset: small.foot).point(at: 0.5 + (CGFloat(bar) + 0.5) / CGFloat(small.barCount)).point }
        XCTAssertTrue(inner.allSatisfy { hypot($0.x - 60, $0.y - 60) >= 60 + small.gap }, "Every bar starts outside the gap")
        XCTAssertEqual(Double(small.outsets.left), Double(small.outsets.right), accuracy: 1)
        XCTAssertEqual(Double(small.outsets.top), Double(small.outsets.bottom), accuracy: 1)
        // The voice's range wanders around the ring and closes on itself, with no seam and no gaps.
        XCTAssertEqual(PersonaVoiceRingGeometry.range(at: 0), PersonaVoiceRingGeometry.range(at: 1), accuracy: 0.000001)
        let places = (0...720).map { PersonaVoiceRingGeometry.range(at: Double($0) / 720) }
        XCTAssertTrue(places.min()! < 0.08 && places.max()! > 0.92, "The whole range is shown (\(places.min()!)...\(places.max()!))")
        XCTAssertTrue(zip(places, places.dropFirst()).allSatisfy { abs($0 - $1) < 0.04 }, "Neighbouring bars show neighbouring sounds")
        // A badge circle inside its picture needs less room than a full-bleed card.
        let badge = PersonaVoiceRingGeometry(outline: .circle(center: CGPoint(x: 0.5, y: 0.536), radius: 0.357), artwork: CGRect(x: 0, y: 0, width: 240, height: 240))
        let card = PersonaVoiceRingGeometry(outline: .roundedRect(CGRect(x: 0, y: 0, width: 1, height: 1), radius: 0.06), artwork: CGRect(x: 0, y: 0, width: 240, height: 240))
        XCTAssertGreaterThan(card.outsets.left, badge.outsets.left)
        // A rounded rectangle's edge is walked once around, outward all the way.
        let edge = PersonaArtworkOutline.roundedRect(CGRect(x: 0, y: 0, width: 100, height: 60), radius: 20).perimeter(outset: 4)
        // Grown by 4 the corners round by 24: two 60-point and two 20-point sides between them.
        XCTAssertEqual(Double(edge.length), Double(2 * 60 + 2 * 20 + 2 * CGFloat.pi * 24), accuracy: 0.001)
        var corners: [CGFloat] = []
        for step in 0..<200 {
            let (point, outward, corner) = edge.point(at: CGFloat(step) / 200)
            corners.append(corner)
            XCTAssertTrue(CGRect(x: -4.001, y: -4.001, width: 108.002, height: 68.002).contains(point), "On the grown edge (\(point))")
            XCTAssertEqual(Double(hypot(outward.dx, outward.dy)), 1, accuracy: 0.0001)
            XCTAssertTrue((point.x - 50) * outward.dx + (point.y - 30) * outward.dy > 0, "Outward points away from the artwork")
        }
        XCTAssertTrue(corners.allSatisfy { (0...1).contains($0) } && corners.max()! > 0.95 && corners.filter { $0 == 0 }.count > 80, "Corners are known, so bars can stand shorter where they fan apart")
        XCTAssertEqual(small.outline.perimeter(outset: 0).point(at: 0.3).corner, 0, "A circle has no corners")
        // The outline value the handles share: containment and bounds.
        let circle = PersonaArtworkOutline.circle(center: CGPoint(x: 0.5, y: 0.5), radius: 0.4).placed(in: CGRect(x: 10, y: 20, width: 100, height: 100))
        XCTAssertEqual(circle.bounds, CGRect(x: 20, y: 30, width: 80, height: 80))
        XCTAssertTrue(circle.contains(CGPoint(x: 60, y: 70)))
        XCTAssertFalse(circle.contains(CGPoint(x: 22, y: 32)), "A circle's corners are not artwork")
        let rounded = PersonaArtworkOutline.roundedRect(CGRect(x: 0, y: 0, width: 100, height: 60), radius: 20)
        XCTAssertTrue(rounded.contains(CGPoint(x: 50, y: 30)) && rounded.contains(CGPoint(x: 20, y: 20)))
        XCTAssertFalse(rounded.contains(CGPoint(x: 2, y: 2)), "A rounded corner's outside is not artwork")
    }

    func testRingSleepsInSilenceAndRisesOnTheFirstSyllable() {
        let ring = PersonaVoiceRingLayer()
        // Both default to the Mac's own accessibility settings; CI's runner may have Reduce Motion on.
        ring.increaseContrast = false; ring.reduceMotion = false
        ring.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        ring.geometry = PersonaVoiceRingGeometry(outline: .circle(center: CGPoint(x: 0.5, y: 0.5), radius: 0.5), artwork: CGRect(x: 50, y: 50, width: 200, height: 200))
        let paths = { ring.sublayers?.compactMap { $0 as? CAShapeLayer } ?? [] }
        let bars = { paths().last! }
        let resting = (opacity: bars().opacity, box: bars().path?.boundingBoxOfPath ?? .zero)
        XCTAssertEqual(paths().filter { $0.path != nil }.count, 2, "At rest a ring of dots and its rim show it is listening")
        XCTAssertTrue(ring.heights.allSatisfy { $0 == 0 }, "At rest every bar is a dot")
        let quiet = PersonaVoiceFrame.quiet.lasting(0.021)
        var changes: [VoiceEnvelope.Visible] = []
        ring.onVisibleChange = { state, _ in changes.append(state) }
        var clock = 100.0
        for _ in 0..<40 { ring.receive([quiet, quiet, quiet, quiet, quiet], at: clock); clock += 0.1; ring.advance(to: clock) }
        XCTAssertFalse(ring.isMoving, "Silence never wakes the display link")
        XCTAssertEqual(bars().opacity, resting.opacity); XCTAssertEqual(bars().path?.boundingBoxOfPath, resting.box)
        // A voice: a vowel's spectrum at a usual level, as the analyser hands it over.
        func voice(_ level: Float, _ energy: Float) -> PersonaVoiceFrame {
            // A vowel has no sound in the upper part of the voice's range.
            PersonaVoiceFrame(level: level, speaking: true, seconds: 0.021, energy: energy,
                              bands: VoiceSpectrum.vowel(Double(energy)).enumerated().map { $0.offset < VoiceSpectrum.usualCount * 3 / 5 ? Float($0.element) : 0 })
        }
        ring.receive([quiet, voice(0.5, 0.8)], at: clock)
        XCTAssertTrue(ring.isMoving)
        ring.advance(to: clock + 1.0 / 60)
        XCTAssertEqual(changes, [.normal], "The first syllable lights the ring by the next display frame")
        // A microphone delivers about ten times a second.
        func speak(_ frame: PersonaVoiceFrame, steps: ClosedRange<Int>) {
            for step in steps {
                if step % 6 == 0 { ring.receive([frame], at: clock + Double(step) / 60) }
                ring.advance(to: clock + Double(step) / 60)
            }
        }
        speak(voice(0.5, 0.8), steps: 2...30)
        let usual = ring.heights
        XCTAssertTrue(bars().opacity > resting.opacity + 0.3, "Brighter while a voice is heard")
        XCTAssertTrue((usual.max() ?? 0) > ring.geometry!.barReach * 0.4, "The voice's strongest sounds stand tall (\(usual.max() ?? 0))")
        XCTAssertTrue(usual.filter { $0 < 1 }.count > usual.count / 8, "Where the voice has no sound the ring stays dots (\(usual.filter { $0 < 1 }.count) of \(usual.count))")
        XCTAssertTrue(Set(usual.map { ($0 * 2).rounded() }).count > 6, "Bars differ: never one line repeated")
        XCTAssertTrue((bars().path?.boundingBoxOfPath.width ?? 0) > resting.box.width + 8, "Bars reach outward from the dots")
        // In place: the same bars stand for the same sound a moment later.
        speak(voice(0.5, 0.8), steps: 31...60)
        XCTAssertTrue(zip(usual, ring.heights).allSatisfy { abs($0 - $1) < 0.5 }, "A steady sound holds its bars where they are")
        speak(voice(1, 1), steps: 61...120)
        XCTAssertEqual(ring.visible, .loud)
        XCTAssertTrue((ring.heights.max() ?? 0) > (usual.max() ?? 0), "A raised voice stands taller")
        ring.receive([PersonaVoiceFrame(level: 0, speaking: false, seconds: 0.021)], at: clock + 2)
        for step in 121...200 { ring.advance(to: clock + Double(step) / 60) }
        XCTAssertFalse(ring.isMoving, "Without a voice it settles and sleeps")
        XCTAssertTrue(ring.heights.allSatisfy { $0 == 0 }); XCTAssertEqual(bars().opacity, resting.opacity)
        XCTAssertEqual(bars().path?.boundingBoxOfPath, resting.box, "Back to the ring of dots")
        XCTAssertEqual(changes, [.normal, .loud, .normal, .quiet], "A raised voice fades back through the usual look to rest")
        // Reduce Motion: the dots hold still and only brightness says a voice is heard.
        ring.reduceMotion = true
        for step in 0...30 {
            if step % 6 == 0 { ring.receive([voice(1, 1)], at: clock + 4 + Double(step) / 60) }
            ring.advance(to: clock + 4 + Double(step + 1) / 60)
        }
        XCTAssertEqual(ring.visible, .loud)
        XCTAssertEqual(bars().path?.boundingBoxOfPath, resting.box, "Reduce Motion keeps the dots still")
        XCTAssertTrue(bars().opacity > resting.opacity + 0.4, "A voice brightens them")
        XCTAssertEqual(paths().filter { $0.path != nil }.count, 2)
        ring.reset()
        XCTAssertEqual(ring.visible, .quiet); XCTAssertFalse(ring.isMoving)
        // Reduce Motion keeps dots and rim equally lit across soft and raised speech.
        for step in 0...40 {
            ring.receive([voice(0.1, 0.3)], at: clock + 6 + Double(step) / 60)
            ring.advance(to: clock + 6 + Double(step + 1) / 60)
        }
        let softRim = paths()[0].opacity
        XCTAssertTrue(abs(Double(softRim) - 0.7) < 0.001, "The whole ring shows voice presence with Reduce Motion")
        for step in 0...40 {
            ring.receive([voice(1, 1)], at: clock + 7 + Double(step) / 60)
            ring.advance(to: clock + 7 + Double(step + 1) / 60)
        }
        XCTAssertEqual(paths()[0].opacity, softRim, "Syllable volume does not animate the reduced-motion rim")
        ring.reset()
        // Increase Contrast strengthens the resting dots and their rim.
        let plainEdge = paths()[0].lineWidth
        ring.increaseContrast = true
        XCTAssertTrue(bars().opacity > resting.opacity && paths()[0].lineWidth > plainEdge)
    }

    /// Set WORKBENCH_LAYOUT_EVIDENCE to write synthetic renders of the outline:
    /// quiet, usual and raised voice, small and large, round and rectangular,
    /// over a light slide and a dark editor, and with Increase Contrast.
    func testOffscreenVoiceRingRenders() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let card = try PersonaCardRenderer.image(portrait: Self.badge(), style: PersonaCardStyle(label: "Care lead"))
        let photo = NSImage(size: CGSize(width: 400, height: 300), flipped: false) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.2, green: 0.45, blue: 0.7, alpha: 1), ending: NSColor(srgbRed: 0.95, green: 0.9, blue: 0.8, alpha: 1))!.draw(in: rect, angle: 60); return true
        }
        let states: [(String, Float?)] = [("quiet", nil), ("usual", 0.5), ("raised", 1)]
        for (name, artwork) in [("badge", Self.badge()), ("card", card), ("photo", photo)] {
            for (sizeName, width) in [("small", CGFloat(120)), ("large", 360)] {
                for contrast in [false, true] where !contrast || sizeName == "large" {
                    var sheet: [CGImage] = []
                    for (label, level) in states {
                        let stage = try Stage(artwork, width: width, increaseContrast: contrast)
                        stage.speak(level)
                        let image = try stage.snapshot()
                        sheet.append(image)
                        try png(image, to: directory.appendingPathComponent("voice-outline-\(name)-\(sizeName)\(contrast ? "-contrast" : "")-\(label).png"))
                    }
                    try png(Self.sideBySide(sheet), to: directory.appendingPathComponent("sheet-\(name)-\(sizeName)\(contrast ? "-contrast" : "").png"))
                }
            }
            try animate(artwork, to: directory.appendingPathComponent("voice-outline-\(name)-speech.gif"))
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
    static func sideBySide(_ images: [CGImage]) throws -> CGImage {
        let width = images.reduce(0) { $0 + $1.width }, height = images.map(\.height).max() ?? 1
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PersonaError.unreadableImage }
        var x = 0
        for image in images { context.draw(image, in: CGRect(x: x, y: 0, width: image.width, height: image.height)); x += image.width }
        guard let result = context.makeImage() else { throw PersonaError.unreadableImage }
        return result
    }
    /// Synthetic artwork and its outline over half a light slide, half a dark editor.
    private final class Stage {
        let ring = PersonaVoiceRingLayer()
        let image: CGImage
        let canvas: CGSize
        let artworkRect: CGRect
        private var clock = 50.0
        init(_ artwork: NSImage, width: CGFloat = 240, increaseContrast: Bool = false) throws {
            guard let image = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PersonaError.unreadableImage }
            self.image = image
            let outline = PersonaArtworkOutline.analyze(image)
            let size = CGSize(width: width, height: width * artwork.size.height / artwork.size.width)
            let insets = PersonaVoiceRingGeometry(outline: outline, artwork: CGRect(origin: .zero, size: size)).outsets
            canvas = CGSize(width: size.width + insets.left + insets.right + 40, height: size.height + insets.top + insets.bottom + 40)
            artworkRect = CGRect(x: insets.left + 20, y: insets.bottom + 20, width: size.width, height: size.height)
            ring.increaseContrast = increaseContrast; ring.reduceMotion = false
            ring.frame = CGRect(origin: .zero, size: canvas); ring.contentsScale = 2
            ring.colors = VoiceStyle.overlayColors(chosen: PersonaVoiceRingLayer.usualColor.nsColor.cgColor)
            ring.geometry = PersonaVoiceRingGeometry(outline: outline, artwork: artworkRect)
            ring.layoutIfNeeded()
        }
        /// Settles the outline on a voice at `level`, or rest for nil.
        func speak(_ level: Float?) {
            guard let level else { return }
            for _ in 0..<30 {
                ring.receive([PersonaVoiceFrame(level: level, speaking: true, seconds: 0.021)], at: clock)
                clock += 1.0 / 60; ring.advance(to: clock)
            }
        }
        func deliver(_ frames: [PersonaVoiceFrame], then seconds: Double) {
            if !frames.isEmpty { ring.receive(frames, at: clock) }
            let end = clock + seconds
            while clock + 1.0 / 60 <= end { clock += 1.0 / 60; ring.advance(to: clock) }
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
        print("Offscreen voice outline: " + url.path)
    }
    /// Synthetic speech through the real analyzer, delivered as macOS does
    /// (100 ms at a time) and sampled at 20 frames a second, about what a
    /// meeting app sends of a shared screen.
    private func animate(_ artwork: NSImage, to url: URL) throws {
        let rate = 48_000.0
        var voice = Voice()
        let samples = voice.render(seconds: 4, rate: rate, speech: -24, noise: -58).samples
        let analyzer = PersonaVoiceAnalyzer(sampleRate: rate)
        let stage = try Stage(artwork)
        let count = 80
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw PersonaError.unreadableImage }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var delivered = 0
        for index in 0..<count {
            let due = min(samples.count, Int(Double(index + 1) / 20 * rate) / 4_800 * 4_800)
            var frames: [PersonaVoiceFrame] = []
            if due > delivered { frames = samples[delivered..<due].withUnsafeBufferPointer { analyzer.process($0) }; delivered = due }
            stage.deliver(frames, then: 1.0 / 20)
            CGImageDestinationAddImage(gif, try stage.snapshot(scale: 1), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 20]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { throw PersonaError.unreadableImage }
        print("Offscreen voice outline: " + url.path)
    }
}
