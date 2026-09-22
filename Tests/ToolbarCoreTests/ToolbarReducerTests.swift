import XCTest
@testable import ToolbarCore

/// One test per row of the table in docs/floating-toolbar.md. No sleeps, no
/// windows, no pointer sampling: a failure names the row that broke.
final class ToolbarReducerTests: XCTestCase {
    private func driven(_ events: [ToolbarEvent], pinnedPreference: Bool = false) -> ToolbarState {
        var state = ToolbarState(pinnedPreference: pinnedPreference)
        for event in events { state.apply(event) }
        return state
    }
    private func step(_ state: ToolbarState, _ event: ToolbarEvent) -> (ToolbarState, [ToolbarEffect]) {
        ToolbarState.reduce(state, event)
    }

    // MARK: Pointer

    func testPointerEntryRevealsFromResting() {
        let (state, effects) = step(ToolbarState(), .pointerEntered)
        XCTAssertEqual(state.tier, .peeking)
        XCTAssertEqual(effects, [.show(.peeking)])
        XCTAssertTrue(state.pointerInside)
    }

    func testPointerEntryChangesNothingVisibleWhilePinned() {
        let (state, effects) = step(ToolbarState(pinnedPreference: true), .pointerEntered)
        XCTAssertEqual(state.tier, .pinned)
        XCTAssertEqual(effects, [])
    }

    func testPointerExitFromPeekingStartsGrace() {
        let (state, effects) = step(driven([.pointerEntered]), .pointerLeft)
        XCTAssertEqual(state.tier, .peeking, "leaving must not collapse immediately; the pointer has to be able to reach the controls")
        XCTAssertEqual(effects, [.startGrace])
        XCTAssertTrue(state.graceRunning)
    }

    func testReturningPointerCancelsGrace() {
        let (state, effects) = step(driven([.pointerEntered, .pointerLeft]), .pointerEntered)
        XCTAssertEqual(effects, [.cancelGrace])
        XCTAssertEqual(state.tier, .peeking)
        XCTAssertFalse(state.graceRunning)
    }

    func testGraceElapsedCollapses() {
        let (state, effects) = step(driven([.pointerEntered, .pointerLeft]), .graceElapsed)
        XCTAssertEqual(state.tier, .resting)
        XCTAssertEqual(effects, [.show(.resting)])
    }

    func testStaleGraceElapsedIsIgnored() {
        // The host cancelled this timer when the pointer came back, but a timer
        // that has already fired can still be delivered.
        let (state, effects) = step(driven([.pointerEntered, .pointerLeft, .pointerEntered]), .graceElapsed)
        XCTAssertEqual(state.tier, .peeking)
        XCTAssertEqual(effects, [])
    }

    func testPointerExitWhilePinnedDoesNotCollapse() {
        let (state, effects) = step(driven([.pillClicked, .pointerEntered]), .pointerLeft)
        XCTAssertEqual(state.tier, .pinned)
        XCTAssertEqual(effects, [])
    }

    // MARK: Holds

    func testHoldKeepsTheToolbarOpenWhileThePointerIsAway() {
        let state = driven([.pointerEntered, .holdBegan(.menu), .pointerLeft])
        XCTAssertEqual(state.tier, .peeking)
        XCTAssertFalse(state.graceRunning, "an open menu must not be racing a collapse timer")
    }

    func testHoldEndingAwayFromTheToolbarStartsGrace() {
        let (state, effects) = step(driven([.pointerEntered, .holdBegan(.menu), .pointerLeft]), .holdEnded(.menu))
        XCTAssertEqual(effects, [.startGrace])
        XCTAssertEqual(state.tier, .peeking)
    }

    func testHoldEndingUnderThePointerKeepsTheToolbarOpen() {
        let (state, effects) = step(driven([.pointerEntered, .holdBegan(.menu)]), .holdEnded(.menu))
        XCTAssertEqual(state.tier, .peeking)
        XCTAssertEqual(effects, [])
    }

    func testHoldBeginningCancelsAPendingCollapse() {
        let (state, effects) = step(driven([.pointerEntered, .pointerLeft]), .holdBegan(.menu))
        XCTAssertEqual(effects, [.cancelGrace])
        XCTAssertEqual(state.tier, .peeking)
    }

    func testLastHoldDecidesTheCollapse() {
        let state = driven([.pointerEntered, .holdBegan(.menu), .holdBegan(.drag), .pointerLeft, .holdEnded(.menu)])
        XCTAssertFalse(state.graceRunning, "the drag is still holding it")
        let (after, effects) = step(state, .holdEnded(.drag))
        XCTAssertEqual(effects, [.startGrace])
        XCTAssertEqual(after.tier, .peeking)
    }

    func testDraggingNeverResizesTheToolbar() {
        // Revealing on drag would change the frame of the window being dragged.
        let (state, effects) = step(ToolbarState(), .holdBegan(.drag))
        XCTAssertEqual(state.tier, .resting)
        XCTAssertEqual(effects, [])
    }

    // MARK: Pin and collapse

