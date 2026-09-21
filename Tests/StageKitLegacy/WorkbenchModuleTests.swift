import AppKit
import Carbon

final class WorkbenchModuleTests: XCTestCase {
    private func withDrawingFixture(_ body: (AppCoordinator) throws -> Void) throws {
        let suite = "WorkbenchDrawingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        settings.value.onboardingComplete = true
        settings.value.autoFade = false
        // These tests drive the coordinator directly and never compete with a
        // running app for its ordinary global shortcuts.
        for action in Action.allCases {
            var shortcut = action.defaultShortcut; shortcut.enabled = false
            settings.value.shortcuts[action.rawValue] = shortcut
        }
        let app = AppCoordinator(settings: settings, archiveURL: root.appendingPathComponent("boards.json"), embedded: true)
        app.demoScenes = DemoScenes(root: root.appendingPathComponent("Scenes"), systemIntegrationEnabled: false)
        app.start(); defer { app.shutdown() }
        try body(app)
    }

    func testDrawingAdmissionIsSeparateFromGeneralInteraction() throws {
        try withDrawingFixture { app in
            app.mayBeginInteraction = { false }
            app.startDrawing(.pen, latched: true)
            XCTAssertFalse(app.isDrawing, "An unset drawing guard must retain the host's existing restriction")
            app.handleHotkey(.pen, down: true)
            XCTAssertFalse(app.isDrawing)
            app.perform(.arrow)
            XCTAssertFalse(app.isDrawing)

            app.mayBeginDrawing = { true }
            app.handleHotkey(.pen, down: true)
            XCTAssertTrue(app.isDrawing, "The host can admit held drawing during its voice operation")
            XCTAssertEqual(app.tool, .pen)
            app.mayBeginDrawing = { false }
            app.handleHotkey(.pen, down: false)
            XCTAssertFalse(app.isDrawing, "A release must complete even after admission changes")
            app.mayBeginDrawing = { true }
            app.perform(.arrow)
            XCTAssertTrue(app.isDrawing, "Clicked tools use the same narrow admission rule")
            XCTAssertEqual(app.tool, .arrow)
            app.toggleBoard(.white)
            app.toggleTimer()
            var screenshotLaunches = 0
            app.screenshotLauncher = { _ in screenshotLaunches += 1 }
            app.openScreenshot()
            XCTAssertTrue(app.boards.isEmpty, "Drawing permission must not allow a new board")
            XCTAssertFalse(app.timerSessionStarted)
            XCTAssertEqual(screenshotLaunches, 0)
            XCTAssertTrue(app.isDrawing, "Denied independent actions preserve active drawing")

            app.setShortcutsSuspended(true)
            XCTAssertFalse(app.isDrawing)
            app.perform(.pen)
            app.handleHotkey(.arrow, down: true)
            XCTAssertFalse(app.isDrawing, "Even permissive host admission cannot bypass keyboard practice")
            app.setShortcutsSuspended(false)
            app.recordingAction = .pen
            app.startDrawing(.arrow, latched: true)
            XCTAssertFalse(app.isDrawing, "Shortcut recording also owns keyboard input")
            app.recordingAction = nil
            app.mayBeginDrawing = nil
            app.mayBeginInteraction = { true }
            app.perform(.pen)
            XCTAssertTrue(app.isDrawing, "The fallback remains usable when the general guard permits it")

            app.mayBeginDrawing = { true }
            var finishScreenshot: (() -> Void)?
            app.screenshotLauncher = { completion in finishScreenshot = { completion(nil) } }
            app.startDrawing(.text, latched: true)
            app.onDrawingChanged = { drawing in
                if !drawing {
                    XCTAssertTrue(app.screenshotHandoffActive, "The host sees screenshot ownership before drawing ends")
                    XCTAssertTrue(app.panels.values.allSatisfy { !$0.isKeyWindow }, "Screenshot must release the annotation editor before notification")
                }
            }
            app.openScreenshot()
            XCTAssertTrue(app.screenshotHandoffActive)
            app.perform(.arrow); app.handleHotkey(.pen, down: true)
            XCTAssertFalse(app.isDrawing, "Even an explicit drawing allowance cannot intercept screenshot input")
            finishScreenshot?()
            let deadline = Date().addingTimeInterval(1)
            while app.screenshotHandoffActive && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertFalse(app.screenshotHandoffActive)
            app.onDrawingChanged = nil
        }
    }

