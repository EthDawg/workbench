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

    private var timerVisible: Bool { NSApp.windows.contains { $0.title == "Workbench · Timer" && $0.isVisible } }

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

    /// Chooses a menu item as a menu does.
    private func choose(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        _ = (item.target as AnyObject?)?.perform(action, with: item)
    }

    /// A transport a control showed is the one it performs, and only while it still applies
    /// (#174). Drawn while the countdown runs, More's Pause timer, the Timer menu's Pause Timer and
    /// the timer's own Pause button do nothing once it has finished: none restarts it. Restart
    /// comes only from a control drawn after it finished. A Pause shown before another control
    /// paused the countdown never resumes it, and a step shown for one countdown does nothing to
    /// the next, though it has the same name.
    func testAShownTransportIsTheOnlyOneItPerforms() throws {
        try withTimer { app, settings, clock in
            MainActor.assumeIsolated {
                settings.value.timerMinutes = 1
                var starts = 0
                app.onBeginActivity = { starts += 1 }
                let stage = StageKitController(coordinator: app)
                app.startTimer()
                XCTAssertEqual(starts, 1)
                // Drawn while it runs: More's item keeps the step More showed, the Timer menu its item,
                // and the timer's window, the quick controls and the Draw page their button's action.
                let more = stage.timerStep
                guard let menu = stage.makeTimerMenu().items.first(where: { $0.title == "Pause Timer" }) else {
                    XCTAssertTrue(false, "The Timer menu offers Pause Timer while it runs"); return
                }
                let button = TimerTransportAction(app)
                XCTAssertEqual(more.transport, .running)
                XCTAssertEqual(button.transport, .running)
                clock.now += 61
                settle { app.timerFinished }
                XCTAssertEqual(app.timerTransport, .finished)
                // Each on its own, so one cannot undo what another did.
                stage.performTimerTransport(expected: more)
                XCTAssertEqual(app.timerTransport, .finished, "More's Pause timer shown while it ran never restarts a finished timer")
                choose(menu)
                XCTAssertEqual(app.timerTransport, .finished, "nor does the Timer menu's Pause Timer")
                button()
                XCTAssertEqual(app.timerTransport, .finished, "nor the timer's own Pause button")
                XCTAssertEqual(starts, 1, "and none begins a new countdown")
                XCTAssertEqual(app.timerText, "00:00")
                // Drawn after it finished, Restart restarts.
                let restart = stage.timerStep
                XCTAssertEqual(restart.transport, .finished)
                stage.performTimerTransport(expected: restart)
                XCTAssertEqual(app.timerTransport, .running, "a Restart drawn after the end restarts")
                XCTAssertEqual(starts, 2)
                // A Pause shown before another control paused the countdown does not resume it.
                let shownPause = stage.timerStep
                guard let shownMenu = stage.makeTimerMenu().items.first(where: { $0.title == "Pause Timer" }) else {
                    XCTAssertTrue(false, "The Timer menu offers Pause Timer after the restart"); return
                }
                let shownButton = TimerTransportAction(app)
                app.pauseResumeTimer()
                XCTAssertEqual(app.timerTransport, .paused)
                stage.performTimerTransport(expected: shownPause)
                XCTAssertEqual(app.timerTransport, .paused, "More's Pause timer shown before the pause never resumes")
                choose(shownMenu)
                XCTAssertEqual(app.timerTransport, .paused, "nor does the Timer menu's Pause Timer")
                shownButton()
                XCTAssertEqual(app.timerTransport, .paused, "nor the timer's own Pause button")
                // A step shown for one countdown does nothing to the next, the same step by name.
                let oldResume = stage.timerStep
                XCTAssertEqual(oldResume.transport, .paused)
                app.resetTimer(); app.startTimer(); app.pauseResumeTimer()
                XCTAssertEqual(app.timerTransport, .paused)
                XCTAssertEqual(starts, 3)
                stage.performTimerTransport(expected: oldResume)
                XCTAssertEqual(app.timerTransport, .paused, "the last countdown's Resume leaves the new one paused")
                stage.performTimerTransport(expected: stage.timerStep)
                XCTAssertEqual(app.timerTransport, .running, "the new countdown's own Resume resumes it")
                app.resetTimer(); app.hideTimer()
            }
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
    /// One name and one word set on every surface (1 October): the Timer menu, the panel's
    /// Options, Home and the chooser offer the one next step, Show or Hide timer for the
    /// window alone and Stop timer; never a second Start that silently restarts a running
    /// countdown. Every surface reads one state line, a finished timer stays until it is
    /// stopped, and Position is kept before the window has ever opened.
    func testOneNameAndWordSetFollowTheTimerEverywhere() throws {
        try withTimer { app, settings, clock in
            try MainActor.assumeIsolated {
                settings.value.timerMinutes = 1
                let stage = StageKitController(coordinator: app)
                func titles(_ menu: NSMenu) -> [String] { menu.items.map(\.title) }
                func item(_ menu: NSMenu, _ title: String) throws -> NSMenuItem {
                    guard let found = menu.items.first(where: { $0.title == title }) else {
                        throw TimerWordsError.missing(title, titles(menu))
                    }
                    return found
                }
                XCTAssertEqual(Action.timer.title, "Timer", "The shortcut has the capability's name")
                // Position is a Timer option, kept before the window first opens.
                app.setTimerPosition(.topLeft)
                XCTAssertEqual(app.timerPlacementAnchor, .topLeft, "Position from the panel works before the timer has opened")
                XCTAssertFalse(timerVisible, "Choosing a position opens nothing")
                // Position… is one control with the eight docks, the floating toolbar's, never a
                // submenu of anchors (#134 Fit rule 1). It opens before the window ever has.
                for menu in [stage.makeTimerMenu(), stage.makeTimerMenu(optionsOnly: true)] {
                    XCTAssertTrue(titles(menu).contains("Position…"), "Position… is in the Timer menu and the panel's Options: \(titles(menu))")
                    XCTAssertFalse(menu.items.contains { $0.title == "Position" && $0.hasSubmenu }, "No tree of anchors remains: \(titles(menu))")
                }
                XCTAssertFalse(stage.isTimerPositionControlShown)
                choose(try item(stage.makeTimerMenu(optionsOnly: true), "Position…"))
                XCTAssertTrue(stage.isTimerPositionControlShown, "Position… opens its control before the timer window exists")
                XCTAssertFalse(timerVisible, "and opens no timer window")
                let control = app.timerPositionPanel.window
                XCTAssertEqual(control?.title, "Timer position")
                XCTAssertTrue(control?.isVisible == true && control?.isKeyWindow == true, "The control takes the keyboard")
                XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(control?.frame ?? .infinite) }, "and sits on a display: \(String(describing: control?.frame))")
                app.timerPositionPanel.close()
                XCTAssertFalse(stage.isTimerPositionControlShown, "Escape, a choice or a click elsewhere closes it")
                XCTAssertEqual(app.timerPlacementAnchor, .topLeft, "Closing without a choice keeps the saved position")

                XCTAssertEqual(titles(stage.makeTimerMenu()).prefix(1), ["Start Timer"])
                XCTAssertFalse(titles(stage.makeTimerMenu(optionsOnly: true)).contains("Start Timer"), "The panel row starts it")
                XCTAssertEqual(stage.timerStateDetail, "")
                choose(try item(stage.makeTimerMenu(), "Start Timer"))
                XCTAssertEqual(app.timerTransport, .running)
                XCTAssertTrue(timerVisible && stage.isTimerShown)
                // Beside the shown window, a choice moves it at once and closes the control.
                choose(try item(stage.makeTimerMenu(), "Position…"))
                XCTAssertTrue(stage.isTimerPositionControlShown)
                app.setTimerPosition(.bottomRight); app.timerPositionPanel.close(.chose)
                XCTAssertEqual(app.timerPlacementAnchor, .bottomRight)
                XCTAssertFalse(stage.isTimerPositionControlShown)
                choose(try item(stage.makeTimerMenu(), "Position…"))
                choose(try item(stage.makeTimerMenu(), "Hide Timer"))
                XCTAssertFalse(stage.isTimerPositionControlShown, "Hide timer takes Position… with the window")
                choose(try item(stage.makeTimerMenu(), "Show Timer"))
                let running = titles(stage.makeTimerMenu())
                XCTAssertEqual(Array(running.prefix(3)), ["Pause Timer", "Hide Timer", "Stop Timer"], "\(running)")
                XCTAssertFalse(running.contains("Start Timer") || running.contains("Reset Timer") || running.contains("End Timer"),
                               "No second Start, Reset or End beside the one word set: \(running)")
                XCTAssertEqual(Array(titles(stage.makeTimerMenu(optionsOnly: true)).prefix(2)), ["Pause Timer", "Hide Timer"],
                               "The panel's Options keep the next step and Show or Hide; its row stops")
                XCTAssertEqual(stage.timerStateDetail, "01:00")

                let hide = try item(stage.makeTimerMenu(), "Hide Timer")
                choose(hide)
                XCTAssertFalse(timerVisible || stage.isTimerShown, "Hide timer hides the window")
                XCTAssertEqual(app.timerTransport, .running, "and leaves the countdown running")
                XCTAssertEqual(stage.timerStateDetail, "01:00 · Hidden")
                choose(hide)
                XCTAssertFalse(timerVisible, "A Hide drawn before never shows it again")
                choose(try item(stage.makeTimerMenu(), "Show Timer"))
                XCTAssertTrue(timerVisible && stage.isTimerShown, "Show timer brings the window back")

                choose(try item(stage.makeTimerMenu(), "Pause Timer"))
                XCTAssertEqual(stage.timerStateDetail, "01:00 · Paused")
                choose(try item(stage.makeTimerMenu(), "Resume Timer"))
                clock.now += 61
                settle { app.timerFinished }
                XCTAssertEqual(stage.timerStateDetail, "Time is up")
                XCTAssertTrue(stage.hasTimerSession, "A finished timer stays, as its window keeps it, until it is stopped")
                XCTAssertEqual(titles(stage.makeTimerMenu()).first, "Restart Timer")

                choose(try item(stage.makeTimerMenu(), "Stop Timer"))
                XCTAssertEqual(app.timerTransport, .idle)
                XCTAssertFalse(timerVisible || stage.hasTimerSession, "Stop timer ends the countdown and closes its window")
                XCTAssertEqual(stage.timerStateDetail, "")
            }
        }
    }
}

