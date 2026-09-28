import AppKit

/// The break timer's one transport state, driven through the coordinator that
/// owns it. Every global shortcut is off, so none is registered; the chime is
/// off, so nothing is heard; and the countdown reads a clock the test moves.
final class TimerTransportTests {
    private final class Clock { var now = Date(timeIntervalSinceReferenceDate: 800_000_000) }

    private func withTimer(_ body: (AppCoordinator, SettingsStore, Clock) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TimerTransport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A suite named by a path keeps its plist in this folder, not in ~/Library/Preferences.
        let defaults = UserDefaults(suiteName: root.appendingPathComponent("settings").path)!
        let settings = SettingsStore(defaults: defaults)
        settings.value.onboardingComplete = true
        settings.value.timerChime = false
        for action in Action.allCases {
            var shortcut = action.defaultShortcut; shortcut.enabled = false
            settings.value.shortcuts[action.rawValue] = shortcut
        }
        let display = BreakTimerDisplay(id: "timer-transport", visibleFrame: NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800))
        let app = AppCoordinator(settings: settings, archiveURL: root.appendingPathComponent("boards.json"), embedded: true,
                                 timerDisplays: { [display] }, timerFallbackID: { display.id })
        app.demoScenes = DemoScenes(root: root.appendingPathComponent("Scenes"), systemIntegrationEnabled: false)
        let clock = Clock()
        app.timerClock = { clock.now }
        app.start(); defer { app.shutdown() }
        try body(app, settings, clock)
    }

    private var timerVisible: Bool { NSApp.windows.contains { $0.title == "Workbench · Break timer" && $0.isVisible } }

    /// Lets the periodic countdown update run, as it does between the presenter's clicks.
    private func settle(until ready: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(ready() ? 0 : 0.6)
        while !ready() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testIdleAndResetOfferStartAndNeverResumeAHiddenCountdown() throws {
        try withTimer { app, settings, clock in
            settings.value.timerMinutes = 5
            var activities = 0
            app.onBeginActivity = { activities += 1 }
            XCTAssertEqual(app.timerTransport, .idle)
            XCTAssertEqual(app.timerTransport.title, "Start")
            // The Resume that used to sit beside Start break.
            app.pauseResumeTimer()
            clock.now += 30; settle()
            XCTAssertEqual(app.timerTransport, .idle, "Resume must not begin a new countdown")
            XCTAssertFalse(app.timerRunning); XCTAssertFalse(app.timerSessionStarted); XCTAssertFalse(app.hasActiveTimer)
            XCTAssertTrue(app.countdownTimer == nil, "Resume while idle must not start a periodic update")
            XCTAssertEqual(app.timerText, "05:00")
            XCTAssertFalse(timerVisible, "Nothing opens a hidden countdown")
            XCTAssertEqual(activities, 0)

            app.performTimerTransport()
            XCTAssertEqual(app.timerTransport, .running, "Start begins the countdown")
            XCTAssertEqual(activities, 1, "Start reports the activity like every other start")
            XCTAssertTrue(timerVisible, "Start opens the visible timer")
            XCTAssertTrue(app.countdownTimer != nil)

            app.resetTimer()
            XCTAssertEqual(app.timerTransport, .idle, "Reset returns to Start")
            XCTAssertTrue(app.countdownTimer == nil)
            app.pauseResumeTimer()
            clock.now += 30; settle()
            XCTAssertEqual(app.timerTransport, .idle, "Reset leaves nothing to resume")
            XCTAssertFalse(app.timerSessionStarted); XCTAssertTrue(app.countdownTimer == nil)
            XCTAssertEqual(app.timerText, "05:00")

            app.mayBeginInteraction = { false }
            app.performTimerTransport()
            XCTAssertEqual(app.timerTransport, .idle, "Start keeps the host's admission")
            XCTAssertEqual(activities, 1)
            app.mayBeginInteraction = nil
            app.hideTimer()
        }
    }

    func testFinishedOffersRestartThroughTheNormalStartPath() throws {
        try withTimer { app, settings, clock in
            settings.value.timerMinutes = 1
            var activities = 0
            app.onBeginActivity = { activities += 1 }
            app.startTimer()
            XCTAssertFalse(settings.value.timerChime, "The chime stays off in checks")
            clock.now += 61
            settle { app.timerFinished }
            XCTAssertEqual(app.timerTransport, .finished)
            XCTAssertEqual(app.timerTransport.title, "Restart")
            XCTAssertEqual(app.timerText, "00:00")
            XCTAssertFalse(app.hasActiveTimer, "A finished timer is no longer an active job")
            XCTAssertTrue(app.countdownTimer == nil, "Finishing stops the periodic update")

            // The Resume that used to stay enabled on the page after finishing.
            app.pauseResumeTimer()
            settle()
            XCTAssertEqual(app.timerTransport, .finished, "Resume after finishing does nothing")
            XCTAssertTrue(app.countdownTimer == nil, "Resume after finishing must not start a periodic update")
            XCTAssertEqual(app.timerText, "00:00")

            // Restart uses the configured duration and the normal start path, even when hidden.
            app.hideTimer()
            XCTAssertFalse(timerVisible)
            settings.value.timerMinutes = 3
            XCTAssertEqual(app.timerText, "00:00", "A duration edit waits for Restart")
            app.performTimerTransport()
            XCTAssertEqual(app.timerTransport, .running)
            XCTAssertEqual(app.timerText, "03:00", "Restart uses the configured duration")
            XCTAssertEqual(activities, 2, "Restart reports the activity like Start")
            XCTAssertTrue(timerVisible, "Restart opens the visible timer")

            // A countdown that reaches zero between updates finishes instead of pausing at 00:00.
            clock.now += 180
            app.pauseResumeTimer()
            XCTAssertEqual(app.timerTransport, .finished)
            XCTAssertTrue(app.countdownTimer == nil)
            app.resetTimer(); app.hideTimer()
        }
    }

    func testPausedResumeKeepsItsTimeAndTheShortcutOnlyShowsOrHides() throws {
        try withTimer { app, settings, clock in
            settings.value.timerMinutes = 5
            app.startTimer()
            clock.now += 90
            app.performTimerTransport()
            XCTAssertEqual(app.timerTransport, .paused)
            XCTAssertEqual(app.timerTransport.title, "Resume")
            XCTAssertEqual(app.timerText, "03:30")
            XCTAssertTrue(app.countdownTimer == nil, "A paused countdown has no periodic update")
            XCTAssertTrue(app.hasActiveTimer, "A paused timer is still an active job")
            settings.value.timerMinutes = 10
            clock.now += 600
            XCTAssertEqual(app.timerText, "03:30", "A duration edit during a pause waits for the next Start or Reset")

            // The timer shortcut hides and reopens; it never pauses or resumes.
            app.handleHotkey(.timer, down: true)
            XCTAssertFalse(timerVisible)
            XCTAssertEqual(app.timerTransport, .paused); XCTAssertEqual(app.timerText, "03:30")
            app.handleHotkey(.timer, down: true)
            XCTAssertTrue(timerVisible)
            XCTAssertEqual(app.timerTransport, .paused); XCTAssertEqual(app.timerText, "03:30")

            app.performTimerTransport()
            XCTAssertEqual(app.timerTransport, .running)
            clock.now += 30
            settle { app.timerText == "03:00" }
            XCTAssertEqual(app.timerText, "03:00", "Resume continues from the paused time, not the new duration")
            app.handleHotkey(.timer, down: true)
            XCTAssertFalse(timerVisible)
            XCTAssertEqual(app.timerTransport, .running, "Hiding keeps a running countdown")
            clock.now += 60
            app.handleHotkey(.timer, down: true)
            XCTAssertTrue(timerVisible)
            settle { app.timerText == "02:00" }
            XCTAssertEqual(app.timerText, "02:00", "Reopening keeps the running countdown's time")
            XCTAssertEqual(app.timerTransport, .running)

            app.resetTimer()
            XCTAssertEqual(app.timerText, "10:00", "Reset applies the edited duration")
            XCTAssertEqual(app.timerTransport, .idle)
            app.hideTimer()
        }
    }

    func testTransportLeavesMarksAndBoardsAlone() throws {
        try withTimer { app, settings, clock in
            settings.value.timerMinutes = 1
            let display = app.currentID
            let ink = Annotation(tool: .arrow, color: .coral, width: 4, points: [InkPoint(CGPoint(x: 10, y: 10)), InkPoint(CGPoint(x: 90, y: 90))])
            app.history(for: display)?.append(ink)
            app.performTimerTransport()
            app.performTimerTransport()
            app.performTimerTransport()
            clock.now += 61
            settle { app.timerFinished }
            app.performTimerTransport()
            app.resetTimer(); app.hideTimer()
            XCTAssertEqual(app.history(for: display)?.annotations, [ink], "Timer transport keeps existing marks")
            XCTAssertTrue(app.boards.isEmpty); XCTAssertFalse(app.isDrawing)
        }
    }
}
