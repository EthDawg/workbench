import AppKit
import QuartzCore
import SwiftUI
import StageKit
import XCTest
import ToolbarCore
import VoiceAppearance
@testable import ToolbarKit

final class ToolbarInteractionTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// Optional native render evidence, containing only this file's synthetic fixtures.
    @MainActor private func record(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TOOLBAR_REVIEW_OUTPUT"] else { return }
        let target = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: target.appendingPathComponent(name + ".png"))
    }

    @MainActor private func host<V: View>(_ root: V) -> (NSPanel, NSHostingView<V>) {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -19900, y: -19900), size: view.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = view
        panel.orderFrontRegardless(); view.layoutSubtreeIfNeeded()
        return (panel, view)
    }

    @MainActor func testEveryCommandAndAccessoryHasARealSymbolAndKeepsItsWords() throws {
        for state in ToolbarGallery.states where state.tier == .revealed {
            XCTAssertNotNil(NSImage(systemSymbolName: state.actionSymbol, accessibilityDescription: nil), state.name)
            let (panel, view) = host(ToolbarRow(state: state))
            defer { panel.close() }
            let commands = state.captureChoices.isEmpty
                ? [("toolbar.primary", state.actionTitle, state.actionHelp)]
                : state.captureChoices.map { ("toolbar.capture." + $0.rawValue, $0.title, state.captureHelp($0)) }
            for (identifier, title, help) in commands {
                let primary = try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier() == identifier } as? ToolbarIconButton)
                XCTAssertEqual(primary.title, "")
                XCTAssertNotNil(primary.image, state.name)
                XCTAssertEqual(primary.accessibilityLabel(), title)
                XCTAssertEqual(primary.hint, help)
                XCTAssertEqual(primary.isEnabled, state.isActionEnabled)
                XCTAssertFalse(primary.needsPanelToBecomeKey, "pointer use preserves the destination field")
            }
        }
        for accessory in ToolbarAccessory.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: accessory.symbol, accessibilityDescription: nil), accessory.title)
        }
    }

    @MainActor func testCaptureSourcesDispatchTheirOwnChoiceAndJoinTheKeyboardCycle() throws {
        for anchor in [ToolbarAnchor.left, .right] {
            var selected: [ToolbarCaptureKind] = []
            let state = ToolbarViewState(name: "capture", tier: .revealed, anchor: anchor, mode: .snapAndTalk,
                accessory: .review, captureChoices: ToolbarCaptureKind.allCases)
            let (panel, view) = host(ToolbarRow(state: state, pressCapture: { kind in { selected.append(kind) } }))
            defer { panel.close() }
            let controls = descendants(view).compactMap { $0 as? NSButton }
            XCTAssertNil(controls.first { $0.accessibilityIdentifier() == "toolbar.primary" }, "no duplicate generic capture")
            let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            let ids = ["toolbar.launcher"] + ToolbarCaptureKind.allCases.map { "toolbar.capture." + $0.rawValue } + ["toolbar.accessory"]
            for (index, identifier) in ids.enumerated() {
                let button = try XCTUnwrap(controls.first { $0.accessibilityIdentifier() == identifier })
                XCTAssertTrue(panel.makeFirstResponder(button))
                button.keyDown(with: tab)
                XCTAssertEqual((panel.firstResponder as? NSButton)?.accessibilityIdentifier(), ids[(index + 1) % ids.count])
            }
            for kind in ToolbarCaptureKind.allCases {
                let button = try XCTUnwrap(controls.first { $0.accessibilityIdentifier() == "toolbar.capture." + kind.rawValue })
                button.performClick(nil)
            }
            XCTAssertEqual(selected, [.region, .window, .screen])
            try record(view, name: "capture-sources-" + anchor.rawValue)
        }
    }

    /// A popup tracks the original press. The row holds it before tracking starts, and the
    /// selected work begins only once tracking has returned and that hold has been released.
    @MainActor func testMoreHandsTheOriginalPressToMenuTrackingAndReleasesItsHold() throws {
        final class Menu: NSMenu {
            var track: (() -> Void)?
            override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
                track?(); return true
            }
        }
        let defaults = UserDefaults(suiteName: FileManager.default.temporaryDirectory.appendingPathComponent("toolbar-menu-test-\(UUID().uuidString)").path)!
        let session = ToolbarSession(defaults: defaults)
        session.activate(); session.send(.pointerEntered)
        let menu = Menu(title: "Options")
        var events: [String] = []
        menu.track = {
            XCTAssertTrue(session.state.holds.contains(.menu))
            XCTAssertNotNil(NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: false),
                "the button must not consume the press's mouse-up before the menu can track it")
            events.append("tracking")
            session.afterMenuTracking { events.append("action") }
            XCTAssertEqual(events, ["tracking"], "the action waits for tracking to return")
        }
        let (panel, view) = host(ToolbarRow(state: .init(name: "menu", tier: .revealed, mode: .present, quickControl: .presentationView), makeViewMenu: { menu },
            menuBegan: session.beginMenu, menuEnded: { events.append("ended"); session.endMenu(pointerInside: false) }))
        defer { panel.close(); session.suspend() }
        let more = try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier() == "toolbar.view" } as? NSButton)
        let point = more.convert(NSPoint(x: more.bounds.midX, y: more.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, window: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp, window: 0), atStart: false)
        panel.sendEvent(event(.leftMouseDown, window: panel.windowNumber))
        while NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true) != nil {}
        XCTAssertEqual(events, ["tracking", "ended", "action"])
        XCTAssertFalse(session.state.holds.contains(.menu))
        XCTAssertTrue(session.state.graceRunning, "the toolbar can collapse after dismissing outside")
    }

    func testGlyphsWaitForTheLastExpansionFrames() {
        for progress in [CGFloat(0), 0.3, 0.6, 0.8] { XCTAssertEqual(ToolbarRevealVisuals.glyphOpacity(progress: progress), 0) }
        XCTAssertEqual(ToolbarRevealVisuals.glyphOpacity(progress: 0.9), 0.5, accuracy: 0.001)
        XCTAssertEqual(ToolbarRevealVisuals.glyphOpacity(progress: 1), 1, accuracy: 0.001)
    }

    @MainActor func testHintStaysOnTheDisplayAboveOrBelowItsTarget() {
        let screen = NSRect(x: -1000, y: 25, width: 1440, height: 875)
        for x in [screen.minX, screen.midX, screen.maxX - 36] {
            for y in [screen.minY, screen.midY, screen.maxY - 32] {
                let target = NSRect(x: x, y: y, width: 36, height: 32)
                let frame = ToolbarHintController.frame(size: NSSize(width: 180, height: 32), target: target, visible: screen)
                XCTAssertTrue(screen.contains(frame)); XCTAssertFalse(frame.intersects(target))
                if y == screen.maxY - 32 { XCTAssertLessThan(frame.maxY, target.minY) }
                else { XCTAssertGreaterThan(frame.minY, target.maxY) }
            }
        }
    }

    @MainActor func testHintNeverTakesClicksKeyboardOrAccessibilityFocus() {
        let panel = ToolbarHintController.makePanel(frame: NSRect(x: -19900, y: -19900, width: 120, height: 32))
        defer { panel.close() }
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isAccessibilityElement())
        XCTAssertFalse(panel.isVisible, "constructing a hint does not show or focus a window")
    }

    @MainActor func testHintCrossesAdjacentTargetsWithoutALateExitHidingTheNewTarget() {
        var scheduled: [(TimeInterval, DispatchWorkItem)] = []
        let hints = ToolbarHintController { scheduled.append(($0, $1)) }
        let first = ToolbarIconButton(frame: .zero), next = ToolbarIconButton(frame: .zero)
        first.hints = hints; first.hint = "Dictate · ⌥D"
        next.hints = hints; next.hint = "More"
        first.setHovered(true)
        first.setHovered(false)
        XCTAssertTrue(hints.source === first, "the visible hint survives the gap between targets")
        XCTAssertEqual(scheduled.last?.0, ToolbarHintController.handoffGrace)
        let oldHide = scheduled.last!.1
        next.setHovered(true)
        oldHide.perform()
        hints.leave(from: first)
        XCTAssertTrue(hints.source === next, "an old exit cannot dismiss the next action's hint")
        next.setHovered(false)
        scheduled.last!.1.perform()
        XCTAssertNil(hints.source, "leaving the row hides the hint after the bounded grace")
        next.setHovered(true)
        next.dismissHint()
        for (_, task) in scheduled { task.perform() }
        XCTAssertNil(hints.source, "actions cancel every pending hint immediately")
        XCTAssertNil(hints.panel, "late work cannot create a hint after dismissal")
    }

    @MainActor func testHintKeepsTheFullActionAndShortcutAtLargerType() throws {
        for scale in [CGFloat(1), 1.35] {
            let hint = ToolbarHintLabel(text: "Capture next · 12 · ⌥C", size: 11 * scale)
            let (panel, view) = host(hint)
            defer { panel.close() }
            XCTAssertLessThanOrEqual(view.fittingSize.width, 324)
            XCTAssertGreaterThanOrEqual(view.fittingSize.height, 28)
            try record(view, name: scale == 1 ? "hint" : "hint-large")
        }
    }

    @MainActor func testHintsKeepOneRailForShortAndLongTextAtEveryEdge() {
        let screen = NSRect(x: -1440, y: -200, width: 1440, height: 900)
        for anchor in ToolbarAnchor.allCases {
            let target = ToolbarGeometry.frame(size: NSSize(width: 252, height: 40), position: .docked(anchor), screen: screen)
            let short = ToolbarHintController.frame(size: NSSize(width: 72, height: 29), target: target, visible: screen)
            let long = ToolbarHintController.frame(size: NSSize(width: 324, height: 65), target: target, visible: screen)
            XCTAssertEqual(short.midX, long.midX)
            XCTAssertEqual(short.minY > target.maxY, long.minY > target.maxY)
            if short.minY > target.maxY { XCTAssertEqual(short.minY, long.minY) }
            else { XCTAssertEqual(short.maxY, long.maxY) }
            XCTAssertTrue(screen.contains(short)); XCTAssertTrue(screen.contains(long))
        }
    }

    @MainActor func testHintsCannotAppearWhileControlsAreMoving() {
        var scheduled: [DispatchWorkItem] = []
        let hints = ToolbarHintController { _, work in scheduled.append(work) }
        let button = ToolbarIconButton(frame: .zero)
        button.hint = "Region · Select a region"; button.hints = hints
        button.setHovered(true)
        hints.isReady = false
        scheduled.forEach { $0.perform() }
        XCTAssertNil(hints.source); XCTAssertNil(hints.panel)
        button.setHovered(true)
        XCTAssertNil(hints.source)
    }

    @MainActor func testCollapsedTargetHasNoVisibleHazeOutsideItsCapsule() throws {
        for anchor in ToolbarAnchor.allCases {
            let state = ToolbarViewState(name: "clear-rest", tier: .resting, anchor: anchor)
            let view = NSHostingView(rootView: ToolbarRow(state: state))
            view.frame = NSRect(origin: .zero, size: ToolbarLayout.mark(for: anchor)); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            var outsideAlpha: CGFloat = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where abs((CGFloat(anchor.isVertical ? x : y) + 0.5) / scale - 14) > 5 {
                    outsideAlpha = max(outsideAlpha, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                }
            }
            XCTAssertLessThanOrEqual(outsideAlpha, 1.0 / 255, "\(anchor): the clear target leaked paint around the 8-point capsule")
            let target = try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier() == "toolbar.rest" })
            XCTAssertEqual(target.bounds.size, ToolbarLayout.mark(for: anchor))
        }
    }

    /// WindowServer decides routing before NSView.hitTest. An on-screen query is needed
    /// to prove that the almost clear padding still belongs to the native window.
    @MainActor func testCollapsedPaddingReceivesNativeWindowHits() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOOLBAR_WINDOW_HIT_TESTS"] == "1",
                          "Run explicitly: briefly shows a synthetic nonactivating toolbar; sends no input.")
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        defer { app.setActivationPolicy(policy) }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let (panel, view) = host(ToolbarRow(state: .init(name: "native-hit", tier: .resting)))
        defer { panel.close() }
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.setFrameOrigin(NSPoint(x: screen.minX + 80, y: screen.maxY - 100))
        panel.orderFrontRegardless(); view.layoutSubtreeIfNeeded(); panel.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        for x in [CGFloat(1), 24, 47] {
            for y in [CGFloat(1), 5, 14, 23, 27] {
                let point = panel.convertPoint(toScreen: CGPoint(x: x, y: y))
                XCTAssertEqual(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0), panel.windowNumber,
                               "the full 48 × 28 target must receive the hit, including padding at \(x), \(y)")
            }
        }
        XCTAssertFalse(panel.isKeyWindow); XCTAssertFalse(panel.isMainWindow)
    }

    @MainActor func testCaptureButtonsWaitUntilTheWholeRowIsOpen() throws {
        for anchor in [ToolbarAnchor.bottom, .left, .right] {
            let state = ToolbarViewState(name: "opening", tier: .revealed, anchor: anchor, mode: .snapAndTalk,
                accessory: .review, captureChoices: ToolbarCaptureKind.allCases)
            let full = NSHostingView(rootView: ToolbarRow(state: state)).fittingSize
            for (size, ready) in [(ToolbarLayout.mark(for: anchor), false), (ToolbarLayout.oriented(NSSize(width: 130, height: 36), for: anchor), false), (full, true)] {
                var captures = 0, popups = 0
                let row = ToolbarRow(state: state, openAccessory: { _ in popups += 1 },
                    pressCapture: { _ in { captures += 1 } }, openChooser: { _ in popups += 1 },
                    makeMenu: { popups += 1; return NSMenu() }, menuBegan: { _ in false }).pinnedToDock(anchor)
                let view = NSHostingView(rootView: row)
                let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -19900, y: -19900), size: size),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.contentView = view
                defer { panel.close() }
                view.frame = NSRect(origin: .zero, size: size); panel.orderFrontRegardless(); view.layoutSubtreeIfNeeded()
                let commands = descendants(view).compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier().hasPrefix("toolbar.capture.") }
                XCTAssertEqual(commands.count, 3)
                for command in commands {
                    XCTAssertEqual(command.isEnabled, ready, "\(anchor), \(size)")
                    command.performClick(nil)
                }
                XCTAssertEqual(captures, ready ? 3 : 0, "invisible controls cannot start a capture")
                let returnKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                for control in descendants(view).compactMap({ $0 as? NSButton }) where ["toolbar.launcher", "toolbar.accessory"].contains(control.accessibilityIdentifier()) {
                    XCTAssertEqual(control.isEnabled, ready)
                    control.performClick(nil); control.keyDown(with: returnKey)
                }
                XCTAssertEqual(popups > 0, ready, "keyboard and accessibility cannot open controls from moving geometry")
            }
        }
    }

    @MainActor func testMouseUpContributesTheFinalDragPosition() {
        _ = NSApplication.shared
        let button = LauncherButton(frame: NSRect(x: 0, y: 0, width: 48, height: 40))
        let panel = NSPanel(contentRect: NSRect(x: -19900, y: -19900, width: 48, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = button; panel.orderFrontRegardless()
        defer { panel.close() }
        let origin = panel.frame.origin
        var ended: NSPoint?, moved = 0, opened = 0
        button.open = { opened += 1 }
        button.drag = .init(move: { moved += 1 }, end: { ended = panel.frame.origin })
        func event(_ type: NSEvent.EventType, point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: type == .leftMouseUp ? 0 : panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Keep queued coordinates local, as the native click helper does. AppKit can
        // remap a posted event carrying a window number through screen coordinates.
        // The directly delivered mouse-down still identifies its actual window.
        NSApp.postEvent(event(.leftMouseUp, point: NSPoint(x: 34, y: 15)), atStart: true)
        button.mouseDown(with: event(.leftMouseDown, point: NSPoint(x: 24, y: 20)))
        XCTAssertEqual(ended?.x, origin.x + 10)
        // Allow one point for native event coordinate rounding on the vertical axis.
        XCTAssertEqual(ended?.y ?? .infinity, origin.y - 5, accuracy: 1)
        XCTAssertEqual(moved, 1); XCTAssertEqual(opened, 0)
    }

    @MainActor func testHoverOnlyChangesTheButtonsBackground() throws {
        let (panel, host) = host(ToolbarRow(state: .init(name: "hover", tier: .revealed)))
        defer { panel.close() }
        let button = try XCTUnwrap(descendants(host).first { $0.accessibilityIdentifier() == "toolbar.primary" } as? ToolbarIconButton)
        button.hints = nil
        let frame = button.frame
        func image() throws -> Data {
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let resting = try image()
        try record(host, name: "row-before-hover")
        button.setHovered(true)
        XCTAssertEqual(button.frame, frame)
        XCTAssertNotEqual(try image(), resting, "the hovered target has its own grey background")
        try record(host, name: "row-hover")
        button.setHovered(false)
        XCTAssertEqual(try image(), resting)
    }

    /// The recorder's samples reach the native trace in both tiers. Check both native drawing
    /// modes explicitly: SwiftUI's read-only accessibility environment otherwise inherits the
    /// CI machine's settings. Reduce Motion holds its shape while opacity follows the samples.
    @MainActor func testRecordingSamplesReachTheHostedTraceInBothTiers() throws {
        for tier in ToolbarTier.allCases {
            for reduceMotion in [false, true] {
                var state = ToolbarViewState(name: "meter", tier: tier, actionTitle: "Stop", actionSymbol: "stop.fill",
                    status: .resolve(ToolbarActivity(capture: .dictation, level: 0)))
                let (panel, view) = host(ToolbarRow(state: state, accent: WorkbenchPalette.accent))
                defer { panel.close() }
                let trace = try XCTUnwrap(descendants(view).compactMap { $0 as? VoiceTraceView }.first)
                func setDrawingMode() {
                    trace.reduceMotion = reduceMotion
                    trace.increaseContrast = false
                }
                setDrawingMode()
                XCTAssertEqual(trace.amplitude, reduceMotion ? 1.5 : 0)
                XCTAssertEqual(trace.stroke.opacity, 0.45, accuracy: 0.001)
                state.status = .resolve(ToolbarActivity(capture: .dictation, level: 0.8))
                view.rootView = ToolbarRow(state: state, accent: WorkbenchPalette.accent); view.layoutSubtreeIfNeeded()
                setDrawingMode()
                trace.advance(to: CACurrentMediaTime() + 0.1)
                XCTAssertGreaterThan(trace.stroke.opacity, 0.8, "the real sample visibly brightens the trace in \(tier)")
                if reduceMotion {
                    XCTAssertEqual(trace.amplitude, 1.5, "Reduce Motion keeps the shape still")
                    XCTAssertEqual(trace.lineWidth, 1.5, "Reduce Motion keeps its weight still")
                } else {
                    XCTAssertGreaterThan(trace.amplitude, 1, "the real sample reaches the native drawing in \(tier)")
                }
                try record(view, name: "recording-\(tier.rawValue)\(reduceMotion ? "-reduce-motion" : "")")
                XCTAssertNil(trace.hitTest(.zero), "the recording trace never takes the launcher's clicks")
                state.status = .resolve(ToolbarActivity(capture: .dictation, level: 0))
                view.rootView = ToolbarRow(state: state, accent: WorkbenchPalette.accent); view.layoutSubtreeIfNeeded()
                setDrawingMode()
                let start = CACurrentMediaTime()
                for tick in 1...12 { trace.advance(to: start + Double(tick) * 0.1) }
                XCTAssertEqual(trace.stroke.opacity, 0.45, accuracy: 0.01, "silence returns the trace to its quiet brightness")
                if reduceMotion {
                    XCTAssertEqual(trace.amplitude, 1.5)
                } else {
                    XCTAssertLessThan(trace.amplitude, 0.1, "silence becomes still without an invented wiggle")
                }
            }
        }
    }
}
