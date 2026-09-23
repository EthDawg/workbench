import XCTest
@testable import ToolbarCore

/// One test per row of the table in docs/floating-toolbar.md. No sleeps, no
/// windows, no pointer sampling: a failure names the row that broke.
final class ToolbarReducerTests: XCTestCase {
    private func driven(_ events: [ToolbarEvent], keepsOpen: Bool = false) -> ToolbarState {
        var state = ToolbarState(keepsOpen: keepsOpen)
        for event in events { state.apply(event) }
        return state
    }
    private func step(_ state: ToolbarState, _ event: ToolbarEvent) -> (ToolbarState, [ToolbarEffect]) {
        ToolbarState.reduce(state, event)
    }

    // MARK: Pointer

    func testPointerEntryRevealsTheRow() {
        let (state, effects) = step(ToolbarState(), .pointerEntered)
        XCTAssertEqual(state.tier, .revealed)
        XCTAssertEqual(effects, [.show(.revealed)])
        XCTAssertTrue(state.pointerInside)
    }

    func testPointerExitStartsGrace() {
        let (state, effects) = step(driven([.pointerEntered]), .pointerLeft)
        XCTAssertEqual(state.tier, .revealed, "leaving must not collapse at once; the pointer has to be able to reach the controls")
        XCTAssertEqual(effects, [.startGrace])
    }

    func testReturningPointerCancelsGrace() {
        let (state, effects) = step(driven([.pointerEntered, .pointerLeft]), .pointerEntered)
        XCTAssertEqual(effects, [.cancelGrace])
        XCTAssertEqual(state.tier, .revealed)
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
        XCTAssertEqual(state.tier, .revealed)
        XCTAssertEqual(effects, [])
    }

    // MARK: Holds

    func testHoldKeepsTheRowUpWhileThePointerIsAway() {
        let state = driven([.pointerEntered, .holdBegan(.menu), .pointerLeft])
        XCTAssertEqual(state.tier, .revealed)
        XCTAssertFalse(state.graceRunning, "an open menu must not be racing a collapse timer")
    }

    func testHoldEndingAwayFromTheToolbarStartsGrace() {
        let (state, effects) = step(driven([.pointerEntered, .holdBegan(.menu), .pointerLeft]), .holdEnded(.menu))
        XCTAssertEqual(effects, [.startGrace])
        XCTAssertEqual(state.tier, .revealed)
    }

    func testHoldEndingUnderThePointerKeepsTheRowUp() {
        let (state, effects) = step(driven([.pointerEntered, .holdBegan(.menu)]), .holdEnded(.menu))
        XCTAssertEqual(state.tier, .revealed)
        XCTAssertEqual(effects, [])
    }

    func testHoldBeginningCancelsAPendingCollapse() {
        let (state, effects) = step(driven([.pointerEntered, .pointerLeft]), .holdBegan(.menu))
        XCTAssertEqual(effects, [.cancelGrace])
        XCTAssertEqual(state.tier, .revealed)
    }

    func testLastHoldDecidesTheCollapse() {
        let state = driven([.pointerEntered, .holdBegan(.menu), .holdBegan(.drag), .pointerLeft, .holdEnded(.menu)])
        XCTAssertFalse(state.graceRunning, "the drag is still holding it")
        let (after, effects) = step(state, .holdEnded(.drag))
        XCTAssertEqual(effects, [.startGrace])
        XCTAssertEqual(after.tier, .revealed)
    }

    func testDraggingTheRestingGlyphNeverResizesIt() {
        // Revealing on drag would change the frame of the window being dragged.
        let (state, effects) = step(ToolbarState(), .holdBegan(.drag))
        XCTAssertEqual(state.tier, .resting)
        XCTAssertEqual(effects, [])
    }

    // MARK: Keep open

    func testKeepOpenHoldsTheRowUpWithNoPointerAndNoHold() {
        let (state, effects) = step(driven([.pointerEntered, .pointerLeft]), .keepOpenChanged(true))
        XCTAssertEqual(state.tier, .revealed)
        XCTAssertEqual(effects, [.persistKeepOpen(true), .cancelGrace])
        let (after, later) = step(state, .pointerLeft)
        XCTAssertEqual(after.tier, .revealed)
        XCTAssertEqual(later, [], "keep open is the answer to a pointer that has gone")
    }

    func testUntickingKeepOpenInsideTheMenuFadesWhenTheMenuCloses() {
        // This is the whole job the minimise button used to do.
        var state = driven([.pointerEntered, .keepOpenChanged(true), .holdBegan(.menu), .pointerLeft])
        let atUntick = state.apply(.keepOpenChanged(false))
        XCTAssertEqual(atUntick, [.persistKeepOpen(false)], "the open menu still holds the row up")
        XCTAssertEqual(state.tier, .revealed)
        let atClose = state.apply(.holdEnded(.menu))
        XCTAssertEqual(atClose, [.startGrace])
        state.apply(.graceElapsed)
        XCTAssertEqual(state.tier, .resting)
    }

    func testUntickingKeepOpenUnderThePointerKeepsTheRowUp() {
        let (state, effects) = step(driven([.pointerEntered, .keepOpenChanged(true)]), .keepOpenChanged(false))
        XCTAssertEqual(state.tier, .revealed, "the pointer is still on it")
        XCTAssertEqual(effects, [.persistKeepOpen(false)])
    }

