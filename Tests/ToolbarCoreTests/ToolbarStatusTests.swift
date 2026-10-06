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

    func testPausedAndReconnectingCapturesNeverClaimLiveAudio() {
        for capture in [ToolbarActivity.Capture.dictation, .meeting] {
            let recording = ToolbarStatus.resolve(.init(capture: capture, level: 0.7))
            for transport in [ToolbarActivity.CaptureTransport.paused, .reconnecting] {
                let status = ToolbarStatus.resolve(.init(capture: capture, level: 0.7, stopsSoon: true, quiet: true,
                                                        captureTransport: transport))
                XCTAssertEqual(status.indicator, transport == .paused ? .paused : .processing)
                XCTAssertNil(status.level, "A stale input sample must not animate a paused or reconnecting capture")
                XCTAssertNil(status.levelWords)
                XCTAssertFalse(status.quiet || status.stopsSoonBadge)
                XCTAssertFalse(status.description.contains("Recording") || status.description.contains("5-minute"))
                XCTAssertTrue(status.description.lowercased().contains(capture.rawValue))
                XCTAssertTrue(status.description.contains(transport == .paused ? "paused" : "Reconnecting"))
                XCTAssertTrue(status.announces(after: recording))
                XCTAssertFalse(status.announces(after: status), "Transport changes announce once, not on each elapsed tick")
            }
        }
        XCTAssertEqual(ToolbarStatus.resolve(.init(captureTransport: .reconnecting)), .idle,
                       "A completed session's stale transport cannot resurrect activity")
    }

    func testAutomaticMeetingFinishWarnsOnceAndOnlyForTheActiveMeeting() {
        let recording = ToolbarStatus.resolve(.init(capture: .meeting))
        let grace = ToolbarStatus.resolve(.init(capture: .meeting, meetingFinishesSoon: true))
        XCTAssertTrue(grace.stopsSoonBadge)
        XCTAssertTrue(grace.description.contains("Call audio ended") && grace.description.contains("Keep recording"))
        XCTAssertFalse(grace.description.contains("5-minute"))
        XCTAssertTrue(grace.announces(after: recording))
        XCTAssertFalse(grace.announces(after: grace), "The countdown lives in the chooser; it must not announce each second")
        for transport in [ToolbarActivity.CaptureTransport.paused, .reconnecting] {
            let interrupted = ToolbarStatus.resolve(.init(capture: .meeting, captureTransport: transport, meetingFinishesSoon: true))
            XCTAssertFalse(interrupted.stopsSoonBadge || interrupted.description.contains("Call audio ended"))
        }
        XCTAssertEqual(ToolbarStatus.resolve(.init(meetingFinishesSoon: true)), .idle, "A stale grace flag cannot resurrect work")
    }

    /// Capture and playback, processing, failure, a pending result or capture, paused work, other
    /// live work, idle: each wins over everything after it.
    func testThePriorityIsFixed() {
        let ladder: [(ToolbarActivity, ToolbarStatus.Indicator)] = [
            (ToolbarActivity(capture: .dictation, processing: true, failure: true, pendingDelivery: true,
                             unsavedCapture: true, paused: true, live: [.presenting]), .capture),
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
        XCTAssertNil(ToolbarStatus.resolve(ToolbarActivity(level: 0.5, processing: true)).level)
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
                              (ToolbarActivity(processing: true), ToolbarActivity(processing: true, unsavedCapture: true))] {
            let before = ToolbarStatus.resolve(base), after = ToolbarStatus.resolve(added)
            XCTAssertEqual(after.indicator, before.indicator, "the indicator keeps its priority")
            XCTAssertTrue(after.announces(after: before), "\(after.description) is heard")
            XCTAssertFalse(after.announces(after: after), "once")
        }
    }

    /// In a recording's last seconds before its 5-minute limit the mark carries a timer badge, and
    /// VoiceOver hears it once, when it appears; it never outlasts the capture (#134 T4).
    func testTheTimeLimitWarningIsABadgeHeardOnce() {
        let recording = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.3))
        let ending = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.6, stopsSoon: true))
        XCTAssertEqual(ending.indicator, .capture)
        XCTAssertTrue(ending.stopsSoonBadge)
        XCTAssertFalse(ending.attentionBadge, "the limit is not another job needing attention")
        XCTAssertTrue(ending.description.contains("Recording dictation") && ending.description.contains("5-minute limit"), ending.description)
        XCTAssertTrue(ending.announces(after: recording), "the warning is heard when it appears")
        XCTAssertFalse(ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.1, stopsSoon: true)).announces(after: ending),
                       "and not again while the seconds run down")
        XCTAssertFalse(ToolbarStatus.resolve(ToolbarActivity(processing: true, stopsSoon: true)).stopsSoonBadge,
                       "a capture that has ended carries no warning")
        let both = ToolbarStatus.resolve(ToolbarActivity(capture: .narration, failure: true, stopsSoon: true))
        XCTAssertTrue(both.attentionBadge && both.stopsSoonBadge, "a background failure and the limit keep both signals")
    }

    /// A background failure in a recording's last ten seconds shows both badges, the timer and the
    /// warning, and the words name both states (#211 F4).
    func testBothBadgesShowAndBothStatesAreNamed() {
        let both = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.4, failure: true, stopsSoon: true))
        XCTAssertEqual(both.badges, [.stopsSoon, .attention])
        XCTAssertTrue(both.description.contains("5-minute limit") && both.description.contains("Needs attention"), both.description)
        XCTAssertEqual(ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, stopsSoon: true)).badges, [.stopsSoon])
        XCTAssertEqual(ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, pendingDelivery: true)).badges, [.attention])
        XCTAssertEqual(ToolbarStatus.resolve(ToolbarActivity(failure: true, stopsSoon: true)).badges, [], "no badges without a capture")
        let failing = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.4, stopsSoon: true))
        XCTAssertTrue(both.announces(after: failing), "a failure arriving in the last seconds is heard")
    }

    /// The level in words is VoiceOver's value, never announced (#211 F7): Quiet, Receiving sound,
    /// or Low microphone level once the owner judges the microphone too quiet to use.
    func testTheLevelInWordsIsTheValueAndNeverAnnounced() {
        let quiet = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.01))
        let sound = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.6))
        let low = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.01, quiet: true))
        XCTAssertEqual([quiet.levelWords, sound.levelWords, low.levelWords], ["Quiet", "Receiving sound", "Low microphone level"])
        XCTAssertEqual(sound.spokenValue, "Recording dictation. Receiving sound")
        XCTAssertNil(ToolbarStatus.resolve(ToolbarActivity(capture: .meeting)).levelWords, "no words without a level sample")
        XCTAssertNil(ToolbarStatus.resolve(ToolbarActivity(processing: true, quiet: true)).levelWords, "and none without a capture")
        XCTAssertFalse(sound.announces(after: quiet) || low.announces(after: sound) || quiet.announces(after: low),
                       "the level and its words are never announced")
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