extension TimerTransportTests {
    /// Position… sits above a timer window in the lower half of its display and below one in
    /// the upper half; with no window shown it opens under the pointer. It never leaves the
    /// usable screen.
    func testPositionControlSitsByTheWindowOrThePointer() throws {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 860), size = NSSize(width: 150, height: 170)
        let low = NSRect(x: 300, y: 40, width: 570, height: 330)
        let aboveLow = AppCoordinator.timerPositionFrame(size: size, beside: low, pointer: .zero, visible: visible)
        XCTAssertEqual(aboveLow.origin, NSPoint(x: 300, y: low.maxY + 8), "Above a low window")
        let high = NSRect(x: 300, y: 500, width: 570, height: 330)
        let belowHigh = AppCoordinator.timerPositionFrame(size: size, beside: high, pointer: .zero, visible: visible)
        XCTAssertEqual(belowHigh.origin, NSPoint(x: 300, y: high.minY - 8 - size.height), "Below a high window")
        let edge = NSRect(x: 1400, y: 40, width: 570, height: 330)
        let clamped = AppCoordinator.timerPositionFrame(size: size, beside: edge, pointer: .zero, visible: visible)
        XCTAssertTrue(visible.contains(clamped), "Kept on the usable screen: \(clamped)")
        let pointer = NSPoint(x: 700, y: 400)
        let atPointer = AppCoordinator.timerPositionFrame(size: size, beside: nil, pointer: pointer, visible: visible)
        XCTAssertTrue(atPointer.contains(pointer) && visible.contains(atPointer), "Under the pointer before the window opens: \(atPointer)")
        let corner = AppCoordinator.timerPositionFrame(size: size, beside: nil, pointer: NSPoint(x: 1435, y: 5), visible: visible)
        XCTAssertTrue(visible.contains(corner), "A pointer at the corner still gets a control on screen: \(corner)")
        // The shared control's grid: arrow keys step over the empty middle and stop at the edge.
        XCTAssertEqual(FloatingPositionControl.neighbour(of: .left, column: 1, row: 0), .right)
        XCTAssertEqual(FloatingPositionControl.neighbour(of: .top, column: 0, row: 1), .bottom)
        XCTAssertEqual(FloatingPositionControl.neighbour(of: .topLeft, column: -1, row: 0), .topLeft)
        XCTAssertEqual(FloatingPositionControl.neighbour(of: .bottom, column: 1, row: 0), .bottomRight)
    }
}

private enum TimerWordsError: Error { case missing(String, [String]) }
