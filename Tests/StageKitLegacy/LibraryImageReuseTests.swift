import AppKit
import SwiftUI

/// Exercises the actual preparation owners with temporary files and fake Persona
/// display objects. No native overlay, capture, provider, or wallpaper is started.
final class LibraryImageReuseTests {
    private final class Display: PersonaSessionDisplaying {
        var onPlacementChange: ((PersonaOverlayState) -> Void)?
        var onSelection: (() -> Void)?
        var frame: CGRect? = CGRect(x: 0, y: 0, width: 80, height: 100)
        var shown = 0
        var image: NSImage?
        func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState { shown += 1; self.image = image; return state }
        func configure(image: NSImage, name: String, state: PersonaOverlayState) { self.image = image }
        func hide() {}
        func shutdown() {}
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryImageReuse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func picture(_ color: NSColor) throws -> Data {
        let image = NSImage(size: CGSize(width: 100, height: 80), flipped: false) { rect in color.setFill(); rect.fill(); return true }
        return try PersonaCardRenderer.png(image)
    }
    private func files(_ root: URL) throws -> [String: Data] {
        let root = root.standardizedFileURL
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let file as URL in enumerator where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            files[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
        }
        return files
    }
    func testScenePreparationCancelCreateAndReplace() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = DemoScenes(root: root, systemIntegrationEnabled: false)
        defer { model.shutdown() }
        var starts = 0; model.onBeginPresentation = { starts += 1 }
        let original = try picture(.systemTeal), candidate = try picture(.systemOrange)
        let before = try files(root)
        let decoded = try BackdropImage.decode(original)
        XCTAssertEqual(model.scenes.count, 0)
        XCTAssertEqual(try files(root), before, "Opening/cancelling first-scene preparation writes no image or record")
        try model.addImage(decoded, name: "Library first scene")
        XCTAssertEqual(model.scenes.count, 1); XCTAssertEqual(model.selected?.name, "Library first scene")
        let scene = model.selected!
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(scene.background)), original)
        XCTAssertEqual(starts, 0); XCTAssertFalse(model.isPresenting)
        let afterCreate = try files(root), selection = model.selectedID
        let draft = try model.makeBackdropReplacement(sceneID: scene.id, image: BackdropImage.decode(candidate), title: "Library second image")
        XCTAssertEqual(draft.candidate?.image.data, candidate)
        draft.x = 0.3; draft.zoom = 1.2
        XCTAssertEqual(try files(root), afterCreate)
        XCTAssertEqual(model.selectedID, selection); XCTAssertEqual(starts, 0)
        draft.cancel()
        XCTAssertThrowsError(try model.applyBackdrop(draft))
        XCTAssertEqual(try files(root), afterCreate)
        let confirmed = try model.makeBackdropReplacement(sceneID: scene.id, image: BackdropImage.decode(candidate), title: "Library second image")
        try model.applyBackdrop(confirmed)
        XCTAssertEqual(model.scenes.count, 1); XCTAssertEqual(model.selectedID, selection)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(model.selected!.background)), candidate)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(scene.background)), original)
        XCTAssertEqual(starts, 0, "Prepare/Create/Use backdrop never invoke Present")
        XCTAssertFalse(model.isPresenting)
        let preserved = try files(root)
        XCTAssertThrowsError(try BackdropImage.decode(Data("invalid image".utf8)))
        XCTAssertEqual(try files(root), preserved)
        let blocked = DemoScenes(root: root, readOnlyReason: "Synthetic unavailable library", systemIntegrationEnabled: false)
        XCTAssertThrowsError(try blocked.addImage(decoded, name: "Not saved"))
        XCTAssertEqual(try files(root), preserved, "Failed Create scene leaves originals and library bytes intact")
    }
    func testPersonaPreparationCancelAndAddPreserveLiveCopies() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var displays: [Display] = []
        let library = PersonaLibrary(root: root, sessionPanelFactory: { let display = Display(); displays.append(display); return display }, sessionHUDEnabled: false)
        defer { library.shutdown() }
        let bytes = try picture(.systemTeal)
        let existing = try library.add(library.portraitDraft(imageData: bytes, name: "Shown persona"))
        let group = try library.createGroup(name: "Prepared group", members: [existing.id])
        try library.saveGroupLayout(group, overlays: [PersonaOverlayItem(personaID: existing.id), PersonaOverlayItem(personaID: existing.id)], publicLabel: "Prepared group")
        try library.startOverlaySession(groupIDs: [group], initialGroupID: group, softReveal: false)
        library.performOverlayAction(.visible(library.sessionState.instances[0].id, false))
        library.performOverlayAction(.position(library.sessionState.instances[1].id, 0.2, 0.7))
        let visibility = library.sessionState.instances.map(\.visible)
        let placements = library.sessionState.instances.map(\.placement), identities = library.sessionState.instances.map(\.id)
        let images = displays.compactMap(\.image)
        let calls = displays.map(\.shown), previous = try files(root), selected = library.selectedID, groups = library.groups
        let draft = try library.portraitDraft(imageData: picture(.systemOrange), name: "Reusable portrait")
        let editor = PersonaEditorSession(.new(draft)); editor.style.label = "Prepared only"
        XCTAssertEqual(try files(root), previous); XCTAssertEqual(library.selectedID, selected); XCTAssertEqual(library.groups, groups)
        editor.cancel()
        XCTAssertEqual(try files(root), previous, "Cancel adds no persona, group member, image or selection")
        XCTAssertEqual(library.sessionState.instances.map(\.id), identities)
        XCTAssertEqual(library.sessionState.instances.map(\.placement), placements)
        XCTAssertEqual(displays.map(\.shown), calls)
        XCTAssertThrowsError(try library.portraitDraft(imageData: Data("invalid image".utf8), name: "Bad image"))
        XCTAssertEqual(try files(root), previous)
        let commit = PersonaEditorSession(.new(draft))
        XCTAssertTrue(commit.commit(to: library))
        XCTAssertEqual(library.items.count, 2); XCTAssertEqual(library.selectedID, draft.id)
        XCTAssertTrue(library.groups.first(where: { $0.id == group })!.personaIDs.contains(draft.id))
        XCTAssertEqual(library.sessionState.phase, .active)
        XCTAssertEqual(library.sessionState.instances.map(\.id), identities)
        XCTAssertEqual(library.sessionState.instances.map(\.placement), placements)
        XCTAssertEqual(library.sessionState.instances.map(\.visible), visibility, "Add persona cannot reveal a hidden copy")
        XCTAssertEqual(displays.count, identities.count, "Add persona does not create another display")
        XCTAssertTrue(zip(images, displays.compactMap(\.image)).allSatisfy { $0 === $1 }, "The shown copy keeps the same frozen image")
        XCTAssertEqual(library.sessionState.candidates.map(\.id), [existing.id], "The live session keeps its frozen candidates")
        XCTAssertTrue(commit.commit(to: library)); XCTAssertEqual(library.items.count, 2)
    }
    @MainActor func renderPreparationViews() throws {
        guard let path = ProcessInfo.processInfo.environment["WORKBENCH_LIBRARY_RENDER_DIR"] else { return }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = DemoScenes(root: root, systemIntegrationEnabled: false)
        defer { model.shutdown() }
        let bytes = try picture(.systemTeal), image = try BackdropImage.decode(bytes)
        let persona = try model.personas.portraitDraft(imageData: bytes, name: "Synthetic portrait")
        let views: [(String, AnyView, CGSize)] = [
            ("library-first-scene", AnyView(PhotoBackdropChooser(model: model, image: image, title: "Synthetic Library image")), CGSize(width: 840, height: 660)),
            ("library-persona-editor", AnyView(PersonaCardEditor(library: model.personas, session: PersonaEditorSession(.new(persona)))), CGSize(width: 640, height: 660))
        ]
        for (name, content, size) in views {
            let view = NSHostingView(rootView: content.environment(\.colorScheme, .light))
            view.frame = NSRect(origin: .zero, size: size); view.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view; window.displayIfNeeded(); view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15)); view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
    }
}
