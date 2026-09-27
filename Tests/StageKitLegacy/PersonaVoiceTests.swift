import AppKit

/// The voice ring owns a live microphone, so these checks pin when it may run:
/// only while turned on and a persona is showing, and never after hide, End,
/// Quit or a denied permission. A fake source stands in for the microphone.
final class PersonaVoiceTests {
    private final class Source: PersonaVoiceSource {
        var onLevel: ((CGFloat) -> Void)?
        var onUnavailable: ((String) -> Void)?
        var failure: Error?
        private(set) var running = false
        func start() throws { if let failure { throw failure }; running = true }
        func stop() { running = false }
    }
    private final class Sources { var made: [Source] = []; var failure: Error? }
    private final class Display: PersonaSessionDisplaying {
        var onPlacementChange: ((PersonaOverlayState) -> Void)?
        var onSelection: (() -> Void)?
        var frame: CGRect? = CGRect(x: 0, y: 0, width: 80, height: 80)
        var level: CGFloat?
        func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState { state }
        func configure(image: NSImage, name: String, state: PersonaOverlayState) {}
        func hide() {}
        func shutdown() {}
        func setVoiceLevel(_ level: CGFloat?) { self.level = level }
    }
    private final class Displays { var made: [Display] = [] }

    private func fixture(defaults: UserDefaults, sources: Sources, displays: Displays) throws -> (URL, PersonaLibrary, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaVoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = NSImage(size: CGSize(width: 120, height: 120), flipped: false) { rect in NSColor.systemPink.setFill(); rect.fill(); return true }
        let picture = root.appendingPathComponent("sample.png")
        try SceneRenderer.png(DemoScene(background: "sample.png"), image: image, size: image.size).write(to: picture)
        let library = PersonaLibrary(root: root, sessionPanelFactory: { let display = Display(); displays.made.append(display); return display },
                                     sessionHUDEnabled: false,
                                     voiceSourceFactory: { let source = Source(); source.failure = sources.failure; sources.made.append(source); return source },
                                     voicePreferences: defaults)
        let persona = try library.addImage(picture, name: "Sample presenter")
        let group = try library.createGroup(name: "Sample group", members: [persona.id])
        try library.saveGroupLayout(group, overlays: [PersonaOverlayItem(personaID: persona.id)], publicLabel: "Sample set")
        return (root, library, group)
    }
    private func temporaryDefaults() -> (UserDefaults, String) {
        let name = "PersonaVoiceTests-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    func testVoiceRingRunsOnlyWhileOnAndAPersonaIsShowing() throws {
        let (defaults, suite) = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = Sources(), displays = Displays()
        let (root, library, group) = try fixture(defaults: defaults, sources: sources, displays: displays)
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }

        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
        XCTAssertFalse(library.voiceRing, "The voice ring starts off")
        XCTAssertTrue(sources.made.isEmpty, "Showing a persona never opens the microphone by itself")

        library.setVoiceRing(true)
        XCTAssertEqual(sources.made.count, 1)
        XCTAssertTrue(sources.made[0].running)
        XCTAssertEqual(displays.made.first?.level, 0, "The quiet ring appears as soon as it is turned on")
        sources.made[0].onLevel?(0.7)
        XCTAssertEqual(displays.made.first?.level, 0.7)

        library.pauseOverlaySession()
        XCTAssertFalse(sources.made[0].running, "Hiding every persona stops the microphone")
        XCTAssertTrue(displays.made.first?.level == nil)
        try library.resumeOverlaySession()
        XCTAssertEqual(sources.made.count, 2)
        XCTAssertTrue(sources.made[1].running, "Showing again resumes the ring that is still turned on")

        library.setVoiceRing(false)
        XCTAssertFalse(sources.made[1].running, "Turning the ring off stops the microphone at once")
        XCTAssertTrue(displays.made.first?.level == nil)
        XCTAssertFalse(defaults.bool(forKey: PersonaLibrary.voiceRingKey))

        library.setVoiceRing(true)
        XCTAssertTrue(sources.made[2].running)
        library.endOverlaySession()
        XCTAssertFalse(sources.made[2].running, "End overlays stops the microphone")
        XCTAssertTrue(library.voiceRing, "Ending the overlays keeps the choice for next time")
        let reopened = PersonaLibrary(root: root, sessionPanelFactory: { Display() }, sessionHUDEnabled: false,
                                      voiceSourceFactory: { Source() }, voicePreferences: defaults)
        XCTAssertTrue(reopened.voiceRing, "The choice is remembered")
        reopened.shutdown()

        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
        XCTAssertTrue(sources.made[3].running)
        library.shutdown()
        XCTAssertFalse(sources.made[3].running, "Quit stops the microphone")
    }

    func testVoiceRingTurnsOffWhenTheMicrophoneIsUnavailable() throws {
        let (defaults, suite) = temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = Sources(), displays = Displays()
        let (root, library, group) = try fixture(defaults: defaults, sources: sources, displays: displays)
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)

        sources.failure = PersonaVoiceError.microphoneDenied
        library.setVoiceRing(true)
        XCTAssertFalse(library.voiceRing, "A denied microphone turns the ring back off")
        XCTAssertTrue(library.notice?.contains("microphone access") == true)
        XCTAssertTrue(displays.made.first?.level == nil)

        sources.failure = nil
        library.setVoiceRing(true)
        XCTAssertTrue(sources.made.last?.running == true)
        sources.made.last?.onUnavailable?("Synthetic device loss.")
        XCTAssertFalse(library.voiceRing)
        XCTAssertFalse(sources.made.last?.running == true, "A lost device leaves no microphone running")
        XCTAssertEqual(library.notice, "Synthetic device loss.")
    }

    func testVoiceRingInsetsArtworkInsteadOfCoveringIt() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let artwork = PersonaVoiceRing.artworkRect(in: bounds)
        XCTAssertEqual(Double(artwork.width / artwork.height), 2, accuracy: 0.001)
        XCTAssertTrue(bounds.contains(artwork) && artwork.width < bounds.width, "The artwork keeps its shape inside the ring")
    }
}
