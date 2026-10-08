import AppKit
import SwiftUI

final class PersonaWorkspaceTests {
    private final class Display: PersonaSessionDisplaying {
        func setVoiceRing(_ on: Bool) {}
        func setVoiceColor(_ color: InkColor) {}
        func showVoice(_ frames: [PersonaVoiceFrame]) {}
        var onPlacementChange: ((PersonaOverlayState) -> Void)?
        var onSelection: (() -> Void)?
        var frame: CGRect? = CGRect(x: 0, y: 0, width: 80, height: 120)
        var visible = false
        func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState {
            visible = true; return state
        }
        func configure(image: NSImage, name: String, state: PersonaOverlayState) {}
        func hide() { visible = false }
        func shutdown() { visible = false }
    }
    private func fixture() throws -> (URL, PersonaLibrary, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaWorkspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try picture(in: root)
        let library = PersonaLibrary(root: root, sessionPanelFactory: { Display() }, sessionHUDEnabled: false)
        let persona = try library.addImage(source, name: "Sample account manager")
        let group = try library.createGroup(name: "Sample group", members: [persona.id])
        try library.saveGroupLayout(group, overlays: [PersonaOverlayItem(personaID: persona.id), PersonaOverlayItem(personaID: persona.id)], publicLabel: "Sample set")
        return (root, library, group)
    }
    private func picture(in root: URL) throws -> URL {
        let image = NSImage(size: CGSize(width: 160, height: 90), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        let source = root.appendingPathComponent("sample.png")
        try SceneRenderer.png(DemoScene(background: "sample.png"), image: image, size: image.size).write(to: source)
        return source
    }
    func testWorkspaceStartsWithoutDismissalAndPreservesPausedArrangement() throws {
        let (root, library, group) = try fixture()
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("persona-library.json")
        let before = try Data(contentsOf: manifest)
        var launches = 0
        library.onShow = { launches += 1 }
        var launch = PersonaLibraryLaunchState()
        let result = launch.request(.prepared(groupIDs: [group], softReveal: false), from: .workspace, in: library)
        XCTAssertNotNil(result); try result?.get()
        XCTAssertEqual(library.sessionState.phase, .active)
        XCTAssertTrue(library.toolbarCycle?.isSet == true, "a prepared set uses set switching, never single-card cycling")
        XCTAssertFalse(library.toolbarCycle?.canAdvance ?? true, "one prepared set has no Next set")
        XCTAssertTrue(launch.pending == nil)
        XCTAssertEqual(launches, 1)
        let ids = library.sessionState.instances.map(\.id)
        library.performOverlayAction(.visible(ids[0], false))
        library.performOverlayAction(.position(ids[1], 0.2, 0.8))
        library.performOverlayAction(.locked(ids[1], true))
        let arranged = library.sessionState.instances.map(\.placement)
        try library.togglePersonaVisibility().get()
        XCTAssertEqual(library.sessionState.phase, .paused)
        XCTAssertTrue(library.toolbarCycle == nil, "a hidden set resumes before switching")
        try library.togglePersonaVisibility().get()
        XCTAssertEqual(library.sessionState.phase, .active)
        XCTAssertEqual(library.sessionState.instances.map(\.placement), arranged)
        library.pauseOverlaySession()
        let resumed = launch.request(.resume, from: .workspace, in: library)
        XCTAssertNotNil(resumed); try resumed?.get()
        XCTAssertEqual(library.sessionState.phase, .active)
        XCTAssertEqual(library.sessionState.instances.map(\.id), ids)
        XCTAssertEqual(library.sessionState.instances.map(\.placement), arranged)
        XCTAssertFalse(library.sessionState.instances[0].visible)
        XCTAssertTrue(library.sessionState.instances[1].visible)
        XCTAssertTrue(launch.dismissed(in: library) == nil, "Leaving the workspace cannot replay Start or Resume")
        XCTAssertEqual(launches, 1)
        library.hideOverlay()
        XCTAssertEqual(library.sessionState.phase, .idle)
        XCTAssertTrue(library.sessionState.instances.isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifest), before, "Temporary geometry, hide, resume and End retain the saved library")
    }
    func testWorkspaceSingleCardShowsAndStopsWithoutDismissal() throws {
        let (root, library, _) = try fixture()
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
        library.usesSharedControls = true
        let manifest = root.appendingPathComponent("persona-library.json")
        let before = try Data(contentsOf: manifest)
        var launches = 0
        library.onShow = { launches += 1 }
        var launch = PersonaLibraryLaunchState()
        let result = launch.request(.oneCard, from: .workspace, in: library)
        XCTAssertNotNil(result); try result?.get()
        XCTAssertTrue(library.overlayVisible)
        XCTAssertEqual(library.sessionState.phase, .idle)
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(launch.pending == nil)
        try library.togglePersonaVisibility().get()
        XCTAssertFalse(library.overlayVisible)
        XCTAssertTrue(launch.dismissed(in: library) == nil)
        XCTAssertEqual(launches, 1, "Closing the workspace must not show a card that was hidden")
        try library.togglePersonaVisibility().get()
        XCTAssertTrue(library.overlayVisible)
        XCTAssertEqual(launches, 2)
        library.hideOverlay()
        XCTAssertFalse(library.overlayVisible)
        XCTAssertEqual(try Data(contentsOf: manifest), before)
    }
    func testSheetLaunchWaitsForDismissalAndIsConsumedOnce() throws {
        let (root, library, group) = try fixture()
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
        var launches = 0
        library.onShow = { launches += 1 }
        var launch = PersonaLibraryLaunchState()
        XCTAssertTrue(launch.request(.prepared(groupIDs: [group], softReveal: false), from: .sheet, in: library) == nil)
        XCTAssertEqual(library.sessionState.phase, .idle)
        XCTAssertNotNil(launch.pending)
        try launch.dismissed(in: library)?.get()
        XCTAssertEqual(library.sessionState.phase, .active)
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(launch.pending == nil)
        XCTAssertTrue(launch.dismissed(in: library) == nil)
        XCTAssertEqual(launches, 1)
        library.pauseOverlaySession()
        XCTAssertTrue(launch.request(.resume, from: .sheet, in: library) == nil)
        XCTAssertEqual(library.sessionState.phase, .paused)
        try launch.dismissed(in: library)?.get()
        XCTAssertEqual(library.sessionState.phase, .active)
    }
    func testWorkspaceFailureIsImmediateAndDoesNotReplaceSession() throws {
        let (root, library, group) = try fixture()
        defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
        let ids = library.sessionState.instances.map(\.id)
        library.pauseOverlaySession()
        library.mayBeginInteraction = { false }
        XCTAssertThrowsError(try library.togglePersonaVisibility().get())
        XCTAssertEqual(library.sessionState.phase, .paused, "A denied quick resume retains the prepared session")
        library.mayBeginInteraction = { true }
        try library.resumeOverlaySession()
        library.mayBeginInteraction = { false }
        var launch = PersonaLibraryLaunchState()
        for request in [PersonaLibraryLaunchState.Request.oneCard, .prepared(groupIDs: [group], softReveal: false), .resume] {
            let result = launch.request(request, from: .workspace, in: library)
            guard case .failure = result else { XCTAssertTrue(false, "A busy owner must return an immediate failure"); continue }
            XCTAssertTrue(launch.pending == nil)
            XCTAssertEqual(library.sessionState.instances.map(\.id), ids)
            XCTAssertEqual(library.sessionState.phase, .active)
        }
    }
    func testPresentPreviewReservesControlsAndFitsNarrowEditors() {
        for width: CGFloat in [320, 440, 620, 850] {
            for height: CGFloat in [400, 530, 730, 900] {
                for aspect: CGFloat in [0.75, 16 / 9, 2.4] {
                    let size = DemoScenesLayout.previewSize(in: CGSize(width: width, height: height), aspect: aspect)
                    XCTAssertTrue(size.width > 0 && size.height > 0)
                    XCTAssertTrue(size.width <= width - DemoScenesLayout.padding * 2 + 0.001)
                    XCTAssertTrue(size.height <= height * 0.5 + 0.001, "The canvas must leave room for fixed actions and everyday controls")
                    XCTAssertEqual(size.width / size.height, aspect, accuracy: 0.001)
                }
            }
        }
        XCTAssertTrue(DemoScenesLayout.sidebarWidth(in: 834) < DemoScenesLayout.sidebarWidth(in: 1085))
        let fallback = DemoScenesLayout.previewSize(in: CGSize(width: 620, height: 730), aspect: .nan)
        XCTAssertTrue(fallback.width.isFinite && fallback.height.isFinite)
    }

