import AppKit
import Carbon

final class CoreTests: XCTestCase {
    func stroke(_ tool: DrawingTool = .pen, from: CGPoint = .zero, to: CGPoint = CGPoint(x: 100, y: 100), created: Double = 100) -> Annotation {
        Annotation(tool: tool, color: .coral, width: 4, points: [InkPoint(from), InkPoint(to)], created: created)
    }

    func testInkColourAccessibilityDescriptions() {
        XCTAssertEqual(InkColor.presets.map(\.accessibilityDescription), ["Coral", "Amber", "Mint", "Blue", "Violet", "White"])
        XCTAssertEqual(InkColor(0.1, 0.2, 0.3).accessibilityDescription, "Custom #19334C")
        XCTAssertEqual([Action.color1, .color2, .color3, .color4, .color5, .color6].map(\.title),
                       ["Coral colour", "Amber colour", "Mint colour", "Blue colour", "Violet colour", "White colour"])
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
    func testScreenshotHandoffStateAndFadePause() {
        var state = ScreenshotHandoffState()
        XCTAssertTrue(state.begin(at: 100, autoFade: true))
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.begin(at: 101, autoFade: true), "A second capture cannot replace the active handoff")
        XCTAssertEqual(state.finish(at: 103), 3)
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.finish(at: 104), nil, "A late duplicate completion is ignored")

        var ink = Annotation(tool: .pen, color: .coral, width: 4, points: [InkPoint(.zero)])
        ink.created = 90
        let history = CanvasHistory([ink])
        history.pauseFade(by: 3)
        XCTAssertEqual(history.annotations.first?.created, 93)

