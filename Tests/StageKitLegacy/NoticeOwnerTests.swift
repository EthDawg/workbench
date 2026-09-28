import AppKit
import Carbon
import ServiceManagement

/// Each StageKit notice records the page that owns it where it is raised, and the controller the
/// menu-bar panel reads reports that page (#134 review). Guessing from the words sent all of these
/// to Draw; these fail on that version.
final class NoticeOwnerTests: XCTestCase {
    private struct LoginFixtureError: LocalizedError { var errorDescription: String? { "Synthetic login failure" } }

    /// A disposable coordinator and the controller the panel reads, on a temporary folder only.
    private func withFixture(settingsData: Data? = nil, _ body: @MainActor (AppCoordinator, StageKitController) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchNoticeOwnerTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: root.appendingPathComponent("settings").path)!
        if let settingsData { defaults.set(settingsData, forKey: "preferences.v1") }
        let settings = SettingsStore(defaults: defaults)
        let app = AppCoordinator(settings: settings, archiveURL: root.appendingPathComponent("boards.json"), embedded: true)
        let scenes = DemoScenes(root: root.appendingPathComponent("Scenes"), systemIntegrationEnabled: false)
        app.demoScenes = scenes
        defer { scenes.shutdown() }
        MainActor.assumeIsolated { body(app, StageKitController(coordinator: app)) }
    }

    func testShortcutRecordingNoticesBelongToKeyboard() {
        withFixture { app, stage in
            app.record(Shortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey)), for: .pen)
            XCTAssertEqual(stage.notice, "Include Control or Option with your shortcut.")
            XCTAssertTrue(stage.noticePage == .keyboard, "A shortcut without Control or Option is Settings › Keyboard's to explain")
            let taken = app.settings.value.shortcut(for: .arrow)
            app.record(Shortcut(keyCode: taken.keyCode, modifiers: taken.modifiers), for: .pen)
            XCTAssertEqual(stage.notice, "That shortcut belongs to \(Action.arrow.title). Choose another combination.")
            XCTAssertTrue(stage.noticePage == .keyboard, "A shortcut another action has is Settings › Keyboard's to explain")
            XCTAssertTrue(stage.notice(on: .keyboard) == stage.notice && stage.notice(on: .draw) == nil, "Keyboard owns it, not Draw")
        }
    }

    func testLoginNoticesBelongToGeneral() {
        withFixture { app, stage in
            app.loginItem = { _ in throw LoginFixtureError() }
            app.setLaunchAtLogin(true)
            XCTAssertEqual(stage.notice, "Login setting could not be changed: Synthetic login failure")
            XCTAssertTrue(stage.noticePage == .general, "Open at login is Settings › General's")
            XCTAssertFalse(app.launchAtLogin)
        }
    }

    func testSavedSettingsNoticesBelongToGeneral() {
        withFixture(settingsData: Data("invalid".utf8)) { app, stage in
            XCTAssertEqual(stage.notice, "Saved settings could not be read. Defaults are in use; the original settings have been preserved.")
            XCTAssertTrue(stage.noticePage == .general, "Saved settings are Settings › General's")
            XCTAssertTrue(stage.notice(on: .general) == stage.notice && stage.notice(on: .draw) == nil, "General owns it, not Draw")
            // A drawing notice raised afterwards is Draw's and comes first; General keeps its own.
            app.copyBoard()
            XCTAssertTrue(stage.noticePage == .draw, "A board that could not be copied is Draw's")
            XCTAssertTrue(stage.notice(on: .general) != nil, "General still shows its saved-settings notice")
            app.clearNotice(); app.settings.clearNotice()
            XCTAssertTrue(stage.notice == nil && stage.noticePage == nil, "Draw's dismiss clears both")
        }
    }
}
