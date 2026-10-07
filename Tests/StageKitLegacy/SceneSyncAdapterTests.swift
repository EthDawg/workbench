import AppKit
import AVFoundation
import SceneSyncKit
import ImageIO
import UniformTypeIdentifiers

final class SceneSyncAdapterTests {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneSyncAdapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func png(_ red: CGFloat = 0.2) -> Data {
        let context = CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 2, y: 2, width: 36, height: 76))
        let output = NSMutableData(); let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        return output as Data
    }
    func testMigrationRetainsEveryLayerAndNeverWritesLegacyAgain() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            var original = DemoScene(name: "Synthetic reception", background: "photo.png", backgroundX: 0.1, backgroundY: 0.9, zoom: 1.7,
                showsPhone: false, phoneX: 0.2, phoneY: 0.8, phoneHeight: 0.63,
                logo: SceneLogo(image: "logo.png", corner: .bottomLeft, width: 0.23, backing: .dark),
                viewport: DeviceViewport(aspect: 0.72, border: 0.016, corners: 0.08),
                hand: SceneHand(image: "hand.png", scale: 1.2, x: -0.2, y: 0.3, mirrored: true, tone: .deeper),
                persona: PersonaPlacement(image: "persona.png", x: 0.12, y: 0.66, width: 0.27))
            var originals: [String: Data] = [:]
            for (i, name) in ["photo.png", "logo.png", "hand.png", "persona.png"].enumerated() {
                let bytes = png(CGFloat(i) / 5); originals[name] = bytes; try bytes.write(to: root.appendingPathComponent(name))
            }
            let legacy = root.appendingPathComponent("scenes.json"); try SceneStorage.save([original], to: legacy)
            let oldBytes = try Data(contentsOf: legacy)
            let adapter = MacSceneSync(root: root, systemIntegrationEnabled: false)
            XCTAssertFalse(adapter.isBlocked); XCTAssertEqual(adapter.library.records.count, 1); XCTAssertFalse(adapter.library.isConfigured)
            let record = adapter.library.records[0], package = try adapter.library.package(for: record.scene)
            XCTAssertEqual(Set(package.assets.values), Set(originals.values))
            var translated = adapter.scenes[0]
            original.background = translated.background; original.logo?.image = translated.logo!.image
            original.hand?.image = translated.hand!.image; original.persona?.image = translated.persona!.image
            XCTAssertEqual(translated, original, "Every authored layout value must survive filename translation")
            translated.name = "Renamed locally"; try adapter.save(translated)
            XCTAssertEqual(try Data(contentsOf: legacy), oldBytes)
            for (name, bytes) in originals { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), bytes) }
            let reopened = MacSceneSync(root: root, systemIntegrationEnabled: false)
            XCTAssertEqual(reopened.scenes.count, 1); XCTAssertEqual(reopened.scenes[0].name, "Renamed locally")
            try reopened.remove(reopened.scenes[0])
            for name in originals.keys { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
            let afterDeletion = MacSceneSync(root: root, systemIntegrationEnabled: false)
            XCTAssertTrue(afterDeletion.scenes.isEmpty, "A migrated legacy ID must never resurrect after canonical deletion")
            XCTAssertTrue(afterDeletion.recoveryIDs.isEmpty); XCTAssertEqual(try Data(contentsOf: legacy), oldBytes)
        }
    }
    func testMissingLegacyAssetStaysVisibleAndRetryIsIdempotent() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let first = DemoScene(name: "Readable", background: "good.png"), second = DemoScene(name: "Needs picture", background: "missing.png")
            try png().write(to: root.appendingPathComponent("good.png"))
            let legacy = root.appendingPathComponent("scenes.json"); try SceneStorage.save([first, second], to: legacy)
            let bytes = try Data(contentsOf: legacy)
            let adapter = MacSceneSync(root: root, systemIntegrationEnabled: false)
            XCTAssertFalse(adapter.isBlocked); XCTAssertEqual(adapter.scenes.count, 2); XCTAssertEqual(adapter.library.records.count, 1)
            XCTAssertTrue(adapter.isReadOnly(second.id)); XCTAssertNotNil(adapter.migrationNotice)
            XCTAssertThrowsError(try adapter.remove(adapter.scenes.first { $0.id == second.id }!))
            try png(0.8).write(to: root.appendingPathComponent("missing.png")); adapter.migratePreviousScenes(); adapter.migratePreviousScenes()
            XCTAssertEqual(adapter.library.records.count, 2); XCTAssertTrue(adapter.recoveryIDs.isEmpty)
            XCTAssertEqual(try Data(contentsOf: legacy), bytes)
            let record = adapter.library.records[0], asset = record.scene.background
            let assetBytes = try Data(contentsOf: adapter.library.assetURL(asset))
            try FileManager.default.removeItem(at: adapter.library.assetURL(asset))
            adapter.migratePreviousScenes()
            XCTAssertTrue(adapter.scenes.contains { $0.id == record.id }, "A damaged canonical asset must not make its document disappear")
            XCTAssertTrue(adapter.unavailableAssetIDs.contains(record.id)); XCTAssertTrue(adapter.isReadOnly(record.id))
            _ = try adapter.library.importAsset(assetBytes)
            let cache = root.appendingPathComponent(MacSceneSync.materializedName(asset)), conflict = Data("existing unrelated bytes".utf8)
            try conflict.write(to: cache); adapter.migratePreviousScenes()
            XCTAssertEqual(try Data(contentsOf: cache), conflict, "Materialization must never replace an existing image")
            XCTAssertTrue(adapter.scenes.contains { $0.id == record.id }); XCTAssertTrue(adapter.unavailableAssetIDs.contains(record.id))
        }
    }
    func testMacEditsPreservePortableFieldsAndRejectStaleRevision() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let library = SceneLibraryModel(directory: root.appendingPathComponent("Portable"))
            let background = try library.importAsset(png()), fallback = try library.importAsset(png(0.8)), portrait = try library.importAsset(png(0.6))
            var scene = PortableScene(name: "Prepared on another device", background: background)
            scene.groupID = UUID(); scene.legacyMobileProject = Data("synthetic original collage".utf8)
            scene.persona = ScenePersonaLayer(image: fallback, x: 0.2, y: 0.7, width: 0.25)
            scene.persona?.card = SceneCardStyle(portrait: portrait, label: "Operations lead", red: 0.2, green: 0.3, blue: 0.4)
            _ = try library.create(scene)
            let adapter = MacSceneSync(root: root, systemIntegrationEnabled: false, library: library)
            let old = adapter.scenes[0]; var edit = old; edit.phoneX = 0.17; edit.persona?.width = 0.3
            try adapter.save(edit)
            XCTAssertEqual(library.records[0].scene.groupID, scene.groupID)
            XCTAssertEqual(library.records[0].scene.legacyMobileProject, scene.legacyMobileProject)
            XCTAssertEqual(library.records[0].scene.persona?.card, scene.persona?.card)
            XCTAssertEqual(library.records[0].scene.persona?.width, 0.3)
            let current = library.records[0]
            var stale = old; stale.name = "Stale edit"; XCTAssertThrowsError(try adapter.save(stale))
            XCTAssertEqual(library.records[0], current)
            let duplicate = try adapter.duplicate(adapter.scenes[0])
            XCTAssertEqual(library.records.first { $0.id == duplicate }?.scene.persona?.card, scene.persona?.card)
            try adapter.reorder([duplicate, scene.id])
            XCTAssertEqual(library.records.filter { !$0.isDeleted }.map(\.id), [duplicate, scene.id])
            XCTAssertThrowsError(try adapter.reorder([duplicate, duplicate]))
            let reopened = MacSceneSync(root: root, systemIntegrationEnabled: false)
            XCTAssertEqual(reopened.scenes.map(\.id), [duplicate, scene.id])
        }
    }
    func testMacEditKeepsOriginalMobileAttachmentsInPortablePackage() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let library = SceneLibraryModel(directory: root.appendingPathComponent("Portable"))
            let background = try library.importAsset(png())
            let attachmentBytes = [png(0.5), png(0.9)]
            let attachments = try attachmentBytes.map { try library.importAsset($0) }
            var original = PortableScene(name: "Original mobile composition", background: background)
            original.legacyMobileProject = Data("synthetic mobile project with two original attachments".utf8)
            original.retainedAssets = attachments
            _ = try library.create(original)
            let adapter = MacSceneSync(root: root, systemIntegrationEnabled: false, library: library)
            var edit = adapter.scenes[0]; edit.name = "Adjusted on Mac"; edit.phoneX = 0.23
            try adapter.save(edit)

            // The native renderer has no attachment fields. Saving its editable
            // projection must keep the originals that only mobile understands.
            let saved = library.records[0].scene
            XCTAssertEqual(saved.retainedAssets, attachments)
            XCTAssertEqual(saved.legacyMobileProject, original.legacyMobileProject)
            let package = try library.package(for: saved)
            XCTAssertEqual(Set(package.assets.keys), Set([background] + attachments))
            for (name, bytes) in zip(attachments, attachmentBytes) { XCTAssertEqual(package.assets[name], bytes) }
            let transferred = try JSONDecoder().decode(ScenePackage.self, from: JSONEncoder().encode(package)).validated()
            XCTAssertEqual(transferred, package)

            let reopened = MacSceneSync(root: root, systemIntegrationEnabled: false)
            XCTAssertEqual(reopened.scenes[0].name, "Adjusted on Mac")
            XCTAssertEqual(reopened.scenes[0].phoneX, 0.23)
            XCTAssertEqual(try reopened.library.package(for: reopened.library.records[0].scene), package)
        }
    }
    func testPersonaPlacementCopiesRenderedAndAuthoredValues() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.png"); try png().write(to: source)
            let model = DemoScenes(root: root, systemIntegrationEnabled: false)
            try model.addImage(source, name: "Synthetic demo")
            let persona = try model.personas.addImage(source, card: PersonaCardStyle(label: "Reception lead", background: InkColor(0.2, 0.4, 0.6)))
            model.usePersona(persona, in: model.selected!.id)
            let library = model.sceneSync!.library, record = library.records[0]
            XCTAssertEqual(record.scene.persona?.card?.label, "Reception lead")
            XCTAssertEqual(record.scene.persona?.card?.red, 0.2)
            XCTAssertTrue(record.scene.persona?.image != record.scene.persona?.card?.portrait)
            let package = try library.package(for: record.scene)
            XCTAssertTrue(model.personas.updateCard(persona.id, style: PersonaCardStyle(label: "Later library label")))
            model.personas.remove(persona.id)
            XCTAssertEqual(try library.package(for: library.records[0].scene), package)
            XCTAssertNotNil(model.personaImage(for: model.selected!))
            let reopened = DemoScenes(root: root, systemIntegrationEnabled: false)
            XCTAssertEqual(reopened.sceneSync!.library.records[0].scene, record.scene)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scenes.json").path), "New installs must never create the old writable manifest")
        }
    }
    func testBackdropUsesCurrentForegroundAndConcurrentStoreFailureKeepsOriginals() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.png"), replacement = root.appendingPathComponent("replacement.png")
            try png().write(to: source); try png(0.8).write(to: replacement)
            let model = DemoScenes(root: root, systemIntegrationEnabled: false); try model.addImage(source, name: "Before")
            let draft = BackdropReplacement(scene: model.selected!, root: root); try draft.chooseImage(replacement)
            var newer = model.selected!; newer.name = "Later name"; newer.phoneX = 0.21; XCTAssertTrue(model.update(newer))
            try model.applyBackdrop(draft)
            XCTAssertEqual(model.selected?.name, "Later name"); XCTAssertEqual(model.selected?.phoneX, 0.21)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(model.selected!.background)), png(0.8))
            let library = model.sceneSync!.library, store = SceneLibraryStore(directory: library.directory)
            var external = try store.load(); external.records[0].scene.name = "External owner"; external.records[0].revision = UUID(); try store.save(external)
            let before = try Data(contentsOf: store.manifest), current = model.selected!
            var edit = current; edit.name = "Must not overwrite"; XCTAssertFalse(model.update(edit))
            XCTAssertEqual(try Data(contentsOf: store.manifest), before); XCTAssertEqual(model.selected, current)
            XCTAssertEqual(try Data(contentsOf: source), png())
        }
    }
    func testCanvasDragCommitsOnceAndRejectsInterveningRevision() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("portrait.png"); try png().write(to: source)
            let model = DemoScenes(root: root, systemIntegrationEnabled: false); try model.addImage(source, name: "Synthetic canvas")
            var initial = model.selected!; initial.showsPhone = false; XCTAssertTrue(model.update(initial)); initial = model.selected!
            let canvas = SceneCanvasView(previewLayer: AVCaptureVideoPreviewLayer())
            canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
            canvas.receive(initial); canvas.image = model.image(for: initial)
            var attempts: [DemoScene] = []
            canvas.update = { value in attempts.append(value); return model.update(value) ? model.selected : nil }
            func event(_ kind: NSEvent.EventType, _ y: CGFloat) -> NSEvent {
                // Windowless events are delivered to this synthetic view only;
                // nothing is posted to the system event queue or another app.
                NSEvent.mouseEvent(with: kind, location: CGPoint(x: 100, y: y), modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: event(.leftMouseDown, 200))
            canvas.mouseDragged(with: event(.leftMouseDragged, 215)); canvas.mouseDragged(with: event(.leftMouseDragged, 240))
            XCTAssertTrue(attempts.isEmpty); XCTAssertEqual(model.selected, initial)
            canvas.mouseUp(with: event(.leftMouseUp, 240))
            XCTAssertEqual(attempts.count, 1); XCTAssertTrue(model.selected!.backgroundY != initial.backgroundY)
            let next = model.selected!; canvas.receive(next)
            canvas.mouseDown(with: event(.leftMouseDown, 200)); canvas.mouseDragged(with: event(.leftMouseDragged, 250))
            var remote = next; remote.name = "Newer revision"; XCTAssertTrue(model.update(remote)); canvas.receive(model.selected!)
            canvas.mouseUp(with: event(.leftMouseUp, 250))
            XCTAssertEqual(attempts.count, 2); XCTAssertEqual(attempts.last?.libraryRevision, next.libraryRevision)
            XCTAssertEqual(model.selected?.name, "Newer revision"); XCTAssertEqual(model.selected?.backgroundY, next.backgroundY)
            XCTAssertNotNil(model.notice)
            canvas.mouseDown(with: event(.leftMouseDown, 200)); canvas.mouseDragged(with: event(.leftMouseDragged, 250))
            var elsewhere = next; elsewhere.id = UUID(); canvas.receive(elsewhere)
            canvas.mouseUp(with: event(.leftMouseUp, 250)); XCTAssertEqual(attempts.count, 2, "Changing the selected scene cancels its old gesture")
        }
    }

}
