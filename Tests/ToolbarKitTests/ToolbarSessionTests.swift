import AppKit
import XCTest
import ToolbarCore
@testable import ToolbarKit

@MainActor private final class ManualClock: ToolbarGraceClock {
    var pending: (() -> Void)?
    var starts = 0
    func start(_ elapsed: @escaping @MainActor () -> Void) { starts += 1; pending = elapsed }
    func cancel() { pending = nil }
    func fire() { let callback = pending; pending = nil; callback?() }
}

final class ToolbarSessionTests: XCTestCase {
    @MainActor private func fixture() -> (ToolbarSession, ManualClock, UserDefaults, String) {
        let domain = "workbench.toolbar.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let clock = ManualClock()
        return (ToolbarSession(defaults: defaults, clock: clock), clock, defaults, domain)
    }

    @MainActor func testMenuClosingOutsideStartsExactlyOneGraceAndCollapses() {
        let (session, clock, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        session.activate(); session.send(.pointerEntered)
        session.beginMenu(NSMenu())
        session.send(.keepOpenChanged(true)); session.send(.keepOpenChanged(false))
        XCTAssertFalse(defaults.bool(forKey: ToolbarSession.keepOpenKey))
        XCTAssertNil(clock.pending)
        session.endMenu(pointerInside: false)
        XCTAssertEqual(clock.starts, 1)
        clock.fire()
        XCTAssertEqual(session.state.tier, .resting)
    }

    @MainActor func testDragEndReconcilesOutsideBeforeReleasingItsHold() {
        let (session, clock, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        session.activate(); session.send(.pointerEntered); session.send(.holdBegan(.drag))
        // Native tracking is suspended during drag. No pointerLeft arrives.
        session.send(.pointerLeft); session.send(.holdEnded(.drag))
        XCTAssertNotNil(clock.pending)
        clock.fire()
        XCTAssertEqual(session.state.tier, .resting)
    }

    @MainActor func testReentryCancelsDeadlineAndRepeatedExitDoesNotExtendIt() {
        let (session, clock, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        session.activate(); session.send(.pointerEntered); session.send(.pointerLeft)
        session.send(.pointerLeft)
        XCTAssertEqual(clock.starts, 1)
        session.send(.pointerEntered)
        XCTAssertNil(clock.pending)
        clock.fire()
        XCTAssertEqual(session.state.tier, .revealed)
    }

    @MainActor func testHiddenToolbarRejectsLateMenuFocusAndPointerCallbacks() {
        let (session, clock, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        session.activate(); session.send(.pointerEntered); session.beginMenu(NSMenu())
        session.suspend()
        XCTAssertFalse(session.beginMenu(NSMenu()), "a stale glyph must not open a menu over a recording HUD")
        session.endMenu(pointerInside: true)
        session.send(.pointerEntered); session.send(.holdBegan(.keyboard))
        clock.fire()
        XCTAssertEqual(session.state.tier, .resting)
        XCTAssertTrue(session.state.holds.isEmpty)
        XCTAssertNil(clock.pending)
        session.activate()
        XCTAssertEqual(session.state.tier, .resting)
    }

    @MainActor func testCaptureAndRelaunchPreserveKeepOpenButKeyboardFocusDoesNotPersistIt() {
        let (session, clock, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        session.activate(); session.send(.holdBegan(.keyboard))
        XCTAssertFalse(defaults.bool(forKey: ToolbarSession.keepOpenKey))
        session.send(.keepOpenChanged(true)); session.suspend(); session.activate()
        XCTAssertEqual(session.state.tier, .revealed)
        XCTAssertNil(clock.pending)
        let restored = ToolbarSession(defaults: defaults, clock: ManualClock())
        restored.activate()
        XCTAssertTrue(restored.state.keepsOpen)
        XCTAssertEqual(restored.state.tier, .revealed)
    }

    @MainActor func testMenuReconciliationUpdatesGateBeforeImmediateReentry() {
        let (session, clock, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        session.activate()
        var gate = ToolbarPointerGate(point: .zero)
        session.send(gate.crossing(at: NSPoint(x: 10, y: 10), inside: true)!)
        session.beginMenu(NSMenu())
        // Menu tracking swallows the exit. Reconcile both owners on close.
        gate.settled(at: NSPoint(x: 60, y: 60), inside: false)
        session.endMenu(pointerInside: false)
        let entry = gate.crossing(at: NSPoint(x: 12, y: 10), inside: true)
        XCTAssertEqual(entry, .pointerEntered)
        if let entry { session.send(entry) }
        XCTAssertNil(clock.pending, "returning before grace expires must cancel the collapse")
        XCTAssertEqual(session.state.tier, .revealed)
    }

    @MainActor func testProductionClockCancellationAndInjectedDelay() async {
        let clock = ToolbarTaskClock(delay: 0.01)
        var calls: [String] = []
        let latest = expectation(description: "latest deadline")
        clock.start { calls.append("cancelled") }
        clock.cancel()
        clock.start { calls.append("latest"); latest.fulfill() }
        await fulfillment(of: [latest], timeout: 1)
        XCTAssertEqual(calls, ["latest"])
        clock.cancel()
    }
}
