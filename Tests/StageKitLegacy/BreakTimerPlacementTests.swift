import AppKit

final class BreakTimerPlacementTests {
    func testFreeAndNamedPositionsRecoverAcrossDisplayChanges() throws {
        let display = BreakTimerDisplay(id: "wide", visibleFrame: NSRect(x: -1600, y: 40, width: 1600, height: 900))
        let changed = BreakTimerDisplay(id: "wide", visibleFrame: NSRect(x: 0, y: 24, width: 1024, height: 640))
        let fallback = BreakTimerDisplay(id: "fallback", visibleFrame: NSRect(x: 1024, y: 80, width: 800, height: 600))
        let size = NSSize(width: 570, height: 330)
        var placement = BreakTimerPlacement()

        let initial = placement.destination(size: size, displays: [display], fallbackID: display.id)
        XCTAssertEqual(initial?.display, display)
        XCTAssertEqual(Double(initial?.frame.midX ?? 0), Double(display.visibleFrame.midX), accuracy: 0.001)
        XCTAssertEqual(Double(initial?.frame.midY ?? 0), Double(display.visibleFrame.midY), accuracy: 0.001)

        let free = NSRect(x: -1300, y: 250, width: size.width, height: size.height)
        placement.move(to: free, on: display)
        XCTAssertTrue(placement.position.anchor == nil)
        let decoded = try JSONDecoder().decode(BreakTimerPlacement.self, from: JSONEncoder().encode(placement)).validated()
        XCTAssertEqual(decoded, placement)
        let resized = placement.destination(size: NSSize(width: 480, height: 280), displays: [changed], fallbackID: fallback.id)
        XCTAssertEqual(resized?.display, changed)
        XCTAssertTrue(changed.visibleFrame.contains(resized?.frame ?? .zero))

        placement.setAnchor(.bottomRight, on: display)
        let recovered = placement.destination(size: size, displays: [fallback], fallbackID: fallback.id)
        XCTAssertEqual(recovered?.display, fallback, "A removed display must fall back to an available display")
        XCTAssertEqual(recovered?.frame, FloatingControlGeometry.frame(anchor: .bottomRight, size: size, visibleFrame: fallback.visibleFrame))
        XCTAssertThrowsError(try BreakTimerPlacement(version: 2).validated())
        XCTAssertThrowsError(try BreakTimerPlacement(position: PresentationControlPlacement(x: .nan)).validated())
    }

    func testStoragePreservesFutureCorruptAndConcurrentFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchTimerPlacement-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("break-timer-placement.json")
        let future = try JSONEncoder().encode(BreakTimerPlacement(version: 2))
        try future.write(to: url)
        let blocked = BreakTimerPlacementStore(url: url)
        XCTAssertTrue(blocked.storageBlocked)
        XCTAssertNotNil(blocked.notice)
        blocked.setAnchor(.topLeft, on: BreakTimerDisplay(id: "main", visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 800)))
        XCTAssertEqual(try Data(contentsOf: url), future, "Future placement data must remain byte-for-byte unchanged")

        try FileManager.default.removeItem(at: url)
        let store = BreakTimerPlacementStore(url: url)
        let display = BreakTimerDisplay(id: "main", visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        store.move(to: NSRect(x: 340, y: 210, width: 570, height: 330), on: display)
        XCTAssertEqual(BreakTimerPlacementStore(url: url).value, store.value, "A dragged free position must survive reopening")
        store.setAnchor(.top, on: display)
        XCTAssertFalse(store.storageBlocked)
        XCTAssertEqual(BreakTimerPlacementStore(url: url).value.position.anchor, .top)
        let external = Data("external position update".utf8)
        try external.write(to: url, options: .atomic)
        store.setAnchor(.left, on: display)
        XCTAssertTrue(store.storageBlocked)
        XCTAssertEqual(try Data(contentsOf: url), external, "A concurrent change must not be overwritten")
    }

    func testNativeTimerReopensAtItsSavedAnchor() throws {
        let suite = "WorkbenchTimerNative." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        for action in Action.allCases {
            var shortcut = action.defaultShortcut; shortcut.enabled = false
            settings.value.shortcuts[action.rawValue] = shortcut
        }
        let testDisplay = BreakTimerDisplay(id: "native-test", visibleFrame: NSRect(x: 100, y: 80, width: 1280, height: 800))
        let app = AppCoordinator(settings: settings, archiveURL: root.appendingPathComponent("boards.json"), embedded: true,
                                 timerDisplays: { [testDisplay] }, timerFallbackID: { testDisplay.id })
        app.start(); defer { app.shutdown() }
        app.startTimer()
        guard let window = NSApp.windows.first(where: { $0.title == "Workbench · Break timer" }) else {
            XCTAssertTrue(false, "The native break timer window must open"); return
        }
        app.setTimerPosition(.topLeft)
        XCTAssertEqual(app.timerPlacementAnchor, .topLeft)
        let placementURL = root.appendingPathComponent("break-timer-placement.json")
        let saved = try JSONDecoder().decode(BreakTimerPlacement.self, from: Data(contentsOf: placementURL)).validated()
        XCTAssertEqual(saved.position.anchor, .topLeft)
        XCTAssertEqual(saved.screenID, testDisplay.id)
        app.hideTimer(); app.toggleTimer()
        XCTAssertEqual(app.timerPlacementAnchor, .topLeft, "Hiding and reopening must preserve the named position")
        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(window.contentView)
    }
}
