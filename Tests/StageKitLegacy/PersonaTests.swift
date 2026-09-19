import AppKit
import SceneSyncKit
import ImageIO
import UniformTypeIdentifiers

final class PersonaTests {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func fixture() throws -> Data {
        let context = CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8, bytesPerRow: 160,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        context.clear(CGRect(x: 15, y: 30, width: 10, height: 20))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw PersonaError.unreadableImage }
        return data as Data
    }

    func testGeometryBoundsAndValidation() throws {
        for image in [CGSize(width: 300, height: 100), CGSize(width: 100, height: 800), CGSize(width: 1, height: 1)] {
            for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 800, height: 1600), CGSize(width: 1, height: 1)] {
                for x in [0.0, 0.5, 1.0] {
                    for y in [0.0, 0.5, 1.0] {
                        let placement = PersonaPlacement(image: "persona.png", x: x, y: y, width: 0.4)
                        let rect = PersonaGeometry.rect(placement, imageSize: image, in: canvas)
                        XCTAssertTrue(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= canvas.width + 1e-8 && rect.maxY <= canvas.height + 1e-8)
                        XCTAssertTrue(rect.width <= canvas.width * 0.4 + 1e-8 && rect.height <= canvas.height * 0.6 + 1e-8)
                        XCTAssertEqual(rect.width / rect.height, image.width / image.height, accuracy: 1e-8)
                        if y == 1 { XCTAssertEqual(rect.maxY, canvas.height, accuracy: 1e-8) }
                    }
                }
            }
        }
        for path in ["../persona.png", "/persona.png", "folder\\persona.png", ".hidden.png", "persona.svg", "", "bad\0.png"] {
            XCTAssertThrowsError(try PersonaPlacement(image: path).validated())
        }
        XCTAssertThrowsError(try PersonaPlacement(image: "persona.png", x: .nan).validated())
        let clamped = try PersonaPlacement(image: "persona.png", x: -2, y: 8, width: 3).validated()
        XCTAssertEqual(clamped.x, 0); XCTAssertEqual(clamped.y, 1); XCTAssertEqual(clamped.width, 0.4)
        XCTAssertEqual(PersonaGeometry.rect(clamped, imageSize: .zero, in: CGSize(width: 100, height: 100)), .zero)
        let defensive = PersonaGeometry.rect(PersonaPlacement(image: "persona.png", x: .nan, y: .infinity, width: .nan),
                                             imageSize: CGSize(width: 300, height: 100), in: CGSize(width: 800, height: 600))
        XCTAssertTrue([defensive.minX, defensive.minY, defensive.width, defensive.height].allSatisfy(\.isFinite))
    }

    func testDurableImportSeparatePlacementAndRemoval() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Operations leader.png"); try fixture().write(to: source)
        let store = root.appendingPathComponent("store")
        let library = PersonaLibrary(root: store)
        let item = try library.addImage(source)
        XCTAssertEqual(library.items, [item]); XCTAssertEqual(library.selectedID, item.id)
        XCTAssertTrue(item.image.hasPrefix("persona-") && item.image.hasSuffix(".png"))
        XCTAssertFalse(library.overlayVisible)
        library.setOverlayWidth(0.32); library.setOverlayLocked(true)
        library.setOverlayPosition(x: 0.02, y: 0.98)
        let scenePlacement = PersonaPlacement(image: item.image, x: 0.1, y: 0.9, width: 0.12)
        try FileManager.default.removeItem(at: source)
        let reopened = PersonaLibrary(root: store)
        XCTAssertFalse(reopened.overlayVisible, "A persisted card must never reopen over another app on launch")
        XCTAssertTrue(reopened.overlayLocked); XCTAssertEqual(reopened.overlayWidth, 0.32)
        let savedPosition = try JSONDecoder().decode(PersonaOverlayState.self, from: Data(contentsOf: store.appendingPathComponent("persona-overlay.json")))
        XCTAssertEqual(savedPosition.x, 0.02); XCTAssertEqual(savedPosition.y, 0.98)
        XCTAssertEqual(scenePlacement.width, 0.12)
        XCTAssertNotNil(reopened.image(named: item.image))
        let image = reopened.image(named: item.image)!
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        XCTAssertEqual(Double(bitmap.colorAt(x: 20, y: 40)!.alphaComponent), 0, accuracy: 0.001)
        reopened.rename(item.id, name: "Edited persona")
        XCTAssertEqual(reopened.selected?.name, "Edited persona")
        reopened.remove(item.id)
        XCTAssertTrue(reopened.items.isEmpty)
        XCTAssertTrue(reopened.image(named: item.image) != nil, "Scenes can still reference removed library entries")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(item.image).path))
        XCTAssertTrue(reopened.image(named: "../Operations leader.png") == nil)
    }

    func testCorruptFutureAndConcurrentArchivesStayUntouched() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("persona.png"); try fixture().write(to: source)
        let item = SavedPersona(name: "Saved", image: "persona.png")
        let invalidArchives = [Data("not json".utf8),
            try JSONEncoder().encode(PersonaArchive(version: 999, items: [], selectedID: nil)),
            try JSONEncoder().encode(PersonaArchive(items: [item, item], selectedID: item.id)),
            try JSONEncoder().encode(PersonaArchive(items: [item], selectedID: UUID()))]
        for invalid in invalidArchives {
            let store = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            let archive = store.appendingPathComponent("persona-library.json"); try invalid.write(to: archive)
            let library = PersonaLibrary(root: store)
            XCTAssertTrue(library.isReadOnly); XCTAssertThrowsError(try library.addImage(source))
            library.remove(item.id); library.rename(item.id, name: "Changed")
            XCTAssertEqual(try Data(contentsOf: archive), invalid)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), ["persona-library.json"])
        }
        let store = root.appendingPathComponent("changed")
        let library = PersonaLibrary(root: store); _ = try library.addImage(source)
        let archive = store.appendingPathComponent("persona-library.json")
        let invalid = Data("external edit".utf8); try invalid.write(to: archive)
        let before = try FileManager.default.contentsOfDirectory(atPath: store.path).sorted()
        XCTAssertThrowsError(try library.addImage(source))
        XCTAssertEqual(try Data(contentsOf: archive), invalid)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path).sorted(), before, "A failed commit must remove only its new unreferenced PNG")
        let overlay = store.appendingPathComponent("persona-overlay.json"); try invalid.write(to: overlay)
        let blocked = PersonaLibrary(root: store)
        blocked.setOverlayWidth(0.25)
        XCTAssertEqual(try Data(contentsOf: overlay), invalid)

        let linkedStore = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linkedStore, withIntermediateDirectories: true)
        let link = linkedStore.appendingPathComponent("persona-library.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("absent-target"))
        let linked = PersonaLibrary(root: linkedStore)
        XCTAssertTrue(linked.isReadOnly); XCTAssertThrowsError(try linked.addImage(source))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), root.appendingPathComponent("absent-target").path)
    }

    func testSceneAttachmentTransparencyAndMissingFile() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("persona.png"); try fixture().write(to: source)
        let model = DemoScenes(root: root.appendingPathComponent("store"), systemIntegrationEnabled: false)
        try model.addImage(source, name: "First scene"); let firstID = model.selected!.id
        try model.addImage(source, name: "Second scene"); let secondID = model.selected!.id
        let persona = try model.personas.addImage(source)
        model.usePersona(persona, in: firstID)
        XCTAssertNotNil(model.scenes.first { $0.id == firstID }?.persona)
        XCTAssertTrue(model.scenes.first { $0.id == secondID }?.persona == nil, "A chooser must attach to its captured scene ID")
        var scene = model.scenes.first { $0.id == firstID }!
        scene.showsPhone = false; scene.persona?.x = 0.5; scene.persona?.y = 0.5; scene.persona?.width = 0.4
        XCTAssertTrue(model.update(scene)); scene = model.scenes.first { $0.id == firstID }!
        let roundTrip = DemoScenes(root: model.root, systemIntegrationEnabled: false)
        XCTAssertEqual(roundTrip.scenes.first { $0.id == firstID }?.persona, scene.persona)
        model.personas.remove(persona.id)
        XCTAssertNotNil(model.personaImage(for: scene))
        let background = NSImage(size: CGSize(width: 300, height: 200), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let output = try model.renderPNG(scene, image: background, size: CGSize(width: 300, height: 200))
        let bitmap = NSBitmapImageRep(data: output)!
        let center = bitmap.colorAt(x: 150, y: 100)!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(center.redComponent, 0.95, "The persona's transparent hole must show the scene below")
        let edge = bitmap.colorAt(x: 130, y: 100)!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(edge.blueComponent, 0.95, "The saved persona must be included in the exported scene")
        try FileManager.default.removeItem(at: model.root.appendingPathComponent(persona.image))
        XCTAssertTrue(model.personaImage(for: scene) != nil, "Removing the library source cannot break an independently placed scene")
        let cache = model.root.appendingPathComponent(scene.persona!.image)
        try FileManager.default.removeItem(at: cache)
        let recovered = DemoScenes(root: model.root, systemIntegrationEnabled: false)
        XCTAssertTrue(recovered.personaImage(for: scene) != nil, "A missing cache is recreated from canonical bytes")
        let asset = MainActor.assumeIsolated { recovered.sceneSync!.library.records.first { $0.id == firstID }!.scene.persona!.image }
        let assetURL = try MainActor.assumeIsolated { try recovered.sceneSync!.library.assetURL(asset) }
        try FileManager.default.removeItem(at: assetURL); try FileManager.default.removeItem(at: cache)
        let missing = DemoScenes(root: model.root, systemIntegrationEnabled: false)
        XCTAssertTrue(missing.personaImage(for: scene) == nil)
        XCTAssertThrowsError(try missing.renderPNG(scene, image: background, size: CGSize(width: 300, height: 200)))
        XCTAssertTrue(missing.scenes.contains { $0.id == firstID }); XCTAssertNotNil(missing.notice)
        let legacy = try JSONEncoder().encode(DemoScene(background: "old.png"))
        XCTAssertTrue(try JSONDecoder().decode(DemoScene.self, from: legacy).persona == nil)
    }

    func testLegacyMigrationKeepsFinishedPixelsAndRequiresExplicitGroup() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let item = SavedPersona(name: "Private legacy customer", image: "finished.png")
        let original = try fixture(); try original.write(to: root.appendingPathComponent(item.image))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1,
            "items": [["id": item.id.uuidString, "name": item.name, "image": item.image]], "selectedID": item.id.uuidString])
        let url = root.appendingPathComponent("persona-library.json"); try data.write(to: url)
        let library = PersonaLibrary(root: root)
        XCTAssertFalse(library.isReadOnly); XCTAssertTrue(library.groups.isEmpty)
        XCTAssertTrue(library.activeGroupID == nil); XCTAssertTrue(library.liveSelection == nil)
        XCTAssertFalse(library.overlayVisible); XCTAssertEqual(library.selectedID, item.id)
        XCTAssertTrue(library.items[0].card == nil)
        XCTAssertEqual(try library.renderedPNG(for: library.items[0]), original)
        XCTAssertEqual(try Data(contentsOf: url), data, "Opening v1 must not write a migration or create an all-library group")
        library.rename(item.id, name: "Renamed privately")
        let reopened = PersonaLibrary(root: root)
        XCTAssertEqual(reopened.items[0].name, "Renamed privately")
        XCTAssertTrue(reopened.groups.isEmpty); XCTAssertFalse(reopened.overlayVisible)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(item.image)), original)
        XCTAssertEqual(try JSONDecoder().decode(PersonaArchive.self, from: Data(contentsOf: url)).version, 2)
    }

    func testOrderedGroupsAndDeletionNeverSelectAnotherCustomer() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("portrait.png"); try fixture().write(to: source)
        let store = root.appendingPathComponent("library"), library = PersonaLibrary(root: root.appendingPathComponent("library"))
        let a = try library.addImage(source), b = try library.addImage(source), other = try library.addImage(source)
        let alpha = try library.createGroup(name: "Private Alpha", members: [b.id, a.id])
        let beta = try library.createGroup(name: "Private Beta", members: [other.id])
        library.prepareGroup(alpha)
        XCTAssertEqual(library.visibleItems.map(\.id), [b.id, a.id]); XCTAssertEqual(library.selectedID, b.id)
        library.moveMember(a.id, by: -1); library.renameGroup(alpha, name: "Renamed Alpha")
        XCTAssertEqual(library.activeGroup?.personaIDs, [a.id, b.id])
        XCTAssertEqual(library.activeGroup?.id, alpha)
        let before = library.groups
        library.setGroupMembers([a.id, UUID()], in: alpha)
        XCTAssertEqual(library.groups, before); XCTAssertNotNil(library.notice)
        library.selectedID = a.id; library.remove(a.id)
        XCTAssertTrue(library.selectedID == nil, "Deletion must not select the first item in any group")
        XCTAssertEqual(library.activeGroup?.personaIDs, [b.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(a.image).path))
        library.removeGroup(alpha)
        XCTAssertTrue(library.activeGroupID == nil); XCTAssertTrue(library.selectedID == nil)
        XCTAssertEqual(library.groups.map(\.id), [beta]); XCTAssertEqual(library.items.map(\.id), [b.id, other.id])
        let reopened = PersonaLibrary(root: store)
        XCTAssertEqual(reopened.groups, library.groups); XCTAssertTrue(reopened.activeGroupID == nil)
        XCTAssertFalse(reopened.overlayVisible)
    }

    func testLiveCandidatesRemainScopedAndHUDLabelsExcludePrivateNames() throws {
        let a = UUID(), b = UUID(), other = UUID()
        var group = PersonaGroup(name: "Secret customer", personaIDs: [a, b])
        var session = PersonaLiveSelection(group: group, selectedID: a)
        session.select(other); XCTAssertEqual(session.currentID, a)
        session.step(1); XCTAssertEqual(session.currentID, b)
        session.step(1); XCTAssertEqual(session.currentID, a)
        session.step(-1); XCTAssertEqual(session.currentID, b)
        group.personaIDs = [b, other, a]
        session.reconcile(group: group, existingIDs: [a, b, other])
        XCTAssertEqual(session.candidateIDs, [a, b], "A new or reordered library member must not silently enter a live session")
        session.select(a); group.personaIDs = [b, other]
        session.reconcile(group: group, existingIDs: [a, b, other])
        XCTAssertTrue(session.currentID == nil); XCTAssertEqual(session.candidateIDs, [b])
        session.step(1); XCTAssertTrue(session.currentID == nil, "No automatic fallback after current removal")
        session.reconcile(group: nil, existingIDs: [a, b, other]); XCTAssertTrue(session.candidateIDs.isEmpty)
        let legacy = SavedPersona(name: "DO NOT SHOW Customer A", image: "portrait.png")
        XCTAssertEqual(PersonaHUDItem.make(persona: legacy, ordinal: 2, image: nil).label, "Persona 2")
        var editable = legacy; editable.card = PersonaCardStyle(label: "Site manager")
        XCTAssertEqual(PersonaHUDItem.make(persona: editable, ordinal: 1, image: nil).label, "Site manager")
    }

    func testEditableCardRenderingAndSaveFailurePreserveSources() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("portrait.png"), original = try fixture()
        try original.write(to: source)
        let store = root.appendingPathComponent("library"), library = PersonaLibrary(root: root.appendingPathComponent("library"))
        let item = try library.addImage(source, card: PersonaCardStyle(label: "Site manager", background: InkColor(1, 1, 1)))
        // Existing import normalizes supported images to PNG. Editing must keep
        // that stored portrait and the caller's source intact, not re-import it.
        let storedPortrait = try Data(contentsOf: store.appendingPathComponent(item.image))
        let first = try library.renderedPNG(for: item)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let bitmap = NSBitmapImageRep(data: first)!
        XCTAssertEqual(bitmap.pixelsWide, 480); XCTAssertEqual(bitmap.pixelsHigh, 600)
        let corner = bitmap.colorAt(x: 0, y: 0)!
        XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(PersonaCardRenderer.labelColor(on: InkColor(1, 1, 1)), NSColor.black)
        XCTAssertEqual(PersonaCardRenderer.labelColor(on: InkColor(0, 0, 0)), NSColor.white)
        XCTAssertTrue(library.updateCard(item.id, style: PersonaCardStyle(label: "Operations lead", background: InkColor(0.2, 0.1, 0.1))))
        let changed = library.items[0], second = try library.renderedPNG(for: changed)
        XCTAssertFalse(first == second); XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: store.appendingPathComponent(item.image)), storedPortrait)
        let reopened = PersonaLibrary(root: store)
        XCTAssertEqual(reopened.items[0].card, changed.card)
        let archive = store.appendingPathComponent("persona-library.json"), external = Data("concurrent edit".utf8)
        try external.write(to: archive)
        XCTAssertFalse(reopened.updateCard(item.id, style: PersonaCardStyle(label: "Uncommitted")))
        XCTAssertEqual(reopened.items[0].card, changed.card)
        XCTAssertEqual(try Data(contentsOf: archive), external)
        XCTAssertThrowsError(try PersonaCardStyle(label: "two\nlines").validated())
        XCTAssertThrowsError(try PersonaCardStyle(label: String(repeating: "x", count: 81)).validated())
        XCTAssertThrowsError(try PersonaCardStyle(background: InkColor(.nan, 0, 0)).validated())
    }

    private func hudControls() -> (NSWindow, NSPopUpButton, NSPopUpButton, [NSButton])? {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let window = NSApp.windows.first(where: { $0.title == "Persona controls" && $0.isVisible }),
              let content = window.contentView else { return nil }
        let views = descendants(content)
        guard let picker = views.compactMap({ $0 as? NSPopUpButton }).first(where: { !$0.pullsDown }),
              let options = views.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.pullsDown }) else { return nil }
        return (window, picker, options, views.compactMap { $0 as? NSButton })
    }

    private func invoke(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { XCTAssertTrue(false, "Expected a native menu action"); return }
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
    }

    func testUngroupedHUDStaysScopedToDisplayedPersonaAndControlsItsLifecycle() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Private preparation name.png"); try fixture().write(to: source)
        let library = PersonaLibrary(root: root.appendingPathComponent("library")); defer { library.shutdown() }
        let first = try library.addImage(source)
        let second = try library.addImage(source, card: PersonaCardStyle(label: "Site manager"))
        library.selectedID = first.id
        let previousKey = NSApp.keyWindow, frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        library.showOverlay()
        XCTAssertTrue(library.overlayVisible)
        XCTAssertEqual(library.liveSelection?.candidateIDs, [first.id, second.id])
        guard let (window, picker, options, buttons) = hudControls() else {
            XCTAssertTrue(false, "An ungrouped displayed persona needs its own visible native controls"); return
        }
        XCTAssertTrue(NSApp.keyWindow === previousKey)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
        XCTAssertFalse(window.canBecomeKey); XCTAssertFalse(window.canBecomeMain)
        XCTAssertEqual(picker.itemTitles, ["Persona 1", "Site manager"], "Private library names must never become HUD labels")
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, first.id)
        XCTAssertTrue(picker.isEnabled)
        XCTAssertTrue(buttons.filter { $0.toolTip?.contains("available persona") == true }.allSatisfy(\.isEnabled))

        library.selectedID = second.id
        XCTAssertTrue(library.overlayVisible, "Browsing another item must keep the displayed persona and controls")
        XCTAssertEqual(library.selectedID, second.id)
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, first.id)
        library.stepQuickPersona(1)
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, second.id)
        library.stepQuickPersona(-1)
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, first.id)
        invoke(options.item(withTitle: "Lock artwork · clicks pass through"))
        XCTAssertTrue(library.overlayLocked)
        let oldWidth = library.overlayWidth
        invoke(options.item(withTitle: "Larger persona"))
        XCTAssertEqual(library.overlayWidth, oldWidth + 0.02, accuracy: 0.0001)
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, first.id)
        library.remove(second.id)
        XCTAssertTrue(library.overlayVisible, "Removing a browsed item must keep the original displayed item")
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, first.id)
        guard let hide = buttons.first(where: { $0.toolTip == "Hide persona and controls" }) else {
            XCTAssertTrue(false, "Expected the native Hide control"); return
        }
        hide.performClick(nil)
        XCTAssertFalse(library.overlayVisible); XCTAssertFalse(window.isVisible)
        library.selectedID = first.id
        library.toggleQuickPersona(); XCTAssertTrue(library.overlayVisible)
        library.toggleQuickPersona(); XCTAssertFalse(library.overlayVisible)
        library.showOverlay()
        XCTAssertTrue(window.isVisible)
        library.remove(first.id)
        XCTAssertFalse(library.overlayVisible); XCTAssertFalse(window.isVisible)

        // Prepared sessions retain their own frozen membership when preparation
        // selection changes or a new member is added after showing the artwork.
        let a = try library.addImage(source), b = try library.addImage(source), outside = try library.addImage(source)
        let group = try library.createGroup(name: "Private group", members: [a.id, b.id])
        library.showOverlay()
        library.selectedID = b.id
        library.setGroupMembers([a.id, b.id, outside.id], in: group)
        XCTAssertEqual(picker.itemArray.compactMap { $0.representedObject as? UUID }, [a.id, b.id])
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, a.id)
        library.selectLivePersona(outside.id)
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, a.id)
        library.stepLivePersona(1)
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, b.id)
        library.remove(b.id)
        XCTAssertFalse(library.overlayVisible); XCTAssertFalse(window.isVisible)
    }

    func testReadOnlyUngroupedHUDDoesNotPersistBrowsingOrPlacement() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("portrait.png"); try fixture().write(to: source)
        let store = root.appendingPathComponent("library"), seed = PersonaLibrary(root: root.appendingPathComponent("library"))
        let first = try seed.addImage(source), second = try seed.addImage(source)
        seed.selectedID = first.id; seed.shutdown()
        func storedFiles() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: store.path).map {
                ($0, try Data(contentsOf: store.appendingPathComponent($0)))
            })
        }
        let original = try storedFiles()
        let library = PersonaLibrary(root: store, readOnlyReason: "Synthetic read-only library"); defer { library.shutdown() }
        XCTAssertTrue(library.isReadOnly)
        library.showOverlay()
        guard let (window, picker, options, _) = hudControls() else {
            XCTAssertTrue(false, "Read-only browsing still needs working floating controls"); return
        }
        library.selectedID = second.id
        XCTAssertTrue(library.overlayVisible)
        XCTAssertEqual(picker.itemArray.compactMap { $0.representedObject as? UUID }, [first.id, second.id])
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, first.id)
        library.stepLivePersona(1)
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, second.id)
        invoke(options.item(withTitle: "Lock artwork · clicks pass through"))
        invoke(options.item(withTitle: "Larger persona"))
        invoke(options.item(withTitle: "Control position")?.submenu?.items.last)
        XCTAssertTrue(library.overlayLocked); XCTAssertEqual(library.overlayWidth, 0.18, accuracy: 0.0001)
        XCTAssertEqual(try storedFiles(), original, "Read-only HUD actions must not create position files or modify originals")
        library.hideOverlay(); XCTAssertFalse(window.isVisible)
        library.showOverlay()
        XCTAssertEqual(picker.itemArray.compactMap { $0.representedObject as? UUID }, [first.id, second.id])
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, second.id)
        library.selectedID = nil
        XCTAssertTrue(library.overlayVisible, "Clearing preparation selection must not discard the displayed item")
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, second.id)
        library.shutdown(); XCTAssertFalse(window.isVisible)
        XCTAssertEqual(try storedFiles(), original)
    }

    func testNativeOverlayWindowAndDragLifecycle() throws {
        let controller = PersonaOverlayController()
        defer { controller.shutdown() }
        guard let window = controller.window, let artwork = window.contentView,
              let screen = NSScreen.main ?? NSScreen.screens.first,
              let image = NSImage(data: try fixture()) else {
            XCTAssertTrue(false, "The native overlay test needs a display and its synthetic image")
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let previousKeyWindow = NSApp.keyWindow
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        var state = PersonaOverlayState(x: 0.5, y: 0.5, width: 0.10, screenID: displayID)
        var placements: [PersonaOverlayState] = []
        controller.onPlacementChange = { placements.append($0) }
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            // Deliver only to this synthetic panel. Nothing is posted to the
            // system event queue, so other apps never receive mouse input.
            NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func isOnScreen(_ frame: CGRect) -> Bool {
            NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(frame) }
        }

        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.canBecomeKey); XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.isOpaque); XCTAssertFalse(window.hasShadow)
        XCTAssertEqual(window.level, .floating)
        controller.configure(image: image, name: "Synthetic persona test", state: state)
        XCTAssertFalse(window.isVisible, "Configuring or resizing must not show a hidden persona")
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertTrue(isOnScreen(window.frame))
        let shown = controller.show(image: image, name: "Synthetic persona test", state: state)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isKeyWindow); XCTAssertFalse(window.isMainWindow)
        XCTAssertNotNil(shown.screenID)
        XCTAssertTrue(isOnScreen(window.frame))
        XCTAssertTrue(NSApp.keyWindow === previousKeyWindow, "Showing the persona must preserve the existing key window")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost,
                       "Showing a nonactivating persona must preserve the foreground application")

        let start = window.frame
        let anchor = CGPoint(x: start.midX, y: start.midY)
        let first = CGPoint(x: anchor.x + 18, y: anchor.y + 12)
        let second = CGPoint(x: anchor.x + 36, y: anchor.y + 24)
        let down = event(.leftMouseDown, at: anchor)
        XCTAssertTrue(artwork.acceptsFirstMouse(for: down))
        artwork.mouseDown(with: down)
        artwork.mouseDragged(with: event(.leftMouseDragged, at: first))
        artwork.mouseDragged(with: event(.leftMouseDragged, at: second))
        artwork.mouseUp(with: event(.leftMouseUp, at: second))
        XCTAssertEqual(placements.count, 1)
        XCTAssertEqual(window.frame.minX, start.minX + 36, accuracy: 1)
        XCTAssertEqual(window.frame.minY, start.minY + 24, accuracy: 1)
        XCTAssertTrue(isOnScreen(window.frame))
        guard let dragged = placements.last else { return }
        XCTAssertGreaterThan(dragged.x, state.x); XCTAssertGreaterThan(dragged.y, state.y)

        state = dragged; state.locked = true
        controller.configure(image: image, name: "Synthetic persona test", state: state)
        let lockedFrame = window.frame
        XCTAssertTrue(window.ignoresMouseEvents)
        artwork.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: lockedFrame.midX, y: lockedFrame.midY)))
        artwork.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: lockedFrame.midX + 60, y: lockedFrame.midY + 40)))
        artwork.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: lockedFrame.midX + 60, y: lockedFrame.midY + 40)))
        XCTAssertEqual(window.frame, lockedFrame, "Locked artwork must ignore even directly delivered drag events")
        XCTAssertEqual(placements.count, 1)

        state.locked = false
        controller.configure(image: image, name: "Synthetic persona test", state: state)
        XCTAssertFalse(window.ignoresMouseEvents)
        let edgeAnchor = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let outside = CGPoint(x: screen.visibleFrame.maxX + 500, y: screen.visibleFrame.maxY + 500)
        artwork.mouseDown(with: event(.leftMouseDown, at: edgeAnchor))
        artwork.mouseDragged(with: event(.leftMouseDragged, at: outside))
        artwork.mouseUp(with: event(.leftMouseUp, at: outside))
        XCTAssertEqual(placements.count, 2)
        XCTAssertTrue(isOnScreen(window.frame), "Ending an off-screen drag must clamp the card to an available display")
        XCTAssertTrue(placements.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        XCTAssertFalse(window.isKeyWindow); XCTAssertFalse(window.isMainWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
        controller.hide(); XCTAssertFalse(window.isVisible)
        controller.configure(image: image, name: "Synthetic persona test", state: state)
        XCTAssertFalse(window.isVisible)
        controller.shutdown(); XCTAssertFalse(window.isVisible)
        XCTAssertTrue(controller.onPlacementChange == nil)
    }
}