    func testKeepOpenIsOnlyWrittenWhenItChanges() {
        XCTAssertEqual(step(driven([], keepsOpen: true), .keepOpenChanged(true)).1, [])
        XCTAssertEqual(step(ToolbarState(), .keepOpenChanged(false)).1, [])
    }

    func testAToolbarKeptOpenLaunchesRevealed() {
        XCTAssertEqual(ToolbarState(keepsOpen: true).tier, .revealed)
        XCTAssertEqual(ToolbarState().tier, .resting)
    }

    // MARK: Keyboard

    func testKeyboardFocusRevealsWithoutChangingTheRememberedChoice() {
        let (state, effects) = step(ToolbarState(), .holdBegan(.keyboard))
        XCTAssertEqual(state.tier, .revealed)
        XCTAssertEqual(effects, [.show(.revealed)], "tabbing to the toolbar must not rewrite a setting")
        XCTAssertFalse(state.keepsOpen)
    }

    func testKeyboardFocusEndingLandsOnThePointer() {
        let away = driven([.holdBegan(.keyboard)])
        XCTAssertEqual(step(away, .holdEnded(.keyboard)).1, [.startGrace])
        let under = driven([.pointerEntered, .holdBegan(.keyboard)])
        XCTAssertEqual(step(under, .holdEnded(.keyboard)).1, [])
    }

    func testKeyboardFocusEndingLeavesAKeptOpenToolbarAlone() {
        let state = driven([.keepOpenChanged(true), .holdBegan(.keyboard), .holdEnded(.keyboard)])
        XCTAssertEqual(state.tier, .revealed)
        XCTAssertTrue(state.keepsOpen)
    }

    // MARK: Surface takeover

    func testSurfaceTakeoverRestsWithoutForgettingTheChoice() {
        let (state, effects) = step(driven([.keepOpenChanged(true), .pointerEntered]), .surfaceLeftTools)
        XCTAssertEqual(state.tier, .resting)
        XCTAssertTrue(state.keepsOpen, "recording must not silently change the idle toolbar's setting")
        XCTAssertEqual(effects, [.show(.resting)])
    }

    func testSurfaceReturnRestoresTheRememberedChoice() {
        let kept = driven([.keepOpenChanged(true), .surfaceLeftTools, .surfaceReturnedToTools])
        XCTAssertEqual(kept.tier, .revealed)
        let quiet = driven([.pointerEntered, .surfaceLeftTools, .surfaceReturnedToTools])
        XCTAssertEqual(quiet.tier, .resting)
        XCTAssertFalse(quiet.pointerInside, "the host reconciles the pointer with pointerSettled once the frame is final")
    }

    func testScreenshotTakeoverDuringAnOpenMenu() {
        let (state, effects) = step(driven([.pointerEntered, .holdBegan(.menu)]), .surfaceLeftTools)
        XCTAssertTrue(state.holds.isEmpty)
        XCTAssertEqual(effects, [.releaseHolds, .show(.resting)])
    }

    // MARK: Reconciling after the frame or the surface moves

    func testTheHostReconcilesWithTheEventThatMatchesThePointer() {
        // AppKit cannot deliver a crossing to a pointer that never moved, so the
        // host says where the pointer is after an animation. Both events are
        // idempotent, so agreeing with the core costs nothing.
        var onIt = driven([.pointerEntered])
        XCTAssertEqual(onIt.apply(.pointerEntered), [])
        var awayFromIt = driven([.pointerEntered, .pointerLeft])
        XCTAssertEqual(awayFromIt.apply(.pointerLeft), [], "a second report must not restart the timer")
        XCTAssertTrue(awayFromIt.graceRunning)
    }

    func testARowThatOpensUnderAStillPointerStaysOpen() {
        // The row is far wider than the glyph, so its frame moves out from under
        // the pointer as it opens. Reconciling must not close it.
        var state = driven([.pointerEntered])
        XCTAssertEqual(state.apply(.pointerEntered), [])
        XCTAssertEqual(state.tier, .revealed)
    }

    func testTheRowComesBackForAPointerThatNeverMoved() {
        // Dictation took the window while the pointer sat on the toolbar, and the
        // user clicked Stop without moving. When the tools surface returns, the
        // row belongs up: nothing dismissed it, so a pointer on it still means show.
        var state = driven([.pointerEntered, .surfaceLeftTools])
        XCTAssertEqual(state.tier, .resting)
        XCTAssertEqual(state.apply(.pointerEntered), [.show(.revealed)],
                       "the toolbar must not ignore a pointer that is already on it")
    }

    func testSettlingAwayFromThePointerStartsGrace() {
        var state = driven([.pointerEntered, .holdBegan(.drag)])
        state.apply(.holdEnded(.drag))
        XCTAssertEqual(state.tier, .revealed, "the pointer was still recorded as inside when the drag ended")
        XCTAssertEqual(state.apply(.pointerLeft), [.startGrace], "the docked frame landed away from the pointer")
    }

    func testAMenuThatSwallowedTheExitIsReconciledWhenItCloses() {
        // Native menu tracking eats the owning window's exit event.
        var state = driven([.pointerEntered, .holdBegan(.menu)])
        XCTAssertEqual(state.apply(.pointerLeft), [], "the menu still holds the row up")
        XCTAssertEqual(state.apply(.holdEnded(.menu)), [.startGrace])
    }
}
