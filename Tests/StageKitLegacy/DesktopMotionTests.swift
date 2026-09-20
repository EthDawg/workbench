import AppKit

final class DesktopMotionTests {
    private let still = URL(fileURLWithPath: "/synthetic/desktop/applied.png")

    func testDesktopOwnershipLossCannotResumeOrFollowAnotherSpace() throws {
        XCTAssertTrue(DesktopMotionSession(displayID: 7, expectedStill: URL(string: "https://example.invalid/image.png")!) == nil)
        XCTAssertTrue(DesktopMotionSession(displayID: 7, expectedStill: URL(fileURLWithPath: "/synthetic/", isDirectory: true)) == nil)
        var session = DesktopMotionSession(displayID: 7, expectedStill: still)!
        XCTAssertEqual(session.displayID, 7)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: still), .show)
        session.pause(true)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: still), .hide)
        XCTAssertTrue(session.isPaused)
        // A manual choice made while Pause shows the real desktop wins too.
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: URL(fileURLWithPath: "/other/applied.png")), .stop)
        session.pause(false)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: still), .stop)
        XCTAssertFalse(session.isValid)

        var unavailable = DesktopMotionSession(displayID: 7, expectedStill: still)!
        XCTAssertEqual(unavailable.evaluate(displayExists: true, currentStill: nil), .stop)
        XCTAssertEqual(unavailable.evaluate(displayExists: true, currentStill: still), .stop)
        var changedSpace = DesktopMotionSession(displayID: 7, expectedStill: still)!
        changedSpace.invalidate()
        XCTAssertEqual(changedSpace.evaluate(displayExists: true, currentStill: still), .stop,
                       "The same still on another Space does not authorize following it")
    }

    func testDesktopSleepReasonsAndPauseRemainIndependent() throws {
        var session = DesktopMotionSession(displayID: 7, expectedStill: still)!
        session.suspend(.computerSleep, true)
        session.suspend(.displaySleep, true)
        session.suspend(.inactiveSession, true)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: nil), .hide)
        XCTAssertTrue(session.isValid, "Transient sleeping desktop queries must not discard the explicit session")
        session.suspend(.computerSleep, false)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: still), .hide)
        session.suspend(.inactiveSession, false)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: still), .hide)
        session.pause(true)
        session.suspend(.displaySleep, false)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: still), .hide)
        XCTAssertTrue(session.isPaused, "Wake does not undo the person's Pause")
        session.pause(false)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: still), .show)

        session.suspend(.displaySleep, true)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: nil), .hide)
        session.suspend(.displaySleep, false)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: URL(fileURLWithPath: "/synthetic/manual.png")), .stop,
                       "Wake must verify ownership before showing the overlay")
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: still), .stop)
    }

    func testDesktopRemovalStopsEvenDuringSleepAndRestartNeedsNewSession() throws {
        var session = DesktopMotionSession(displayID: 7, expectedStill: still)!
        session.suspend(.displaySleep, true)
        XCTAssertEqual(session.evaluate(displayExists: false, currentStill: nil), .stop)
        session.suspend(.displaySleep, false)
        XCTAssertEqual(session.evaluate(displayExists: true, currentStill: still), .stop)
        var explicitNewSession = DesktopMotionSession(displayID: 9, expectedStill: still)!
        XCTAssertEqual(explicitNewSession.displayID, 9)
        XCTAssertEqual(explicitNewSession.evaluate(displayExists: true, currentStill: still), .show)
        let equivalentPath = URL(fileURLWithPath: "/synthetic/desktop/../desktop/applied.png")
        XCTAssertEqual(explicitNewSession.evaluate(displayExists: true, currentStill: equivalentPath), .show)
        XCTAssertEqual(explicitNewSession.evaluate(displayExists: true, currentStill: URL(string: "https://example.invalid/applied.png")), .stop)
    }
}
