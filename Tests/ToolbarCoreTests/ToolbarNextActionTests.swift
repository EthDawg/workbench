import XCTest
@testable import ToolbarCore

/// The next action is one pure function of the live state. These walk the whole
/// product, so a wrong priority is a failing test rather than a screen that
/// reads differently on two identical days.
final class ToolbarNextActionTests: XCTestCase {
    func testGlyphFollowsTheCommandWhenAnotherToolOwnsTheInput() {
        let recording = ToolbarNextAction.resolve(ToolbarLiveState(mode: .present, dictation: .recording))
        XCTAssertEqual(recording.title, "Stop")
        XCTAssertEqual(recording.symbol, "stop.fill")
        let playing = ToolbarNextAction.resolve(ToolbarLiveState(mode: .dictate, reading: .playing))
        XCTAssertEqual(playing.symbol, "pause.fill")
        let paused = ToolbarNextAction.resolve(ToolbarLiveState(mode: .present, reading: .paused))
        XCTAssertEqual(paused.symbol, "play.fill")
        let waiting = ToolbarNextAction.resolve(ToolbarLiveState(mode: .draw, dictation: .processing))
        XCTAssertEqual(waiting.symbol, "hourglass")
        XCTAssertFalse(waiting.isEnabled)
    }

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

    /// Input-consuming work claims the label whatever the mode.
    private static func inputLive(_ live: ToolbarLiveState) -> Bool {
        live.insertingPrompt || live.dictation != .idle || live.capturingScreen || live.narrating || live.drawing
            || live.reading != .idle
    }

