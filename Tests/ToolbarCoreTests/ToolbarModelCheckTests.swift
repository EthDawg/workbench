import XCTest
@testable import ToolbarCore

/// Exhaustive check over every state the toolbar can actually reach, applying
/// every event to each one. The state space is small on purpose, so this proves
/// the invariants outright instead of sampling a few journeys.
final class ToolbarModelCheckTests: XCTestCase {
    private static let events: [ToolbarEvent] =
        [.pointerEntered, .pointerLeft, .graceElapsed,
         .keepOpenChanged(true), .keepOpenChanged(false),
         .surfaceLeftTools, .surfaceReturnedToTools]
        + ToolbarHold.allCases.map { ToolbarEvent.holdBegan($0) }
        + ToolbarHold.allCases.map { ToolbarEvent.holdEnded($0) }

    /// Breadth-first from both launch states, following every event.
    private func reachable() -> [ToolbarState] {
        var seen = Set<ToolbarState>()
        var queue = [ToolbarState(keepsOpen: false), ToolbarState(keepsOpen: true)]
        seen.formUnion(queue)
        while let state = queue.popLast() {
            for event in Self.events {
                let (next, _) = ToolbarState.reduce(state, event)
                if seen.insert(next).inserted { queue.append(next) }
            }
        }
        return Array(seen)
    }

    func testNoReachableStateLeavesTheRowStuckOpen() {
        for state in reachable() {
            XCTAssertFalse(state.tier == .revealed && state.holds.isEmpty && !state.pointerInside
                           && !state.keepsOpen && !state.graceRunning,
                           "revealed, nothing holding it, no pointer, not kept open and no timer: \(state)")
        }
    }

    /// The dead-toolbar invariant. An earlier draft had a reconciliation event
    /// that recorded the pointer without revealing, which made this state
    /// reachable: the row sat closed under a pointer that was on it, and only an
    /// exit and re-entry freed it. Removing that event made the state
    /// unrepresentable rather than merely avoided.
    func testTheToolbarIsNeverClosedUnderAPointerThatIsOnIt() {
        for state in reachable() where state.tier == .resting {
            XCTAssertFalse(state.pointerInside, "\(state)")
        }
    }

    /// A host resizes its window when it sees `show`, and AppKit can deliver a
    /// tracking-area crossing synchronously from that resize, re-entering the
    /// reducer part-way through a batch of effects. `show` coming last means the
    /// re-entrant call can never invalidate an effect the host has yet to run.
    func testShowIsAlwaysTheLastEffectInABatch() {
        for state in reachable() {
            for event in Self.events {
                let effects = ToolbarState.reduce(state, event).1
                guard let index = effects.firstIndex(where: { if case .show = $0 { return true } else { return false } })
                else { continue }
                XCTAssertEqual(index, effects.count - 1, "\(event) from \(state) produced \(effects)")
            }
        }
    }

    func testATimerOnlyRunsForARevealedToolbar() {
        for state in reachable() where state.graceRunning {
            XCTAssertEqual(state.tier, .revealed, "\(state)")
        }
    }

    func testAToolbarTheUserAskedToKeepOpenIsNeverCountingDown() {
        for state in reachable() where state.keepsOpen {
            XCTAssertFalse(state.graceRunning, "\(state)")
        }
    }

    func testKeyboardFocusIsNeverOnAnInvisibleToolbar() {
        for state in reachable() where state.holds.contains(.keyboard) {
            XCTAssertEqual(state.tier, .revealed, "\(state)")
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

    /// A complexity budget. Five fields could combine 128 ways; the invariants
    /// above cut that to 40 — 8 resting and 32 revealed — which is the whole of
    /// the toolbar's behaviour. Adding a field or a tier roughly doubles it, and
    /// the table in the docs stops being the whole story: a jump here is the
    /// signal to stop and take something away instead.
    func testTheStateSpaceStaysSmallEnoughToReasonAbout() {
        let count = reachable().count
        XCTAssertLessThanOrEqual(count, 48, "reachable states grew to \(count)")
    }
}