    /// Optional offscreen evidence. No app is installed, activated or shown.
    func testOffscreenWorkspaceLayouts() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] else { return }
        try MainActor.assumeIsolated {
            let (root, library, group) = try fixture()
            defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let scenes = DemoScenes(root: root.appendingPathComponent("Scenes"), systemIntegrationEnabled: false)
            defer { scenes.shutdown() }
            scenes.usesSharedControls = true
            try scenes.addImage(root.appendingPathComponent("sample.png"), name: "Sample customer with a deliberately long presentation and device name")
            let persona = try scenes.personas.addImage(root.appendingPathComponent("sample.png"), name: "Sample persona")
            scenes.usePersona(persona, in: scenes.selectedID!)
            for (name, size) in [("present-small", CGSize(width: 834, height: 730)), ("present-normal", CGSize(width: 1085, height: 780)), ("present-narrow", CGSize(width: 620, height: 650))] {
                try render(DemoScenesView(model: scenes), size: size, to: directory.appendingPathComponent(name + ".png"))
            }
            // The phone's status inside the frame and under the preview, from pinned signals; no capture runs offscreen.
            var onUSB = PhoneLinkSignals(); onUSB.usb = [.init(name: "iPhone", kind: .iPhone, productID: 0x12A8)]
            var restricted = PhoneLinkSignals(); restricted.access = .restricted
            var twoScreens = PhoneLinkSignals()
            // Two phone screens: a camera beside one phone is no longer a choice (#285, 7 October 2026).
            twoScreens.sources = [.init(id: "a", name: "Sample iPhone", isScreen: true), .init(id: "b", name: "Sample iPad", isScreen: true)]
            for (name, signals) in [("present-phone-none", PhoneLinkSignals()), ("present-phone-on-usb", onUSB), ("present-phone-restricted", restricted), ("present-phone-choose", twoScreens)] {
                scenes.phoneLink.fixture = signals
                try render(DemoScenesView(model: scenes), size: CGSize(width: 1085, height: 780), to: directory.appendingPathComponent(name + ".png"))
            }
            // The stage itself, windowed size, with the status inside the device frame.
            guard let stageScene = scenes.selected, let stageImage = scenes.image(for: stageScene) else { throw PersonaError.unreadableImage }
            for (name, signals) in [("stage-phone-none", PhoneLinkSignals()), ("stage-phone-choose", twoScreens)] {
                scenes.phoneLink.fixture = signals
                try render(DemoPresentation.offscreenStage(scene: stageScene, image: stageImage, capture: scenes.capture, phoneLink: scenes.phoneLink, root: root.appendingPathComponent("Scenes")),
                           size: CGSize(width: 1100, height: 720), to: directory.appendingPathComponent(name + ".png"))
            }
            scenes.phoneLink.fixture = nil
            for (name, size) in [("persona-small", CGSize(width: 620, height: 650)), ("persona-normal", CGSize(width: 834, height: 730))] {
                try render(PersonaLibraryView(library: library, mode: .workspace), size: size, to: directory.appendingPathComponent(name + ".png"))
            }
            library.usesSharedControls = true
            try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
            for paused in [false, true] {
                if paused { library.pauseOverlaySession() }
                let name = paused ? "persona-live-set-hidden" : "persona-live-set-active"
                try render(PersonaLibraryView(library: library, mode: .workspace), size: CGSize(width: 620, height: 730),
                    to: directory.appendingPathComponent(name + ".png"))
            }
        }
    }
    @MainActor private func render<V: View>(_ content: V, size: CGSize, to url: URL) throws {
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw PersonaError.unreadableImage }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PersonaError.unreadableImage }
        try data.write(to: url)
        XCTAssertEqual(hosting.bounds.size, size)
        print("Offscreen layout: " + url.path)
    }
}