    /// The selected mode's own step or ending, which claims the label only there.
    private static func ownLive(_ live: ToolbarLiveState) -> Bool {
        switch live.mode {
        case .persona: return live.persona != .none
        case .snapAndTalk: return live.captureCount != nil
        case .dictate: return live.meetingRecording
        case .present: return live.presenting
        case .read, .snap, .draw: return false
        }
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
            case .stopReading: ok = false
            case .pauseOverlays: ok = live.persona == .session && live.mode == .persona
            case .resumeOverlays: ok = live.persona == .sessionHidden && live.mode == .persona
            case .hidePersona: ok = live.persona == .shown && live.mode == .persona
            case .captureNext: ok = live.mode == .snapAndTalk && live.captureCount != nil
            case .stopMeetingTranscription: ok = live.meetingRecording && live.mode == .dictate
            case .endPresentation: ok = live.presenting && live.mode == .present
            case .start(let mode): ok = mode == live.mode
            case .wait: ok = live.capturingScreen || live.dictation == .processing || live.dictation == .cancelling
                || live.dictation == .waitingForDrawing
            }
            if !ok, failures.count < 5 { failures.append("\(action.operation) for \(live)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Dictated words waiting for drawing to end (#211 F5): Stop drawing leads in every tool,
    /// because it is what delivers them, never a disabled Processing…; once drawing has ended
    /// they are a moment's processing; and an insertion still comes first.
    func testWordsWaitingForDrawingLeadWithStopDrawing() {
        for mode in ToolbarMode.allCases {
            let waiting = ToolbarNextAction.resolve(ToolbarLiveState(mode: mode, dictation: .waitingForDrawing, drawing: true))
            XCTAssertEqual(waiting.operation, .finishDrawing, "\(mode)")
            XCTAssertEqual(waiting.title, "Stop drawing")
            XCTAssertTrue(waiting.isEnabled)
        }
        let ended = ToolbarNextAction.resolve(ToolbarLiveState(mode: .dictate, dictation: .waitingForDrawing))
        XCTAssertEqual(ended.operation, .wait)
        XCTAssertEqual(ended.title, "Processing…")
        XCTAssertEqual(ToolbarNextAction.resolve(ToolbarLiveState(mode: .dictate, dictation: .waitingForDrawing, drawing: true,
                                                                  insertingPrompt: true)).operation, .stopInserting)
        XCTAssertTrue(ToolbarLiveState(mode: .draw, dictation: .waitingForDrawing).isLive(.dictate), "the dictation is still live")
    }

    /// A mode's ending never claims another mode's label: presenting in Draw
    /// reads Draw, a meeting in Read reads Read, a persona set in Snap reads Snap.
    func testCrossModeEndingsNeverClaimTheLabel() {
        var failures = 0
        Self.product { live in
            let operation = ToolbarNextAction.resolve(live).operation
            if operation == .endPresentation, live.mode != .present { failures += 1 }
            if operation == .stopMeetingTranscription, live.mode != .dictate { failures += 1 }
            if [.pauseOverlays, .resumeOverlays, .hidePersona].contains(operation), live.mode != .persona { failures += 1 }
            if operation == .captureNext, live.mode != .snapAndTalk { failures += 1 }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(ToolbarNextAction.resolve(ToolbarLiveState(mode: .draw, presenting: true)).title, "Draw")
        XCTAssertEqual(ToolbarNextAction.resolve(ToolbarLiveState(mode: .read, meetingRecording: true)).title, "Read")
        XCTAssertEqual(ToolbarNextAction.resolve(ToolbarLiveState(mode: .snap, persona: .session)).title, "Snap")
    }

    func testTheModesOwnEndingOnlyWhenNoInputWorkIsLive() {
        var failures = 0
        Self.product { live in
            let action = ToolbarNextAction.resolve(live)
            let own = [.endPresentation, .stopMeetingTranscription, .captureNext, .pauseOverlays, .resumeOverlays, .hidePersona]
                .contains(action.operation)
            if own, Self.inputLive(live) { failures += 1 }
            if Self.ownLive(live), !Self.inputLive(live), !own { failures += 1 }
        }
        XCTAssertEqual(failures, 0)
    }

    func testTheStartVerbOnlyWhenNothingClaimsTheLabelAndEnabledOnlyByAdmission() {
        var failures = 0
        Self.product { live in
            let action = ToolbarNextAction.resolve(live)
            if case .start = action.operation {
                if Self.inputLive(live) || Self.ownLive(live) { failures += 1 }
                if action.isEnabled != live.mayStart { failures += 1 }
            } else if !Self.inputLive(live), !Self.ownLive(live) {
                failures += 1
            }
        }
        XCTAssertEqual(failures, 0)
    }

    /// Only input-consuming work holds a waiting result back from the pointer's reveal (#220, #222):
    /// exactly the global work the next action puts first, never the chosen tool's own session.
    func testOnlyInputConsumingWorkHoldsAResultBack() {
        var failures = 0
        Self.product { live in
            if live.consumesInput != Self.inputLive(live) { failures += 1 }
            // A tool's own session claims its label, yet holds no result back.
            if Self.ownLive(live) && !Self.inputLive(live) && live.consumesInput { failures += 1 }
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
            case .start, .captureNext:
                if action.isEnabled != live.mayStart { failures += 1 }
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
        // Input first, then the cheapest to undo, then the mode's own step or ending.
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
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Stop transcribing", "Dictate owns the meeting")
        next.meetingRecording = false
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Dictate", "presenting and personas belong to other modes")
        next.mode = .present
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "End presentation")
        next.presenting = false
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Present")
        next.mode = .persona
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Hide personas")
        next.persona = .none
        XCTAssertEqual(ToolbarNextAction.resolve(next).title, "Show persona")
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

    /// A key is offered only for an operation that key performs.
    func testOnlyOperationsAKeyPerformsHaveAKeyMode() {
        XCTAssertNil(ToolbarOperation.stopInserting.keyMode, "Present's key does not stop an insertion")
        XCTAssertNil(ToolbarOperation.stopMeetingTranscription.keyMode, "Dictate's key does not stop a meeting")
        XCTAssertNil(ToolbarOperation.pauseOverlays.keyMode, "the persona key refuses to pause a prepared set")
        XCTAssertNil(ToolbarOperation.resumeOverlays.keyMode)
        XCTAssertNil(ToolbarOperation.wait.keyMode)
        XCTAssertNil(ToolbarOperation.stopReading.keyMode, "the Read key pauses; it does not stop")
        XCTAssertEqual(ToolbarOperation.stopReading.mode, .read)
        XCTAssertEqual(ToolbarNextAction.title(.stopReading, live: ToolbarLiveState(mode: .read)), "Stop reading")
        XCTAssertEqual(ToolbarOperation.stopDictation.keyMode, .dictate)
        XCTAssertEqual(ToolbarOperation.hidePersona.keyMode, .persona)
        XCTAssertEqual(ToolbarOperation.captureNext.keyMode, .snapAndTalk)
        XCTAssertEqual(ToolbarOperation.endPresentation.keyMode, .present)
        XCTAssertEqual(ToolbarOperation.start(.snap).keyMode, .snap)
        XCTAssertEqual(ToolbarOperation.stopMeetingTranscription.mode, .dictate, "the symbol still belongs to Dictate")
    }

    /// The chooser lists all seven tools, checks the chosen one and lights each whose work is live (#134).
    func testTheChooserLightsTheToolWhoseWorkIsLive() {
        let rows = ToolbarNextAction.choices(for: ToolbarLiveState(mode: .dictate, drawing: true), key: { $0 == .draw ? "⌥D" : nil })
        XCTAssertEqual(rows.map(\.mode), ToolbarMode.allCases)
        XCTAssertEqual(rows.filter(\.isSelected).map(\.mode), [.dictate])
        XCTAssertEqual(rows.filter(\.isLive).map(\.mode), [.draw])
        XCTAssertEqual(rows.first { $0.mode == .draw }?.key, "⌥D")
        XCTAssertFalse(ToolbarLiveState(mode: .dictate, drawing: true).isLive(.dictate))
        let presenting = ToolbarNextAction.choices(for: ToolbarLiveState(mode: .draw, presenting: true))
        XCTAssertEqual(presenting.filter(\.isLive).map(\.mode), [.present])
    }

    func testIdleVerbsStayWithinTheTitleBudget() {
        XCTAssertEqual(ToolbarNextAction.idleVerbs.count, ToolbarMode.allCases.count + 2)
        for verb in ToolbarNextAction.idleVerbs { XCTAssertLessThanOrEqual(verb.count, ToolbarNextAction.titleBudget) }
    }
}
