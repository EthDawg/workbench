import XCTest
@testable import ToolbarCore

/// The compact rest's one status (#134): the indicator's priority, the recording badge, the
/// accessible words and when VoiceOver hears a change. The status never decides the tier.
final class ToolbarStatusTests: XCTestCase {
    func testNothingRunningIsTheIdleMark() {
        let status = ToolbarStatus.resolve(.idle)
        XCTAssertEqual(status.indicator, .idle)
        XCTAssertFalse(status.attentionBadge)
        XCTAssertNil(status.level)
        XCTAssertEqual(status.description, "Nothing running")
        XCTAssertEqual(status, .idle)
    }

    /// Capture and playback, processing, failure, a pending result or capture, paused work, other
    /// live work, idle: each wins over everything after it.
    func testThePriorityIsFixed() {
        let ladder: [(ToolbarActivity, ToolbarStatus.Indicator)] = [
            (ToolbarActivity(capture: .dictation, playback: true, processing: true, failure: true, pendingDelivery: true,
                             unsavedCapture: true, paused: true, live: [.presenting]), .capture),
            (ToolbarActivity(playback: true, processing: true, failure: true, pendingDelivery: true, unsavedCapture: true,
                             paused: true, live: [.presenting]), .playback),
            (ToolbarActivity(processing: true, failure: true, pendingDelivery: true, unsavedCapture: true, paused: true, live: [.presenting]), .processing),
            (ToolbarActivity(failure: true, pendingDelivery: true, unsavedCapture: true, paused: true, live: [.presenting]), .failure),
            (ToolbarActivity(pendingDelivery: true, unsavedCapture: true, paused: true, live: [.presenting]), .pendingDelivery),
            (ToolbarActivity(unsavedCapture: true, paused: true, live: [.presenting]), .unsavedCapture),
            (ToolbarActivity(paused: true, live: [.presenting]), .paused),
            (ToolbarActivity(live: [.timer, .presenting]), .live(.presenting)),
            (ToolbarActivity(live: [.timer]), .live(.timer)),
            (.idle, .idle)
        ]
        for (activity, indicator) in ladder {
            XCTAssertEqual(ToolbarStatus.resolve(activity).indicator, indicator, "\(activity)")
        }
    }

    /// Recording while another job needs attention keeps the recording signal and adds the badge.
    func testRecordingKeepsItsSignalAndBadgesAJobThatNeedsAttention() {
        for other in [ToolbarActivity(capture: .narration, failure: true), ToolbarActivity(capture: .meeting, pendingDelivery: true),
                      ToolbarActivity(capture: .dictation, unsavedCapture: true)] {
            let status = ToolbarStatus.resolve(other)
            XCTAssertEqual(status.indicator, .capture)
            XCTAssertTrue(status.attentionBadge, "\(other)")
        }
        XCTAssertFalse(ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, processing: true, live: [.drawing])).attentionBadge,
                       "processing and live work are not attention")
        XCTAssertFalse(ToolbarStatus.resolve(ToolbarActivity(failure: true)).attentionBadge, "a failure alone is its own indicator, not a badge")
        let both = ToolbarStatus.resolve(ToolbarActivity(capture: .narration, failure: true))
        XCTAssertTrue(both.description.contains("Recording narration") && both.description.contains("Needs attention"),
                      "the accessible description names both states: \(both.description)")
    }

    /// The level is the capturing owner's own sample, kept between 0 and 1, and only for capture.
    func testTheLevelIsTheOwnersSampleAndOnlyForCapture() {
        XCTAssertEqual(ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.4)).level, 0.4)
        XCTAssertEqual(ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 3)).level, 1)
        XCTAssertEqual(ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: -1)).level, 0)
        XCTAssertNil(ToolbarStatus.resolve(ToolbarActivity(capture: .meeting)).level, "an owner without a sample shows the still outline")
        XCTAssertNil(ToolbarStatus.resolve(ToolbarActivity(level: 0.5, playback: true)).level)
    }

    /// VoiceOver hears a new indicator, badge or state in words once, never a level or a repeated state.
    func testOnlyMeaningfulChangesAreAnnounced() {
        let quiet = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.1))
        let loud = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.9))
        XCTAssertFalse(loud.announces(after: quiet), "a level change is not news")
        XCTAssertFalse(quiet.announces(after: quiet))
        XCTAssertTrue(ToolbarStatus.resolve(ToolbarActivity(processing: true)).announces(after: quiet))
        XCTAssertTrue(ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, failure: true)).announces(after: quiet), "the badge is news")
        let processing = ToolbarStatus.resolve(ToolbarActivity(processing: true))
        XCTAssertFalse(ToolbarStatus.resolve(ToolbarActivity(processing: true)).announces(after: processing), "no repeated processing chatter")
    }

    /// A job that needs the person, arriving under a higher-priority indicator, changes the words
    /// but not the indicator, and is still heard once (#205 review).
    func testAResultArrivingUnderProcessingOrPlaybackIsHeard() {
        for (base, added) in [(ToolbarActivity(processing: true), ToolbarActivity(processing: true, failure: true)),
                              (ToolbarActivity(processing: true), ToolbarActivity(processing: true, pendingDelivery: true)),
                              (ToolbarActivity(playback: true), ToolbarActivity(playback: true, unsavedCapture: true))] {
            let before = ToolbarStatus.resolve(base), after = ToolbarStatus.resolve(added)
            XCTAssertEqual(after.indicator, before.indicator, "the indicator keeps its priority")
            XCTAssertTrue(after.announces(after: before), "\(after.description) is heard")
            XCTAssertFalse(after.announces(after: after), "once")
        }
    }

    /// Live work keeps one order, whatever order the host listed it in, and its words.
    func testLiveWorkHasOneOrderAndItsOwnWords() {
        let activity = ToolbarActivity(live: [.snapAndTalk, .timer, .drawing])
        XCTAssertEqual(activity.live, [.drawing, .timer, .snapAndTalk])
        XCTAssertEqual(ToolbarStatus.resolve(activity).description, "Drawing, Timer running, Snap & Talk session open")
        XCTAssertEqual(ToolbarActivity.Live.drawing.symbol, ToolbarMode.draw.symbol, "the same symbol as the tool")
        XCTAssertEqual(ToolbarActivity.Live.persona.symbol, ToolbarMode.persona.symbol)
    }
}
