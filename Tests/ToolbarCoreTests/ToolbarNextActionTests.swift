import XCTest
@testable import ToolbarCore

/// The next action is one pure function of the live state. These walk the whole
/// product, so a wrong priority is a failing test rather than a screen that
/// reads differently on two identical days.
final class ToolbarNextActionTests: XCTestCase {
    private static let counts: [Int?] = [nil, 0, 1, 3]

    /// Every combination, once. Bools and enums are finite; the count is bounded.
    private static func product(_ body: (ToolbarLiveState) -> Void) {
        for mode in ToolbarMode.allCases {
        for dictation in ToolbarLiveState.Dictation.allCases {
        for canRecordAgain in [false, true] {
        for reading in ToolbarLiveState.Reading.allCases {
        for narrating in [false, true] {
        for capturingScreen in [false, true] {
        for pendingNarration in [false, true] {
        for captureCount in counts {
        for drawing in [false, true] {
        for presenting in [false, true] {
        for persona in ToolbarLiveState.Persona.allCases {
        for timer in ToolbarLiveState.Timer.allCases {
        for insertingPrompt in [false, true] {
        for meetingRecording in [false, true] {
        for mayStart in [false, true] {
            body(ToolbarLiveState(mode: mode, dictation: dictation, canRecordAgain: canRecordAgain, reading: reading,
                                  narrating: narrating, capturingScreen: capturingScreen, pendingNarration: pendingNarration,
                                  captureCount: captureCount, drawing: drawing, presenting: presenting, persona: persona,
                                  timer: timer, insertingPrompt: insertingPrompt, meetingRecording: meetingRecording,
                                  mayStart: mayStart))
        }}}}}}}}}}}}}}}
    }

    /// Rows 1 to 12: something is live that the label can act on.
    private static func rows1to12(_ live: ToolbarLiveState) -> Bool {
        live.insertingPrompt || live.dictation != .idle || live.capturingScreen || live.narrating || live.drawing
            || live.reading != .idle || live.persona != .none
            || (live.mode == .snapAndTalk && live.captureCount != nil) || live.meetingRecording
    }

