import XCTest
@testable import ToolbarCore

/// Exhaustive check over every state the toolbar can actually reach, applying
/// every event to each one. The state space is small on purpose, so this proves
/// the invariants outright instead of sampling a few journeys.
final class ToolbarModelCheckTests: XCTestCase {
    private static let events: [ToolbarEvent] =
        [.pointerEntered, .pointerLeft, .pointerSettled(inside: true), .pointerSettled(inside: false),
         .graceElapsed, .pillClicked, .expandClicked, .collapseRequested,
         .surfaceLeftTools, .surfaceReturnedToTools]
        + ToolbarHold.allCases.map { ToolbarEvent.holdBegan($0) }
        + ToolbarHold.allCases.map { ToolbarEvent.holdEnded($0) }

    /// Breadth-first from both launch states, following every event.
    private func reachable() -> [ToolbarState] {
        var seen = Set<ToolbarState>()
        var queue = [ToolbarState(pinnedPreference: false), ToolbarState(pinnedPreference: true)]
        seen.formUnion(queue)
        while let state = queue.popLast() {
            for event in Self.events {
                let (next, _) = ToolbarState.reduce(state, event)
                if seen.insert(next).inserted { queue.append(next) }
            }
        }
        return Array(seen)
    }

    func testNoReachableStateLeavesTheToolbarStuckOpen() {
        for state in reachable() {
            XCTAssertFalse(state.tier == .peeking && state.holds.isEmpty
                           && !state.pointerInside && !state.graceRunning,
                           "revealed, nothing holding it, no pointer and no timer: \(state)")
        }
    }

    func testATimerOnlyRunsForARevealedToolbar() {
        for state in reachable() where state.graceRunning {
            XCTAssertEqual(state.tier, .peeking, "\(state)")
        }
    }

    func testKeyboardFocusIsNeverOnAnInvisibleToolbar() {
        for state in reachable() where state.holds.contains(.keyboard) {
            XCTAssertEqual(state.tier, .pinned, "\(state)")
        }
    }

    func testAToolbarThatStaysOpenWithNoHoldIsADeliberateChoice() {
        for state in reachable() where state.tier == .pinned && state.holds.isEmpty {
            XCTAssertTrue(state.pinnedPreference, "\(state)")
        }
    }

    func testEveryShowEffectMatchesTheResultingTier() {
        for state in reachable() {
            for event in Self.events {
                let (next, effects) = ToolbarState.reduce(state, event)
                for case .show(let tier) in effects {
                    XCTAssertEqual(tier, next.tier, "\(event) from \(state)")
                }
                XCTAssertEqual(effects.filter { if case .show = $0 { return true } else { return false } }.count,
                               next.tier == state.tier ? 0 : 1, "\(event) from \(state)")
            }
        }
    }

    func testReducingIsPure() {
        for state in reachable() {
            for event in Self.events {
                let first = ToolbarState.reduce(state, event)
                let second = ToolbarState.reduce(state, event)
                XCTAssertEqual(first.0, second.0)
                XCTAssertEqual(first.1, second.1)
            }
        }
    }

    /// A complexity budget. Five fields could combine 384 ways; the invariants
    /// above cut that to 62, which is the whole of the toolbar's behaviour.
    /// Adding one more boolean roughly doubles it, and the table in the docs
    /// stops being the whole story — so a jump here is the signal to stop.
    func testTheStateSpaceStaysSmallEnoughToReasonAbout() {
        let count = reachable().count
        XCTAssertLessThanOrEqual(count, 72, "reachable states grew to \(count)")
    }
}