        XCTAssertTrue(state.begin(at: 200, autoFade: false))
        XCTAssertEqual(state.finish(at: 205), nil, "A handoff must not age-shift ink when auto-fade is off")
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
        let on = Set(Action.allCases.filter { prefs.shortcut(for: $0).enabled })
        XCTAssertEqual(on, Action.presenterEssentials, "Only the presenter essentials start on; everything else is one recording away")
        XCTAssertEqual(prefs.shortcut(for: .pen).label, "⌃⌥S")
        XCTAssertEqual(prefs.shortcut(for: .personaToggle).label, "⌃⌥P")
        XCTAssertEqual(prefs.shortcut(for: .personaPrevious).label, "⌃⌥,")
        XCTAssertEqual(prefs.shortcut(for: .personaNext).label, "⌃⌥.")
        // Rectangle's recommended set (Magnet uses the same layout) takes these with Control-Option;
        // Spectacle uses ⌃⌥← and ⌃⌥→. Source: Rectangle/WindowAction.swift, alternateDefault.
        let windowKeys = Set([kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_E, kVK_ANSI_T, kVK_ANSI_R, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K,
                              kVK_ANSI_C, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_Delete].map(UInt32.init))
        for action in on {
            let shortcut = prefs.shortcut(for: action)
            XCTAssertTrue(shortcut.modifiers & UInt32(controlKey) != 0 && shortcut.modifiers & UInt32(optionKey) != 0, "\(action) uses the Workbench chord")
            XCTAssertFalse(shortcut.modifiers == UInt32(controlKey | optionKey) && windowKeys.contains(shortcut.keyCode), "\(action) default is a window-manager key")
        }
    }
    func testUpdateMovesOnlyUntouchedShortcutsToPresenterDefaults() throws {
        let suite = "StageMarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var previous = Preferences()
        for action in Action.allCases { previous.shortcuts[action.rawValue] = action.legacyDefaultShortcut }
        let chosen = Shortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(controlKey | optionKey))
        previous.shortcuts[Action.timer.rawValue] = chosen
        defaults.set(try JSONEncoder().encode(previous), forKey: "preferences.v1")
        defaults.set(3, forKey: "preferences.schema")
        let updated = SettingsStore(defaults: defaults)
        for action in Action.allCases where action != .timer {
            XCTAssertEqual(updated.value.shortcut(for: action), action.defaultShortcut, "\(action) was untouched, so it moves")
        }
        XCTAssertEqual(updated.value.shortcut(for: .timer), chosen, "A chosen shortcut is kept")
        XCTAssertEqual(defaults.integer(forKey: "preferences.schema"), 4)
        XCTAssertEqual(SettingsStore(defaults: defaults).value.shortcuts, updated.value.shortcuts, "The move is saved, not recomputed on every launch")
    }
    func testNewDefaultNeverTakesAChosenCombination() throws {
        let suite = "StageMarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var previous = Preferences()
        for action in Action.allCases { previous.shortcuts[action.rawValue] = action.legacyDefaultShortcut }
        // Someone moved drawing controls off ⌃⌥S and gave ⌃⌥S to the timer.
        previous.shortcuts[Action.controls.rawValue] = Shortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | optionKey))
        previous.shortcuts[Action.timer.rawValue] = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey))
        defaults.set(try JSONEncoder().encode(previous), forKey: "preferences.v1")
        defaults.set(3, forKey: "preferences.schema")
        let updated = SettingsStore(defaults: defaults)
        XCTAssertEqual(updated.value.shortcut(for: .timer).label, "⌃⌥S")
        XCTAssertEqual(updated.value.shortcut(for: .pen), Action.pen.legacyDefaultShortcut, "Draw keeps ⌃⌥D rather than take the timer's key")
        XCTAssertEqual(updated.value.shortcut(for: .personaToggle).label, "⌃⌥P", "Other untouched essentials still move")
    }
    func testUpdateReturnsAppCommandsToOtherApps() throws {
        let suite = "StageMarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var previous = Preferences()
        for action in Action.allCases { previous.shortcuts[action.rawValue] = action.legacyDefaultShortcut }
        // Chords a shortcut recorder captured from the top row; each one blocked a command in every app.
        for (action, key) in [(Action.pen, kVK_ANSI_E), (.highlighter, kVK_ANSI_W), (.arrow, kVK_ANSI_Q), (.clear, kVK_ANSI_R),
                              (.eraser, kVK_ANSI_S), (.whiteboard, kVK_ANSI_T), (.undo, kVK_ANSI_1)] {
            previous.shortcuts[action.rawValue] = Shortcut(keyCode: UInt32(key), modifiers: UInt32(cmdKey))
        }
        defaults.set(try JSONEncoder().encode(previous), forKey: "preferences.v1")
        defaults.set(3, forKey: "preferences.schema")
        let updated = SettingsStore(defaults: defaults)
        XCTAssertTrue(Action.allCases.allSatisfy { action in
            let shortcut = updated.value.shortcut(for: action)
            return !shortcut.enabled || GlobalShortcutRule.allows(modifiers: shortcut.modifiers)
        }, "No app command stays assigned")
        XCTAssertEqual(updated.value.shortcut(for: .pen).label, "⌃⌥S", "Draw lands on the presenter key, not on nothing")
        XCTAssertEqual(updated.value.shortcut(for: .highlighter).label, "⌃⌥H")
        XCTAssertEqual(updated.value.shortcut(for: .clear).label, "⌃⌥X")
        XCTAssertFalse(updated.value.shortcut(for: .eraser).enabled, "Tools outside the essentials start off")
    }
    func testFreshInstallKeepsLaterChoicesOfOldKeys() throws {
        let suite = "StageMarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = SettingsStore(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "preferences.schema"), 4)
        fresh.value.shortcuts[Action.timer.rawValue] = Action.timer.legacyDefaultShortcut
        XCTAssertTrue(SettingsStore(defaults: defaults).value.shortcut(for: .timer).enabled, "Turning a shortcut on with its old key sticks")
    }
    func testAppCommandsAreNeverRegisteredGlobally() {
        _ = NSApplication.shared
        var prefs = Preferences()
        for action in Action.allCases { var shortcut = action.defaultShortcut; shortcut.enabled = false; prefs.shortcuts[action.rawValue] = shortcut }
        prefs.shortcuts[Action.timer.rawValue] = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey))
        prefs.shortcuts[Action.redo.rawValue] = Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | shiftKey))
        let manager = HotkeyManager()
        manager.register(prefs)
        XCTAssertEqual(Set(manager.failures.keys), [.timer, .redo])
        XCTAssertTrue(manager.failures[.timer]?.contains("Control or Option") == true, "The row explains how to fix it")
        manager.unregister()
        XCTAssertTrue(GlobalShortcutRule.problem(label: "⌃⌘T", modifiers: UInt32(controlKey | cmdKey)) == nil, "Control or Option makes it a Workbench key")
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
            keyCode: Action.personaToggle.legacyDefaultShortcut.keyCode,
            modifiers: Action.personaToggle.legacyDefaultShortcut.modifiers,
            enabled: true)
        defaults.set(try JSONEncoder().encode(previous), forKey: "preferences.v1")
        defaults.set(2, forKey: "preferences.schema")
        let migrated = SettingsStore(defaults: defaults)
        XCTAssertFalse(migrated.value.shortcut(for: .personaToggle).enabled,
            "A new default must not take over an existing enabled assignment")
        XCTAssertTrue(migrated.value.shortcut(for: .personaPrevious).enabled)
        XCTAssertTrue(migrated.value.shortcut(for: .personaNext).enabled)
        XCTAssertEqual(defaults.integer(forKey: "preferences.schema"), 4)
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
