import AppKit
import Carbon

final class AnnotationMenuTests: XCTestCase {
    private func withFixture(start: Bool = true, _ body: (AppCoordinator, AnnotationMenu) throws -> Void) throws {
        let suite = "WorkbenchAnnotationMenuTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        settings.value.onboardingComplete = true
        settings.value.autoFade = false
        settings.value.boardPalette = .hide
        for action in Action.allCases {
            var shortcut = action.defaultShortcut; shortcut.enabled = false
            settings.value.shortcuts[action.rawValue] = shortcut
        }
        let app = AppCoordinator(settings: settings, archiveURL: root.appendingPathComponent("boards.json"), embedded: true)
        app.demoScenes = DemoScenes(root: root.appendingPathComponent("Scenes"), systemIntegrationEnabled: false)
        if start { app.start() }
        defer { if start { app.shutdown() } }
        try body(app, AnnotationMenu(coordinator: app))
    }

    private func item(_ id: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier?.rawValue == "annotation.\(id)" { return item }
            if let submenu = item.submenu, let found = self.item(id, in: submenu) { return found }
        }
        return nil
    }

    private func invoke(_ id: String, in menu: NSMenu) {
        guard let item = item(id, in: menu), let owner = item.menu else {
            XCTAssertTrue(false, "Missing native annotation action \(id)"); return
        }
        owner.performActionForItem(at: owner.index(of: item))
    }

    private func reopen(_ menu: AnnotationMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
    }

    func testMenuUsesLiveShortcutsWithoutAddingAKeyRoute() throws {
        // This fixture never starts, so even enabled synthetic shortcuts remain
        // display data and cannot compete with a running app's registrations.
        try withFixture(start: false) { app, menu in
            XCTAssertEqual(menu.title, "Annotate")
            XCTAssertFalse(menu.autoenablesItems)
            for tool in DrawingTool.allCases {
                XCTAssertNotNil(menu.items.first { $0.identifier?.rawValue == "annotation.\(tool.rawValue)" })
            }
            XCTAssertTrue(item("pen", in: menu)?.toolTip?.contains("Shortcut off") == true)
            XCTAssertEqual(item("pen", in: menu)?.keyEquivalent, "")
            XCTAssertEqual(item("pen", in: menu)?.state, .on)
            XCTAssertEqual(item("finish", in: menu)?.isEnabled, false)

            app.settings.value.shortcuts[Action.pen.rawValue] = Shortcut(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | shiftKey))
            reopen(menu)
            XCTAssertEqual(item("pen", in: menu)?.keyEquivalent, String(UnicodeScalar(NSF18FunctionKey)!))
            XCTAssertEqual(item("pen", in: menu)?.keyEquivalentModifierMask, [.control, .option, .shift])
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.control, .option, .shift], timestamp: 0, windowNumber: 0,
                context: nil, characters: String(UnicodeScalar(NSF18FunctionKey)!),
                charactersIgnoringModifiers: String(UnicodeScalar(NSF18FunctionKey)!), isARepeat: false, keyCode: UInt16(kVK_F18))!
            XCTAssertFalse(menu.performKeyEquivalent(with: event), "The existing held-key owner alone dispatches shortcuts")
            let mainMenu = NSMenu(title: "Main")
            let annotationItem = NSMenuItem(title: "Annotate", action: nil, keyEquivalent: "")
            annotationItem.submenu = menu
            mainMenu.addItem(annotationItem)
            XCTAssertFalse(mainMenu.performKeyEquivalent(with: event), "Embedding under the app menu must not add a second key route")
            XCTAssertFalse(app.isDrawing)

            app.shortcutFailures[.pen] = "Synthetic registration conflict"
            reopen(menu)
            XCTAssertEqual(item("pen", in: menu)?.keyEquivalent, "")
            XCTAssertTrue(item("pen", in: menu)?.title.contains("unavailable") == true)
            XCTAssertTrue(item("pen", in: menu)?.toolTip?.contains("Synthetic registration conflict") == true)
            XCTAssertTrue(item("pen", in: menu)?.isEnabled == true, "An unavailable shortcut does not remove its clickable action")
            app.shortcutFailures.removeValue(forKey: .pen)
            app.settings.value.shortcuts[Action.pen.rawValue]?.enabled = false
            reopen(menu)
            XCTAssertEqual(item("pen", in: menu)?.title, "Pen")
            XCTAssertEqual(item("pen", in: menu)?.keyEquivalent, "")
            XCTAssertTrue(item("pen", in: menu)?.toolTip?.contains("Shortcut off") == true)
        }
    }

    func testNativeActionsRefreshSelectionAndHistory() throws {
        try withFixture { app, menu in
            XCTAssertEqual(item("undo", in: menu)?.isEnabled, false)
            XCTAssertEqual(item("redo", in: menu)?.isEnabled, false)
            invoke("arrow", in: menu)
            XCTAssertTrue(app.isDrawing)
            XCTAssertEqual(app.tool, .arrow)
            reopen(menu)
            XCTAssertEqual(item("arrow", in: menu)?.state, .on)
            XCTAssertEqual(item("pen", in: menu)?.state, .off)
            XCTAssertEqual(item("finish", in: menu)?.isEnabled, true)

            invoke("color4", in: menu)
            XCTAssertEqual(app.settings.value.color, .blue)
            reopen(menu)
            XCTAssertEqual(item("color4", in: menu)?.state, .on)
            invoke("black", in: menu)
            XCTAssertEqual(app.settings.value.color, .black)
            reopen(menu)
            XCTAssertEqual(item("black", in: menu)?.state, .on)
            XCTAssertEqual(item("color4", in: menu)?.state, .off)
            invoke("pointer", in: menu)
            invoke("fade", in: menu)
            reopen(menu)
            XCTAssertTrue(app.pointerEnabled)
            XCTAssertTrue(app.settings.value.autoFade)
            XCTAssertEqual(item("pointer", in: menu)?.state, .on)
            XCTAssertEqual(item("fade", in: menu)?.state, .on)
            app.settings.value.autoFade = false

            let mark = Annotation(tool: .arrow, color: .blue, width: 4,
                points: [InkPoint(CGPoint(x: 10, y: 10)), InkPoint(CGPoint(x: 40, y: 40))])
            app.history(for: app.currentID)?.append(mark)
            reopen(menu)
            XCTAssertEqual(item("undo", in: menu)?.isEnabled, true)
            invoke("undo", in: menu)
            XCTAssertEqual(app.history(for: app.currentID)?.annotations, [])
            reopen(menu)
            XCTAssertEqual(item("redo", in: menu)?.isEnabled, true)
            invoke("redo", in: menu)
            XCTAssertEqual(app.history(for: app.currentID)?.annotations, [mark])

            app.mayBeginInteraction = { false }
            app.mayBeginDrawing = { true }
            reopen(menu)
            XCTAssertEqual(item("pen", in: menu)?.isEnabled, true)
            XCTAssertEqual(item("undo", in: menu)?.isEnabled, false)
            XCTAssertEqual(item("whiteboard", in: menu)?.isEnabled, false)
            XCTAssertEqual(item("pointer", in: menu)?.isEnabled, false)
            XCTAssertEqual(item("clear", in: menu)?.isEnabled, true)
            app.mayBeginDrawing = { false }
            reopen(menu)
            XCTAssertEqual(item("arrow", in: menu)?.isEnabled, false)
            XCTAssertEqual(item("finish", in: menu)?.isEnabled, true)
            invoke("finish", in: menu)
            XCTAssertFalse(app.isDrawing, "Finishing remains available when admission is blocked")
            XCTAssertEqual(app.history(for: app.currentID)?.annotations, [mark])
        }
    }

    func testBoardsAndControlsPreserveInkUntilExplicitClear() throws {
        try withFixture { app, menu in
            var controls = 0, shortcuts = 0
            app.onOpenControls = { controls += 1 }
            app.onOpenShortcuts = { shortcuts += 1 }
            invoke("whiteboard", in: menu)
            let display = app.currentID
            XCTAssertEqual(app.boards[display], .white)
            let mark = Annotation(tool: .pen, color: .coral, width: 4,
                points: [InkPoint(CGPoint(x: 15, y: 15)), InkPoint(CGPoint(x: 45, y: 45))])
            app.history(for: display)?.append(mark)
            reopen(menu)
            XCTAssertEqual(item("whiteboard", in: menu)?.state, .on)
            XCTAssertEqual(item("blackboard", in: menu)?.state, .off)
            invoke("finish", in: menu)
            XCTAssertFalse(app.isDrawing)
            XCTAssertEqual(app.boards[display], .white)
            XCTAssertEqual(app.history(for: display)?.annotations, [mark])
            reopen(menu)
            invoke("controls", in: menu)
            XCTAssertEqual(controls, 1)
            XCTAssertEqual(app.selectedTab, "Drawing")
            XCTAssertEqual(app.boards[display], .white)
            XCTAssertEqual(app.history(for: display)?.annotations, [mark])
            invoke("shortcuts", in: menu)
            XCTAssertEqual(shortcuts, 1)
            XCTAssertEqual(app.boards[display], .white)
            invoke("blackboard", in: menu)
            XCTAssertEqual(app.boards[display], .black)
            reopen(menu)
            XCTAssertEqual(item("blackboard", in: menu)?.state, .on)
            invoke("clear", in: menu)
            XCTAssertFalse(app.isDrawing)
            XCTAssertTrue(app.boards.isEmpty)
            app.toggleBoard(.white)
            XCTAssertEqual(app.history(for: display)?.annotations, [], "Explicit Clear & return clears the board history")
        }
    }

    func testStaleMenuCannotBypassChangedAdmission() throws {
        try withFixture { app, menu in
            XCTAssertEqual(item("pen", in: menu)?.isEnabled, true)
            app.mayBeginDrawing = { false }
            invoke("pen", in: menu)
            XCTAssertFalse(app.isDrawing, "An open menu must recheck admission when clicked")
            app.mayBeginInteraction = { false }
            invoke("whiteboard", in: menu)
            XCTAssertTrue(app.boards.isEmpty)
            app.mayBeginDrawing = { true }
            app.mayBeginInteraction = { true }
            app.setShortcutsSuspended(true)
            reopen(menu)
            for id in ["pen", "arrow", "clear", "color1", "black", "controls", "shortcuts", "whiteboard"] {
                XCTAssertEqual(item(id, in: menu)?.isEnabled, false, "\(id) must respect keyboard practice")
            }
            invoke("pen", in: menu)
            XCTAssertFalse(app.isDrawing)
            app.setShortcutsSuspended(false)
            app.recordingAction = .pen
            reopen(menu)
            XCTAssertEqual(item("pen", in: menu)?.isEnabled, false)
            XCTAssertEqual(item("controls", in: menu)?.isEnabled, false)
            app.recordingAction = nil
        }
    }
}
