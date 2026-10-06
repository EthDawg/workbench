import AppKit
import SwiftUI
import XCTest
import ToolbarCore
@testable import ToolbarKit

final class ToolbarActivityChooserTests: XCTestCase {
    @MainActor func testACommandCannotTurnIntoAnotherOperationOrActAfterItReturns() {
        let pause = ToolbarChooserAction("dictate.pause", "Pause dictation", identity: "capture-1")
        var row = ToolbarToolChoice(mode: .dictate, isLive: true); row.actions = [pause]
        let model = ToolbarChooserModel(choices: [row])
        var performed: [String] = []; model.perform = { performed.append($0.id) }
        let held = model.press(pause)
        row.actions = [.init("dictate.resume", "Resume dictation", identity: "capture-1")]; model.refresh([row])
        row.actions = [pause]; model.refresh([row])
        held?()
        XCTAssertTrue(performed.isEmpty, "a Pause that left and came back is a different press")
        model.press(pause)?()
        XCTAssertEqual(performed, ["dictate.pause"])
    }

    @MainActor func testEveryDestructiveActivityRejectsAReplacementOperation() {
        for id in ["dictate.stop", "dictate.pause", "dictate.resume", "meeting.stop", "meeting.pause", "meeting.resume",
                   "draw.stop", "present.end", "present.stop-inserting", "snap-talk.stop", "snap-talk.cancel", "persona.end", "persona.visibility"] {
            let first = ToolbarChooserAction(id, "Unchanged label", identity: UUID().uuidString)
            var row = ToolbarToolChoice(mode: .present); row.actions = [first]
            let model = ToolbarChooserModel(choices: [row])
            var performed = 0; model.perform = { _ in performed += 1 }
            let held = model.press(first)
            row.actions = [.init(id, first.title, identity: UUID().uuidString)]
            model.refresh([row]); held?()
            XCTAssertEqual(performed, 0, "A held \(id) must not target its replacement")
            model.press(row.actions[0])?()
            XCTAssertEqual(performed, 1)
        }
    }

