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

/// A pass-through never springs the toolbar. Entry into a resting toolbar waits
/// for the pointer to stay; exits and settles are immediate; the reducer sees
/// ordinary crossings and nothing new.
final class ToolbarTrackingViewTests: XCTestCase {
    @MainActor private final class Fixture {
        let panel: NSPanel
        let tracking: ToolbarTrackingView
        let clock = ManualClock()
        var events: [ToolbarEvent] = []
        var pointer = NSPoint(x: -19849.5, y: -19881.75)
        static let outside = NSPoint(x: -19600.5, y: -19600.25)
        init() {
            _ = NSApplication.shared
            // A visible but offscreen nonactivating host exercises native containment
            // without covering the user's desktop or taking focus.
            panel = NSPanel(contentRect: NSRect(x: -19900, y: -19900, width: 140, height: 36),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: 36))
            tracking = ToolbarTrackingView(content: content, clock: clock)
            tracking.frame = content.frame
            panel.contentView = tracking
            panel.orderFrontRegardless()
            tracking.acceptsCrossings = true
            tracking.locatePointer = { [unowned self] in self.pointer }
            tracking.event = { [unowned self] in self.events.append($0) }
        }
        func enter() { tracking.cross(at: pointer, inside: true) }
        func leave() { pointer = Self.outside; tracking.cross(at: pointer, inside: false) }
        func close() { panel.close() }
    }

    @MainActor func testEntryIntoARestingToolbarWaitsThenDeliversOnce() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { true }
        fixture.enter()
        XCTAssertEqual(fixture.events, [], "the crossing waits for the pointer to stay")
        XCTAssertEqual(fixture.clock.starts, 1)
        fixture.clock.fire()
        XCTAssertEqual(fixture.events, [.pointerEntered])
        fixture.clock.fire()
        XCTAssertEqual(fixture.events, [.pointerEntered], "a spent deadline delivers nothing more")
    }

    @MainActor func testAnExitBeforeExpiryCancelsAndDeliversNothing() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { true }
        fixture.enter(); fixture.leave()
        XCTAssertNil(fixture.clock.pending)
        XCTAssertEqual(fixture.events, [], "the core never learned of the entry, so there is no exit to report")
        fixture.pointer = NSPoint(x: -19839.5, y: -19879.75)
        fixture.enter()
        XCTAssertEqual(fixture.clock.starts, 2, "a fresh entry starts a fresh wait")
        fixture.clock.fire()
        XCTAssertEqual(fixture.events, [.pointerEntered])
    }

    @MainActor func testAPointerThatLeftWithoutACrossingIsNotRevealed() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { true }
        fixture.enter()
        fixture.pointer = Fixture.outside
        fixture.clock.fire()
        XCTAssertEqual(fixture.events, [], "expiry checks where the pointer actually is")
    }

    @MainActor func testEntriesIntoARevealedRowAndEveryExitAreImmediate() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { false }
        fixture.enter()
        XCTAssertEqual(fixture.events, [.pointerEntered])
        XCTAssertEqual(fixture.clock.starts, 0)
        fixture.leave()
        XCTAssertEqual(fixture.events, [.pointerEntered, .pointerLeft])
    }

    @MainActor func testSettleBypassesAPendingEntry() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { true }
        fixture.enter()
        fixture.tracking.settle()
        XCTAssertEqual(fixture.events, [.pointerEntered], "settle reports where the pointer is, at once")
        XCTAssertNil(fixture.clock.pending)
        fixture.clock.fire()
        XCTAssertEqual(fixture.events, [.pointerEntered], "the cancelled wait cannot deliver later")
    }

    @MainActor func testCrossingsAreIgnoredWhileNotAccepted() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { true }
        fixture.tracking.acceptsCrossings = false
        fixture.enter()
        XCTAssertEqual(fixture.clock.starts, 0)
        XCTAssertEqual(fixture.events, [])
    }

    @MainActor func testSuspendingTrackingCancelsPendingReveal() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { true }
        fixture.enter()
        let staleDeadline = fixture.clock.pending
        fixture.tracking.acceptsCrossings = false
        XCTAssertNil(fixture.clock.pending, "resize and drag cancel the old geometry's hover intent")
        staleDeadline?()
        XCTAssertEqual(fixture.events, [], "even an already-queued expiry cannot reveal while suspended")
    }

    @MainActor func testCancelledDeadlineCannotConsumeANewerDwell() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { true }
        fixture.enter()
        let staleDeadline = fixture.clock.pending
        fixture.leave()
        fixture.pointer = NSPoint(x: -19839.5, y: -19879.75)
        fixture.enter()
        staleDeadline?()
        XCTAssertEqual(fixture.events, [], "a previous entry must not shorten the new dwell")
        fixture.clock.fire()
        XCTAssertEqual(fixture.events, [.pointerEntered], "the new entry still reveals once at its own deadline")
    }

    @MainActor func testAMissedExitStillAllowsTheNextEntryToReveal() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { true }
        fixture.enter()
        fixture.pointer = Fixture.outside
        fixture.clock.fire()
        fixture.pointer = NSPoint(x: -19839.5, y: -19879.75)
        fixture.enter()
        XCTAssertEqual(fixture.clock.starts, 2, "a swallowed exit cannot leave the pill stuck closed")
        XCTAssertEqual(fixture.events, [])
        fixture.clock.fire()
        XCTAssertEqual(fixture.events, [.pointerEntered])
    }

    @MainActor func testRemovingTheTrackingViewCancelsItsDwell() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { true }
        fixture.enter()
        let staleDeadline = fixture.clock.pending
        fixture.tracking.removeFromSuperview()
        XCTAssertNil(fixture.clock.pending)
        staleDeadline?()
        XCTAssertEqual(fixture.events, [])
    }

    @MainActor func testResumingTrackingReconcilesOnceAtTheNewGeometry() {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.tracking.isRestingSized = { true }
        fixture.enter()
        let staleDeadline = fixture.clock.pending
        fixture.tracking.acceptsCrossings = false
        fixture.tracking.acceptsCrossings = true
        fixture.tracking.settle()
        staleDeadline?()
        XCTAssertEqual(fixture.events, [.pointerEntered], "only the host's final containment check reveals")
        XCTAssertNil(fixture.clock.pending)
    }

    @MainActor func testTheRevealDelayIsShorterThanTheGrace() {
        XCTAssertEqual(ToolbarTrackingView.revealDelay, 0.12)
        XCTAssertLessThan(ToolbarTrackingView.revealDelay, 0.45)
    }
}