    func testFinishDrawingPreservesBoardInkAndReportsSettledTransitions() throws {
        try withDrawingFixture { app in
            let display = app.currentID
            let overlayInk = Annotation(tool: .arrow, color: .coral, width: 4,
                points: [InkPoint(CGPoint(x: 10, y: 10)), InkPoint(CGPoint(x: 80, y: 80))])
            app.history(for: display)?.append(overlayInk)
            var transitions: [Bool] = []
            app.onDrawingChanged = { drawing in
                transitions.append(drawing)
                XCTAssertEqual(app.isDrawing, drawing, "Callbacks observe the new state")
                if !drawing {
                    XCTAssertTrue(app.panels.values.allSatisfy { !$0.isKeyWindow }, "Drawing releases keyboard focus before notifying the host")
                    if app.boards.isEmpty {
                        XCTAssertTrue(app.panels.values.allSatisfy(\.ignoresMouseEvents), "Screen input returns before the host can resume delivery")
                    }
                }
            }
            app.startDrawing(.pen, latched: true)
            app.startDrawing(.highlighter, latched: true)
            XCTAssertEqual(transitions, [true], "Tool changes are not drawing state transitions")
            app.stopDrawing(); app.stopDrawing()
            XCTAssertEqual(transitions, [true, false], "Finishing twice must not notify twice")
            XCTAssertEqual(app.history(for: display)?.annotations, [overlayInk])

            app.toggleBoard(.white)
            let boardInk = Annotation(tool: .rectangle, color: .blue, width: 5,
                points: [InkPoint(CGPoint(x: 20, y: 20)), InkPoint(CGPoint(x: 90, y: 90))])
            app.history(for: display)?.append(boardInk)
            let pendingInk = Annotation(tool: .pen, color: .coral, width: 3,
                points: [InkPoint(CGPoint(x: 30, y: 30)), InkPoint(CGPoint(x: 70, y: 70))])
            app.canvases[display]?.draft = pendingInk
            app.mayBeginInteraction = { false }; app.mayBeginDrawing = { false }
            app.stopDrawing()
            XCTAssertFalse(app.isDrawing, "Finishing never needs permission to begin another activity")
            XCTAssertEqual(app.boards[display], .white, "Done must preserve the board surface")
            let finishedInk = app.history(for: display)?.annotations ?? []
            XCTAssertEqual(finishedInk.map(\.id), [boardInk.id, pendingInk.id], "Done commits pending marks and preserves saved marks")
            XCTAssertEqual(finishedInk.first, boardInk)
            XCTAssertEqual(finishedInk.last?.points, pendingInk.points)
            XCTAssertEqual(finishedInk.last?.tool, pendingInk.tool)
            XCTAssertTrue(app.canvases[display]?.draft == nil)
            XCTAssertEqual(transitions, [true, false, true, false])
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 50),
                modifierFlags: [], timestamp: 0, windowNumber: app.panels[display]?.windowNumber ?? 0,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            app.canvases[display]?.mouseDown(with: click)
            XCTAssertFalse(app.isDrawing)
            XCTAssertTrue(app.canvases[display]?.draft == nil, "A visible board cannot bypass a denied drawing guard on click")
            XCTAssertEqual(app.history(for: display)?.annotations, finishedInk)
            app.boards.removeAll()
            XCTAssertEqual(app.history(for: display)?.annotations, [overlayInk], "Finishing the board must not mutate independent screen ink")
        }
    }

    func testShortcutReregistrationReleasesOnlyHeldDrawing() throws {
        try withDrawingFixture { app in
            app.handleHotkey(.pen, down: true)
            XCTAssertTrue(app.isDrawing)
            var shortcut = app.settings.value.shortcut(for: .pen)
            shortcut.keyCode = UInt32(kVK_F18)
            app.settings.value.shortcuts[Action.pen.rawValue] = shortcut
            XCTAssertFalse(app.isDrawing, "A removed key-up route must not leave held drawing active")
            app.handleHotkey(.pen, down: false)
            XCTAssertFalse(app.isDrawing)
            app.startDrawing(.arrow, latched: true)
            shortcut.keyCode = UInt32(kVK_F19)
            app.settings.value.shortcuts[Action.pen.rawValue] = shortcut
            XCTAssertTrue(app.isDrawing, "Editing a shortcut must preserve explicitly latched drawing")
        }
    }

    func testMigrationCopiesPreviewOnceAndPreservesMalformedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchMigration-" + UUID().uuidString)
        let suite = "WorkbenchMigrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let source = root.appendingPathComponent("StageMark Preview")
        let production = root.appendingPathComponent("StageMark")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Scenes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
        let malformed = Data("preserve this malformed archive".utf8)
        try malformed.write(to: source.appendingPathComponent("boards.json"))
        try malformed.write(to: source.appendingPathComponent("Scenes/scenes.json"))
        try Data("old Space recovery".utf8).write(to: source.appendingPathComponent("Scenes/desktop-restore.json"))
        try Data("production must not win".utf8).write(to: production.appendingPathComponent("boards.json"))
        let notice = Workbench.prepareStageData(applicationSupport: root, defaults: defaults, preview: true)
        XCTAssertTrue(notice == nil)
        let destination = root.appendingPathComponent("Workbench Preview/StageMark")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("boards.json")), malformed)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Scenes/scenes.json")), malformed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Scenes/desktop-restore.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Scenes/desktop-restore.json").path))
        XCTAssertThrowsError(try BoardStorage.load(from: destination.appendingPathComponent("boards.json")))
        let scenes = DemoScenes(root: destination.appendingPathComponent("Scenes"))
        XCTAssertTrue(scenes.storageBlocked)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Scenes/scenes.json")), malformed)
        let newData = Data("my new preview board".utf8)
        try newData.write(to: destination.appendingPathComponent("boards.json"))
        XCTAssertTrue(Workbench.prepareStageData(applicationSupport: root, defaults: defaults, preview: true) == nil)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("boards.json")), newData)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("boards.json")), malformed)
    }

    func testMigrationRejectsSymlinksAndRetriesCleanly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchMigrationLinks-" + UUID().uuidString)
        let suite = "WorkbenchMigrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let source = root.appendingPathComponent("StageMark")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("outside.json")
        let bytes = Data("unrelated original".utf8)
        try bytes.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("boards.json"), withDestinationURL: elsewhere)
        XCTAssertTrue(Workbench.prepareStageData(applicationSupport: root, defaults: defaults, preview: true) != nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Workbench Preview/StageMark").path))
        XCTAssertEqual(try Data(contentsOf: elsewhere), bytes)
        try FileManager.default.removeItem(at: source.appendingPathComponent("boards.json"))
        try BoardStorage.save(BoardArchive(), to: source.appendingPathComponent("boards.json"))
        XCTAssertTrue(Workbench.prepareStageData(applicationSupport: root, defaults: defaults, preview: true) == nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Workbench Preview/StageMark/boards.json").path))
    }

    func testEmbeddedCallbacksAndSuspendedShortcutSettings() throws {
        let suite = "WorkbenchEmbeddedTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        for action in Action.allCases { var shortcut = action.defaultShortcut; shortcut.enabled = false; settings.value.shortcuts[action.rawValue] = shortcut }
        let app = AppCoordinator(settings: settings, archiveURL: root.appendingPathComponent("boards.json"), embedded: true)
        app.demoScenes = DemoScenes(root: root.appendingPathComponent("Scenes"))
        var controls = 0, scenes = 0, keyboard = 0
        app.onOpenControls = { controls += 1 }
        app.onOpenScenes = { scenes += 1 }
        app.onOpenShortcuts = { keyboard += 1 }
        app.start()
        defer { app.shutdown() }
        XCTAssertFalse(app.hasPersistentMenuItem)
        app.showQuickControls(); app.showDemoScenes(); app.beginRecording(.pen)
        XCTAssertEqual(controls, 1); XCTAssertEqual(scenes, 1); XCTAssertEqual(keyboard, 1)
        XCTAssertTrue(app.recordingAction == nil)
        app.setShortcutsSuspended(true)
        settings.value.shortcuts[Action.pen.rawValue] = Shortcut(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | shiftKey))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_F18))!
        XCTAssertNotNil(app.hotkeys.handleLocalEvent(event))
        XCTAssertFalse(app.isDrawing)
        app.mayBeginInteraction = { false }
        app.startDrawing(.pen, latched: true)
        XCTAssertFalse(app.isDrawing)
        app.setShortcutsSuspended(false)
        XCTAssertTrue(app.shortcutFailures[.pen] == nil)
        XCTAssertTrue(app.hotkeys.handleLocalEvent(event) == nil)
        XCTAssertFalse(app.isDrawing)
    }
}