    @MainActor func testVoiceTransportCommandsStayReachableAtLargerTextWithoutChangingThePill() {
        _ = NSApplication.shared
        for paused in [false, true] {
            var dictate = ToolbarToolChoice(mode: .dictate, isSelected: true, isLive: true)
            let transport = paused ? "Resume" : "Pause"
            dictate.actions = [.init("dictate.stop", "Finish dictation", identity: "dictation-1"),
                                .init("dictate.transport", transport + " dictation", identity: "dictation-1"),
                                .init("dictate.cancel", "Cancel", identity: "dictation-1")]
            let model = ToolbarChooserModel(choices: [dictate])
            model.refreshActivities(.init([.init(id: "meeting", title: "Meetings", symbol: "person.2.wave.2",
                detail: paused ? "Paused · recording kept" : "Recording", actions: [
                    .init("meeting.stop", "Finish meeting", identity: "meeting-1"),
                    .init("meeting.transport", transport + " meeting", identity: "meeting-1"),
                    .init("meeting.review", "Open Meetings…")])]))
            for scale in [CGFloat(1), 1.35] {
                let host = NSHostingView(rootView: ToolbarChooserView(model: model, textScale: scale, available: 360, availableWidth: 280))
                host.frame = NSRect(origin: .zero, size: host.fittingSize); host.layoutSubtreeIfNeeded()
                func buttons(_ view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
                let commands = buttons(host).filter { $0.accessibilityIdentifier().hasPrefix("chooser.action.") }
                XCTAssertEqual(commands.count, 7, "Both captures retain their own transport and workspace access")
                XCTAssertTrue(commands.contains { $0.title == transport + " dictation" })
                XCTAssertTrue(commands.contains { $0.title == transport + " meeting" })
                XCTAssertTrue(commands.allSatisfy(\.acceptsFirstResponder))
                XCTAssertLessThanOrEqual(host.fittingSize.width, 281)
                XCTAssertLessThanOrEqual(host.fittingSize.height, 361)
                for command in commands {
                    let frame = command.convert(command.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(frame.minX, -1)
                    XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX + 1)
                }
            }
        }
    }

    @MainActor func testAnotherActivityAndTimerTicksDoNotCancelTheNamedCommand() {
        let stop = ToolbarChooserAction("dictate.stop", "Finish dictation", identity: "capture-1")
        var row = ToolbarToolChoice(mode: .dictate, isLive: true); row.actions = [stop]
        let model = ToolbarChooserModel(choices: [row])
        var performed = 0; model.perform = { _ in performed += 1 }
        let held = model.press(stop)
        model.refreshActivities(.init([.init(id: "timer", title: "Timer", symbol: "timer", detail: "00:09",
            actions: [.init("timer.transport", "Pause timer", identity: "countdown-2")])]))
        model.refreshActivities(.init([.init(id: "timer", title: "Timer", symbol: "timer", detail: "00:08",
            actions: [.init("timer.transport", "Pause timer", identity: "countdown-2")])]))
        held?()
        XCTAssertEqual(performed, 1)
        let old = model.press(stop)
        row.actions = [.init("dictate.stop", "Finish dictation", identity: "capture-2")]; model.refresh([row]); old?()
        XCTAssertEqual(performed, 1, "the same label must not stop a replacement capture")
    }

    @MainActor func testEveryVisibleActivityCommandIsASeparateNativeButtonAndFits() {
        _ = NSApplication.shared
        var choices = ToolbarMode.allCases.map { ToolbarToolChoice(mode: $0, isSelected: $0 == .present) }
        choices[0].actions = [.init("dictate.retry", "Retry transcription"), .init("dictate.review", "Review recordings"), .init("dictate.dismiss", "Dismiss message")]
        choices[2].actions = [.init("snap-talk.stop", "Stop narration"), .init("snap-talk.cancel", "Cancel narration")]
        choices[4].actions = [.init("present.end", "End presentation")]
        let model = ToolbarChooserModel(choices: choices)
        var opened: [ToolbarMode] = []; model.openTool = { opened.append($0) }
        model.highlight(.persona)
        XCTAssertEqual(model.selected, .present, "hover and arrow selection do not retarget the workspace door")
        model.refreshActivities(.init([.init(id: "timer", title: "Timer", symbol: "timer", detail: "00:09",
            actions: [.init("timer.pause", "Pause timer"), .init("timer.end", "End timer")])]))
        for scale in [CGFloat(1), 1.35] {
            let host = NSHostingView(rootView: ToolbarChooserView(model: model, textScale: scale, available: 360, availableWidth: 320))
            host.frame = NSRect(origin: .zero, size: host.fittingSize); host.layoutSubtreeIfNeeded()
            func buttons(_ view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
            let controls = buttons(host).filter { $0.accessibilityIdentifier().hasPrefix("chooser.action.") }
            XCTAssertEqual(controls.count, 9, "eight owner commands and one explicit workspace door")
            XCTAssertEqual(host.fittingSize.width, 320, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, 360, accuracy: 1)
            XCTAssertTrue(controls.allSatisfy { !$0.title.isEmpty && $0.acceptsFirstResponder })
            for control in controls {
                let frame = control.convert(control.bounds, to: host)
                XCTAssertGreaterThanOrEqual(frame.minX, -1)
                XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX + 1)
            }
            let footer = controls.first { $0.accessibilityIdentifier() == "chooser.action.open-tool" }
            XCTAssertEqual(footer?.title, "Open Present…")
            footer?.performClick(nil)
            XCTAssertEqual(opened.last, .present)
        }
    }

    @MainActor func testTabReachesNativeCommandsAndAccessibilityPressUsesTheCurrentCommand() {
        _ = NSApplication.shared
        var row = ToolbarToolChoice(mode: .dictate, isSelected: true)
        row.actions = [.init("dictate.pause", "Pause dictation", identity: "capture"), .init("dictate.stop", "Finish dictation", identity: "capture")]
        let model = ToolbarChooserModel(choices: [row])
        var performed: [String] = []; model.perform = { performed.append($0.id) }
        let host = FocusableChooserHost(rootView: ToolbarChooserView(model: model))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); host._renderForTest(interval: 0)
        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        window.makeFirstResponder(host)
        var visited: [String] = []
        for _ in 0..<3 {
            XCTAssertTrue(ToolbarChooserKeyboard.tab(tab, in: window, from: window.firstResponder as? NSButton))
            let button = window.firstResponder as? NSButton
            visited.append(button?.accessibilityIdentifier() ?? "missing")
            if visited.count == 1 { XCTAssertTrue(button?.accessibilityPerformPress() == true) }
        }
        XCTAssertEqual(visited, ["chooser.action.dictate.pause", "chooser.action.dictate.stop", "chooser.action.open-tool"])
        XCTAssertEqual(performed, ["dictate.pause"])
        XCTAssertTrue(ToolbarChooserKeyboard.tab(tab, in: window, from: window.firstResponder as? NSButton))
        XCTAssertTrue(window.firstResponder === host)
    }

    @MainActor func testThereIsNoOverflowControlAndBothContextualControlsFitAtEveryDock() {
        _ = NSApplication.shared
        for anchor in ToolbarAnchor.allCases {
            for mode in ToolbarMode.allCases {
                let state = ToolbarViewState(name: "native-pill", tier: .revealed, anchor: anchor, mode: mode,
                    accessory: mode == .present ? .prompts : mode == .persona ? .personaPicker : nil,
                    quickControl: mode == .present ? .presentationView : mode == .persona ? .nextPersona : nil)
                let host = NSHostingView(rootView: ToolbarRow(state: state)); host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded(); host._renderForTest(interval: 0)
                func buttons(_ view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
                let controls = buttons(host)
                XCTAssertFalse(controls.contains { $0.accessibilityIdentifier() == "toolbar.more" })
                XCTAssertEqual(controls.count, 2 + state.accessoryCount)
                for button in controls {
                    let frame = button.convert(button.bounds, to: host)
                    XCTAssertTrue(host.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(anchor) \(mode) \(button.accessibilityIdentifier()): \(frame) in \(host.bounds)")
                }
            }
        }
    }
}

@MainActor private final class FocusableChooserHost: NSHostingView<ToolbarChooserView> {
    override var acceptsFirstResponder: Bool { true }
}
