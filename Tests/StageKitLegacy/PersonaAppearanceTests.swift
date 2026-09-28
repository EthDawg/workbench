import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Circle / Card / Original (#169). New editable portraits start as a Circle;
/// switching shape keeps the source, the framing and the label and colour;
/// personas saved before the choice keep their look; a shown copy changes shape
/// from its frozen ingredients, keeping its width, centre, lock and voice
/// outline, and every other copy; and the outline and handles follow the shape
/// actually drawn, for tall, wide, small and transparent artwork.
final class PersonaAppearanceTests {
    // MARK: Fixtures

    /// A fake microphone and permission, so the voice outline can be on without
    /// opening a real microphone or saving a preference.
    private final class Microphone: PersonaVoiceSource {
        var onFrames: (([PersonaVoiceFrame]) -> Void)?
        var onUnavailable: ((String) -> Void)?
        var onDevice: ((String?) -> Void)?
        private(set) var running = false
        var deviceName: String? { running ? "Synthetic microphone" : nil }
        func start() throws { running = true }
        func stop() { running = false }
    }
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
    /// Prepared copies draw into these instead of windows over the desktop.
    private final class Panel: PersonaSessionDisplaying {
        var onPlacementChange: ((PersonaOverlayState) -> Void)?
        var onSelection: (() -> Void)?
        var frame: CGRect? = CGRect(x: 0, y: 0, width: 80, height: 120)
        var image: NSImage?
        var outline: PersonaArtworkOutline?
        var state = PersonaOverlayState()
        func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState {
            self.image = image; self.state = state; return state
        }
        func configure(image: NSImage, name: String, state: PersonaOverlayState) { self.image = image; self.state = state }
        func hide() {}
        func shutdown() {}
        func setOutline(_ outline: PersonaArtworkOutline?) { self.outline = outline }
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaAppearance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    /// A synthetic picture: an opaque rectangle with a darker centre mark, or a
    /// round badge on transparency.
    private func png(width: Int, height: Int, badge: Bool = false) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PersonaError.unreadableImage }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.85, green: 0.62, blue: 0.3, alpha: 1))
        if badge { context.fillEllipse(in: CGRect(x: 0, y: 0, width: width, height: height)) }
        else { context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: width / 3, y: height / 3, width: max(1, width / 3), height: max(1, height / 3)))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw PersonaError.unreadableImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PersonaError.unreadableImage }
        return data as Data
    }
    private func write(_ data: Data, named name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name); try data.write(to: url); return url
    }
    private func alpha(_ image: NSImage, x: Double, y: Double) -> CGFloat {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        return bitmap.colorAt(x: min(bitmap.pixelsWide - 1, Int(Double(bitmap.pixelsWide) * x)),
                              y: min(bitmap.pixelsHigh - 1, Int(Double(bitmap.pixelsHigh) * y)))?.alphaComponent ?? -1
    }
    private func pixels(_ image: NSImage?) -> Data? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
    private func screen() -> NSScreen? { NSScreen.main ?? NSScreen.screens.first }
    private func displayID(_ screen: NSScreen) -> UInt32? { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }

    // MARK: 1. New portraits start as a Circle; switching keeps everything

    func testNewPortraitStartsAsCircleAndSwitchingShapesKeepsEverything() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try write(png(width: 300, height: 400), named: "Synthetic portrait.png", in: root)
        let starters = root.appendingPathComponent("starters")
        try FileManager.default.createDirectory(at: starters, withIntermediateDirectories: true)
        for starter in PersonaStarterLibrary.portraits { _ = try write(png(width: 200, height: 200), named: starter.filename, in: starters) }
        let library = PersonaLibrary(root: root.appendingPathComponent("library")); defer { library.shutdown() }
        library.usesSharedControls = true

        // An imported portrait: Circle, centred. A starter: Circle, with its curated framing.
        var draft = try library.portraitDraft(from: source, card: PersonaCardStyle(label: "Synthetic lead", background: InkColor(0.2, 0.3, 0.6)))
        XCTAssertEqual(draft.appearance.shape, .circle, "A new profile portrait previews as a Circle")
        XCTAssertEqual(draft.appearance.currentFraming, .centred, "Imports use centred framing")
        let starter = try PersonaStarterLibrary(directory: starters).draft(PersonaStarterLibrary.portraits[0], for: library)
        XCTAssertEqual(starter.appearance.shape, .circle)
        XCTAssertEqual(starter.appearance.currentFraming, PersonaStarterLibrary.portraits[0].framing, "Bundled portraits use curated framing")
        let preview = try draft.image()
        XCTAssertEqual(preview.size.width, preview.size.height, "Circle is round")
        XCTAssertEqual(Double(alpha(preview, x: 0.02, y: 0.02)), 0, accuracy: 0.01)
        XCTAssertEqual(Double(alpha(preview, x: 0.5, y: 0.5)), 1, accuracy: 0.01)
        XCTAssertTrue(library.items.isEmpty, "The Circle preview is shown before anything is saved")

        // Circle → Card → Original → Circle keeps the source, the framing and the label and colour.
        let framed = PersonaFraming(x: 0.45, y: 0.62, zoom: 1.6)
        draft.appearance.framing = framed
        for shape in [PersonaAppearance.Shape.card, .original, .circle] {
            draft.appearance.shape = shape
            XCTAssertEqual(draft.appearance.framing, framed, "Framing survives \(shape.title)")
            XCTAssertEqual(draft.card.label, "Synthetic lead")
        }
        XCTAssertEqual(try draft.image().size.width, try draft.image().size.height)
        draft.appearance.shape = .card
        XCTAssertEqual(try draft.image().size, PersonaCardRenderer.size)
        draft.appearance.shape = .original
        XCTAssertTrue(try draft.image() === draft.portrait, "Original is the picture itself")
        draft.appearance.shape = .circle

        let saved = try library.add(draft)
        XCTAssertEqual(saved.appearance?.shape, .circle)
        XCTAssertEqual(saved.appearance?.framing, framed)
        let stored = library.root.appendingPathComponent(saved.image)
        let original = try Data(contentsOf: stored)
        XCTAssertEqual(original, draft.png, "The original picture is saved unchanged")
        let circle = pixels(library.renderedImage(for: saved))

        for shape in [PersonaAppearance.Shape.card, .original, .circle] {
            XCTAssertTrue(library.setShape(shape, for: saved.id))
            let item = library.items.first { $0.id == saved.id }!
            XCTAssertEqual(item.effectiveAppearance.shape, shape)
            XCTAssertEqual(item.appearance?.framing, framed, "The quick choice keeps the framing")
            XCTAssertEqual(item.card, PersonaCardStyle(label: "Synthetic lead", background: InkColor(0.2, 0.3, 0.6)), "It keeps the label and colour")
            XCTAssertEqual(try Data(contentsOf: stored), original, "It never changes the original picture")
            let rendered = library.renderedImage(for: item)
            switch shape {
            case .card: XCTAssertEqual(rendered?.size, PersonaCardRenderer.size)
            case .original: XCTAssertEqual(try library.renderedPNG(for: item), original, "Original exports the saved bytes")
            case .circle: XCTAssertEqual(pixels(rendered), circle, "Back to Circle draws the same circle")
            }
        }
        // Reset framing returns to the automatic framing.
        var item = library.items.first { $0.id == saved.id }!
        var reset = item.effectiveAppearance; reset.framing = nil
        XCTAssertTrue(library.updateAppearance(saved.id, appearance: reset, card: item.card))
        item = library.items.first { $0.id == saved.id }!
        XCTAssertEqual(item.effectiveAppearance.currentFraming, .centred)
        XCTAssertFalse(pixels(library.renderedImage(for: item)) == circle, "Reset framing draws the centred circle")
        let reopened = PersonaLibrary(root: library.root); defer { reopened.shutdown() }
        XCTAssertEqual(reopened.items, library.items, "The appearance is saved with the persona")
    }

    // MARK: 2. Existing personas look the same after the upgrade

    func testExistingPersonasKeepTheirLookAfterUpgrade() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let rectangle = try png(width: 160, height: 90), badge = try png(width: 120, height: 120, badge: true), portrait = try png(width: 90, height: 120)
        _ = try write(rectangle, named: "finished-rectangle.png", in: root)
        _ = try write(badge, named: "finished-badge.png", in: root)
        _ = try write(portrait, named: "card-portrait.png", in: root)
        // Written by an app from before the choice existed: no appearance anywhere.
        let items: [[String: Any]] = [
            ["id": UUID().uuidString, "name": "Finished rectangle", "image": "finished-rectangle.png"],
            ["id": UUID().uuidString, "name": "Transparent badge", "image": "finished-badge.png"],
            ["id": UUID().uuidString, "name": "Editable card", "image": "card-portrait.png",
             "card": ["label": "Site lead", "background": ["r": 0.1, "g": 0.4, "b": 0.3, "a": 1]]]
        ]
        let archive = try JSONSerialization.data(withJSONObject: ["version": 2, "items": items, "groups": [], "preparedGroupIDs": []])
        let url = root.appendingPathComponent("persona-library.json"); try archive.write(to: url)
        let library = PersonaLibrary(root: root); defer { library.shutdown() }
        XCTAssertFalse(library.isReadOnly, "An archive from before the choice still opens")
        XCTAssertEqual(library.items.map(\.effectiveAppearance.shape), [.original, .original, .card])
        XCTAssertTrue(library.items.allSatisfy { $0.appearance == nil })
        XCTAssertEqual(try library.renderedPNG(for: library.items[0]), rectangle, "Rectangular artwork is exactly as before")
        XCTAssertEqual(try library.renderedPNG(for: library.items[1]), badge, "Transparent artwork is exactly as before")
        let card = library.renderedImage(for: library.items[2])
        XCTAssertEqual(card?.size, PersonaCardRenderer.size, "An editable card is still a card")
        XCTAssertEqual(pixels(card), pixels(try PersonaCardRenderer.image(portrait: library.image(named: "card-portrait.png")!,
                                                                        style: library.items[2].card!)))
        XCTAssertEqual(try Data(contentsOf: url), archive, "Opening writes nothing")
        // Editing the label of finished artwork keeps it Original.
        XCTAssertTrue(library.updateCard(library.items[1].id, style: PersonaCardStyle(label: "Badge")))
        XCTAssertEqual(library.items[1].effectiveAppearance.shape, .original)
        XCTAssertEqual(try library.renderedPNG(for: library.items[1]), badge)
        // A version 1 archive cannot carry an appearance.
        let legacy = try JSONEncoder().encode(PersonaArchive(version: 1, items: [SavedPersona(name: "Legacy", image: "finished-badge.png",
                                                                                         appearance: PersonaAppearance(shape: .circle))]))
        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try legacy.write(to: legacyRoot.appendingPathComponent("persona-library.json"))
        XCTAssertTrue(PersonaLibrary(root: legacyRoot).isReadOnly)
    }

    // MARK: 3. A shown copy changes shape by itself

    /// The native overlay: switching Card → Circle → Original keeps the artwork's
    /// width and centre, the lock and the voice outline, and the outline and
    /// handles follow the new edge. Body clicks keep passing through.
    func testShownCopyReshapesKeepingWidthCentreLockAndOutline() throws {
        guard let screen = screen() else { XCTAssertTrue(false, "The native check needs a display"); return }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let portraitURL = try write(png(width: 300, height: 400), named: "portrait.png", in: root)
        guard let portrait = NSImage(contentsOf: portraitURL) else { return }
        let card = try PersonaCardRenderer.image(portrait: portrait, style: PersonaCardStyle(label: "Synthetic lead"))
        let circle = try PersonaCircleRenderer.image(portrait: portrait, framing: .centred)
        let pointer = PersonaTestPointer()
        let controller = PersonaOverlayController(pointer: pointer, revealDelay: 0)
        defer { controller.shutdown() }
        guard let window = controller.window else { return }
        controller.setVoiceRing(true)
        controller.setOutline(PersonaAppearance.Shape.card.outline)
        let start = PersonaOverlayState(x: 0.4, y: 0.5, width: 0.16, screenID: displayID(screen), locked: true)
        _ = controller.show(image: card, name: "Synthetic lead", state: start)
        guard let before = controller.visibleFrame else { XCTAssertTrue(false, "The card's edge is known"); return }
        XCTAssertTrue(window.ignoresMouseEvents)

        var state = controller.reshape(image: circle, outline: PersonaAppearance.Shape.circle.outline, name: "Synthetic lead", state: start)
        guard let round = controller.visibleFrame else { return }
        XCTAssertEqual(Double(round.width), Double(before.width), accuracy: 1, file: #filePath, line: #line)
        XCTAssertEqual(Double(round.width / round.height), 1, accuracy: 0.01)
        XCTAssertEqual(Double(round.midX), Double(before.midX), accuracy: 1)
        XCTAssertEqual(Double(round.midY), Double(before.midY), accuracy: 1)
        XCTAssertEqual(state.width, start.width); XCTAssertTrue(state.locked, "The lock is unchanged")
        XCTAssertTrue(window.ignoresMouseEvents, "Body clicks still pass through")
        XCTAssertTrue(window.frame.width > round.width + 4, "The voice outline keeps its room around the circle")
        pointer.move(to: CGPoint(x: round.maxX + 8, y: round.midY))
        let handles = controller.handleWindows
        XCTAssertTrue(handles[.move].map { abs($0.frame.midX - round.midX) < 1 && $0.frame.minY >= round.maxY - 3 } ?? false,
                      "The grab handle sits on the circle's top edge")
        XCTAssertTrue(handles[.bottomRight].map { $0.frame.minX >= round.maxX - 10 && $0.frame.maxY <= round.minY + 10 } ?? false,
                      "A corner handle sits at the circle's corner")

        state = controller.reshape(image: portrait, outline: nil, name: "Synthetic lead", state: state)
        guard let plain = controller.visibleFrame else { return }
        XCTAssertEqual(Double(plain.midX), Double(before.midX), accuracy: 1)
        XCTAssertEqual(Double(plain.midY), Double(before.midY), accuracy: 1)
        XCTAssertEqual(Double(plain.width / plain.height), 0.75, accuracy: 0.02, file: #filePath, line: #line)
        XCTAssertTrue(window.ignoresMouseEvents)

        // Tall artwork limited by the display's height shows narrower than its
        // Size; a Circle made from it keeps that displayed width, not the Size.
        let tallURL = try write(png(width: 200, height: 800), named: "tall.png", in: root)
        if let tallImage = NSImage(contentsOf: tallURL) {
            let tallCircle = try PersonaCircleRenderer.image(portrait: tallImage, framing: .centred)
            let wide = PersonaOverlayState(x: 0.3, y: 0.3, width: 0.3, screenID: displayID(screen), locked: true)
            controller.setOutline(nil)
            _ = controller.show(image: tallImage, name: "Synthetic lead", state: wide)
            if let limited = controller.visibleFrame, limited.width < screen.visibleFrame.width * 0.3 - 2 {
                let round = controller.reshape(image: tallCircle, outline: PersonaAppearance.Shape.circle.outline, name: "Synthetic lead", state: wide)
                XCTAssertEqual(Double(controller.visibleFrame?.width ?? 0), Double(limited.width), accuracy: 1, file: #filePath, line: #line)
                XCTAssertTrue(round.width < 0.3, "The Size follows the displayed width")
                XCTAssertEqual(Double(controller.visibleFrame?.midX ?? 0), Double(limited.midX), accuracy: 1)
            }
        }

        // Near an edge it moves only as far as it must to stay on screen.
        let edge = PersonaOverlayState(x: 1, y: 1, width: 0.16, screenID: displayID(screen), locked: true)
        controller.setOutline(PersonaAppearance.Shape.circle.outline)
        _ = controller.show(image: circle, name: "Synthetic lead", state: edge)
        _ = controller.reshape(image: card, outline: PersonaAppearance.Shape.card.outline, name: "Synthetic lead", state: edge)
        XCTAssertTrue(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame), "The taller card stays on screen")
    }

    /// Through the library: the shown copy changes shape from its frozen
    /// ingredients with the voice outline on; the saved persona, the library
    /// file and the microphone state are unchanged, and an image that changed on
    /// disk leaves the copy as it was.
    func testLiveShapeUsesFrozenIngredientsAndChangesOnlyThatCopy() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try write(png(width: 300, height: 400), named: "portrait.png", in: root)
        let voice = Voice()
        let library = PersonaLibrary(root: root.appendingPathComponent("library"), sessionHUDEnabled: false, voice: voice.access)
        defer { library.shutdown() }
        library.usesSharedControls = true
        let persona = try library.addImage(source, name: "Private name", card: PersonaCardStyle(label: "Site lead"))
        library.setVoiceRing(true)
        library.setOverlayLocked(true)
        try library.showOverlay().get()
        XCTAssertTrue(voice.running, "The voice outline listens while the card shows")
        XCTAssertEqual(library.shownCard?.appearance, .card)
        let archive = library.root.appendingPathComponent("persona-library.json")
        let saved = try Data(contentsOf: archive)
        let width = library.overlayWidth

        // A later library edit does not reach the shown copy's ingredients.
        XCTAssertTrue(library.updateCard(persona.id, style: PersonaCardStyle(label: "Changed later")))
        library.setLiveShape(.circle, for: library.selectedLiveCopy!)
        XCTAssertEqual(library.shownCard?.appearance, .circle)
        XCTAssertEqual(library.shownCard?.shape, .circle)
        library.setLiveShape(.card, for: library.selectedLiveCopy!)
        let frozen = try PersonaCardRenderer.image(portrait: NSImage(contentsOf: source)!, style: PersonaCardStyle(label: "Site lead"))
        let drawn = library.cardDeck?.images[persona.id]
        XCTAssertEqual(pixels(drawn), pixels(library.renderedImage(for: SavedPersona(id: persona.id, name: "x", image: persona.image,
                                                                                     card: PersonaCardStyle(label: "Site lead")))),
                       "The copy's card is drawn from the frozen label, not the later edit")
        XCTAssertFalse(pixels(drawn) == pixels(library.renderedImage(for: library.items[0])))
        XCTAssertEqual(drawn?.size, frozen.size)
        XCTAssertEqual(library.items[0].effectiveAppearance.shape, .card, "The saved persona keeps its own look")
        XCTAssertEqual(library.items[0].card?.label, "Changed later")
        XCTAssertTrue(library.overlayLocked); XCTAssertEqual(library.overlayWidth, width)
        XCTAssertTrue(library.voiceRing && voice.running, "The voice outline stays on")
        let afterEdit = try Data(contentsOf: archive)
        XCTAssertFalse(afterEdit == saved)
        library.setLiveShape(.original, for: library.selectedLiveCopy!)
        XCTAssertEqual(try Data(contentsOf: archive), afterEdit, "A live change writes nothing to the library")

        // Its image changed on disk: the copy stays as it is and says why.
        let shownImage = library.cardDeck?.images[persona.id]
        try png(width: 64, height: 64).write(to: library.root.appendingPathComponent(persona.image))
        library.setLiveShape(.circle, for: library.selectedLiveCopy!)
        XCTAssertEqual(library.shownCard?.appearance, .original)
        XCTAssertTrue(library.cardDeck?.images[persona.id] === shownImage)
        XCTAssertTrue(library.notice?.contains("Site lead") == true, "The notice names the card by its public label")
        XCTAssertFalse(library.notice?.contains("Private name") == true)
        library.hideOverlay()
        XCTAssertFalse(voice.running)
    }

    /// In a prepared set, one copy changes shape; another copy of the same
    /// persona keeps its look, and the layout is saved only when asked. A saved
    /// copy's shape is drawn again, within the budget, when the set starts.
    func testPreparedCopyChangesShapeAloneAndSavesOnlyWhenAsked() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try write(png(width: 300, height: 400), named: "portrait.png", in: root)
        var panels: [Panel] = []
        let library = PersonaLibrary(root: root.appendingPathComponent("library"),
                                     sessionPanelFactory: { let panel = Panel(); panels.append(panel); return panel }, sessionHUDEnabled: false)
        defer { library.shutdown() }
        library.usesSharedControls = true
        let persona = try library.addImage(source, name: "Private name", card: PersonaCardStyle(label: "Site lead"))
        let group = try library.createGroup(name: "Private group", members: [persona.id])
        let first = PersonaOverlayItem(personaID: persona.id, placement: PersonaOverlayState(x: 0.1, y: 0.2, width: 0.14, locked: true))
        let second = PersonaOverlayItem(personaID: persona.id, placement: PersonaOverlayState(x: 0.8, y: 0.2, width: 0.14, locked: true))
        try library.saveGroupLayout(group, overlays: [first, second], publicLabel: "Set")
        let archive = library.root.appendingPathComponent("persona-library.json")
        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
        let saved = try Data(contentsOf: archive)
        library.performOverlayAction(.selectInstance(second.id))
        let menu = library.makeControlsMenu()
        guard let appearance = menu.items.first(where: { $0.title == "Appearance" })?.submenu else {
            XCTAssertTrue(false, "The selected copy's Options offer Appearance"); return
        }
        XCTAssertEqual(appearance.items.map(\.title), ["Circle", "Card", "Original"])
        XCTAssertEqual(appearance.items.filter { $0.state == .on }.map(\.title), ["Card"], "The current look is checked")
        guard let circle = appearance.items.first, let action = circle.action else { return }
        NSApp.sendAction(action, to: circle.target, from: circle)
        let instances = library.sessionState.instances
        XCTAssertEqual(instances.map(\.shape), [.card, .circle], "Only the selected copy changed")
        XCTAssertEqual(instances[1].image.size.width, instances[1].image.size.height)
        XCTAssertEqual(instances[0].image.size, PersonaCardRenderer.size)
        XCTAssertEqual(panels.count, 2)
        XCTAssertEqual(panels.last?.outline, PersonaAppearance.Shape.circle.outline, "Its outline and handles follow the circle")
        XCTAssertEqual(panels.first?.outline, PersonaAppearance.Shape.card.outline)
        XCTAssertTrue(library.sessionState.hasUnsavedLayout)
        XCTAssertEqual(try Data(contentsOf: archive), saved, "Nothing is saved until Save Layout")
        // An explicit copy is changed exactly, whichever copy is selected; a copy
        // from a set that is no longer current is left alone.
        guard let selected = library.selectedLiveCopy else { XCTAssertTrue(false, "The selected copy is named"); return }
        XCTAssertEqual(selected, .overlay(second.id, group: group))
        library.setLiveShape(.original, for: .overlay(first.id, group: group))
        XCTAssertEqual(library.sessionState.instances.map(\.shape), [.original, .circle])
        XCTAssertEqual(library.liveShape(of: .overlay(first.id, group: group)), .original)
        library.setLiveShape(.circle, for: .overlay(first.id, group: UUID()))
        XCTAssertEqual(library.sessionState.instances.map(\.shape), [.original, .circle], "A stale target changes nothing")
        library.setLiveShape(.card, for: .overlay(first.id, group: group))
        library.performOverlayAction(.saveLayout)
        XCTAssertEqual(library.groups[0].overlays?.map(\.shape), [nil, .circle])
        library.endOverlaySession()
        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
        XCTAssertEqual(library.sessionState.instances.map(\.shape), [.card, .circle], "The saved look is drawn again at Start")
    }

    // MARK: 4. Keyboard and announced state

    func testAppearanceChoiceIsOneKeyboardReachableSelection() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try write(png(width: 120, height: 160), named: "portrait.png", in: root)
        let library = PersonaLibrary(root: root.appendingPathComponent("library"), sessionHUDEnabled: false)
        defer { library.shutdown() }
        library.usesSharedControls = true
        _ = try library.addImage(source, name: "Private name", card: PersonaCardStyle(label: "Site lead"))
        try library.showOverlay().get()
        let menu = library.makeControlsMenu()
        let submenus = menu.items.filter { $0.title == "Appearance" }
        XCTAssertEqual(submenus.count, 1, "One Appearance choice in the live Options, not a second style menu")
        guard let items = submenus.first?.submenu?.items else { return }
        XCTAssertEqual(items.map(\.title), ["Circle", "Card", "Original"])
        XCTAssertEqual(items.map(\.state), [.off, .on, .off], "The current look is checked, which VoiceOver reads")
        XCTAssertTrue(items.allSatisfy { $0.isEnabled && $0.action != nil }, "Every choice works from the keyboard in the native menu")
        if let circle = items.first, let action = circle.action { NSApp.sendAction(action, to: circle.target, from: circle) }
        XCTAssertEqual(library.makeControlsMenu().items.first { $0.title == "Appearance" }?.submenu?.items.map(\.state), [.on, .off, .off])
        // A stale menu from an earlier card cannot reshape a later one.
        library.endOverlaySession(); try library.showOverlay().get()
        if let original = items.last, let action = original.action { NSApp.sendAction(action, to: original.target, from: original) }
        XCTAssertEqual(library.shownCard?.appearance, .card)
        // The framing preview moves by keyboard the same way as by drag.
        let size = CGSize(width: 300, height: 400)
        let closer = PersonaFraming(x: 0.5, y: 0.5, zoom: 2)
        let moved = closer.dragged(by: CGSize(width: 12, height: 0), diameter: 240, portrait: size)
        XCTAssertTrue(moved.x < 0.5, "Moving the picture right moves the circle left over it")
        XCTAssertEqual(PersonaFraming.centred.dragged(by: CGSize(width: 12, height: 0), diameter: 240, portrait: size).x, 0.5,
                       "A circle as wide as the picture cannot move across it")
        let up = PersonaFraming.centred.dragged(by: CGSize(width: 0, height: -12), diameter: 240, portrait: size)
        XCTAssertTrue(up.y < 0.5, "Moving the picture up moves the circle down over it")
        XCTAssertEqual(PersonaFraming.centred.zoomed(to: 9, portrait: size).zoom, 4)
    }

    /// The floating toolbar's Persona accessory reuses the same action through
    /// StageKitController: a copy captured when drawn is changed exactly, and a
    /// copy that has ended is left alone. No second store or preference.
    func testToolbarChangesExactlyTheCapturedCopy() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try write(png(width: 300, height: 400), named: "portrait.png", in: root)
        // A suite named by a path keeps its plist in this folder, not in ~/Library/Preferences.
        let settings = SettingsStore(defaults: UserDefaults(suiteName: root.appendingPathComponent("settings").path)!)
        for action in Action.allCases {
            var shortcut = action.defaultShortcut; shortcut.enabled = false
            settings.value.shortcuts[action.rawValue] = shortcut
        }
        let app = AppCoordinator(settings: settings, archiveURL: root.appendingPathComponent("boards.json"), embedded: true)
        let scenes = DemoScenes(root: root.appendingPathComponent("scenes"), systemIntegrationEnabled: false)
        app.demoScenes = scenes
        defer { scenes.shutdown() }
        _ = try scenes.personas.addImage(source, name: "Private name", card: PersonaCardStyle(label: "Site lead"))
        MainActor.assumeIsolated {
            let stage = StageKitController(coordinator: app)
            stage.useSharedActivityControls()
            XCTAssertTrue(stage.selectedPersonaCopy == nil, "No live copy, nothing to change")
            stage.togglePersona()
            guard let copy = stage.selectedPersonaCopy else { XCTAssertTrue(false, "The shown card is named"); return }
            XCTAssertEqual(stage.personaShape(of: copy), .card)
            stage.setPersonaShape(.circle, for: copy)
            XCTAssertEqual(stage.personaShape(of: copy), .circle)
            XCTAssertEqual(scenes.personas.shownCard?.appearance, .circle)
            XCTAssertEqual(scenes.personas.items[0].effectiveAppearance.shape, .card, "The saved persona keeps its look")
            XCTAssertEqual(StageKitController.PersonaShape.allCases.map(\.title), ["Circle", "Card", "Original"])
            scenes.personas.endOverlaySession()
            stage.togglePersona()
            XCTAssertTrue(stage.personaShape(of: copy) == nil, "An ended copy is no longer live")
            stage.setPersonaShape(.original, for: copy)
            XCTAssertEqual(scenes.personas.shownCard?.appearance, .card, "A stale copy never changes the new card")
            scenes.personas.endOverlaySession()
        }
    }

    /// The toolbar API's prepared-set path: nothing selected names no copy; a
    /// copy captured in one set is refused once another set is showing; and one
    /// copy changes while a sibling copy of the same persona keeps its look.
    func testToolbarTargetsOnePreparedCopyExactly() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try write(png(width: 300, height: 400), named: "portrait.png", in: root)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: root.appendingPathComponent("settings").path)!)
        for action in Action.allCases {
            var shortcut = action.defaultShortcut; shortcut.enabled = false
            settings.value.shortcuts[action.rawValue] = shortcut
        }
        let app = AppCoordinator(settings: settings, archiveURL: root.appendingPathComponent("boards.json"), embedded: true)
        let scenes = DemoScenes(root: root.appendingPathComponent("scenes"), systemIntegrationEnabled: false, personaPanels: { Panel() })
        app.demoScenes = scenes
        defer { scenes.shutdown() }
        let library = scenes.personas
        let persona = try library.addImage(source, name: "Private name", card: PersonaCardStyle(label: "Site lead"))
        let first = try library.createGroup(name: "Private first", members: [persona.id])
        let a = PersonaOverlayItem(personaID: persona.id), b = PersonaOverlayItem(personaID: persona.id)
        try library.saveGroupLayout(first, overlays: [a, b], publicLabel: "First")
        let second = try library.createGroup(name: "Private second", members: [persona.id])
        try library.saveGroupLayout(second, overlays: [PersonaOverlayItem(personaID: persona.id)], publicLabel: "Second")
        try library.startOverlaySession(groupIDs: [first, second], initialGroupID: first)
        MainActor.assumeIsolated {
            let stage = StageKitController(coordinator: app)
            stage.useSharedActivityControls()
            guard let copyA = stage.selectedPersonaCopy else { XCTAssertTrue(false, "The selected copy is named"); return }
            // One copy changes; its sibling copy of the same persona keeps its look.
            stage.setPersonaShape(.circle, for: copyA)
            XCTAssertEqual(library.sessionState.instances.map(\.shape), [.circle, .card])
            XCTAssertEqual(stage.personaShape(of: copyA), .circle)
            // Nothing selected: no copy to change.
            library.performOverlayAction(.remove(b.id)); library.performOverlayAction(.remove(a.id))
            XCTAssertTrue(library.sessionState.selectedInstanceID == nil)
            XCTAssertTrue(stage.selectedPersonaCopy == nil, "A live set with nothing selected names no copy")
            // A copy captured in the first set is refused once the second set shows.
            library.performOverlayAction(.selectGroup(second))
            guard let other = library.sessionState.instances.first else { return }
            XCTAssertTrue(stage.personaShape(of: copyA) == nil, "The captured copy is not live in this set")
            stage.setPersonaShape(.original, for: copyA)
            XCTAssertEqual(library.sessionState.instances.first { $0.id == other.id }?.shape, .card, "Another set's copy is left alone")
            library.endOverlaySession()
        }
    }

    /// A copy whose look changes while its set is paused comes back where it
    /// was, centred as before, in its new look.
    func testPausedCopyReshapesAroundItsCentre() throws {
        guard let screen = screen() else { XCTAssertTrue(false, "The native check needs a display"); return }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try write(png(width: 300, height: 400), named: "portrait.png", in: root)
        var panels: [PersonaOverlayController] = []
        let library = PersonaLibrary(root: root.appendingPathComponent("library"), sessionPanelFactory: {
            let panel = PersonaOverlayController(pointer: PersonaTestPointer(), revealDelay: 0); panels.append(panel); return panel
        }, sessionHUDEnabled: false)
        defer { library.shutdown() }
        library.usesSharedControls = true
        let persona = try library.addImage(source, name: "Private name", card: PersonaCardStyle(label: "Site lead"))
        let group = try library.createGroup(name: "Private group", members: [persona.id])
        let item = PersonaOverlayItem(personaID: persona.id, placement: PersonaOverlayState(x: 0.4, y: 0.5, width: 0.16, screenID: displayID(screen), locked: true))
        try library.saveGroupLayout(group, overlays: [item], publicLabel: "Set")
        try library.startOverlaySession(groupIDs: [group], initialGroupID: group)
        guard let panel = panels.first, let before = panel.visibleFrame else { XCTAssertTrue(false, "The copy shows"); return }
        library.pauseOverlaySession()
        let menu = library.makeControlsMenu()
        XCTAssertTrue(menu.items.contains { $0.title == "Appearance" }, "Appearance stays available while paused")
        library.setLiveShape(.circle, for: .overlay(item.id, group: group))
        try library.resumeOverlaySession()
        guard let after = panel.visibleFrame else { return }
        XCTAssertEqual(Double(after.width / after.height), 1, accuracy: 0.01)
        XCTAssertEqual(Double(after.midX), Double(before.midX), accuracy: 1)
        XCTAssertEqual(Double(after.midY), Double(before.midY), accuracy: 1, file: #filePath, line: #line)
        XCTAssertEqual(Double(after.width), Double(before.width), accuracy: 1)
        XCTAssertTrue(panel.window?.ignoresMouseEvents == true, "Still locked")
        // VoiceOver's named moves take the arrow keys' step.
        let size = CGSize(width: 300, height: 400), closer = PersonaFraming(x: 0.5, y: 0.5, zoom: 2)
        XCTAssertTrue(PersonaFramingPreview.nudged(closer, .left, diameter: 240, portrait: size).x > 0.5, "Move left moves the picture left")
        XCTAssertTrue(PersonaFramingPreview.nudged(closer, .right, diameter: 240, portrait: size).x < 0.5)
        XCTAssertTrue(PersonaFramingPreview.nudged(closer, .up, diameter: 240, portrait: size).y < 0.5)
        XCTAssertTrue(PersonaFramingPreview.nudged(closer, .down, diameter: 240, portrait: size).y > 0.5)
    }

    // MARK: 5. Tall, wide, small and transparent artwork

    func testTallWideSmallAndTransparentArtworkAgreeWithTheirOutline() throws {
        guard let screen = screen() else { XCTAssertTrue(false, "The native check needs a display"); return }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, Data)] = [("tall", try png(width: 100, height: 300)), ("wide", try png(width: 300, height: 100)),
                                       ("small", try png(width: 12, height: 12)), ("badge", try png(width: 160, height: 160, badge: true))]
        for (name, data) in cases {
            guard let portrait = NSImage(data: data) else { XCTAssertTrue(false, "\(name) decodes"); continue }
            let circle = try PersonaCircleRenderer.image(portrait: portrait, framing: .centred)
            let side = min(portrait.size.width, portrait.size.height)
            XCTAssertEqual(Double(circle.size.width), Double(side), accuracy: 1, file: #filePath, line: #line)
            XCTAssertEqual(circle.size.width, circle.size.height)
            XCTAssertEqual(Double(alpha(circle, x: 0.01, y: 0.99)), 0, accuracy: 0.01)
            // The shape drawn and the shape the outline and handles follow agree.
            for (shape, image) in [(PersonaAppearance.Shape.circle, circle), (.card, try PersonaCardRenderer.image(portrait: portrait, style: PersonaCardStyle())), (.original, portrait)] {
                let controller = PersonaOverlayController(pointer: PersonaTestPointer(), revealDelay: 0)
                defer { controller.shutdown() }
                controller.setVoiceRing(true)
                controller.setOutline(shape.outline)
                _ = controller.show(image: image, name: "Synthetic", state: PersonaOverlayState(x: 0.5, y: 0.5, width: 0.16, screenID: displayID(screen), locked: true))
                guard let window = controller.window, let visible = controller.visibleFrame else { XCTAssertTrue(false, "\(name) \(shape.title) edge"); continue }
                switch shape {
                case .circle:
                    XCTAssertEqual(Double(visible.width / visible.height), 1, accuracy: 0.01)
                case .card:
                    XCTAssertEqual(Double(visible.height / visible.width), 1.25, accuracy: 0.01)
                case .original where name == "badge":
                    XCTAssertEqual(Double(visible.width / visible.height), 1, accuracy: 0.05, file: #filePath, line: #line)
                case .original:
                    XCTAssertEqual(Double(visible.width / visible.height), Double(portrait.size.width / portrait.size.height), accuracy: 0.05)
                }
                XCTAssertTrue(window.frame.contains(visible), "\(name) \(shape.title): the outline's room surrounds the visible edge")
                let frames = PersonaManipulation.frames(around: visible, within: screen.visibleFrame)
                XCTAssertTrue(frames[.move].map { abs($0.midX - visible.midX) < 1 } ?? false, "\(name) \(shape.title): the grab handle is centred on the visible edge")
            }
        }
    }

    // MARK: The frozen deck keys images by look

    func testDeckKeepsTheShownLookUntilTheNewOneIsReady() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try png(width: 200, height: 200)
        let persona = SavedPersona(name: "Synthetic", image: "persona-\(UUID().uuidString).png", card: PersonaCardStyle(label: "Lead"))
        try data.write(to: root.appendingPathComponent(persona.image))
        let library = PersonaLibrary(root: root); defer { library.shutdown() }
        let render: (SavedPersona) -> NSImage? = { library.renderedImage(for: $0) }
        let deck = PersonaCardDeck(candidates: [persona], root: root, budget: 64 * 1024 * 1024, label: { $0.card?.label ?? "Floating persona" })
        let card = try deck.image(for: persona.id, shown: nil, render: render); deck.didShow(persona.id)
        XCTAssertEqual(card.size, PersonaCardRenderer.size)
        XCTAssertTrue(try deck.image(for: persona.id, shown: persona.id, render: render) === card, "The same look is kept")
        let circle = try deck.image(for: persona.id, shown: persona.id, shape: .circle, render: render)
        XCTAssertFalse(circle === card, "Another shape is another image")
        XCTAssertEqual(circle.size.width, circle.size.height)
        XCTAssertEqual(deck.looks[persona.id]?.shape, .circle)
        XCTAssertEqual(deck.images.count, 1, "The old look is released once the new one is ready")
        // Too little room for both looks at once: the shown look stays.
        let tight = PersonaCardDeck(candidates: [persona], root: root, budget: (PersonaCardDeck.decodedBytes(ofImageAt: root.appendingPathComponent(persona.image), card: true) ?? 0) + 1,
                                    label: { _ in "Lead" })
        let kept = try tight.image(for: persona.id, shown: nil, render: render); tight.didShow(persona.id)
        XCTAssertThrowsError(try tight.image(for: persona.id, shown: persona.id, shape: .circle, render: render))
        XCTAssertTrue(tight.images[persona.id] === kept, "A look that does not fit leaves the shown one")
        XCTAssertFalse(tight.unavailable.contains(persona.id), "The shown card is not skipped by Next")
        XCTAssertTrue((PersonaCardDeck.decodedBytes(ofImageAt: root.appendingPathComponent(persona.image), appearance: PersonaAppearance(shape: .circle)) ?? 0)
                      > (PersonaCardDeck.decodedBytes(ofImageAt: root.appendingPathComponent(persona.image), appearance: PersonaAppearance(shape: .original)) ?? .max))
    }

    // MARK: Scenes

    /// Placing a Circle in a scene places the circle as shown, without card
    /// values a later edit could redraw; a Card keeps them.
    func testScenePlacementUsesTheChosenLook() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try write(png(width: 300, height: 400), named: "portrait.png", in: root)
        let model = DemoScenes(root: root.appendingPathComponent("store"), systemIntegrationEnabled: false)
        defer { model.shutdown() }
        try model.addImage(source, name: "Synthetic scene")
        guard let sceneID = model.selected?.id else { return }
        let draft = try model.personas.portraitDraft(from: source, card: PersonaCardStyle(label: "Site lead"))
        let persona = try model.personas.add(draft)
        model.usePersona(persona, in: sceneID)
        guard let scene = model.scenes.first(where: { $0.id == sceneID }), let placed = model.personaImage(for: scene) else {
            XCTAssertTrue(false, "The circle is placed in the scene"); return
        }
        XCTAssertEqual(placed.size.width, placed.size.height, "The scene gets the circle as shown")
    }

    // MARK: Renders

    /// Set WORKBENCH_LAYOUT_EVIDENCE to render Circle, Card and Original with the
    /// voice outline and handles, over a light slide and a dark editor, and the
    /// editor and workspace in light and dark.
    func testOffscreenAppearanceRenders() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"], let screen = screen() else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let starters = PersonaStarterLibrary(directory: repo.appendingPathComponent("Resources/PersonaPortraits"))
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonaLibrary(root: root.appendingPathComponent("library"), sessionHUDEnabled: false)
        defer { library.shutdown() }
        library.usesSharedControls = true
        var draft = try starters.draft(PersonaStarterLibrary.portraits[0], for: library)
        draft.card = PersonaCardStyle(label: "Care lead", background: InkColor(0.08, 0.38, 0.31))
        let persona = try library.add(draft)
        let badge = try write(png(width: 240, height: 240, badge: true), named: "badge.png", in: root)
        let finished = try library.addImage(badge, name: "Synthetic badge")

        // The floating artwork in each look, locked, voice outline on, handles shown.
        for (name, shape, item) in [("circle", PersonaAppearance.Shape.circle, persona), ("card", .card, persona), ("original", .original, persona),
                                    ("original-transparent", .original, finished), ("circle-transparent", .circle, finished)] {
            var look = item; var appearance = look.effectiveAppearance; appearance.shape = shape; look.appearance = appearance
            guard let image = library.renderedImage(for: look) else { continue }
            let pointer = PersonaTestPointer()
            let controller = PersonaOverlayController(pointer: pointer, revealDelay: 0)
            defer { controller.shutdown() }
            controller.setVoiceRing(true)
            controller.setOutline(shape.outline)
            _ = controller.show(image: image, name: "Care lead", state: PersonaOverlayState(x: 0.5, y: 0.5, width: 0.16, screenID: displayID(screen), locked: true))
            guard let window = controller.window, let visible = controller.visibleFrame else { continue }
            pointer.move(to: CGPoint(x: visible.maxX + 8, y: visible.midY))
            let handles = controller.handleWindows
            let area = handles.values.reduce(window.frame) { $0.union($1.frame) }.insetBy(dx: -24, dy: -24)
            let scale: CGFloat = 2
            guard let context = CGContext(data: nil, width: Int(area.width * scale), height: Int(area.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: area.width / 2, height: area.height))
            context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); context.fill(CGRect(x: area.width / 2, y: 0, width: area.width / 2, height: area.height))
            for drawn in [window] + PersonaHandle.allCases.compactMap({ handles[$0] }) {
                guard let layer = drawn.contentView?.layer else { continue }
                drawn.contentView?.layoutSubtreeIfNeeded()
                context.saveGState()
                context.translateBy(x: drawn.frame.minX - area.minX, y: drawn.frame.minY - area.minY)
                layer.render(in: context)
                context.restoreGState()
            }
            guard let rendered = context.makeImage(), let data = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else { continue }
            let url = directory.appendingPathComponent("persona-look-\(name).png")
            try data.write(to: url)
            print("Offscreen persona look: " + url.path)
        }

        // Every bundled starter in its curated Circle framing, on light and dark.
        let side = 180, columns = PersonaStarterLibrary.portraits.count
        if let sheet = CGContext(data: nil, width: side * columns, height: side * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            sheet.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); sheet.fill(CGRect(x: 0, y: 0, width: side * columns, height: side))
            sheet.setFillColor(NSColor.white.cgColor); sheet.fill(CGRect(x: 0, y: side, width: side * columns, height: side))
            for (index, starter) in PersonaStarterLibrary.portraits.enumerated() {
                guard let chosen = try? starters.draft(starter, for: library), let image = try? chosen.image(),
                      let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                for row in 0..<2 { sheet.draw(bitmap, in: CGRect(x: index * side + 6, y: row * side + 6, width: side - 12, height: side - 12)) }
            }
            if let made = sheet.makeImage(), let data = NSBitmapImageRep(cgImage: made).representation(using: .png, properties: [:]) {
                try data.write(to: directory.appendingPathComponent("persona-starters-circle.png"))
            }
        }

        // The editor for a new portrait and for a saved persona, and the workspace, light and dark.
        defer { renderIn(nil) }
        for theme in ["light", "dark"] {
            renderIn(theme == "dark" ? "Dark" : "Light")
            try MainActor.assumeIsolated {
                var circle = draft; circle.appearance.shape = .circle
                try render(PersonaCardEditor(library: library, session: PersonaEditorSession(.new(circle))), to: directory.appendingPathComponent("persona-editor-new-circle-\(theme).png"))
                var card = draft; card.appearance.shape = .card
                try render(PersonaCardEditor(library: library, session: PersonaEditorSession(.new(card))), to: directory.appendingPathComponent("persona-editor-new-card-\(theme).png"))
                try render(PersonaCardEditor(library: library, session: PersonaEditorSession(.saved(finished))), to: directory.appendingPathComponent("persona-editor-saved-original-\(theme).png"))
                library.selectedID = persona.id
                try render(PersonaLibraryView(library: library, mode: .workspace).frame(width: 834, height: 730),
                           to: directory.appendingPathComponent("persona-workspace-\(theme).png"))
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
        print("Offscreen persona appearance: " + url.path)
    }
}
