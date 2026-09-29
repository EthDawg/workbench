import XCTest
@testable import ToolbarCore

/// Which waiting result the pointer's reveal may show over live work (#220, #222).
final class ToolbarResultHoldTests: XCTestCase {
    private enum Result: Hashable { case dictationFailure, readingFailure, receipt(Int) }
    private let idle = ToolbarLiveState(mode: .dictate)

    /// Every kind of input-consuming work, whichever tool is chosen.
    private var inputWork: [(String, ToolbarLiveState)] {
        [("a reading preparing", ToolbarLiveState(mode: .dictate, reading: .preparing)),
         ("a reading playing", ToolbarLiveState(mode: .read, reading: .playing)),
         ("a reading paused", ToolbarLiveState(mode: .present, reading: .paused)),
         ("a narration", ToolbarLiveState(mode: .snapAndTalk, narrating: true, captureCount: 1)),
         ("a recording", ToolbarLiveState(mode: .dictate, dictation: .recording)),
         ("its processing", ToolbarLiveState(mode: .dictate, dictation: .processing)),
         ("drawing", ToolbarLiveState(mode: .draw, drawing: true)),
         ("an insertion", ToolbarLiveState(mode: .present, insertingPrompt: true)),
         ("a screen capture", ToolbarLiveState(mode: .snap, capturingScreen: true))]
    }

    /// The chosen tool's own sessions, which hold nothing back.
    private var sessions: [(String, ToolbarLiveState)] {
        [("a presentation", ToolbarLiveState(mode: .present, presenting: true)),
         ("a Persona set", ToolbarLiveState(mode: .persona, persona: .session)),
         ("a hidden Persona set", ToolbarLiveState(mode: .persona, persona: .sessionHidden)),
         ("a shown card", ToolbarLiveState(mode: .persona, persona: .shown)),
         ("a meeting transcription", ToolbarLiveState(mode: .dictate, meetingRecording: true)),
         ("Snap & Talk between captures", ToolbarLiveState(mode: .snapAndTalk, captureCount: 2))]
    }

    /// The result pending when the work began stays out of the reveal while the work lasts, a new
    /// one that arrives during it is revealed, and the work ending lets the older one go.
    func testTheResultWaitingWhenWorkBeginsIsHeldBackUntilItEnds() {
        for (name, work) in inputWork {
            for older in [Result.dictationFailure, .readingFailure, .receipt(1)] {
                var hold = ToolbarResultHold<Result>()
                hold.observe(idle, pending: older)
                XCTAssertTrue(hold.reveals(older), "\(name): nothing live yet")
                hold.observe(work, pending: older)
                XCTAssertFalse(hold.reveals(older), "\(name): \(older) was waiting when the work began")
                hold.observe(work, pending: older)
                XCTAssertFalse(hold.reveals(older), "\(name): still held while the work lasts")
                XCTAssertTrue(hold.reveals(.receipt(2)), "\(name): a receipt that arrives during the work is new")
                hold.observe(idle, pending: older)
                XCTAssertTrue(hold.reveals(older), "\(name): the work ended")
            }
            // Work that begins with nothing waiting holds nothing: every result that arrives is new.
            var fresh = ToolbarResultHold<Result>()
            fresh.observe(work, pending: nil)
            fresh.observe(work, pending: .dictationFailure)
            XCTAssertTrue(fresh.reveals(.dictationFailure), "\(name): a failure that arrives during the work is revealed")
        }
    }

    /// The held result's own slot set again, to the same words or to none, makes what follows new;
    /// another kind's slot changing keeps it held.
    func testOnlyTheHeldKindsOwnSlotLetsItGo() {
        let reading = ToolbarLiveState(mode: .read, reading: .playing)
        var hold = ToolbarResultHold<Result>()
        hold.observe(reading, pending: .dictationFailure)
        hold.slotChanged(.dictationFailure)
        hold.observe(reading, pending: .dictationFailure)
        XCTAssertTrue(hold.reveals(.dictationFailure), "the same message set again is a new failure")
        var receipt = ToolbarResultHold<Result>()
        receipt.observe(reading, pending: .receipt(1))
        receipt.slotChanged(.dictationFailure)
        receipt.slotChanged(.readingFailure)
        XCTAssertFalse(receipt.reveals(.receipt(1)), "a held receipt stays held when another slot is cleared")
        XCTAssertTrue(receipt.reveals(.receipt(2)), "a new receipt is its own")
    }

    /// The chosen tool's own sessions hold nothing back: older and newer results are revealed.
    func testTheToolsOwnSessionsHoldNothingBack() {
        for (name, session) in sessions {
            for result in [Result.dictationFailure, .readingFailure, .receipt(1)] {
                var older = ToolbarResultHold<Result>()
                older.observe(idle, pending: result)
                older.observe(session, pending: result)
                XCTAssertTrue(older.reveals(result), "\(name): an older \(result) is revealed")
                var newer = ToolbarResultHold<Result>()
                newer.observe(session, pending: nil)
                newer.observe(session, pending: result)
                XCTAssertTrue(newer.reveals(result), "\(name): a newer \(result) is revealed")
            }
        }
    }
}
