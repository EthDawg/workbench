import AppKit
import ImageIO
import UniformTypeIdentifiers

final class PersonaSessionTests {
    private final class Display: PersonaSessionDisplaying {
        var onPlacementChange: ((PersonaOverlayState) -> Void)?
        var onSelection: (() -> Void)?
        var frame: CGRect? = CGRect(x: 16, y: 16, width: 120, height: 200)
        var visible = false
        var closed = false
        var state = PersonaOverlayState()
        var image: NSImage?
        var label = ""
        var fades: [Bool] = []
        func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState {
            configure(image: image, name: name, state: state); visible = true; fades.append(animated); return state
        }
        func configure(image: NSImage, name: String, state: PersonaOverlayState) { self.image = image; label = name; self.state = state }
        func hide() { visible = false }
        func shutdown() { hide(); closed = true; onPlacementChange = nil; onSelection = nil }
    }
    private final class Displays {
        var all: [Display] = []
        func make() -> Display { let panel = Display(); all.append(panel); return panel }
        var visible: [Display] { all.filter { $0.visible && !$0.closed } }
        var current: [Display] { all.filter { !$0.closed } }
    }
    private struct Fixture {
        let root: URL
        let library: PersonaLibrary
        let displays: Displays
        let first: SavedPersona
        let second: SavedPersona
        let group: UUID
        let other: UUID
    }
    private func png(_ red: CGFloat, _ green: CGFloat) throws -> Data {
        let bitmap = CGContext(data: nil, width: 20, height: 32, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: red, green: green, blue: 0.2, alpha: 1))
        bitmap.fill(CGRect(x: 2, y: 1, width: 16, height: 30))
        let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw PersonaError.unreadableImage }
        return data as Data
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaSessionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func fixture() throws -> Fixture {
        let root = try temporary(), displays = Displays()
        let source = root.appendingPathComponent("private-client-name.png")
        try png(0.8, 0.1).write(to: source)
        let library = PersonaLibrary(root: root, sessionPanelFactory: { displays.make() }, sessionHUDEnabled: false)
        let first = try library.addImage(source, card: PersonaCardStyle(label: "Site manager"))
        try png(0.1, 0.8).write(to: source)
        let second = try library.addImage(source)
        let group = try library.createGroup(name: "PRIVATE CUSTOMER ONE", members: [first.id, second.id])
        let other = try library.createGroup(name: "PRIVATE CUSTOMER TWO", members: [second.id])
        let left = PersonaOverlayItem(personaID: first.id, placement: PersonaOverlayState(x: 0.02, y: 0.02, width: 0.12, locked: true), publicLabel: "Left card")
        let right = PersonaOverlayItem(personaID: first.id, placement: PersonaOverlayState(x: 0.98, y: 0.02, width: 0.18, locked: false), publicLabel: "Right card")
        try library.saveGroupLayout(group, overlays: [left, right], publicLabel: "First step")
        try library.saveGroupLayout(other, overlays: [PersonaOverlayItem(personaID: second.id)], publicLabel: nil)
        return Fixture(root: root, library: library, displays: displays, first: first, second: second, group: group, other: other)
    }
    private func cleanup(_ fixture: Fixture) { fixture.library.shutdown(); try? FileManager.default.removeItem(at: fixture.root) }
    private func archive(_ root: URL) throws -> Data { try Data(contentsOf: root.appendingPathComponent("persona-library.json")) }
    private func files(_ root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: root.path).map {
            ($0, try Data(contentsOf: root.appendingPathComponent($0)))
        })
    }

    func testOptInMigrationBacksUpExactArchiveAndPreservesLegacyPlacement() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("portrait.png"), original = try png(0.7, 0.2)
        try original.write(to: source)
        let library = PersonaLibrary(root: root, sessionHUDEnabled: false); defer { library.shutdown() }
        let item = try library.addImage(source)
        let group = try library.createGroup(name: "Old prepared group", members: [item.id])
        library.setOverlayLocked(false); library.setOverlayWidth(0.22)
        let overlay = try Data(contentsOf: root.appendingPathComponent("persona-overlay.json"))
        let old = try archive(root)
        XCTAssertEqual(try JSONDecoder().decode(PersonaArchive.self, from: old).version, 2)
        let reopened = PersonaLibrary(root: root, sessionHUDEnabled: false); defer { reopened.shutdown() }
        XCTAssertEqual(try archive(root), old); XCTAssertTrue(reopened.groups[0].overlays == nil)
        XCTAssertEqual(reopened.sessionState.phase, .idle); XCTAssertFalse(reopened.overlayVisible)
        XCTAssertTrue(FileManager.default.contents(atPath: source.path) == original)
        let instance = PersonaOverlayItem(personaID: item.id)
        XCTAssertTrue(instance.placement.locked, "New multiple-overlay cards default to click-through")
        try reopened.saveGroupLayout(group, overlays: [instance], publicLabel: "Visible step")
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("persona-library.before-overlays-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(backups[0])), old)
        XCTAssertEqual(try JSONDecoder().decode(PersonaArchive.self, from: archive(root)).version, 3)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("persona-overlay.json")), overlay)
        try reopened.savePreparedGroups([group])
        let final = PersonaLibrary(root: root, sessionHUDEnabled: false); defer { final.shutdown() }
        XCTAssertEqual(final.preparedGroupIDs, [group]); XCTAssertEqual(final.groups[0].overlays, [instance])
        XCTAssertEqual(final.sessionState.phase, .idle); XCTAssertFalse(final.overlayVisible)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testTwoInstancesOwnIndependentGeometryVisibilityLockAndOrder() throws {
        let f = try fixture(); defer { cleanup(f) }
        let before = try archive(f.root)
        try f.library.startOverlaySession(groupIDs: [f.group, f.other], initialGroupID: f.group)
        XCTAssertEqual(f.displays.visible.count, 2)
        let state = f.library.sessionState, left = state.instances[0].id, right = state.instances[1].id
        XCTAssertEqual(state.instances.map(\.personaID), [f.first.id, f.first.id])
        XCTAssertFalse(left == right)
        f.library.performOverlayAction(.width(left, 0.3)); f.library.performOverlayAction(.locked(right, true))
        XCTAssertEqual(f.library.sessionState.instances[0].width, 0.3, accuracy: 0.001)
        XCTAssertEqual(f.library.sessionState.instances[1].width, 0.18, accuracy: 0.001)
        XCTAssertTrue(f.library.sessionState.instances[1].locked)
        f.library.performOverlayAction(.position(left, 0.5, 0.9))
        XCTAssertEqual(f.library.sessionState.instances[1].placement.x, 0.98)
        let firstPanel = f.displays.current.first { $0.label == "Left card" }!
        var dragged = firstPanel.state; dragged.x = 0.25; dragged.screenID = 991
        firstPanel.onPlacementChange?(dragged)
        XCTAssertEqual(f.library.sessionState.instances[0].placement.screenID, 991)
        XCTAssertEqual(f.library.sessionState.instances[1].placement.screenID, nil)
        firstPanel.onSelection?(); XCTAssertEqual(f.library.sessionState.selectedInstanceID, left)
        f.library.performOverlayAction(.move(left, 1))
        XCTAssertEqual(f.library.sessionState.instances.map(\.id), [right, left])
        f.library.performOverlayAction(.visible(left, false)); XCTAssertEqual(f.displays.visible.count, 1)
        f.library.pauseOverlaySession(); XCTAssertEqual(f.displays.visible.count, 0)
        XCTAssertEqual(f.library.sessionState.phase, .paused)
        try f.library.resumeOverlaySession(); XCTAssertEqual(f.displays.visible.count, 1)
        XCTAssertFalse(f.library.sessionState.instances.first { $0.id == left }!.visible)
        XCTAssertEqual(try archive(f.root), before, "Runtime arrangement edits remain temporary until Save layout")
        f.library.endOverlaySession()
        XCTAssertEqual(f.displays.visible.count, 0); XCTAssertTrue(f.displays.all.allSatisfy(\.closed))
        XCTAssertEqual(f.library.sessionState.phase, .idle)
        XCTAssertTrue(f.displays.all.allSatisfy { $0.onPlacementChange == nil && $0.onSelection == nil })
    }

    func testEmptySetCanBeRevisitedAndLiveFailuresStayVisible() throws {
        let f = try fixture(); defer { cleanup(f) }
        try f.library.startOverlaySession(groupIDs: [f.group, f.other], initialGroupID: f.group)
        for item in f.library.sessionState.instances { f.library.performOverlayAction(.remove(item.id)) }
        f.library.performOverlayAction(.stepGroup(1)); f.library.performOverlayAction(.stepGroup(-1))
        XCTAssertEqual(f.library.sessionState.currentGroupID, f.group)
        XCTAssertTrue(f.library.sessionState.instances.isEmpty)
        f.library.performOverlayAction(.add(f.first.id))
        XCTAssertEqual(f.displays.visible.count, 1)
        f.library.mayBeginInteraction = { false }
        f.library.performOverlayAction(.stepGroup(1))
        XCTAssertEqual(f.library.sessionState.feedback, "Finish recording or keyboard practice first.")
        XCTAssertEqual(f.library.sessionState.currentGroupID, f.group)
        f.library.performOverlayAction(.dismissFeedback)
        XCTAssertTrue(f.library.sessionState.feedback == nil)
        f.library.mayBeginInteraction = { true }
        let original = f.library.groups.first { $0.id == f.group }!
        try f.library.saveGroupLayout(f.group, overlays: original.overlays!, publicLabel: "Changed privately")
        f.library.performOverlayAction(.saveLayout)
        XCTAssertEqual(f.library.sessionState.feedback, "Layout not saved: preparation changed. Review it in Personas.")
        XCTAssertEqual(f.displays.visible.count, 1)
    }

    func testPausedGroupSwitchKeepsLayoutsAndFrozenAllowedScope() throws {
        let f = try fixture(); defer { cleanup(f) }
        try f.library.startOverlaySession(groupIDs: [f.group, f.other], initialGroupID: f.group, softReveal: true)
        XCTAssertTrue(f.displays.visible.allSatisfy { $0.fades.first == true })
        let left = f.library.sessionState.instances[0].id
        f.library.performOverlayAction(.position(left, 0.42, 0.7)); f.library.pauseOverlaySession()
        f.library.performOverlayAction(.stepGroup(1)); XCTAssertEqual(f.library.sessionState.currentGroupID, f.other)
        XCTAssertEqual(f.displays.visible.count, 0); XCTAssertEqual(f.library.sessionState.phase, .paused)
        f.library.performOverlayAction(.add(f.second.id)); XCTAssertEqual(f.library.sessionState.instances.count, 2)
        XCTAssertEqual(f.displays.visible.count, 0)
        try f.library.resumeOverlaySession(); XCTAssertEqual(f.displays.visible.count, 2)
        XCTAssertTrue(f.displays.visible.allSatisfy { $0.fades.last == false })
        f.library.performOverlayAction(.stepGroup(-1))
        XCTAssertEqual(f.library.sessionState.instances[0].placement.x, 0.42)
        let outside = try f.library.createGroup(name: "PRIVATE OUTSIDE", members: [f.first.id])
        f.library.performOverlayAction(.selectGroup(outside))
        XCTAssertEqual(f.library.sessionState.currentGroupID, f.group)
        XCTAssertEqual(f.library.sessionState.groups.map(\.label), ["First step", "Set 2"])
        XCTAssertFalse(f.library.sessionState.groups.map(\.label).joined().contains("PRIVATE"))
        for _ in 0..<8 { f.library.performOverlayAction(.add(f.first.id)) }
        XCTAssertEqual(f.library.sessionState.instances.count, 8); XCTAssertEqual(f.displays.visible.count, 8)
        let ids = f.library.sessionState.instances.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        f.library.endOverlaySession()
        try f.library.startOverlaySession(groupIDs: [f.group], initialGroupID: f.group)
        XCTAssertEqual(f.library.sessionState.instances.count, 2)
        XCTAssertEqual(f.library.sessionState.instances[0].placement.x, 0.02, "End does not save the temporary layout")
    }

    func testFrozenArtworkSurvivesLibraryEditsAndFailedReplacementStart() throws {
        let f = try fixture(); defer { cleanup(f) }
        try f.library.startOverlaySession(groupIDs: [f.group, f.other], initialGroupID: f.group)
        let frozen = try PersonaCardRenderer.png(f.library.sessionState.instances[0].image)
        f.library.prepareGroup(f.other)
        XCTAssertEqual(f.library.sessionState.currentGroupID, f.group)
        XCTAssertTrue(f.library.updateCard(f.first.id, style: PersonaCardStyle(label: "NEW PRIVATE CONTENT", background: InkColor(1, 1, 0))))
        XCTAssertEqual(try PersonaCardRenderer.png(f.library.sessionState.instances[0].image), frozen)
        XCTAssertEqual(f.library.sessionState.candidates[0].label, "Site manager")
        f.library.renameGroup(f.group, name: "LATER PRIVATE NAME")
        XCTAssertEqual(f.library.sessionState.groups[0].label, "First step")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(f.second.image))
        let panels = f.displays.current
        XCTAssertThrowsError(try f.library.startOverlaySession(groupIDs: [f.group, f.other], initialGroupID: f.other))
        XCTAssertEqual(f.library.sessionState.currentGroupID, f.group)
        XCTAssertTrue(panels.allSatisfy { !$0.closed && $0.visible })
        // The earlier session already owns decoded copies; deletion of a source
        // cannot make a later, allowed switch unexpectedly show newer content.
        f.library.performOverlayAction(.selectGroup(f.other)); XCTAssertEqual(f.displays.visible.count, 1)
        XCTAssertEqual(f.library.sessionState.currentGroupID, f.other)
        f.library.remove(f.second.id)
        XCTAssertEqual(f.library.sessionState.instances.count, 0)
        XCTAssertEqual(f.displays.visible.count, 0); XCTAssertTrue(f.library.sessionState.selectedInstanceID == nil)
        f.library.removeGroup(f.other)
        XCTAssertEqual(f.library.sessionState.phase, .idle)
    }

    func testSaveLayoutIsExplicitAtomicAndRejectsChangedPreparation() throws {
        let f = try fixture(); defer { cleanup(f) }
        try f.library.startOverlaySession(groupIDs: [f.group], initialGroupID: f.group)
        let id = f.library.sessionState.instances[0].id
        f.library.performOverlayAction(.width(id, 0.24))
        f.library.renameGroup(f.group, name: "New private name")
        try f.library.saveSessionLayout()
        XCTAssertFalse(f.library.sessionState.hasUnsavedLayout)
        XCTAssertEqual(f.library.groups.first { $0.id == f.group }!.name, "New private name")
        XCTAssertEqual(f.library.groups.first { $0.id == f.group }!.overlays![0].placement.width, 0.24)
        f.library.performOverlayAction(.width(id, 0.31))
        let current = f.library.groups.first { $0.id == f.group }!
        var later = current.overlays!; later[0].placement.width = 0.19
        try f.library.saveGroupLayout(f.group, overlays: later, publicLabel: current.publicLabel, expected: current)
        let saved = try archive(f.root)
        XCTAssertThrowsError(try f.library.saveSessionLayout())
        XCTAssertEqual(try archive(f.root), saved)
        XCTAssertEqual(f.library.sessionState.instances[0].width, 0.31)
        XCTAssertTrue(f.library.sessionState.hasUnsavedLayout)
        XCTAssertThrowsError(try f.library.saveGroupLayout(f.group, overlays: current.overlays!, publicLabel: current.publicLabel, expected: current))
        XCTAssertEqual(try archive(f.root), saved)
        let external = Data("a separate writer's original".utf8)
        try external.write(to: f.root.appendingPathComponent("persona-library.json"))
        XCTAssertThrowsError(try f.library.savePreparedGroups([f.group]))
        XCTAssertEqual(try archive(f.root), external)
        f.library.endOverlaySession(); XCTAssertEqual(try archive(f.root), external)
    }

    func testReadOnlySessionsAndInteractionGuardsNeverWriteOrTrapOverlays() throws {
        let f = try fixture(); defer { cleanup(f) }
        let before = try files(f.root), displays = Displays()
        let readOnly = PersonaLibrary(root: f.root, readOnlyReason: "Synthetic read-only browsing",
            sessionPanelFactory: { displays.make() }, sessionHUDEnabled: false)
        defer { readOnly.shutdown() }
        readOnly.mayBeginInteraction = { false }
        XCTAssertThrowsError(try readOnly.startOverlaySession(groupIDs: [f.group], initialGroupID: f.group))
        readOnly.showOverlay(); XCTAssertEqual(displays.all.count, 0)
        readOnly.mayBeginInteraction = { true }
        try readOnly.startOverlaySession(groupIDs: [f.group, f.other], initialGroupID: f.group)
        let id = readOnly.sessionState.instances[0].id
        readOnly.performOverlayAction(.width(id, 0.27)); readOnly.performOverlayAction(.locked(id, false))
        XCTAssertFalse(readOnly.sessionState.canSaveLayout)
        XCTAssertThrowsError(try readOnly.saveSessionLayout())
        readOnly.mayBeginInteraction = { false }
        readOnly.performOverlayAction(.selectGroup(f.other)); XCTAssertEqual(readOnly.sessionState.currentGroupID, f.group)
        readOnly.pauseOverlaySession(); XCTAssertEqual(displays.visible.count, 0)
        XCTAssertThrowsError(try readOnly.resumeOverlaySession())
        XCTAssertEqual(readOnly.sessionState.phase, .paused)
        readOnly.endOverlaySession(); XCTAssertTrue(displays.all.allSatisfy(\.closed))
        XCTAssertEqual(try files(f.root), before)
    }

    func testInvalidLayoutsAndFutureArchivePreserveOriginalBytes() throws {
        let f = try fixture(); defer { cleanup(f) }
        let original = try archive(f.root)
        var bad = PersonaOverlayItem(personaID: f.first.id)
        bad.placement.x = .nan
        XCTAssertThrowsError(try f.library.saveGroupLayout(f.group, overlays: [bad], publicLabel: nil))
        let good = PersonaOverlayItem(personaID: f.first.id)
        XCTAssertThrowsError(try f.library.saveGroupLayout(f.group, overlays: [good, good], publicLabel: nil))
        XCTAssertThrowsError(try f.library.saveGroupLayout(f.group, overlays: [PersonaOverlayItem(personaID: UUID())], publicLabel: nil))
        XCTAssertThrowsError(try f.library.saveGroupLayout(f.group, overlays: [good], publicLabel: "bad\nlabel"))
        XCTAssertThrowsError(try f.library.savePreparedGroups([f.group, f.group]))
        XCTAssertEqual(try archive(f.root), original)
        var future = try JSONDecoder().decode(PersonaArchive.self, from: original); future.version = 999
        let bytes = try JSONEncoder().encode(future); try bytes.write(to: f.root.appendingPathComponent("persona-library.json"))
        let blocked = PersonaLibrary(root: f.root, sessionHUDEnabled: false); defer { blocked.shutdown() }
        XCTAssertTrue(blocked.isReadOnly)
        XCTAssertThrowsError(try blocked.savePreparedGroups([]))
        XCTAssertEqual(try archive(f.root), bytes)
    }

    func testBoundedPreflightAlsoProtectsLegacyShowAndCurrentSession() throws {
        let f = try fixture(); defer { cleanup(f) }
        try f.library.startOverlaySession(groupIDs: [f.group], initialGroupID: f.group)
        let panels = f.displays.current
        var ids = [f.first.id, f.second.id]
        for _ in 0..<31 { ids.append(try f.library.addImage(f.root.appendingPathComponent(f.second.image)).id) }
        let large = try f.library.createGroup(name: "Overlarge prepared group", members: ids)
        try f.library.saveGroupLayout(large, overlays: [PersonaOverlayItem(personaID: ids[0])], publicLabel: nil)
        XCTAssertThrowsError(try f.library.startOverlaySession(groupIDs: [large], initialGroupID: large))
        XCTAssertEqual(f.library.sessionState.currentGroupID, f.group)
        let launch = f.library.showOverlay() // Fail before creating a native panel.
        XCTAssertThrowsError(try launch.get())
        if case .failure(let error) = launch {
            XCTAssertEqual(error.localizedDescription, PersonaSessionError.tooManyCandidates.localizedDescription)
        }
        XCTAssertEqual(f.library.sessionState.currentGroupID, f.group)
        XCTAssertTrue(panels.allSatisfy { $0.visible && !$0.closed })
        XCTAssertTrue(f.library.notice?.contains("32") == true)
        let saved = try archive(f.root)
        XCTAssertThrowsError(try f.library.savePreparedGroups([f.group, f.other] + (0..<7).map { _ in UUID() }))
        XCTAssertEqual(try archive(f.root), saved)
        XCTAssertThrowsError(try f.library.startOverlaySession(groupIDs: [f.group, f.group], initialGroupID: f.group))
        XCTAssertEqual(f.displays.visible.count, 2)
    }

    func testSingleCardLaunchFailureReturnsErrorAndPreservesExistingOutput() throws {
        let f = try fixture(); defer { cleanup(f) }
        try f.library.startOverlaySession(groupIDs: [f.group], initialGroupID: f.group)
        f.library.prepareGroup(f.group); f.library.selectedID = f.first.id
        let panels = f.displays.current
        let oldImages = panels.map(\.image), oldLabels = panels.map(\.label), oldStates = panels.map(\.state)
        var didShow = false
        f.library.onShow = { didShow = true }
        let missingURL = f.root.appendingPathComponent(f.second.image)
        let missingBytes = try Data(contentsOf: missingURL)
        try FileManager.default.removeItem(at: missingURL)
        let before = try files(f.root)
        XCTAssertTrue(f.library.renderedImage(for: f.first) != nil, "The chosen card is valid; another frozen candidate is unavailable")
        let missing = f.library.showOverlay()
        XCTAssertThrowsError(try missing.get())
        if case .failure(let error) = missing {
            XCTAssertEqual(error.localizedDescription, PersonaSessionError.missingArtwork.localizedDescription)
            XCTAssertEqual(f.library.notice, error.localizedDescription)
        }
        XCTAssertEqual(try files(f.root), before)
        XCTAssertEqual(f.library.sessionState.currentGroupID, f.group)
        XCTAssertEqual(f.library.sessionState.phase, .active)
        XCTAssertEqual(f.displays.current.count, panels.count)
        XCTAssertTrue(panels.allSatisfy { $0.visible && !$0.closed })
        XCTAssertTrue(zip(panels, oldImages).allSatisfy { $0.image === $1 })
        XCTAssertEqual(panels.map(\.label), oldLabels); XCTAssertEqual(panels.map(\.state), oldStates)
        XCTAssertFalse(didShow, "Failure must not run the successful-launch shell callback")

        try missingBytes.write(to: missingURL)
        f.library.mayBeginInteraction = { false }
        let restored = try files(f.root)
        let busy = f.library.showOverlay()
        XCTAssertThrowsError(try busy.get())
        if case .failure(let error) = busy {
            XCTAssertEqual(error.localizedDescription, PersonaSessionInteractionError.busy.localizedDescription)
            XCTAssertEqual(f.library.notice, error.localizedDescription)
        }
        XCTAssertEqual(try files(f.root), restored)
        XCTAssertEqual(f.library.sessionState.currentGroupID, f.group)
        XCTAssertTrue(panels.allSatisfy { $0.visible && !$0.closed })
        XCTAssertTrue(zip(panels, oldImages).allSatisfy { $0.image === $1 })
        XCTAssertFalse(didShow)
    }
}
