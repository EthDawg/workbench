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
        var pointer = NSPoint(x: 150.5, y: 118.25)
        static let outside = NSPoint(x: 400.5, y: 400.25)
        init() {
            _ = NSApplication.shared
            panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 140, height: 36),
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
        fixture.pointer = NSPoint(x: 160.5, y: 120.25)
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

    func testTheRevealDelayIsShorterThanTheGrace() {
        XCTAssertEqual(ToolbarTrackingView.revealDelay, 0.12)
        XCTAssertLessThan(ToolbarTrackingView.revealDelay, 0.45)
    }
}
