import AppKit

final class IntegrationTests: XCTestCase {
    func testFirstStrokeAfterActivationReachesInactiveCanvas() throws {
        let suite = "StageMarkFirstClick.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(defaults: defaults)
        settings.value.onboardingComplete = true; settings.value.activation = .toggle
        let app = AppCoordinator(settings: settings, archiveURL: directory.appendingPathComponent("boards.json"))
        app.start(); defer { app.shutdown() }
        let id = app.currentID, canvas = app.canvases[id]!, panel = app.panels[id]!
        func event(_ type: NSEvent.EventType, x: Double, y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: canvas.bounds.height - y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let down = event(.leftMouseDown, x: 120, y: 140)
        XCTAssertFalse(canvas.acceptsFirstMouse(for: down), "Idle overlays must not claim clicks")
        for usingShortcut in [true, false] {
            if usingShortcut {
                app.handleHotkey(.pen, down: true); app.handleHotkey(.pen, down: false)
            } else {
                app.showQuickControls(); app.startDrawing(.pen, latched: true)
            }
            panel.resignKey()
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertTrue(canvas.acceptsFirstMouse(for: down), "The first click must reach a newly activated canvas")
            let count = canvas.history!.annotations.count
            // Use NSWindow's dispatch path, not a direct call to the view handler.
            panel.sendEvent(down)
            XCTAssertTrue(canvas.draft != nil, "The initial mouse-down must start the stroke")
            panel.sendEvent(event(.leftMouseDragged, x: 210, y: 190))
            panel.sendEvent(event(.leftMouseUp, x: 210, y: 190))
            XCTAssertEqual(canvas.history!.annotations.count, count + 1)
            XCTAssertEqual(canvas.history!.annotations.last?.first, CGPoint(x: 120, y: 140))
            XCTAssertEqual(canvas.history!.annotations.last?.last, CGPoint(x: 210, y: 190))
            app.handleHotkey(.pen, down: true); app.handleHotkey(.pen, down: false)
            XCTAssertFalse(app.isDrawing)
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertFalse(canvas.acceptsFirstMouse(for: down))
        }
        app.toggleBoard(.white)
        app.stopDrawing()
        XCTAssertTrue(canvas.acceptsFirstMouse(for: down), "A visible board must accept its first stroke too")
        app.escape()
        XCTAssertFalse(canvas.acceptsFirstMouse(for: down))
    }
    func testMenuBarAccessAndQuickAdjustmentsPreserveBoard() throws {
        _ = NSApplication.shared
        let suite = "StageMarkMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(defaults: defaults); settings.value.onboardingComplete = true
        let app = AppCoordinator(settings: settings, archiveURL: directory.appendingPathComponent("boards.json"))
        app.start(); defer { app.shutdown() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(app.hasPersistentMenuItem)
        XCTAssertTrue(app.panels.values.allSatisfy { $0.level.rawValue < NSWindow.Level.mainMenu.rawValue }, "The canvas must not intercept menu-bar access")
        app.toggleBoard(.white)
        let id = app.currentID
        let ink = Annotation(tool: .pen, color: .coral, width: 4, points: [InkPoint(CGPoint(x: 100, y: 100))])
        app.history(for: id)?.append(ink)
        app.showQuickControls()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(app.quickControlsVisible)
        XCTAssertTrue(app.isDrawing)
        XCTAssertEqual(app.boards[id], .white)
        settings.value.color = .blue
        settings.value.lineWidth = 8
        XCTAssertEqual(app.history(for: id)?.annotations, [ink], "Quick adjustments must preserve existing ink")
        XCTAssertTrue(app.quickControlsVisible)
        app.beginRecording(.arrow)
        XCTAssertEqual(app.recordingAction, .arrow)
        XCTAssertTrue(app.quickControlsVisible, "Shortcut recording must stay in the popover")
        app.finishRecording()
        app.hideQuickControls()
        XCTAssertFalse(app.quickControlsVisible)
        XCTAssertTrue(app.hasPersistentMenuItem)
        app.showQuickControls()
        app.startDrawing(.rectangle, latched: true)
        XCTAssertFalse(app.quickControlsVisible, "Choosing a tool should dismiss the controls")
        XCTAssertTrue(app.isDrawing)
        XCTAssertEqual(app.tool, .rectangle)
        XCTAssertEqual(app.history(for: id)?.annotations, [ink])
        app.showQuickControls()
        app.perform(.clear)
        XCTAssertFalse(app.quickControlsVisible)
        XCTAssertFalse(app.isDrawing)
        XCTAssertTrue(app.boards.isEmpty)
        XCTAssertTrue(app.hasPersistentMenuItem)
    }
    func testActualMouseHandlersAndTextCommit() throws {
        _ = NSApplication.shared
        let suite = "StageMarkInput.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(defaults: defaults); settings.value.onboardingComplete = true
        let app = AppCoordinator(settings: settings, archiveURL: directory.appendingPathComponent("boards.json"))
        app.start(); defer { app.shutdown() }
        let id = app.currentID, canvas = app.canvases[id]!, panel = app.panels[id]!
        func event(_ type: NSEvent.EventType, x: Double, y: Double, shift: Bool = false) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: canvas.bounds.height - y),
                modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        for tool in [DrawingTool.pen, .highlighter, .arrow, .line, .rectangle, .ellipse] {
            app.startDrawing(tool, latched: true)
            let before = app.history(for: id)!.annotations.count
            canvas.mouseDown(with: event(.leftMouseDown, x: 100, y: 100))
            canvas.mouseDragged(with: event(.leftMouseDragged, x: 240, y: 185, shift: tool == .rectangle))
            canvas.mouseUp(with: event(.leftMouseUp, x: 240, y: 185))
            XCTAssertEqual(app.history(for: id)!.annotations.count, before + 1)
            let ink = app.history(for: id)!.annotations.last!
            XCTAssertEqual(ink.tool, tool)
            XCTAssertEqual(ink.first, CGPoint(x: 100, y: 100))
            if tool == .rectangle { XCTAssertEqual(ink.rect.width, ink.rect.height) }
        }
        app.startDrawing(.text, latched: true)
        let editor = canvas.subviews.compactMap { $0 as? NSTextView }.first!
        editor.insertText("Live software demo ✓", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.commitText()
        XCTAssertEqual(app.history(for: id)!.annotations.last?.text, "Live software demo ✓")
        app.startDrawing(.eraser, latched: true)
        let before = app.history(for: id)!.annotations.count
        canvas.mouseDown(with: event(.leftMouseDown, x: 100, y: 100))
        canvas.mouseUp(with: event(.leftMouseUp, x: 100, y: 100))
        XCTAssertEqual(app.history(for: id)!.annotations.count, before - 1)
        app.perform(.undo); XCTAssertEqual(app.history(for: id)!.annotations.count, before)
        app.escape(); XCTAssertTrue(panel.ignoresMouseEvents)
    }
    func testDrawingLifecycleAndBoardIsolation() throws {
        _ = NSApplication.shared
        let suite = "StageMarkIntegration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(defaults: defaults)
        settings.value.onboardingComplete = true
        let app = AppCoordinator(settings: settings, archiveURL: directory.appendingPathComponent("boards.json"))
        app.start()
        defer { app.shutdown() }
        let shortcut = settings.value.shortcut(for: .pen)
        let keyDown = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 1,
            windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: UInt16(shortcut.keyCode))!
        let keyUp = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 2,
            windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: UInt16(shortcut.keyCode))!
        XCTAssertTrue(app.hotkeys.handleLocalEvent(keyDown) == nil)
        XCTAssertTrue(app.isDrawing)
        XCTAssertTrue(app.hotkeys.handleLocalEvent(keyUp) == nil)
        XCTAssertFalse(app.isDrawing)
        let normalKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 3,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        XCTAssertNotNil(app.hotkeys.handleLocalEvent(normalKey))
        settings.value.timerMinutes = 1
        app.startTimer(); app.pauseResumeTimer()
        XCTAssertFalse(app.timerRunning)
        let pausedText = app.timerText
        settings.value.timerMessage = "A different message"
        settings.value.timerMinutes = 10
        XCTAssertEqual(app.timerText, pausedText, "Editing timer settings must preserve a paused session")
        app.hideTimer(); app.toggleTimer()
        XCTAssertFalse(app.timerRunning, "Reopening a paused timer must not restart it")
        XCTAssertEqual(app.timerText, pausedText, "Reopening a paused timer must preserve its remaining time")
        XCTAssertTrue(app.timerSessionStarted)
        app.resetTimer(); XCTAssertEqual(app.timerText, "10:00")
        XCTAssertFalse(app.timerSessionStarted)
        app.hideTimer()
        XCTAssertGreaterThan(app.displayCount, 0)
        XCTAssertTrue(app.panels.values.allSatisfy { $0.ignoresMouseEvents })
        app.handleHotkey(.pen, down: true)
        XCTAssertTrue(app.isDrawing)
        XCTAssertTrue(app.panels.values.allSatisfy { !$0.ignoresMouseEvents })
        app.handleHotkey(.pen, down: false)
        XCTAssertFalse(app.isDrawing)
        XCTAssertTrue(app.panels.values.allSatisfy { $0.ignoresMouseEvents })
        settings.value.activation = .toggle
        app.handleHotkey(.arrow, down: true); app.handleHotkey(.arrow, down: false)
        XCTAssertTrue(app.isDrawing)
        XCTAssertEqual(app.tool, .arrow)
        app.handleHotkey(.arrow, down: true)
        XCTAssertFalse(app.isDrawing)
        let display = app.currentID
        let screenStroke = Annotation(tool: .arrow, color: .coral, width: 5, points: [InkPoint(CGPoint(x: 80, y: 80)), InkPoint(CGPoint(x: 180, y: 180))])
        app.history(for: display)?.append(screenStroke)
        app.toggleBoard(.white)
        XCTAssertEqual(app.boards[display], .white)
        XCTAssertTrue(app.history(for: display)?.annotations.isEmpty == true)
        let boardStroke = Annotation(tool: .rectangle, color: .blue, width: 4, points: [InkPoint(CGPoint(x: 200, y: 200)), InkPoint(CGPoint(x: 450, y: 450))])
        app.history(for: display)?.append(boardStroke)
        app.escape()
        XCTAssertTrue(app.boards.isEmpty)
        XCTAssertFalse(app.isDrawing)
        XCTAssertEqual(app.history(for: display)?.annotations, [screenStroke])
        app.toggleBoard(.black)
        XCTAssertEqual(app.history(for: display)?.annotations, [boardStroke])
        app.perform(.clear)
        XCTAssertTrue(app.boards.isEmpty)
        XCTAssertFalse(app.isDrawing)
        app.toggleBoard(.white)
        XCTAssertTrue(app.history(for: display)?.annotations.isEmpty == true)
        app.escape()
        app.perform(.clear)
        XCTAssertTrue(app.history(for: display)?.annotations.isEmpty == true)
        XCTAssertTrue(app.panels.values.allSatisfy { $0.ignoresMouseEvents })
    }
    func testScreenshotHandoffPreservesInkAndSuspendsInput() throws {
        _ = NSApplication.shared
        let suite = "WorkbenchScreenshotHandoff.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(defaults: defaults)
        settings.value.onboardingComplete = true; settings.value.autoFade = true; settings.value.fadeDelay = 3
        let app = AppCoordinator(settings: settings, archiveURL: directory.appendingPathComponent("boards.json"), embedded: true)
        app.start(); defer { app.shutdown() }
        func waitForScreenshotCompletion() {
            // Completion is dispatched to the main queue. Wait for its state
            // transition instead of assuming it runs within 50 ms under load.
            let deadline = Date().addingTimeInterval(2)
            while app.screenshotHandoffActive && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        let display = app.currentID
        var ink = Annotation(tool: .arrow, color: .coral, width: 5,
                             points: [InkPoint(CGPoint(x: 60, y: 80)), InkPoint(CGPoint(x: 180, y: 160))])
        ink.created = Date.timeIntervalSinceReferenceDate - 1
        app.history(for: display)?.append(ink)
        app.startDrawing(.pen, latched: true)
        app.pointerEnabled = true; app.canvases[display]?.pointerVisible = true
        var finishScreenshot: (() -> Void)?
        var launches = 0
        app.screenshotLauncher = { completion in
            launches += 1
            finishScreenshot = { completion(nil) }
        }

        app.openScreenshot()
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(app.screenshotHandoffActive)
        XCTAssertFalse(app.isDrawing)
        XCTAssertTrue(app.panels.values.allSatisfy(\.ignoresMouseEvents), "Screenshot selection must receive input instead of the annotation canvas")
        XCTAssertFalse(app.canvases[display]?.pointerVisible ?? true, "The Workbench pointer is excluded from the screenshot handoff")
        XCTAssertEqual(app.history(for: display)?.annotations.map(\.id), [ink.id])
        app.startDrawing(.rectangle, latched: true); app.perform(.clear); app.escape()
        XCTAssertTrue(app.screenshotHandoffActive, "Workbench Escape must not close or mutate the Apple Screenshot session")
        XCTAssertFalse(app.isDrawing)
        XCTAssertEqual(app.history(for: display)?.annotations.map(\.id), [ink.id], "Capture selection cannot erase visible ink")

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        finishScreenshot?()
        waitForScreenshotCompletion()
        XCTAssertFalse(app.screenshotHandoffActive)
        let preserved = app.history(for: display)?.annotations.first
        XCTAssertNotNil(preserved)
        XCTAssertEqual(preserved?.id, ink.id)
        if let preserved { XCTAssertGreaterThan(preserved.created, ink.created, "Auto-fade time must pause while Screenshot is open") }
        app.startDrawing(.rectangle, latched: true)
        XCTAssertTrue(app.isDrawing, "Drawing must be usable again after Screenshot closes")

        var recoveredControls = false
        app.onOpenControls = { recoveredControls = true }
        app.screenshotLauncher = { completion in
            completion(NSError(domain: "ScreenshotFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic launch failure"]))
        }
        app.openScreenshot()
        waitForScreenshotCompletion()
        XCTAssertFalse(app.screenshotHandoffActive)
        XCTAssertTrue(app.notice?.contains("Synthetic launch failure") == true)
        XCTAssertTrue(recoveredControls, "A launch failure must reopen the host controls so its notice can be read")
        XCTAssertEqual(app.history(for: display)?.annotations.map(\.id), [ink.id], "A failed launch must not clear annotations")
        app.toggleBoard(.white)
        let boardInk = Annotation(tool: .pen, color: .coral, width: 3,
                                  points: [InkPoint(CGPoint(x: 20, y: 20)), InkPoint(CGPoint(x: 80, y: 70))])
        app.history(for: display)?.append(boardInk)
        let boardIDs = app.history(for: display)?.annotations.map(\.id)
        app.openScreenshot()
        waitForScreenshotCompletion()
        XCTAssertEqual(app.boards[display], .white, "Recovery must preserve the visible board")
        XCTAssertEqual(app.history(for: display)?.annotations.map(\.id), boardIDs, "Recovery must preserve board ink")
    }
    func testShortcutRegistrationAndRelease() {
        _ = NSApplication.shared
        let manager = HotkeyManager()
        manager.register(Preferences())
        XCTAssertTrue(manager.failures.isEmpty, "Default shortcut conflicts: \(manager.failures)")
        manager.unregister()
        manager.register(Preferences())
        XCTAssertTrue(manager.failures.isEmpty, "Shortcut registrations were not released")
        manager.unregister()
    }
}
