import AppKit

final class CoreTests: XCTestCase {
    func stroke(_ tool: DrawingTool = .pen, from: CGPoint = .zero, to: CGPoint = CGPoint(x: 100, y: 100), created: Double = 100) -> Annotation {
        Annotation(tool: tool, color: .coral, width: 4, points: [InkPoint(from), InkPoint(to)], created: created)
    }
    func testLineHitTestingUsesSegmentsNotBoundingBox() {
        let line = stroke(.line)
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 52)))
        XCTAssertFalse(line.hitTest(CGPoint(x: 80, y: 10)))
        XCTAssertFalse(line.hitTest(CGPoint(x: 140, y: 140)))
    }
    func testRectangleOnlyErasesAtBorder() {
        let rectangle = stroke(.rectangle)
        XCTAssertTrue(rectangle.hitTest(CGPoint(x: 0, y: 50)))
        XCTAssertFalse(rectangle.hitTest(CGPoint(x: 50, y: 50)))
        XCTAssertFalse(rectangle.hitTest(CGPoint(x: 200, y: 50)))
    }
    func testEllipseOnlyErasesAtBorder() {
        let ellipse = stroke(.ellipse)
        XCTAssertTrue(ellipse.hitTest(CGPoint(x: 100, y: 50)))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 50, y: 50)))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 5, y: 5)))
    }
    func testArrowHeadIsErasable() {
        let arrow = stroke(.arrow, to: CGPoint(x: 100, y: 0))
        let head = Geometry.arrowHead(from: .zero, to: arrow.last, width: arrow.width)
        XCTAssertEqual(head.count, 2)
        XCTAssertTrue(arrow.hitTest(head[0], radius: 0))
    }
    func testDegenerateStrokeDoesNotDivideByZero() {
        let annotation = stroke(.line, to: .zero)
        XCTAssertTrue(annotation.hitTest(.zero))
        XCTAssertFalse(annotation.hitTest(CGPoint(x: 100, y: 0)))
        XCTAssertEqual(Geometry.distance(CGPoint(x: 3, y: 4), .zero, .zero), 5)
    }
    func testShiftConstrainedShapesAcrossQuadrants() {
        for p in [CGPoint(x: 80, y: 20), CGPoint(x: -80, y: 20), CGPoint(x: 20, y: -80), CGPoint(x: -20, y: -80)] {
            let square = Geometry.constrained(p, from: .zero, tool: .rectangle)
            XCTAssertEqual(abs(square.x), abs(square.y))
            XCTAssertEqual(square.x.sign, p.x.sign); XCTAssertEqual(square.y.sign, p.y.sign)
        }
        let straight = Geometry.constrained(CGPoint(x: 100, y: 7), from: .zero, tool: .line)
        XCTAssertEqual(straight.y, 0, accuracy: 0.001)
    }
    func testUndoRedoAndDivergentEdit() {
        let canvas = CanvasHistory(); let first = stroke(); let second = stroke(.arrow)
        canvas.append(first); canvas.append(second)
        canvas.undo(); XCTAssertEqual(canvas.annotations, [first])
        canvas.redo(); XCTAssertEqual(canvas.annotations, [first, second])
        canvas.undo(); canvas.append(stroke(.rectangle))
        XCTAssertFalse(canvas.canRedo); XCTAssertEqual(canvas.annotations.count, 2)
    }
    func testEraserDragIsOneUndoableAction() {
        let canvas = CanvasHistory([stroke(.line), stroke(.line, from: CGPoint(x: 200, y: 0), to: CGPoint(x: 300, y: 100))])
        canvas.beginTransaction(); canvas.erase(at: CGPoint(x: 50, y: 50), radius: 8)
        canvas.erase(at: CGPoint(x: 250, y: 50), radius: 8); canvas.endTransaction()
        XCTAssertEqual(canvas.annotations.count, 0)
        canvas.undo(); XCTAssertEqual(canvas.annotations.count, 2)
        canvas.redo(); XCTAssertEqual(canvas.annotations.count, 0)
    }
    func testNoOpEraserPreservesUndoHistory() {
        let canvas = CanvasHistory([stroke()])
        canvas.beginTransaction(); canvas.erase(at: CGPoint(x: 900, y: 900), radius: 8); canvas.endTransaction()
        XCTAssertFalse(canvas.canUndo)
    }
    func testClearIsUndoableAndEmptyClearDoesNotAddHistory() {
        let canvas = CanvasHistory([stroke()])
        canvas.clear(); canvas.clear(); canvas.undo()
        XCTAssertEqual(canvas.annotations.count, 1); XCTAssertFalse(canvas.canUndo)
    }
    func testHistoryIsBounded() {
        let canvas = CanvasHistory()
        for _ in 0..<75 { canvas.append(stroke()) }
        for _ in 0..<100 { canvas.undo() }
        XCTAssertEqual(canvas.annotations.count, 15)
    }
    func testFadeTimingAndExpiredInkCannotResurrect() {
        let old = stroke(created: 100), new = stroke(created: 110)
        XCTAssertEqual(old.opacity(at: 102.9, fadeDelay: 3), 1)
        XCTAssertEqual(old.opacity(at: 103.4, fadeDelay: 3), 0.5, accuracy: 0.0001)
        XCTAssertEqual(old.opacity(at: 104, fadeDelay: 3), 0)
        XCTAssertEqual(old.opacity(at: 1000, fadeDelay: nil), 1)
        let canvas = CanvasHistory(); canvas.append(old); canvas.append(new)
        canvas.expire(at: 111, delay: 3)
        XCTAssertEqual(canvas.annotations, [new])
        canvas.undo(); XCTAssertTrue(canvas.annotations.isEmpty)
        canvas.redo(); XCTAssertEqual(canvas.annotations, [new])
    }
    func testCountdownPauseResumeAndSleep() {
        let start = Date(timeIntervalSince1970: 1000)
        var timer = Countdown(); timer.start(seconds: 300, now: start)
        timer.pause(now: start.addingTimeInterval(20))
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(100)), 280)
        timer.resume(now: start.addingTimeInterval(100))
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(130)), 250)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(500)), 0)
        timer.reset(seconds: 60); XCTAssertFalse(timer.isRunning); XCTAssertEqual(timer.remaining(), 60)
    }
    func testCountdownRoundingAndHours() {
        XCTAssertEqual(Countdown.formatted(59.2), "01:00")
        XCTAssertEqual(Countdown.formatted(0), "00:00")
        XCTAssertEqual(Countdown.formatted(-1), "00:00")
        XCTAssertEqual(Countdown.formatted(3661), "1:01:01")
    }
    func testBoardPersistenceRoundTripAndSeparateDisplays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boards.json")
        var text = stroke(.text); text.text = "Live demo ✓\nSecond line"; text.fontSize = 38
        let archive = BoardArchive(displays: ["display-one": [stroke(.rectangle), text], "display-two": [stroke(.arrow)]])
        try BoardStorage.save(archive, to: url)
        let loaded = try BoardStorage.load(from: url)
        XCTAssertEqual(loaded.displays, archive.displays)
        try BoardStorage.save(BoardArchive(displays: ["display-one": []]), to: url)
        XCTAssertEqual(try BoardStorage.load(from: url).displays["display-one"], [])
    }
    func testCorruptBoardFailsWithoutOverwriting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("not a board".utf8); try corrupt.write(to: url)
        XCTAssertThrowsError(try BoardStorage.load(from: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
    func testMissingBoardStartsEmptyAndUnknownVersionFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(try BoardStorage.load(from: url).displays.isEmpty)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"version\":99,\"displays\":{}}".utf8).write(to: url)
        XCTAssertThrowsError(try BoardStorage.load(from: url))
    }
    func testDefaultShortcutsAreUniqueAndComplete() {
        let prefs = Preferences()
        let shortcuts = Action.allCases.map { prefs.shortcut(for: $0) }
        XCTAssertEqual(Set(shortcuts).count, Action.allCases.count)
        XCTAssertEqual(DrawingTool.allCases.count, Action.allCases.filter { $0.tool != nil }.count)
        XCTAssertTrue(shortcuts.allSatisfy { $0.modifiers != 0 })
        let optIn: Set<Action> = [.overlayControls, .overlayNext, .overlayPrevious, .overlayVisibility, .overlayEnd]
        XCTAssertTrue(optIn.allSatisfy { !prefs.shortcut(for: $0).enabled }, "New overlay keys must not take over existing app shortcuts")
        XCTAssertTrue(Action.allCases.filter { !optIn.contains($0) }.allSatisfy { prefs.shortcut(for: $0).enabled }, "Existing shortcut defaults stay enabled")
        XCTAssertEqual(prefs.shortcut(for: .personaToggle).label, "⌃⌥I")
        XCTAssertEqual(prefs.shortcut(for: .personaPrevious).label, "⌃⌥←")
        XCTAssertEqual(prefs.shortcut(for: .personaNext).label, "⌃⌥→")
    }
    func testPreferencesPersistAndClamp() throws {
        let suite = "StageMarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.value.lineWidth = 900
        store.value.color = .mint
        store.value.activation = .toggle
        let reread = SettingsStore(defaults: defaults)
        XCTAssertEqual(reread.value.lineWidth, 20)
        XCTAssertEqual(reread.value.color, .mint)
        XCTAssertEqual(reread.value.activation, .toggle)
    }
    func testPersonaShortcutMigrationPreservesExistingOverlayKeys() throws {
        let suite = "StageMarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var previous = Preferences()
        previous.shortcuts.removeValue(forKey: Action.personaToggle.rawValue)
        previous.shortcuts.removeValue(forKey: Action.personaPrevious.rawValue)
        previous.shortcuts.removeValue(forKey: Action.personaNext.rawValue)
        previous.shortcuts[Action.overlayControls.rawValue] = Shortcut(
            keyCode: Action.personaToggle.defaultShortcut.keyCode,
            modifiers: Action.personaToggle.defaultShortcut.modifiers,
            enabled: true)
        defaults.set(try JSONEncoder().encode(previous), forKey: "preferences.v1")
        defaults.set(2, forKey: "preferences.schema")
        let migrated = SettingsStore(defaults: defaults)
        XCTAssertFalse(migrated.value.shortcut(for: .personaToggle).enabled,
            "A new default must not take over an existing enabled assignment")
        XCTAssertTrue(migrated.value.shortcut(for: .personaPrevious).enabled)
        XCTAssertTrue(migrated.value.shortcut(for: .personaNext).enabled)
        XCTAssertEqual(defaults.integer(forKey: "preferences.schema"), 3)
    }
    func testCorruptPreferencesArePreservedForRecovery() {
        let suite = "StageMarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("invalid".utf8); defaults.set(corrupt, forKey: "preferences.v1")
        let store = SettingsStore(defaults: defaults)
        XCTAssertNotNil(store.notice)
        XCTAssertEqual(defaults.data(forKey: "preferences.recovery"), corrupt)
    }
    func testAllToolsRenderToRealPixels() throws {
        _ = NSApplication.shared
        for tool in DrawingTool.allCases where tool != .eraser {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 180, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 240, height: 180).fill(using: .copy)
            var annotation = stroke(tool, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 120))
            annotation.text = "Demo"; InkRenderer.draw(annotation)
            NSGraphicsContext.restoreGraphicsState()
            var painted = 0
            for y in stride(from: 0, to: 180, by: 2) { for x in stride(from: 0, to: 240, by: 2) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 { painted += 1 }
            } }
            XCTAssertGreaterThan(painted, 15, "\(tool) did not draw visible pixels")
        }
    }
}