    func testTheNamedOperationsCapabilityIsLiveInTheInput() {
        var failures: [String] = []
        Self.product { live in
            let action = ToolbarNextAction.resolve(live)
            let ok: Bool
            switch action.operation {
            case .stopInserting: ok = live.insertingPrompt
            case .cancelDictationRequest: ok = live.dictation == .requesting
            case .stopDictation: ok = live.dictation == .recording
            case .finishNarration: ok = live.narrating
            case .finishDrawing: ok = live.drawing
            case .cancelReading: ok = live.reading == .preparing
            case .pauseReading: ok = live.reading == .playing
            case .resumeReading: ok = live.reading == .paused
            case .pauseOverlays: ok = live.persona == .session
            case .resumeOverlays: ok = live.persona == .sessionHidden
            case .hidePersona: ok = live.persona == .shown
            case .captureNext: ok = live.mode == .snapAndTalk && live.captureCount != nil
            case .stopMeetingTranscription: ok = live.meetingRecording
            case .endPresentation: ok = live.presenting
            case .start(let mode): ok = mode == live.mode
            case .wait: ok = live.capturingScreen || live.dictation == .processing || live.dictation == .cancelling
            }
            if !ok, failures.count < 5 { failures.append("\(action.operation) for \(live)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testEndPresentationOnlyWhenNothingEarlierIsLive() {
        var failures = 0
        Self.product { live in
            let action = ToolbarNextAction.resolve(live)
            if action.operation == .endPresentation, Self.rows1to12(live) { failures += 1 }
            if live.presenting, !Self.rows1to12(live), action.operation != .endPresentation { failures += 1 }
        }
        XCTAssertEqual(failures, 0)
    }

    func testTheStartVerbOnlyWhenNothingIsLiveAndEnabledOnlyByAdmission() {
        var failures = 0
        Self.product { live in
            let action = ToolbarNextAction.resolve(live)
            if case .start = action.operation {
                if Self.rows1to12(live) || live.presenting { failures += 1 }
                if action.isEnabled != live.mayStart { failures += 1 }
            } else if !Self.rows1to12(live), !live.presenting {
                failures += 1
            }
        }
        XCTAssertEqual(failures, 0)
    }

    func testTheTimerNeverClaimsTheLabel() {
        var failures = 0
        Self.product { live in
            var quiet = live; quiet.timer = .none
            if ToolbarNextAction.resolve(live) != ToolbarNextAction.resolve(quiet) { failures += 1 }
        }
        XCTAssertEqual(failures, 0)
    }

    func testWaitingIsDisabledAndEverythingElseIsNot() {
        var failures = 0
        Self.product { live in
            let action = ToolbarNextAction.resolve(live)
            switch action.operation {
            case .wait: if action.isEnabled { failures += 1 }
            case .start: break
            default: if !action.isEnabled { failures += 1 }
            }
        }
        XCTAssertEqual(failures, 0)
    }

    func testTheFunctionIsPure() {
        var failures = 0
        Self.product { live in
            if ToolbarNextAction.resolve(live) != ToolbarNextAction.resolve(live) { failures += 1 }
        }
        XCTAssertEqual(failures, 0)
        let sample = ToolbarLiveState(mode: .draw, drawing: true)
        XCTAssertEqual(ToolbarNextAction.resolve(sample), ToolbarNextAction.resolve(sample))
    }

    func testEveryTitleFitsTheBudget() {
        var seen = Set<String>()
        Self.product { live in seen.insert(ToolbarNextAction.resolve(live).title) }
        for title in seen {
            XCTAssertLessThanOrEqual(title.count, ToolbarNextAction.titleBudget, title)
            XCTAssertFalse(title.isEmpty)
        }
        XCTAssertTrue(seen.contains("Stop"))
        XCTAssertTrue(seen.contains("End presentation"))
        XCTAssertTrue(seen.contains("Capture next · 3"))
        XCTAssertTrue(seen.contains("Record again"))
    }

    func testTheFixedPriorityReadsTheSameOnTwoIdenticalScreens() {
        // Input first, then the cheapest to undo, then session steps, then the ending.
        let everything = ToolbarLiveState(mode: .dictate, dictation: .recording, reading: .playing, narrating: true,
                                          captureCount: 3, drawing: true, presenting: true, persona: .session,
                                          insertingPrompt: true, meetingRecording: true)
        XCTAssertEqual(ToolbarNextAction.resolve(everything).title, "Stop inserting")
        var next = everything; next.insertingPrompt = false
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Stop")
        next.dictation = .idle
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Stop narration")
        next.narrating = false
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Stop drawing")
        next.drawing = false
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Pause reading")
        next.reading = .idle
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Hide personas")
        next.persona = .none
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Stop transcribing")
        next.meetingRecording = false
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "End presentation")
        next.presenting = false
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Dictate")
        next.mode = .snapAndTalk
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Capture next · 3")
        next.captureCount = nil
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Capture")
    }

    func testTheHintCarriesCountsAndTheKeyAndNothingElse() {
        let between = ToolbarNextAction.resolve(ToolbarLiveState(mode: .snapAndTalk, pendingNarration: true, captureCount: 3))
        XCTAssertEqual(between.hint(key: "⌥C"), "saving · ⌥C")
        XCTAssertEqual(ToolbarNextAction.resolve(ToolbarLiveState(mode: .dictate)).hint(key: "⌥V"), "⌥V")
        XCTAssertNil(ToolbarNextAction.resolve(ToolbarLiveState(mode: .read)).hint(key: nil))
        XCTAssertNil(ToolbarShortcut.off.hintKey)
        XCTAssertNil(ToolbarShortcut.unavailable.hintKey)
        XCTAssertEqual(ToolbarShortcut.assigned("⌥V").hintKey, "⌥V")
    }

    func testTheStripLightsTheModeWhoseWorkIsLive() {
        let chips = ToolbarNextAction.switcher(for: ToolbarLiveState(mode: .dictate, drawing: true))
        XCTAssertEqual(chips.map(\.mode), ToolbarMode.allCases.filter { $0 != .dictate })
        XCTAssertEqual(chips.filter(\.isBusy).map(\.mode), [.draw])
        XCTAssertFalse(ToolbarLiveState(mode: .dictate, drawing: true).isLive(.dictate))
    }

    func testEveryIdleVerbIsShortAndCoversEveryMode() {
        XCTAssertEqual(ToolbarNextAction.idleVerbs.count, ToolbarMode.allCases.count + 2)
        for verb in ToolbarNextAction.idleVerbs { XCTAssertLessThanOrEqual(verb.count, ToolbarNextAction.titleBudget) }
    }
}
