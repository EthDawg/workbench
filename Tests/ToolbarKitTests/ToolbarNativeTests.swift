import AppKit
import SwiftUI
import XCTest
import ToolbarCore
import StageKit
@testable import ToolbarKit

final class ToolbarNativeTests: XCTestCase {
    private func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    private func laidOut<V: View>(_ root: V, width: CGFloat? = nil) -> NSHostingView<V> {
        let view = NSHostingView(rootView: root)
        let size = view.fittingSize
        view.frame = NSRect(x: 0, y: 0, width: width ?? size.width, height: size.height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Every resting fixture is the same 48 × 28 compact target, whatever it shows (#134); every
    /// revealed row fits its content and grows with larger text.
    @MainActor func testProductionRowsFitContentForEveryFixtureAndLargerText() {
        _ = NSApplication.shared
        for scale in [CGFloat(1), 1.35] {
            for state in ToolbarGallery.states {
                let size = NSHostingView(rootView: ToolbarRow(state: state, textScale: scale)).fittingSize
                if state.tier == .resting {
                    XCTAssertEqual(size, ToolbarLayout.mark, state.name)
                    continue
                }
                XCTAssertGreaterThanOrEqual(size.height, ToolbarLayout.rowHeight * scale - 1, state.name)
                XCTAssertLessThan(size.width, 700, state.name)
                XCTAssertGreaterThanOrEqual(size.width, ToolbarLayout.standardWidth - 0.5, state.name)
                let larger = NSHostingView(rootView: ToolbarRow(state: state, textScale: scale * 1.2)).fittingSize
                XCTAssertGreaterThan(larger.width, size.width, state.name)
            }
        }
    }

    /// Ordinary work shares the quiet handle; recording and recovery remain visible.
    /// Drawn bounds prove no live-tool glyph escapes the thin capsule and the hit target
    /// stays generous. Capture badges retain their separate bounds checks below.
    @MainActor func testTheCompactMarkDistinguishesQuietWorkFromSignalsWithoutMovingItsTarget() throws {
        _ = NSApplication.shared
        func drawn(_ status: ToolbarStatus) throws -> (width: Int, height: Int, size: NSSize) {
            let view = NSHostingView(rootView: ToolbarCompactMark(status: status).environment(\.colorScheme, .light))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let perPoint = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            var rows = Set<Int>(), columns = Set<Int>()
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    rows.insert(y); columns.insert(x)
                }
            }
            func points(_ pixels: Set<Int>) -> Int { pixels.isEmpty ? 0 : Int((CGFloat(pixels.max()! - pixels.min()! + 1) / perPoint).rounded()) }
            return (points(columns), points(rows), view.fittingSize)
        }
        for status in [ToolbarStatus.idle] + ToolbarActivity.Live.allCases.map({ .resolve(ToolbarActivity(live: [$0])) }) {
            let quiet = try drawn(status)
            XCTAssertEqual(quiet.size, ToolbarLayout.mark, status.description)
            XCTAssertEqual(quiet.height, 8, "a quiet handle, without a tiny tool glyph: \(status.description)")
            XCTAssertEqual(quiet.width, 48)
        }
        for activity in [ToolbarActivity(capture: .dictation, level: 0.6), ToolbarActivity(capture: .narration, level: 0.3, stopsSoon: true),
                         ToolbarActivity(processing: true), ToolbarActivity(playback: true), ToolbarActivity(paused: true),
                         ToolbarActivity(failure: true), ToolbarActivity(pendingDelivery: true), ToolbarActivity(unsavedCapture: true)] {
            let working = try drawn(.resolve(activity))
            XCTAssertEqual(working.size, ToolbarLayout.mark, "\(activity)")
            XCTAssertEqual(working.height, 20, "the active capsule: \(activity)")
            XCTAssertEqual(working.width, 48, "nothing is drawn beyond the capsule: \(activity)")
        }
    }

    /// Each badge's frame in `root`'s hosting view, as the badge reports its own layout (#211 F4):
    /// read from the layout rather than from pixels, so no backing scale, colour space or accent
    /// colour can move it.
    @MainActor private func badgeFrames<V: View>(_ root: V) -> (view: NSView, frames: [String: CGRect]) {
        var frames: [String: CGRect] = [:]
        let view = NSHostingView(rootView: root.environment(\.toolbarBadgeFrames) { frames[$0] = $1 })
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView = nil
        return (view, frames)
    }

    /// A background failure in a recording's last seconds shows both badges inside the 48 × 28
    /// target (#211 F4): the timer beside the trace and the warning on the capsule's corner, like
    /// a badge on an icon, each a fixed 7-point square, neither covering the other, and each where
    /// it is when it shows alone.
    @MainActor func testBothBadgesShowInsideTheMark() throws {
        _ = NSApplication.shared
        func badges(_ activity: ToolbarActivity) -> [String: CGRect] { badgeFrames(ToolbarCompactMark(status: .resolve(activity))).frames }
        let timer = badges(ToolbarActivity(capture: .dictation, level: 0.4, stopsSoon: true))
        let warning = badges(ToolbarActivity(capture: .dictation, level: 0.4, failure: true))
        let both = badges(ToolbarActivity(capture: .dictation, level: 0.4, failure: true, stopsSoon: true))
        XCTAssertEqual(Set(timer.keys), ["stopsSoon"])
        XCTAssertEqual(Set(warning.keys), ["attention"])
        XCTAssertEqual(Set(both.keys), ["stopsSoon", "attention"], "both show together")
        let target = CGRect(origin: .zero, size: ToolbarLayout.mark)
        for (badge, frame) in both {
            XCTAssertEqual(frame.size, CGSize(width: ToolbarLayout.badge, height: ToolbarLayout.badge), "\(badge) is a 7-point square")
            XCTAssertTrue(target.contains(frame), "\(badge) stays inside the 48 × 28 target: \(frame)")
        }
        let stopsSoon = try XCTUnwrap(both["stopsSoon"]), attention = try XCTUnwrap(both["attention"])
        XCTAssertFalse(stopsSoon.intersects(attention), "neither badge covers the other: \(stopsSoon), \(attention)")
        XCTAssertEqual(stopsSoon, timer["stopsSoon"], "the timer keeps its place when the warning joins it")
        XCTAssertEqual(attention, warning["attention"], "and the warning keeps its place when the timer joins it")
        XCTAssertLessThanOrEqual(attention.maxY, (ToolbarLayout.mark.height - ToolbarLayout.statusHeight) / 2, "the warning sits on the capsule's corner")
    }

    /// A result waiting for the person keeps its status on the launcher while the row is open
    /// (#211 F1): the mark's glyph as a badge on the tool's symbol, and its words in VoiceOver's
    /// value and the tooltip. With nothing waiting, nothing is added.
    @MainActor func testTheLauncherKeepsAWaitingResultsStatus() throws {
        _ = NSApplication.shared
        func launcher(_ activity: ToolbarActivity) throws -> (button: NSButton, badge: CGRect?, target: CGRect) {
            let state = ToolbarViewState(name: "waiting", tier: .revealed, mode: .dictate, status: .resolve(activity))
            let (view, frames) = badgeFrames(ToolbarRow(state: state))
            let button = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
            return (button, frames["result"], button.convert(button.bounds, to: view))
        }
        let failure = try launcher(ToolbarActivity(failure: true))
        let badge = try XCTUnwrap(failure.badge, "the warning is laid out on the launcher")
        XCTAssertTrue(failure.target.contains(badge), "on the launcher's own target: \(badge) in \(failure.target)")
        XCTAssertEqual(badge.size, CGSize(width: ToolbarLayout.badge, height: ToolbarLayout.badge), "a 7-point square at standard text")
        XCTAssertEqual(failure.button.accessibilityValue() as? String, "Dictate. Needs attention")
        XCTAssertEqual(failure.button.toolTip, "Dictate. Needs attention. Click to choose a tool; drag to move.")
        let receipt = try launcher(ToolbarActivity(pendingDelivery: true))
        XCTAssertNotNil(receipt.badge, "a result waiting to be delivered is badged too")
        XCTAssertEqual(receipt.button.accessibilityValue() as? String, "Dictate. Result waiting to be delivered")
        let idle = try launcher(.idle)
        XCTAssertNil(idle.badge, "with nothing waiting, no badge")
        XCTAssertEqual(idle.button.accessibilityValue() as? String, "Dictate")
    }

    /// Short actions keep their target without reserving space for other tools.
    @MainActor func testTheStandardRowWidths() {
        _ = NSApplication.shared
        let plain = NSHostingView(rootView: ToolbarRow(state: ToolbarViewState(name: "plain", tier: .revealed, mode: .draw))).fittingSize
        XCTAssertEqual(plain, NSSize(width: ToolbarLayout.standardWidth, height: ToolbarLayout.rowHeight))
        let accessory = NSHostingView(rootView: ToolbarRow(state: ToolbarViewState(name: "prompts", tier: .revealed, mode: .present))).fittingSize
        var waiting = ToolbarViewState(name: "prompts-in-more", tier: .revealed, mode: .present)
        waiting.showsAccessory = false
        let without = NSHostingView(rootView: ToolbarRow(state: waiting)).fittingSize.width
        XCTAssertEqual(accessory.width - without, ToolbarLayout.accessoryWidth + ToolbarLayout.gap, accuracy: 0.5)
        XCTAssertLessThan(without, 200, "short verbs should not carry a 152-point action floor")
    }

    /// The launcher sits exactly where the compact mark does: 24 points from the growth edge,
    /// at every anchor and text size, so the two share one centre on screen.
    @MainActor func testTheLauncherSharesTheCompactMarksCentre() throws {
        _ = NSApplication.shared
        for scale in [CGFloat(1), 1.35] {
            for anchor in ToolbarAnchor.allCases {
                let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "launcher", tier: .revealed, anchor: anchor, mode: .present), textScale: scale))
                let launcher = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
                let frame = launcher.convert(launcher.bounds, to: view)
                XCTAssertEqual(frame.width, ToolbarLayout.launcherWidth, "\(anchor) at \(scale)")
                let inset = anchor.growsLeftward ? view.bounds.maxX - frame.midX : frame.midX
                XCTAssertEqual(inset, ToolbarLayout.launcherInset, accuracy: 0.5, "\(anchor) at \(scale)")
            }
        }
    }

    /// A right-hand row reverses its slots: More, the accessory, the next action, then the
    /// launcher at the docked edge. The reading order of the controls is the same in both.
    @MainActor func testARightHandRowReversesItsSlots() {
        _ = NSApplication.shared
        func order(_ anchor: ToolbarAnchor) -> [String] {
            let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "order", tier: .revealed, anchor: anchor, mode: .present)))
            return buttons(view).filter { $0.accessibilityIdentifier().hasPrefix("toolbar.") }
                .sorted { $0.convert($0.bounds, to: view).minX < $1.convert($1.bounds, to: view).minX }
                .map { $0.accessibilityIdentifier() }
        }
        XCTAssertEqual(order(.bottom), ["toolbar.launcher", "toolbar.primary", "toolbar.accessory", "toolbar.more"])
        XCTAssertEqual(order(.right), ["toolbar.more", "toolbar.accessory", "toolbar.primary", "toolbar.launcher"])
    }

    /// The row holds no mode strip any more: the launcher is the one way to another tool.
    @MainActor func testTheRowHasOneLauncherAndNoModeStrip() throws {
        _ = NSApplication.shared
        var opened: [NSView] = []
        let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "strip", tier: .revealed, mode: .dictate), openChooser: { opened.append($0) }))
        XCTAssertTrue(buttons(view).filter { $0.accessibilityIdentifier().hasPrefix("toolbar.mode.") }.isEmpty)
        let launcher = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
        XCTAssertTrue(launcher.acceptsFirstResponder && launcher.acceptsFirstMouse(for: nil))
        XCTAssertEqual(launcher.accessibilityLabel(), "Tool: Dictate")
        launcher.performClick(nil)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first === launcher, "the chooser is anchored to the launcher")
    }

    /// More opens the tool's options only with admission, as the glyph menu did.
    @MainActor func testMoreOpensTheOptionsWithAdmission() throws {
        _ = NSApplication.shared
        var admissionRequests = 0, endings = 0
        let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "more", tier: .revealed),
            menuBegan: { _ in admissionRequests += 1; return false }, menuEnded: { endings += 1 }))
        let more = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.more" })
        XCTAssertTrue(more.acceptsFirstResponder)
        XCTAssertEqual(more.accessibilityLabel(), "More")
        more.performClick(nil)
        XCTAssertEqual(admissionRequests, 1)
        XCTAssertEqual(endings, 0, "rejected native activation never enters menu tracking")
    }

    /// The next action asks its press for what to do, and does nothing when the press says so.
    @MainActor func testThePrimaryActsOnlyThroughItsLatchedPress() throws {
        _ = NSApplication.shared
        var presses = 0, actions = 0, valid = true
        let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "press", tier: .revealed),
            press: { presses += 1; return valid ? { actions += 1 } : nil }))
        let primary = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.primary" })
        primary.performClick(nil)
        XCTAssertEqual(presses, 1); XCTAssertEqual(actions, 1)
        valid = false
        primary.performClick(nil)
        XCTAssertEqual(presses, 2); XCTAssertEqual(actions, 1, "a press whose operation no longer holds does nothing")
    }

    /// The compact rest is one accessible button: pressing it reveals, and nothing else.
    @MainActor func testTheCompactRestOnlyReveals() throws {
        _ = NSApplication.shared
        var reveals = 0, work = 0
        let status = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.5))
        let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "rest", tier: .resting, status: status), action: { work += 1 },
                                      revealFromRest: { reveals += 1 }))
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let target = try XCTUnwrap(all(view).first { $0.accessibilityIdentifier() == "toolbar.rest" })
        XCTAssertTrue(target.isAccessibilityElement())
        XCTAssertEqual(target.accessibilityValue() as? String, status.spokenValue)
        XCTAssertEqual(status.spokenValue, "Recording dictation. Receiving sound", "every state, then the level in words (#211 F7)")
        XCTAssertTrue(target.accessibilityPerformPress())
        XCTAssertEqual(reveals, 1); XCTAssertEqual(work, 0)
        XCTAssertTrue(buttons(view).isEmpty, "no control is reachable at rest but the target")
    }

    @MainActor func testQuietLiveWorkRetainsItsAccessibleStatusAndRevealAction() throws {
        _ = NSApplication.shared
        var reveals = 0
        let status = ToolbarStatus.resolve(ToolbarActivity(live: [.drawing, .presenting, .timer]))
        let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "quiet-live", tier: .resting, mode: .draw, status: status),
                                      revealFromRest: { reveals += 1 }))
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let target = try XCTUnwrap(all(view).first { $0.accessibilityIdentifier() == "toolbar.rest" })
        XCTAssertEqual(target.accessibilityValue() as? String, "Drawing, Presenting, Timer running")
        XCTAssertTrue(target.accessibilityPerformPress())
        XCTAssertEqual(reveals, 1)
        XCTAssertEqual(view.fittingSize, ToolbarLayout.mark)
    }

    /// A real window with the row in it, invisible and taking no pointer, for pressing its
    /// controls through their own mouse handling.
    @MainActor private func shown<V: View>(_ root: V) -> (NSPanel, NSHostingView<V>) {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: view.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.alphaValue = 0; panel.ignoresMouseEvents = true
        panel.contentView = view
        panel.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        return (panel, view)
    }
    /// Presses `control` through its own `mouseDown`, with the mouse-up already queued behind it,
    /// as a click arrives. Whatever the press leaves in the queue is left there for the caller.
    /// The queued mouse-up names no window: AppKit re-maps a posted event's window location
    /// through global coordinates, and one with no window keeps the point it was given.
    @MainActor private func click(_ control: NSView, in window: NSWindow, clickCount: Int = 1) {
        let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, window number: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: number, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp, window: 0), atStart: false)
        control.mouseDown(with: event(.leftMouseDown, window: window.windowNumber))
    }
    @MainActor private func queuedMouseUp(dequeue: Bool = false) -> Bool {
        NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: dequeue) != nil
    }

    /// The next action is latched as the button goes down, before its mouse-up is read, and the
    /// click then does what was latched (#134).
    @MainActor func testTheNextActionIsLatchedWhileTheButtonIsStillDown() throws {
        var upStillQueued: Bool?, actions = 0
        let (window, view) = shown(ToolbarRow(state: ToolbarViewState(name: "latch", tier: .revealed), press: { [self] in
            upStillQueued = queuedMouseUp()
            return { actions += 1 }
        }))
        defer { window.close() }
        let primary = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.primary" })
        click(primary, in: window)
        XCTAssertEqual(upStillQueued, true, "the operation must be latched on mouse-down, not resolved when the button comes up")
        XCTAssertEqual(actions, 1)
        XCTAssertFalse(queuedMouseUp(), "the click took its own mouse-up")
    }

    /// The second click of a double-click does nothing on the next action or the launcher, so a
    /// double-click that begins on the compact rest never reaches work (#134).
    @MainActor func testTheSecondClickOfADoubleClickDoesNothing() throws {
        var presses = 0, opens = 0
        let (window, view) = shown(ToolbarRow(state: ToolbarViewState(name: "double", tier: .revealed),
                                              press: { presses += 1; return {} }, openChooser: { _ in opens += 1 }))
        defer { window.close() }
        for id in ["toolbar.primary", "toolbar.launcher"] {
            let control = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == id })
            click(control, in: window, clickCount: 2)
            while queuedMouseUp(dequeue: true) {}
        }
        XCTAssertEqual(presses, 0, "a second click latched the next action")
        XCTAssertEqual(opens, 0, "a second click opened the chooser")
    }

    /// A click on the compact rest reveals, never works, and takes the whole click: the row that
    /// appears under the pointer never receives its mouse-up (#134).
    @MainActor func testAClickOnTheCompactRestOnlyRevealsAndTakesTheWholeClick() throws {
        var reveals = 0, work = 0
        let status = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.5))
        let (window, view) = shown(ToolbarRow(state: ToolbarViewState(name: "rest-click", tier: .resting, status: status),
                                              action: { work += 1 }, revealFromRest: { reveals += 1 }))
        defer { window.close() }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let target = try XCTUnwrap(all(view).first { $0.accessibilityIdentifier() == "toolbar.rest" })
        click(target, in: window)
        XCTAssertEqual(reveals, 1); XCTAssertEqual(work, 0)
        XCTAssertFalse(queuedMouseUp(), "the mouse-up was the compact rest's")
    }

    /// The launcher holds its place while the window is briefly the wrong size, at every anchor,
    /// because the content is pinned to the growth edge the launcher sits on.
    @MainActor func testTheLauncherHoldsItsPlaceWhileTheWindowIsTheWrongSize() throws {
        _ = NSApplication.shared
        func inset(_ state: ToolbarViewState, width: CGFloat, pinned: Bool) throws -> CGFloat {
            let row = ToolbarRow(state: state)
            let view = NSHostingView(rootView: pinned ? AnyView(row.pinnedToDock(state.anchor)) : AnyView(row))
            view.frame = NSRect(x: 0, y: 0, width: width, height: NSHostingView(rootView: row).fittingSize.height)
            view.layoutSubtreeIfNeeded()
            let launcher = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
            let frame = launcher.convert(launcher.bounds, to: view)
            return state.anchor.growsLeftward ? view.bounds.maxX - frame.maxX : frame.minX
        }
        for anchor in ToolbarAnchor.allCases {
            let state = ToolbarViewState(name: "jump", tier: .revealed, anchor: anchor, mode: .draw)
            let exact = NSHostingView(rootView: ToolbarRow(state: state)).fittingSize.width
            let settled = try inset(state, width: exact, pinned: true)
            for stale in [48, 72, exact - 30, exact + 60, max(400, exact + 1)] {
                XCTAssertEqual(try inset(state, width: stale, pinned: true), settled, accuracy: 0.5,
                               "\(anchor.rawValue): the launcher moved in a \(Int(stale))-point window")
            }
            XCTAssertGreaterThan(abs(try inset(state, width: exact + 60, pinned: false) - settled), 20,
                                 "\(anchor.rawValue): an unpinned row no longer moves, so this test no longer reproduces the jump")
        }
    }

    @MainActor func testLongPrimaryActionGrowsInsteadOfShrinkingText() {
        let short = ToolbarViewState(name: "short", tier: .revealed, actionTitle: "Dictate")
        var long = short; long.actionTitle = "Finish this much longer action"
        let small = NSHostingView(rootView: ToolbarRow(state: short)).fittingSize
        let large = NSHostingView(rootView: ToolbarRow(state: long)).fittingSize
        XCTAssertGreaterThan(large.width, small.width + 40)
        XCTAssertEqual(large.height, small.height, accuracy: 1)
    }

    /// A changing count redrew the row. With proportional digits each redraw
    /// changed its width and re-placed the window under the pointer. The count
    /// now lives in the label, so the label keeps one width per digit.
    @MainActor func testAChangingCountKeepsTheRowTheSameWidth() {
        _ = NSApplication.shared
        func width(_ title: String) -> CGFloat {
            NSHostingView(rootView: ToolbarRow(state: ToolbarViewState(name: "count", tier: .revealed, mode: .snapAndTalk,
                actionTitle: title))).fittingSize.width
        }
        XCTAssertEqual(width("Capture next · 1"), width("Capture next · 8"), accuracy: 0.5, "digits of different shapes resized the window")
        XCTAssertEqual(width("Capture next · 10"), width("Capture next · 99"), accuracy: 0.5)
    }

    /// Dynamic width belongs to one open interaction. It can grow, but only a
    /// collapse permits shrinking, so a changing Stop/Start cannot pull More away.
    @MainActor func testActionWidthFitsTheVerbAndOnlyShrinksAfterCollapse() {
        var state = ToolbarViewState(name: "width", tier: .revealed, mode: .draw, actionTitle: "Draw")
        let view = laidOut(ToolbarRow(state: state))
        let short = view.fittingSize.width
        state.actionTitle = "End presentation"
        view.rootView = ToolbarRow(state: state); view.layoutSubtreeIfNeeded()
        let long = view.fittingSize.width
        XCTAssertGreaterThan(long, short + 25)
        state.actionTitle = "Draw"
        view.rootView = ToolbarRow(state: state); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, long, accuracy: 0.5)
        state.tier = .resting
        view.rootView = ToolbarRow(state: state); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize, ToolbarLayout.mark)
        state.tier = .revealed
        view.rootView = ToolbarRow(state: state); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, short, accuracy: 0.5)
    }

    @MainActor func testActionAndMoreHintsNameTheirActualControl() throws {
        let state = ToolbarViewState(name: "hint", tier: .revealed, mode: .draw, actionTitle: "Draw", actionHint: "Hold ⌥D")
        let view = laidOut(ToolbarRow(state: state))
        let primary = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.primary" })
        let more = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.more" })
        XCTAssertEqual(primary.toolTip, "Draw · Hold ⌥D")
        XCTAssertEqual(primary.accessibilityHelp(), primary.toolTip)
        XCTAssertEqual(more.toolTip, "Options for Draw")
        var noKey = state; noKey.actionHint = nil
        view.rootView = ToolbarRow(state: noKey); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(primary.toolTip, "Draw")
    }

    func testRevealChromeFollowsTheWindowWithNoSecondClock() {
        for scale in [CGFloat(1), 1.35] {
            let row = ToolbarLayout.rowHeight * scale
            XCTAssertEqual(ToolbarRevealVisuals.progress(viewportHeight: 28, rowHeight: row), 0)
            XCTAssertEqual(ToolbarRevealVisuals.progress(viewportHeight: row, rowHeight: row), 1)
            let halfway = ToolbarRevealVisuals.progress(viewportHeight: (28 + row) / 2, rowHeight: row)
            XCTAssertEqual(halfway, 0.5, accuracy: 0.001)
            for (indicator, rest) in [(ToolbarStatus.Indicator.idle, CGFloat(8)), (.live(.presenting), 8), (.capture, 20), (.failure, 20)] {
                XCTAssertEqual(ToolbarRevealVisuals.capsuleHeight(progress: 0, rowHeight: row, indicator: indicator), rest)
                XCTAssertEqual(ToolbarRevealVisuals.capsuleHeight(progress: halfway, rowHeight: row, indicator: indicator), (rest + row) / 2)
                XCTAssertEqual(ToolbarRevealVisuals.capsuleHeight(progress: 1, rowHeight: row, indicator: indicator), row)
            }
        }
    }

    @MainActor func testImmediateRetargetSettlesSynchronouslyAtRequestedDestination() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 48, height: 28),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let motion = ToolbarWindowMotion()
        let final = NSRect(x: 200, y: 160, width: 48, height: 28)
        var completions = 0
        motion.settled = { completions += 1 }
        motion.move(panel, to: NSRect(x: 100, y: 100, width: 248, height: 40), animated: true)
        // AppKit can finish the first animation before move returns (including
        // with Reduce Motion). A completion before retargeting is legitimate.
        let beforeRetarget = completions
        XCTAssertLessThanOrEqual(beforeRetarget, 1)
        motion.move(panel, to: final, animated: false)
        // Assert immediately: a nonanimated replacement must settle before the
        // caller continues, not at some later point in an asynchronous wait.
        XCTAssertEqual(completions, beforeRetarget + 1)
        XCTAssertEqual(panel.frame, final)
        XCTAssertNil(motion.target)
    }

    @MainActor func testFinishingBeforeDragCannotRestoreTheOldOriginLater() async {
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 48, height: 28),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let motion = ToolbarWindowMotion()
        var completions = 0
        motion.settled = { completions += 1 }
        let expanded = NSRect(x: 100, y: 100, width: 248, height: 40)
        motion.move(panel, to: expanded, animated: true)
        motion.finish(panel)
        XCTAssertNil(motion.target)
        XCTAssertEqual(panel.frame, expanded)
        XCTAssertEqual(completions, 1, "finish must be synchronous before a drag records its origin")
        panel.setFrameOrigin(NSPoint(x: 350, y: 250))
        let unexpected = expectation(description: "stale animation completion")
        unexpected.isInverted = true
        motion.settled = { unexpected.fulfill() }
        await fulfillment(of: [unexpected], timeout: 0.25)
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 350, y: 250))
    }

    /// Live work lights the launcher's symbol and its one aggregate dot in the brand accent,
    /// in both appearances.
    @MainActor func testBusyLauncherAndDotUseTheSameBrandColourInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var expected: NSColor!
            appearance.performAsCurrentDrawingAppearance {
                expected = WorkbenchPalette.nativeAccent.usingColorSpace(.deviceRGB)
            }
            let busy = ToolbarLiveState(mode: .draw, drawing: true)
            let view = NSHostingView(rootView: ToolbarRow(
                state: ToolbarViewState(name: "busy-colour", tier: .revealed, mode: .draw, choices: ToolbarNextAction.choices(for: busy), isBusy: true),
                accent: WorkbenchPalette.accent)
                .environment(\.colorScheme, name == .darkAqua ? .dark : .light))
            view.appearance = appearance
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Only the launcher's 48 points: the next action's bezel is accent too.
            let launcherPixels = Int(ToolbarLayout.launcherWidth * CGFloat(bitmap.pixelsWide) / view.bounds.width)
            var upperMatches = 0, lowerMatches = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<launcherPixels {
                    guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let delta = abs(colour.redComponent - expected.redComponent)
                        + abs(colour.greenComponent - expected.greenComponent)
                        + abs(colour.blueComponent - expected.blueComponent)
                    if delta < 0.04 {
                        if y < bitmap.pixelsHigh * 3 / 4 { upperMatches += 1 }
                        else { lowerMatches += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(upperMatches, 0, "the launcher must render the brand accent in \(name)")
            XCTAssertGreaterThan(lowerMatches, 0, "the aggregate dot must render the same accent in \(name)")
        }
    }

    func testBrandPaletteResolvesTheSpecifiedLightAndDarkColours() throws {
        let cases: [(NSAppearance.Name, CGFloat, CGFloat, CGFloat)] = [
            (.aqua, 0.04, 0.43, 0.32), (.darkAqua, 0.43, 0.89, 0.73)
        ]
        for (name, red, green, blue) in cases {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var colour: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                colour = WorkbenchPalette.nativeAccent.usingColorSpace(.sRGB)
            }
            let resolved = try XCTUnwrap(colour)
            XCTAssertEqual(resolved.redComponent, red, accuracy: 0.001, name.rawValue)
            XCTAssertEqual(resolved.greenComponent, green, accuracy: 0.001, name.rawValue)
            XCTAssertEqual(resolved.blueComponent, blue, accuracy: 0.001, name.rawValue)
        }
    }

    /// The chooser is 280 points wide with 36-point rows, the seven tools in order, and it scrolls
    /// only when its display leaves it less than its height.
    @MainActor func testTheChooserMeasures() {
        _ = NSApplication.shared
        let choices = ToolbarNextAction.choices(for: ToolbarLiveState(mode: .dictate))
        for scale in [CGFloat(1), 1.35] {
            let size = NSHostingView(rootView: ToolbarChooserView(model: ToolbarChooserModel(choices: choices), textScale: scale)).fittingSize
            XCTAssertEqual(size.width, ToolbarChooserLayout.width * scale, accuracy: 0.5, "at \(scale)")
            // Rows of 48.6 points at larger text land on whole pixels.
            XCTAssertEqual(size.height, ToolbarChooserLayout.height(rows: 7, scale: scale), accuracy: 1, "at \(scale)")
        }
        let short = NSHostingView(rootView: ToolbarChooserView(model: ToolbarChooserModel(choices: choices), available: 150)).fittingSize
        XCTAssertEqual(short.height, 150, accuracy: 0.5, "a short display scrolls the list rather than clipping it")
    }

    /// The chooser's keys: Down, Return by identity, Escape without a change, typed names.
    @MainActor func testTheChooserKeys() {
        var chosen: [ToolbarMode] = [], dismissed = 0
        let model = ToolbarChooserModel(choices: ToolbarNextAction.choices(for: ToolbarLiveState(mode: .dictate)),
                                        choose: { chosen.append($0) }, dismiss: { dismissed += 1 })
        XCTAssertTrue(model.handle(keyCode: 125, characters: nil, time: 0))
        XCTAssertEqual(model.state.highlighted, .read)
        XCTAssertTrue(model.handle(keyCode: 53, characters: nil, time: 0))
        XCTAssertEqual(dismissed, 1); XCTAssertTrue(chosen.isEmpty, "Escape changes nothing")
        XCTAssertTrue(model.handle(keyCode: 35, characters: "p", time: 1))
        XCTAssertEqual(model.state.highlighted, .present)
        XCTAssertTrue(model.handle(keyCode: 36, characters: "\r", time: 1.1))
        XCTAssertEqual(chosen, [.present])
        XCTAssertFalse(model.handle(keyCode: 48, characters: "\t", time: 2), "Tab is not the chooser's")
    }
}