    func testPillClickPinsAndRemembers() {
        let (state, effects) = step(ToolbarState(), .pillClicked)
        XCTAssertEqual(state.tier, .pinned)
        XCTAssertEqual(effects, [.show(.pinned), .persistPinned(true)])
    }

    func testPinControlsAreEquivalentFromEveryTier() {
        for events in [[], [.pointerEntered], [.pillClicked]] as [[ToolbarEvent]] {
            let base = driven(events)
            XCTAssertEqual(step(base, .pillClicked).0, step(base, .expandClicked).0, "\(events)")
            XCTAssertEqual(step(base, .pillClicked).1, step(base, .expandClicked).1, "\(events)")
        }
    }

    func testCollapseReturnsToRestingAndForgetsThePin() {
        let (state, effects) = step(driven([.pillClicked, .pointerEntered]), .collapseRequested)
        XCTAssertEqual(state.tier, .resting)
        XCTAssertEqual(effects, [.show(.resting), .persistPinned(false)])
        XCTAssertFalse(state.pinnedPreference)
    }

    func testCollapseTearsDownTheMenuThatIssuedIt() {
        // Collapse toolbar is a menu item, so its own menu is still tracking.
        let (state, effects) = step(driven([.pillClicked, .pointerEntered, .holdBegan(.menu)]), .collapseRequested)
        XCTAssertTrue(state.holds.isEmpty)
        XCTAssertEqual(effects, [.releaseHolds, .show(.resting), .persistPinned(false)])
    }

    // MARK: Keyboard

    func testKeyboardFocusRevealsWithoutChangingTheRememberedChoice() {
        let (state, effects) = step(ToolbarState(), .holdBegan(.keyboard))
        XCTAssertEqual(state.tier, .pinned)
        XCTAssertEqual(effects, [.show(.pinned)], "tabbing through the toolbar must not rewrite a setting")
        XCTAssertFalse(state.pinnedPreference)
    }

    func testKeyboardFocusEndingLandsOnThePointer() {
        let away = driven([.holdBegan(.keyboard)])
        XCTAssertEqual(step(away, .holdEnded(.keyboard)).0.tier, .resting)
        let under = driven([.pointerEntered, .holdBegan(.keyboard)])
        XCTAssertEqual(step(under, .holdEnded(.keyboard)).0.tier, .peeking)
    }

    func testKeyboardFocusEndingKeepsAGenuinePin() {
        let state = driven([.pillClicked, .holdBegan(.keyboard), .holdEnded(.keyboard)])
        XCTAssertEqual(state.tier, .pinned)
        XCTAssertTrue(state.pinnedPreference)
    }

    // MARK: Surface takeover

    func testSurfaceTakeoverRestsWithoutForgettingThePin() {
        let (state, effects) = step(driven([.pillClicked, .pointerEntered]), .surfaceLeftTools)
        XCTAssertEqual(state.tier, .resting)
        XCTAssertTrue(state.pinnedPreference, "recording must not silently unpin the idle toolbar")
        XCTAssertEqual(effects, [.show(.resting)])
    }

    func testSurfaceReturnRestoresTheRememberedPin() {
        let pinned = driven([.pillClicked, .surfaceLeftTools, .surfaceReturnedToTools])
        XCTAssertEqual(pinned.tier, .pinned)
        let quiet = driven([.pointerEntered, .surfaceLeftTools, .surfaceReturnedToTools])
        XCTAssertEqual(quiet.tier, .resting)
        XCTAssertFalse(quiet.pointerInside, "the host reconciles the pointer with pointerSettled once the frame is final")
    }

    // MARK: The reported bugs

    func testCollapseClickDoesNotSpringBackOpen() {
        // Collapsing under the pointer, then the window shrinking out from under
        // it. The old build re-revealed here and needed a suppression flag.
        var state = driven([.pillClicked, .pointerEntered])
        state.apply(.collapseRequested)
        let effects = state.apply(.pointerSettled(inside: true))
        XCTAssertEqual(state.tier, .resting)
        XCTAssertEqual(effects, [])
    }

    func testCollapsedToolbarRevealsAgainOnARealCrossing() {
        var state = driven([.pillClicked, .pointerEntered, .collapseRequested, .pointerSettled(inside: true)])
        state.apply(.pointerLeft)
        let effects = state.apply(.pointerEntered)
        XCTAssertEqual(state.tier, .peeking)
        XCTAssertEqual(effects, [.show(.peeking)])
    }

    func testDraggingToANewDockKeepsControlsThenSettles() {
        var state = driven([.pointerEntered, .holdBegan(.drag)])
        state.apply(.holdEnded(.drag))
        XCTAssertEqual(state.tier, .peeking, "the pointer was still recorded as inside when the drag ended")
        let effects = state.apply(.pointerSettled(inside: false))
        XCTAssertEqual(effects, [.startGrace], "the docked frame landed away from the pointer")
    }

    func testScreenshotTakeoverDuringAnOpenMenu() {
        let (state, effects) = step(driven([.pointerEntered, .holdBegan(.menu)]), .surfaceLeftTools)
        XCTAssertTrue(state.holds.isEmpty)
        XCTAssertEqual(effects, [.releaseHolds, .show(.resting)])
    }
}
