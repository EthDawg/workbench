import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Selected versus shown (#170). Browsing saved personas or preparation groups
/// never replaces or hides the shown card; Replace shown and Update shown card
/// are explicit and keep its size, place and lock; Hide keeps the card for Show
/// again, with the microphone stopped while it is hidden; and a prepared set's
/// selected copy is identified and changed on its own.
final class PersonaShownTests {
    private final class Microphone: PersonaVoiceSource {
        var onFrames: (([PersonaVoiceFrame]) -> Void)?
        var onUnavailable: ((String) -> Void)?
        var onDevice: ((String?) -> Void)?
        private(set) var running = false
        var deviceName: String? { running ? "Synthetic microphone" : nil }
        func start() throws { running = true }
        func stop() { running = false }
    }
    /// A fake microphone, permission and remembered choice: nothing real is opened or saved.
    private final class Voice {
        var made: [Microphone] = []
        var saved = false
        var running: Bool { made.contains(where: \.running) }
        var access: PersonaVoiceAccess {
            PersonaVoiceAccess(permission: { .allowed }, requestPermission: { $0(true) },
                               makeSource: { let microphone = Microphone(); self.made.append(microphone); return microphone },
                               savedChoice: { self.saved }, saveChoice: { self.saved = $0 })
        }
    }
    private final class Panel: PersonaSessionDisplaying {
        func setVoiceRing(_ on: Bool) {}
        func setVoiceColor(_ color: InkColor) {}
        func showVoice(_ frames: [PersonaVoiceFrame]) {}
        var onPlacementChange: ((PersonaOverlayState) -> Void)?
        var onSelection: (() -> Void)?
        var frame: CGRect? = CGRect(x: 0, y: 0, width: 80, height: 120)
        var image: NSImage?
        func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState { self.image = image; return state }
        func configure(image: NSImage, name: String, state: PersonaOverlayState) { self.image = image }
        func hide() {}
        func shutdown() {}
    }
    private struct Fixture {
        let root: URL
        let library: PersonaLibrary
        let voice: Voice
        let a: SavedPersona, b: SavedPersona, c: SavedPersona
        let first: UUID, second: UUID
        var archive: URL { library.root.appendingPathComponent("persona-library.json") }
    }
    private func png(width: Int, height: Int, red: CGFloat) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PersonaError.unreadableImage }
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw PersonaError.unreadableImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PersonaError.unreadableImage }
        return data as Data
    }
    /// A in the first group with B, and C in the second; A is selected and shown first.
    private func fixture(panels: (() -> any PersonaSessionDisplaying)? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaShown-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var sources: [URL] = []
        for (index, size) in [(300, 400), (400, 300), (240, 240)].enumerated() {
            let url = root.appendingPathComponent("synthetic-\(index).png")
            try png(width: size.0, height: size.1, red: 0.2 + CGFloat(index) * 0.3).write(to: url); sources.append(url)
        }
        let voice = Voice()
        let library = PersonaLibrary(root: root.appendingPathComponent("library"), sessionPanelFactory: panels,
                                     sessionHUDEnabled: false, voice: voice.access)
        library.usesSharedControls = true
        let a = try library.addImage(sources[0], name: "Private Alpha", card: PersonaCardStyle(label: "Site lead"))
        let b = try library.addImage(sources[1], name: "Private Bravo", card: PersonaCardStyle(label: "Account lead"))
        let c = try library.addImage(sources[2], name: "Private Charlie")
        let second = try library.createGroup(name: "Private second group", members: [c.id])
        let first = try library.createGroup(name: "Private first group", members: [a.id, b.id])
        library.selectedID = a.id
        return Fixture(root: root, library: library, voice: voice, a: a, b: b, c: c, first: first, second: second)
    }
    private func cleanup(_ f: Fixture) { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
    /// Window frames are whole points, so a kept centre can differ by up to a
    /// couple of points on some displays; a moved copy is off by far more.
    private let rounding = 2.0
    /// The one floating card's own window, found by title; only this process's windows are read.
    private func cardWindow() -> NSWindow? { NSApp.windows.first { $0.title == "Workbench persona" && $0.isVisible } }
    private func titles(_ menu: NSMenu) -> [String] { menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
    private func invoke(_ menu: NSMenu, _ title: String) {
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
            XCTAssertTrue(false, "Expected \(title)"); return
        }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    // MARK: Browsing

    /// Selecting another saved persona, choosing another group, creating a group
    /// and saving an unrelated change never replace or hide the shown card, and
    /// its size, lock and position still change the shown card.
    func testBrowsingNeverReplacesOrHidesTheShownCard() throws {
        let f = try fixture(); defer { cleanup(f) }
        try f.library.showOverlay().get()
        let shown = f.library.shownCard
        XCTAssertEqual(shown?.source.id, f.a.id)
        f.library.selectedID = f.b.id
        XCTAssertEqual(f.library.shownCard, shown, "Selecting B leaves A shown")
        XCTAssertTrue(f.library.overlayVisible)
        f.library.prepareGroup(f.second)
        XCTAssertTrue(f.library.overlayVisible, "Choosing another group does not hide the shown card")
        XCTAssertEqual(f.library.shownCard, shown)
        _ = try f.library.createGroup(name: "Private third group", members: [f.c.id])
        XCTAssertTrue(f.library.overlayVisible, "Creating a group does not hide it either")
        // A save while another group is being browsed is reconciled against the
        // shown card's own group, not the one on screen in preparation.
        f.library.rename(f.c.id, name: "Private Charlie renamed")
        XCTAssertTrue(f.library.overlayVisible, "Reconciling a save keeps the shown card")
        XCTAssertEqual(f.library.shownCard, shown)
        XCTAssertEqual(f.library.liveSelection?.candidateIDs, [f.a.id, f.b.id], "Next and Previous still follow A's group")
        f.library.setOverlayWidth(0.22); f.library.setOverlayLocked(true); f.library.setOverlayPosition(x: 0.02, y: 0.98)
        XCTAssertEqual(f.library.overlayWidth, 0.22, accuracy: 0.0001)
        XCTAssertTrue(f.library.overlayLocked)
        XCTAssertEqual(f.library.shownCard, shown, "Live controls change the shown card, not the selection")
        XCTAssertEqual(f.library.shownIdentity?.name, "Private Alpha")
        XCTAssertEqual(f.library.selected?.name, "Private Charlie renamed")
        // Removing the shown persona's membership is an explicit change: it ends the card.
        f.library.setGroupMembers([f.b.id], in: f.first)
        XCTAssertFalse(f.library.overlayVisible)
        XCTAssertTrue(f.library.shownCard == nil)
    }

    // MARK: Replace shown and Update shown card

    func testReplaceShownWithSelectedKeepsSizePlaceAndLock() throws {
        let f = try fixture(); defer { cleanup(f) }
        f.library.setOverlayWidth(0.2); f.library.setOverlayLocked(true)
        try f.library.showOverlay().get()
        guard let before = cardWindow()?.frame, let copy = f.library.shownCard?.copyID else { XCTAssertTrue(false, "A shows"); return }
        XCTAssertTrue(f.library.replacementForShown == nil, "Nothing to replace while A is selected")
        // A cancelled edit of B changes nothing.
        f.library.selectedID = f.b.id
        let edit = PersonaEditorSession(.saved(f.b)); edit.style.label = "Unsaved"; edit.cancel()
        XCTAssertEqual(f.library.shownCard?.source.id, f.a.id)
        XCTAssertEqual(f.library.replacementForShown?.id, f.b.id)
        try f.library.replaceShownWithSelected().get()
        XCTAssertEqual(f.library.shownCard?.source.id, f.b.id, "One explicit action replaces A with B")
        XCTAssertEqual(f.library.shownCard?.copyID, copy, "It is the same copy")
        XCTAssertEqual(f.library.overlayWidth, 0.2, accuracy: 0.0001)
        XCTAssertTrue(f.library.overlayLocked)
        XCTAssertTrue(f.library.overlayVisible)
        if let after = cardWindow()?.frame {
            XCTAssertEqual(Double(after.midX), Double(before.midX), accuracy: rounding)
            XCTAssertEqual(Double(after.midY), Double(before.midY), accuracy: rounding, file: #filePath, line: #line)
        } else { XCTAssertTrue(false, "B shows in A's place") }
        XCTAssertTrue(f.library.replacementForShown == nil)
        f.library.stepLivePersona(1)
        XCTAssertEqual(f.library.shownCard?.source.id, f.a.id, "Next follows B's group")
        // A replacement that cannot show leaves the shown card and names it publicly.
        f.library.prepareGroup(f.second)
        try FileManager.default.removeItem(at: f.library.root.appendingPathComponent(f.c.image))
        XCTAssertThrowsError(try f.library.replaceShownWithSelected().get())
        XCTAssertEqual(f.library.shownCard?.source.id, f.a.id)
        XCTAssertTrue(f.library.overlayVisible)
        XCTAssertFalse(f.library.notice?.contains("Private") == true, "The notice uses public labels only")
    }

    func testUpdateShownCardChangesOnlyThatCopy() throws {
        let f = try fixture(); defer { cleanup(f) }
        try f.library.showOverlay().get()
        guard let copy = f.library.shownCard?.copyID else { return }
        let frozen = f.library.cardDeck?.images[f.a.id]
        XCTAssertFalse(f.library.shownCardHasNewerLook)
        XCTAssertTrue(f.library.updateCard(f.a.id, style: PersonaCardStyle(label: "New site lead")))
        XCTAssertTrue(f.library.shownCardHasNewerLook, "A newer saved look is offered")
        XCTAssertTrue(f.library.cardDeck?.images[f.a.id] === frozen, "The shown copy stays frozen until Update")
        XCTAssertEqual(f.library.shownCard?.source.persona.card?.label, "Site lead")
        f.library.setOverlayWidth(0.18); f.library.setOverlayLocked(true)
        try f.library.updateShownCard().get()
        XCTAssertEqual(f.library.shownCard?.source.persona.card?.label, "New site lead")
        XCTAssertEqual(f.library.shownCard?.copyID, copy)
        XCTAssertFalse(f.library.cardDeck?.images[f.a.id] === frozen)
        XCTAssertFalse(f.library.shownCardHasNewerLook)
        XCTAssertEqual(f.library.overlayWidth, 0.18, accuracy: 0.0001); XCTAssertTrue(f.library.overlayLocked)
        // A saved shape is a newer look too, and Update adopts it over a live one.
        f.library.setLiveShape(.original, for: .card(copy, generation: f.library.liveControlsGeneration))
        XCTAssertTrue(f.library.setShape(.circle, for: f.a.id))
        XCTAssertTrue(f.library.shownCardHasNewerLook)
        try f.library.updateShownCard().get()
        XCTAssertEqual(f.library.shownCard?.appearance, .circle)
        XCTAssertTrue(f.library.shownCard?.shape == nil)
    }

    // MARK: Hide and Show again

    func testHiddenCardIsKeptUntilShowAgainWithTheMicrophoneStopped() throws {
        let f = try fixture(); defer { cleanup(f) }
        f.library.setVoiceRing(true)
        try f.library.showOverlay().get()
        XCTAssertTrue(f.voice.running, "The voice outline listens while the card shows")
        let shown = f.library.shownCard
        f.library.hideOverlay()
        XCTAssertFalse(f.library.overlayVisible)
        XCTAssertEqual(f.library.shownCard, shown, "Hide keeps this session's card")
        XCTAssertFalse(f.voice.running, "A hidden card does not keep the microphone")
        XCTAssertTrue(f.library.shownIdentity?.hidden == true)
        // Browsing meanwhile changes nothing; Show again brings back A, not the selection.
        f.library.selectedID = f.b.id
        f.library.prepareGroup(f.second)
        XCTAssertEqual(f.library.shownCard, shown)
        let menu = f.library.makeControlsMenu()
        XCTAssertTrue(titles(menu).contains("Show Again"))
        XCTAssertTrue(titles(menu).contains("End Overlay"))
        XCTAssertFalse(titles(menu).joined().contains("Private"), "Floating controls use public labels only")
        try f.library.togglePersonaVisibility().get()
        XCTAssertTrue(f.library.overlayVisible)
        XCTAssertEqual(f.library.shownCard, shown, "Show again restores the same card")
        XCTAssertTrue(f.voice.running)
        // Replacing a hidden card keeps it hidden until Show again.
        f.library.hideOverlay()
        f.library.prepareGroup(f.first); f.library.selectedID = f.b.id
        try f.library.replaceShownWithSelected().get()
        XCTAssertFalse(f.library.overlayVisible, "Replace while hidden stays hidden")
        XCTAssertEqual(f.library.shownCard?.source.id, f.b.id)
        XCTAssertFalse(f.voice.running, "The microphone stays stopped until a card is visible")
        invoke(f.library.makeControlsMenu(), "Show Again")
        XCTAssertTrue(f.library.overlayVisible)
        XCTAssertEqual(f.library.shownCard?.source.id, f.b.id, "Show again shows the replacement")
        XCTAssertTrue(f.voice.running)
        // End overlay, and Quit, release the card.
        f.library.hideOverlay()
        invoke(f.library.makeControlsMenu(), "End Overlay")
        XCTAssertTrue(f.library.shownCard == nil)
        try f.library.showOverlay().get()
        f.library.hideOverlay()
        f.library.shutdown()
        XCTAssertTrue(f.library.shownCard == nil, "Quit releases the kept card")
        XCTAssertFalse(f.voice.running)
    }

    // MARK: Prepared sets

    /// The selected copy of a prepared set is Shown: Replace and Update target it
    /// alone, other copies keep their frozen images, and the layout is saved
    /// only when asked.
    func testPreparedCopyIsIdentifiedAndChangedAlone() throws {
        var panels: [PersonaOverlayController] = []
        let f = try fixture(panels: {
            let panel = PersonaOverlayController(pointer: PersonaTestPointer(), revealDelay: 0); panels.append(panel); return panel
        }); defer { cleanup(f) }
        // B is a Circle and A a Card, so a replacement changes the copy's shape.
        XCTAssertTrue(f.library.setShape(.circle, for: f.b.id))
        let screenID = (NSScreen.main ?? NSScreen.screens.first).flatMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        let one = PersonaOverlayItem(personaID: f.a.id, placement: PersonaOverlayState(x: 0.2, y: 0.2, width: 0.14, screenID: screenID, locked: true))
        let two = PersonaOverlayItem(personaID: f.a.id, placement: PersonaOverlayState(x: 0.7, y: 0.2, width: 0.14, screenID: screenID, locked: true))
        try f.library.saveGroupLayout(f.first, overlays: [one, two], publicLabel: "Set")
        try f.library.startOverlaySession(groupIDs: [f.first], initialGroupID: f.first)
        let saved = try Data(contentsOf: f.archive)
        XCTAssertEqual(f.library.shownIdentity?.place, "Copy 1 of 2 in Set")
        XCTAssertEqual(f.library.shownIdentity?.name, "Private Alpha")
        let frozen = f.library.sessionState.instances.map(\.image)
        // Update: the first copy only.
        XCTAssertTrue(f.library.updateCard(f.a.id, style: PersonaCardStyle(label: "New site lead")))
        XCTAssertTrue(f.library.shownCardHasNewerLook)
        XCTAssertTrue(titles(f.library.makeControlsMenu()).contains("Update Selected"))
        try f.library.updateShownCard().get()
        let updated = f.library.sessionState.instances
        XCTAssertFalse(updated[0].image === frozen[0], "The selected copy shows the newer look")
        XCTAssertTrue(updated[1].image === frozen[1], "The other copy of the same persona keeps its frozen image")
        XCTAssertFalse(f.library.shownCardHasNewerLook)
        // Replace: the second copy only, with a persona the set can show.
        f.library.performOverlayAction(.selectInstance(two.id))
        XCTAssertEqual(f.library.shownIdentity?.place, "Copy 2 of 2 in Set")
        XCTAssertTrue(f.library.shownCardHasNewerLook, "The second copy still has the older look")
        f.library.selectedID = f.b.id
        XCTAssertEqual(f.library.replacementForShown?.id, f.b.id)
        guard panels.count == 2, let before = panels[1].visibleFrame else { XCTAssertTrue(false, "Both copies show"); return }
        try f.library.replaceShownWithSelected().get()
        XCTAssertEqual(f.library.sessionState.instances.map(\.personaID), [f.a.id, f.b.id])
        if let after = panels[1].visibleFrame {
            XCTAssertEqual(Double(after.width / after.height), 1, accuracy: 0.01)
            XCTAssertEqual(Double(after.midX), Double(before.midX), accuracy: rounding)
            XCTAssertEqual(Double(after.midY), Double(before.midY), accuracy: rounding, file: #filePath, line: #line)
            XCTAssertTrue(panels[1].window?.ignoresMouseEvents == true, "The replacement keeps the copy's lock")
        } else { XCTAssertTrue(false, "The replacement shows in the copy's place") }
        XCTAssertTrue(updatedImage(f.library, 0) === updated[0].image, "The updated copy is unchanged by the replacement")
        // A persona outside the set is not offered.
        f.library.selectedID = f.c.id
        XCTAssertTrue(f.library.replacementForShown == nil)
        XCTAssertTrue(f.library.sessionState.hasUnsavedLayout)
        let stored = try JSONDecoder().decode(PersonaArchive.self, from: Data(contentsOf: f.archive))
        XCTAssertEqual(stored.groups.first { $0.id == f.first }?.overlays?.map(\.personaID), [f.a.id, f.a.id],
                       "The live replacement is not saved until Save Layout")
        let now = try Data(contentsOf: f.archive)
        XCTAssertFalse(now == saved, "Only the library edit was saved meanwhile")
        f.library.performOverlayAction(.saveLayout)
        XCTAssertEqual(f.library.groups.first { $0.id == f.first }?.overlays?.map(\.personaID), [f.a.id, f.b.id], "Save Layout keeps the replacement")
    }
    /// The End shortcut releases the one floating card: Option-F afterwards
    /// shows the selection as a new card, never the ended one.
    func testEndShortcutReleasesTheCard() throws {
        let f = try fixture(); defer { cleanup(f) }
        // A suite named by a path keeps its plist in this folder, not in ~/Library/Preferences.
        let settings = SettingsStore(defaults: UserDefaults(suiteName: f.root.appendingPathComponent("settings").path)!)
        for action in Action.allCases {
            var shortcut = action.defaultShortcut; shortcut.enabled = false
            settings.value.shortcuts[action.rawValue] = shortcut
        }
        let app = AppCoordinator(settings: settings, archiveURL: f.root.appendingPathComponent("boards.json"), embedded: true)
        let scenes = DemoScenes(root: f.root.appendingPathComponent("scenes"), systemIntegrationEnabled: false)
        app.demoScenes = scenes
        defer { scenes.shutdown() }
        let library = scenes.personas
        let a = try library.addImage(f.root.appendingPathComponent("synthetic-0.png"), name: "Private Alpha", card: PersonaCardStyle(label: "Site lead"))
        let b = try library.addImage(f.root.appendingPathComponent("synthetic-1.png"), name: "Private Bravo", card: PersonaCardStyle(label: "Account lead"))
        library.selectedID = a.id
        app.handleHotkey(.personaToggle, down: true)
        XCTAssertEqual(library.shownCard?.source.id, a.id)
        let ended = library.shownCard?.copyID
        app.handleHotkey(.overlayEnd, down: true)
        XCTAssertTrue(library.shownCard == nil, "End releases the card, not only hides it")
        XCTAssertFalse(library.overlayVisible)
        library.selectedID = b.id
        app.handleHotkey(.personaToggle, down: true)
        XCTAssertEqual(library.shownCard?.source.id, b.id, "Option-F after End shows the selection")
        XCTAssertFalse(library.shownCard?.copyID == ended, "It is a new card, not the ended one")
        library.endOverlaySession()
    }
    private func updatedImage(_ library: PersonaLibrary, _ index: Int) -> NSImage? {
        let instances = library.sessionState.instances
        return instances.indices.contains(index) ? instances[index].image : nil
    }

    // MARK: Renders

    /// Set WORKBENCH_LAYOUT_EVIDENCE to render the workspace with a card shown
    /// while another is selected, hidden, and a prepared copy, light and dark.
    func testOffscreenShownRenders() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = try fixture(); defer { cleanup(f) }
        defer { renderIn(nil) }
        try f.library.showOverlay().get()
        f.library.selectedID = f.b.id
        XCTAssertTrue(f.library.updateCard(f.a.id, style: PersonaCardStyle(label: "New site lead")))
        for theme in ["light", "dark"] {
            renderIn(theme == "dark" ? "Dark" : "Light")
            try MainActor.assumeIsolated {
                try render(PersonaLibraryView(library: f.library, mode: .workspace).frame(width: 900, height: 820),
                           to: directory.appendingPathComponent("persona-shown-\(theme).png"))
            }
        }
        try MainActor.assumeIsolated {
            try render(PersonaLibraryView(library: f.library, mode: .workspace).frame(width: 620, height: 900),
                       to: directory.appendingPathComponent("persona-shown-narrow.png"))
        }
        f.library.hideOverlay()
        for theme in ["light", "dark"] {
            renderIn(theme == "dark" ? "Dark" : "Light")
            try MainActor.assumeIsolated {
                try render(PersonaLibraryView(library: f.library, mode: .workspace).frame(width: 900, height: 820),
                           to: directory.appendingPathComponent("persona-hidden-\(theme).png"))
            }
        }
    }
    private func renderIn(_ appearance: String?) {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["appearance"] = appearance
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        WorkbenchSettings.shared.refresh()
    }
    @MainActor private func render<V: View>(_ content: V, to url: URL) throws {
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
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
        print("Offscreen persona shown: " + url.path)
    }
}
