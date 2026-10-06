import XCTest
@testable import ToolbarCore

final class ToolbarCaptureTests: XCTestCase {
    func testSourcesOnlyReplaceACaptureStep() {
        XCTAssertEqual(ToolbarCaptureKind.offered(for: .init(mode: .snap)), [.region, .window, .screen])
        XCTAssertEqual(ToolbarCaptureKind.offered(for: .init(mode: .snapAndTalk, captureCount: 0)), [.region, .window, .screen])
        XCTAssertTrue(ToolbarCaptureKind.offered(for: .init(mode: .snapAndTalk)).isEmpty)
        for mode in [ToolbarMode.snap, .snapAndTalk] {
            for live in [ToolbarLiveState(mode: mode, dictation: .recording),
                         .init(mode: mode, narrating: true),
                         .init(mode: mode, capturingScreen: true), .init(mode: mode, drawing: true),
                         .init(mode: mode, insertingPrompt: true)] {
                XCTAssertTrue(ToolbarCaptureKind.offered(for: live).isEmpty, "\(live)")
            }
        }
        // A dictation still processing consumes nothing, so Snap keeps its sources.
        XCTAssertEqual(ToolbarCaptureKind.offered(for: .init(mode: .snap, dictation: .processing)), [.region, .window, .screen])
    }

    func testCaptureNextRespectsAdmissionAndOnlyTheDefaultSourceClaimsAKey() {
        XCTAssertFalse(ToolbarNextAction.resolve(.init(mode: .snapAndTalk, captureCount: 4, mayStart: false)).isEnabled)
        for mode in [ToolbarMode.snap, .snapAndTalk] {
            let state = ToolbarViewState(name: "sources", tier: .revealed, mode: mode,
                actionTitle: mode == .snap ? "Snap" : "Capture next · 4", actionHint: "⌥S",
                captureChoices: ToolbarCaptureKind.allCases)
            for kind in ToolbarCaptureKind.allCases {
                XCTAssertEqual(state.captureHelp(kind).contains("⌥S"), kind.usesShortcut(in: mode))
                XCTAssertEqual(state.captureHelp(kind).contains("narration"), mode == .snapAndTalk)
            }
        }
    }

    func testCapturePressCannotSurvivePreemptionOrBecomeStop() {
        let gate = ToolbarPressGate()
        var live = ToolbarLiveState(mode: .snapAndTalk, captureCount: 2)
        gate.shown(.captureNext)
        var captures = 0
        let held = gate.press({ .resolve(live) }, perform: { _ in captures += 1 })
        live.narrating = true; gate.shown(.finishNarration)
        held?()
        XCTAssertEqual(captures, 0)
        live.narrating = false; gate.shown(.captureNext)
        held?()
        XCTAssertEqual(captures, 0)
        let next = gate.press({ .resolve(live) }, perform: { _ in captures += 1 })
        live.mayStart = false
        next?()
        XCTAssertEqual(captures, 0)
    }
}
