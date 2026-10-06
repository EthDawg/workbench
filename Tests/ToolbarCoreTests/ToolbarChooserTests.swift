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
        XCTAssertEqual(chooser.highlighted, .persona, "retired Read cannot be selected by its old name")
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
/// mouse-down, and the click acts only if both still hold on mouse-up. A press on a label that
/// changed since the last redraw latches nothing.
final class ToolbarPressLatchTests: XCTestCase {
    func testAnUnchangedPressActs() {
        var generation = ToolbarActionGeneration()
        generation.observe(.stopDictation)
        let latch = generation.latch(.stopDictation)
        XCTAssertNotNil(latch)
        XCTAssertTrue(latch.map { generation.admits($0, now: .stopDictation) } ?? false)
    }

    /// Stop completes while the button is held: the label is now Dictate, and the click is discarded.
    func testAStopThatCompletesWhilePressedNeverStarts() throws {
        var generation = ToolbarActionGeneration()
        generation.observe(.stopDictation)
        let latch = try XCTUnwrap(generation.latch(.stopDictation))
        generation.observe(.start(.dictate))
        XCTAssertFalse(generation.admits(latch, now: .start(.dictate)))
        // And even if nobody observed the change until the button came up.
        var unobserved = ToolbarActionGeneration()
        unobserved.observe(.stopDictation)
        let press = try XCTUnwrap(unobserved.latch(.stopDictation))
        XCTAssertFalse(unobserved.admits(press, now: .start(.dictate)))
    }

    /// Stop completed after the last redraw but before the press: the button still read Stop, so
    /// a press must not latch the Start nobody saw (#205 review).
    func testAChangeSinceTheLastRedrawLatchesNothing() {
        var generation = ToolbarActionGeneration()
        generation.observe(.stopDictation)
        XCTAssertNil(generation.latch(.start(.dictate)))
        XCTAssertEqual(generation.operation, .stopDictation, "latching does not re-baseline on an unseen change")
        XCTAssertNil(ToolbarActionGeneration().latch(.stopDictation), "a button that never drew latches nothing")
    }

    /// The operation changed and came back while held: a new generation, so the press is discarded.
    func testAnOperationThatChangedAndCameBackIsANewGeneration() throws {
        var generation = ToolbarActionGeneration()
        generation.observe(.stopDictation)
        let latch = try XCTUnwrap(generation.latch(.stopDictation))
        generation.observe(.start(.dictate))
        generation.observe(.stopDictation)
        XCTAssertFalse(generation.admits(latch, now: .stopDictation), "a new recording is not the one that was pressed")
    }

    func testRepeatedObservationsOfOneOperationKeepItsGeneration() throws {
        var generation = ToolbarActionGeneration()
        generation.observe(.endPresentation)
        let latch = try XCTUnwrap(generation.latch(.endPresentation))
        for _ in 0..<5 { generation.observe(.endPresentation) }
        XCTAssertTrue(generation.admits(latch, now: .endPresentation))
        XCTAssertEqual(generation.generation, latch.generation)
    }
}

/// The host's whole press, as FloatingToolbar makes it (#134, #205 review): the button's redraws
/// tell the gate what it shows, a press latches that, and the owner acts only through `admits`.
final class ToolbarPressGateTests: XCTestCase {
    private func next(_ live: ToolbarLiveState) -> ToolbarNextAction { ToolbarNextAction.resolve(live) }

    func testAPressActsOnceOnWhatTheButtonShowed() throws {
        let gate = ToolbarPressGate(), recording = ToolbarLiveState(mode: .dictate, dictation: .recording)
        var performed: [ToolbarOperation] = []
        gate.shown(next(recording).operation)
        let click = try XCTUnwrap(gate.press({ self.next(recording) }, perform: { performed.append($0) }))
        click()
        XCTAssertEqual(performed, [.stopDictation])
    }

    /// Stop is pressed, the recording completes while the button is down, and the button comes up
    /// on Dictate: nothing is performed, least of all a new recording.
    func testStopCompletingThroughThePressPerformsNothing() throws {
        let gate = ToolbarPressGate()
        var live = ToolbarLiveState(mode: .dictate, dictation: .recording)
        var performed: [ToolbarOperation] = []
        gate.shown(next(live).operation)
        let click = try XCTUnwrap(gate.press({ self.next(live) }, perform: { performed.append($0) }))
        live.dictation = .idle
        click()
        XCTAssertEqual(performed, [], "the completion discards the click; it never becomes Dictate")
    }

    /// The recording completed after the button last drew Stop: the press latches nothing.
    func testAPressOnALabelNobodySawDoesNothing() {
        let gate = ToolbarPressGate()
        gate.shown(.stopDictation)
        XCTAssertNil(gate.press({ self.next(ToolbarLiveState(mode: .dictate)) }, perform: { _ in XCTFail("nothing may run") }))
    }

    func testADisabledActionIsNotPressed() {
        let gate = ToolbarPressGate(), waiting = ToolbarLiveState(mode: .dictate, dictation: .processing)
        gate.shown(next(waiting).operation)
        XCTAssertNil(gate.press({ self.next(waiting) }, perform: { _ in XCTFail("a wait never runs") }))
    }
}
