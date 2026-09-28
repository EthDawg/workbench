import XCTest
@testable import ToolbarCore

/// The flat tool chooser's keyboard (#134): Up and Down, Return by identity, and type-ahead as
/// native menus do it. Live updates never move the highlight to another tool.
final class ToolbarChooserTests: XCTestCase {
    private func state(chosen: ToolbarMode = .dictate, live: Set<ToolbarMode> = []) -> ToolbarChooserState {
        ToolbarChooserState(choices: ToolbarMode.allCases.map { ToolbarToolChoice(mode: $0, isSelected: $0 == chosen, isLive: live.contains($0)) })
    }

    func testTheChosenToolIsHighlightedWhenItOpens() {
        XCTAssertEqual(state(chosen: .present).highlighted, .present)
        XCTAssertEqual(state(chosen: .present).committed, .present, "Return at once keeps the same tool")
    }

    func testUpAndDownStopAtTheEnds() {
        var chooser = state(chosen: .dictate)
        chooser.move(-1)
        XCTAssertEqual(chooser.highlighted, .dictate)
        for _ in 0..<10 { chooser.move(1) }
        XCTAssertEqual(chooser.highlighted, .persona)
        chooser.move(-1)
        XCTAssertEqual(chooser.highlighted, .present)
    }

    func testTypingJumpsToAToolByName() {
        var chooser = state()
        chooser.type("s", at: 10)
        XCTAssertEqual(chooser.highlighted, .snap)
        chooser.type("n", at: 10.2); chooser.type("a", at: 10.4); chooser.type("p", at: 10.6); chooser.type(" ", at: 10.8)
        XCTAssertEqual(chooser.highlighted, .snapAndTalk, "typing on extends the name, as a menu does")
        chooser.type("P", at: 13)
        XCTAssertEqual(chooser.highlighted, .present, "after a pause, typing starts again, whatever the case")
        chooser.type("e", at: 13.3)
        XCTAssertEqual(chooser.highlighted, .persona, "pe is Persona's: Present is pr")
        chooser.type("r", at: 13.5); chooser.type("s", at: 13.7)
        XCTAssertEqual(chooser.highlighted, .persona)
        chooser.type("d", at: 13.9)
        XCTAssertEqual(chooser.highlighted, .persona, "no tool starts with persd: the highlight stays until a pause starts the text again")
        chooser.type("r", at: 20); chooser.type("e", at: 20.1); chooser.type("a", at: 20.2)
        XCTAssertEqual(chooser.highlighted, .read)
        chooser.type("d", at: 25)
        XCTAssertEqual(chooser.highlighted, .dictate)
        chooser.type("r", at: 25.2)
        XCTAssertEqual(chooser.highlighted, .draw)
    }

    /// Late facts while the chooser is open, including a new order, keep the highlight on the
    /// same tool, and Return commits that tool, never whatever row now sits at its old index.
    func testLiveUpdatesKeepTheHighlightByIdentity() {
        var chooser = state(chosen: .dictate, live: [.present])
        chooser.highlight(.persona)
        chooser.refresh(ToolbarMode.allCases.reversed().map { ToolbarToolChoice(mode: $0, isSelected: $0 == .dictate, isLive: $0 == .persona) })
        XCTAssertEqual(chooser.highlighted, .persona)
        XCTAssertEqual(chooser.committed, .persona)
        XCTAssertEqual(chooser.choices.first { $0.mode == .persona }?.isLive, true)
        chooser.refresh(ToolbarMode.allCases.filter { $0 != .persona }.map { ToolbarToolChoice(mode: $0, isSelected: $0 == .dictate) })
        XCTAssertEqual(chooser.highlighted, .dictate, "a tool that left the list gives the highlight back to the chosen one")
    }
}

/// The primary's press latch (#134): the operation and its generation are latched on
/// mouse-down, and the click acts only if both still hold on mouse-up.
final class ToolbarPressLatchTests: XCTestCase {
    func testAnUnchangedPressActs() {
        var generation = ToolbarActionGeneration()
        generation.observe(.stopDictation)
        let latch = generation.latch(.stopDictation)
        XCTAssertTrue(generation.admits(latch, now: .stopDictation))
    }

    /// Stop completes while the button is held: the label is now Dictate, and the click is discarded.
    func testAStopThatCompletesWhilePressedNeverStarts() {
        var generation = ToolbarActionGeneration()
        let latch = generation.latch(.stopDictation)
        generation.observe(.start(.dictate))
        XCTAssertFalse(generation.admits(latch, now: .start(.dictate)))
        // And even if nobody observed the change until the button came up.
        var unobserved = ToolbarActionGeneration()
        let press = unobserved.latch(.stopDictation)
        XCTAssertFalse(unobserved.admits(press, now: .start(.dictate)))
    }

    /// The operation changed and came back while held: a new generation, so the press is discarded.
    func testAnOperationThatChangedAndCameBackIsANewGeneration() {
        var generation = ToolbarActionGeneration()
        let latch = generation.latch(.stopDictation)
        generation.observe(.start(.dictate))
        generation.observe(.stopDictation)
        XCTAssertFalse(generation.admits(latch, now: .stopDictation), "a new recording is not the one that was pressed")
    }

    func testRepeatedObservationsOfOneOperationKeepItsGeneration() {
        var generation = ToolbarActionGeneration()
        let latch = generation.latch(.endPresentation)
        for _ in 0..<5 { generation.observe(.endPresentation) }
        XCTAssertTrue(generation.admits(latch, now: .endPresentation))
        XCTAssertEqual(generation.generation, latch.generation)
    }
}
