import AppKit
import Combine
import SceneSyncKit

final class SceneListTests {
    private func fixture() throws -> (URL, DemoScenes, URL, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchSceneList-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = NSImage(size: CGSize(width: 80, height: 45), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let bytes = try SceneRenderer.png(DemoScene(background: "fixture.png"), image: image, size: CGSize(width: 80, height: 45))
        let source = root.appendingPathComponent("original.png"); try bytes.write(to: source)
        let model = DemoScenes(root: root, systemIntegrationEnabled: false)
        for name in ["Alpha", "Beta", "Gamma", "Delta"] { try model.addImage(source, name: name) }
        return (root, model, source, bytes)
    }
    func testSelectionFiltersAndNeverTargetsHiddenScenes() throws {
        let (root, model, _, _) = try fixture(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let ids = model.scenes.map(\.id)
        model.selectScenes([ids[0], ids[2]])
        XCTAssertEqual(model.selectedScenes.map(\.id), [ids[0], ids[2]])
        XCTAssertTrue(model.selected == nil, "Multiple rows must not leave one customer ready to present")
        model.query = "Gamma"
        XCTAssertEqual(model.selection.ids, [ids[2]])
        XCTAssertEqual(model.selected?.id, ids[2])
        XCTAssertFalse(model.canReorderScenes)
        model.query = "missing"
        XCTAssertTrue(model.selection.ids.isEmpty); XCTAssertTrue(model.selectedID == nil)
        model.query = ""
        XCTAssertEqual(model.selected?.id, ids[0]); XCTAssertTrue(model.canReorderScenes)
    }
    func testConfirmedBulkDeletionIsOneCommitAndPreservesEveryImage() throws {
        try MainActor.assumeIsolated {
            let (root, model, source, bytes) = try fixture(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
            let captured = Array(model.scenes.prefix(2)), retained = Array(model.scenes.suffix(2))
            let library = model.sceneSync!.library
            let assets = try library.records.flatMap { try library.package(for: $0.scene).assets.keys }.map { try library.assetURL($0) }
            let cached = model.scenes.map { root.appendingPathComponent($0.background) }
            var published: [[UUID]] = []
            let subscription = library.$records.dropFirst().sink { published.append($0.filter { !$0.isDeleted }.map(\.id)) }
            defer { subscription.cancel() }
            // A confirmation owns these two snapshots even after browsing another row.
            model.selectedID = retained[1].id
            XCTAssertTrue(model.removeScenes(captured))
            XCTAssertEqual(published, [retained.map(\.id)], "No intermediate one-at-a-time deletion may publish")
            XCTAssertEqual(model.scenes.map(\.id), retained.map(\.id))
            XCTAssertEqual(model.selectedID, retained[1].id)
            for url in assets + cached + [source] { XCTAssertEqual(try Data(contentsOf: url), bytes) }
            let reopened = DemoScenes(root: root, systemIntegrationEnabled: false); defer { reopened.shutdown() }
            XCTAssertEqual(reopened.scenes.map(\.id), retained.map(\.id))
        }
    }
    func testStaleOrFailedBulkDeletionKeepsWholeSelection() throws {
        try MainActor.assumeIsolated {
            let (root, model, source, bytes) = try fixture(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
            let captured = Array(model.scenes.prefix(2)), manifest = root.appendingPathComponent("Portable/scene-library.json")
            var updated = captured[1]; updated.name = "Newer Beta"; XCTAssertTrue(model.update(updated))
            let beforeStale = try Data(contentsOf: manifest)
            XCTAssertFalse(model.removeScenes(captured))
            XCTAssertEqual(try Data(contentsOf: manifest), beforeStale)
            XCTAssertEqual(model.scenes.count, 4); XCTAssertEqual(model.scenes[1].name, "Newer Beta")
            XCTAssertFalse(model.removeScenes([model.scenes[0], model.scenes[0]]))
            XCTAssertEqual(try Data(contentsOf: manifest), beforeStale)

            let current = model.scenes
            let external = SceneLibraryStore(directory: root.appendingPathComponent("Portable"))
            var archive = try external.load(); archive.records[3].scene.name = "External owner"; archive.records[3].revision = UUID()
            try external.save(archive)
            let externalBytes = try Data(contentsOf: manifest)
            XCTAssertFalse(model.removeScenes(Array(current.prefix(2))))
            XCTAssertEqual(try Data(contentsOf: manifest), externalBytes)
            XCTAssertEqual(model.scenes, current, "A failed store commit must not remove even the first row in memory")
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }
    func testRenameReconcilesSearchAndRejectsStaleSnapshots() throws {
        let (root, model, _, _) = try fixture(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.query = "Beta"; let captured = model.selected!
        XCTAssertTrue(model.renameScene(captured, to: "  Renamed customer  "))
        XCTAssertEqual(model.query, ""); XCTAssertEqual(model.selectedID, captured.id)
        XCTAssertEqual(model.selected?.name, "Renamed customer")
        XCTAssertEqual(model.selected?.background, captured.background)
        XCTAssertFalse(model.renameScene(model.selected!, to: "  \n "))
        XCTAssertEqual(model.selected?.name, "Renamed customer")
        XCTAssertFalse(model.renameScene(captured, to: "Stale label"))
        XCTAssertEqual(model.selected?.name, "Renamed customer")
        XCTAssertNotNil(model.notice)
        let blurSnapshot = model.selected!
        let browsed = model.scenes.first!.id; model.selectedID = browsed
        XCTAssertTrue(model.renameScene(blurSnapshot, to: "Saved while leaving the row"))
        XCTAssertEqual(model.selectedID, browsed, "Committing a field on blur must preserve an intentional new selection")
        let reopened = DemoScenes(root: root, systemIntegrationEnabled: false); defer { reopened.shutdown() }
        XCTAssertEqual(reopened.scenes.first { $0.id == captured.id }?.name, "Saved while leaving the row")
    }
    func testDragReordersSelectionAndRejectsStaleOrForeignTokens() throws {
        let ids = (0..<5).map { _ in UUID() }
        let order = SceneListOrder(ids: ids)
        XCTAssertEqual(order.moving([ids[1], ids[3]], to: 5), [ids[0], ids[2], ids[4], ids[1], ids[3]])
        XCTAssertEqual(order.moving([ids[1], ids[3]], to: 0), [ids[1], ids[3], ids[0], ids[2], ids[4]])
        XCTAssertTrue(order.moving([ids[1], ids[2]], to: 2) == nil)
        XCTAssertTrue(order.moving([], to: 0) == nil)
        XCTAssertTrue(order.moving([UUID()], to: 0) == nil)
        XCTAssertTrue(order.moving([ids[0]], to: 6) == nil)
        var drag = SceneListDrag()
        let token = drag.begin(selected: [ids[1], ids[3]], order: ids)
        XCTAssertEqual(drag.proposedOrder(payload: token, fromThisTable: true, currentOrder: ids, boundary: 5), order.moving([ids[1], ids[3]], to: 5))
        XCTAssertTrue(drag.proposedOrder(payload: token, fromThisTable: false, currentOrder: ids, boundary: 5) == nil)
        XCTAssertTrue(drag.proposedOrder(payload: "foreign", fromThisTable: true, currentOrder: ids, boundary: 5) == nil)
        XCTAssertTrue(drag.proposedOrder(payload: token, fromThisTable: true, currentOrder: ids.reversed(), boundary: 5) == nil)
        drag.end()
        XCTAssertTrue(drag.proposedOrder(payload: token, fromThisTable: true, currentOrder: ids, boundary: 5) == nil)

        let (root, model, _, _) = try fixture(); defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let before = model.scenes.map(\.id), manifest = root.appendingPathComponent("Portable/scene-library.json")
        model.selectScenes([before[1], before[3]])
        let next = SceneListOrder(ids: before).moving(model.selection.ids, to: 0)!
        XCTAssertTrue(model.reorderScenes(next, expectedOrder: before))
        XCTAssertEqual(model.selection.ids, [before[1], before[3]])
        XCTAssertEqual(model.scenes.map(\.id), next)
        let saved = try Data(contentsOf: manifest)
        XCTAssertFalse(model.reorderScenes(before, expectedOrder: before))
        XCTAssertEqual(try Data(contentsOf: manifest), saved)
        model.query = "Beta"
        XCTAssertFalse(model.reorderScenes(before, expectedOrder: next))
        XCTAssertEqual(try Data(contentsOf: manifest), saved)
        let reopened = DemoScenes(root: root, systemIntegrationEnabled: false); defer { reopened.shutdown() }
        XCTAssertEqual(reopened.scenes.map(\.id), next)
    }
    func testDeleteAndReturnBelongOnlyToFocusedTable() throws {
        let table = SceneListTableView(frame: CGRect(x: 0, y: 50, width: 240, height: 180))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("scene")))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 260, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 260, height: 250))
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 30))
        container.addSubview(table); container.addSubview(field); window.contentView = container
        defer { window.close() }
        var deletes = 0, renames = 0
        table.onDelete = { deletes += 1 }; table.onRename = { renames += 1 }
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertTrue(table.handleListKey(key(51))); XCTAssertTrue(table.handleListKey(key(117)))
        XCTAssertTrue(table.handleListKey(key(36))); XCTAssertTrue(table.handleListKey(key(76)))
        XCTAssertEqual(deletes, 2); XCTAssertEqual(renames, 2)
        XCTAssertFalse(table.handleListKey(key(51, modifiers: .command)))
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(table.handleListKey(key(51))); XCTAssertFalse(table.handleListKey(key(117)))
        XCTAssertFalse(table.handleListKey(key(36)))
        XCTAssertEqual(deletes, 2); XCTAssertEqual(renames, 2)
    }
}
