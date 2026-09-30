import AppKit
import SwiftUI
import XCTest
import ToolbarCore
@testable import ToolbarKit

/// Keyboard entry's traversal of the revealed row (#223). Window › Focus floating toolbar gives the
/// launcher the keyboard; Tab and Shift-Tab then move through the next action, the accessory and
/// More in one logical cycle at every dock, skipping a control that is absent or disabled, whatever
/// Full Keyboard Access says. Each key goes through the window's own event dispatch
/// (`NSWindow.sendEvent`) to whatever is first responder, never to a chosen button's handler, and
/// the test reads `firstResponder` after each key. The windows are never ordered front or made key.
final class ToolbarKeyboardTraversalTests: XCTestCase {
    /// Counts every time AppKit's key-view loop is asked for the next or previous view. That loop
    /// is where Full Keyboard Access decides which views are eligible (`canBecomeKeyView`).
    private final class RecordingWindow: NSWindow {
        var keyViewSelections = 0
        override func selectNextKeyView(_ sender: Any?) { keyViewSelections += 1; super.selectNextKeyView(sender) }
        override func selectPreviousKeyView(_ sender: Any?) { keyViewSelections += 1; super.selectPreviousKeyView(sender) }
        override func selectKeyView(following view: NSView) { keyViewSelections += 1; super.selectKeyView(following: view) }
        override func selectKeyView(preceding view: NSView) { keyViewSelections += 1; super.selectKeyView(preceding: view) }
    }
    private struct Host {
        let window: RecordingWindow
        let view: NSView
        @MainActor func control(_ id: String) -> NSButton? { Self.buttons(view).first { $0.accessibilityIdentifier() == "toolbar." + id } }
        @MainActor static func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        /// The first responder's name: launcher, primary, accessory or more, or what else holds it.
        @MainActor var focused: String {
            guard let view = window.firstResponder as? NSView else { return String(describing: window.firstResponder.map { type(of: $0) }) }
            let id = view.accessibilityIdentifier()
            return id.hasPrefix("toolbar.") ? String(id.dropFirst("toolbar.".count)) : String(describing: type(of: view))
        }
        /// One key press, down and up, through the window's event dispatch.
        @MainActor func press(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, characters: characters,
                                                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
            }
        }
        @MainActor func tab() { press(48, "\t") }
        @MainActor func shiftTab() { press(48, "\u{19}", .shift) }
        @MainActor func close() { window.contentView = nil; window.close() }
    }

    /// The row in a window that is never ordered front, with the launcher first responder, as
    /// Focus floating toolbar leaves it.
    @MainActor private func host(_ row: ToolbarRow) throws -> Host {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: row)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = RecordingWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let host = Host(window: window, view: view)
        let launcher = try XCTUnwrap(host.control("launcher"), "the row has a launcher")
        XCTAssertTrue(window.makeFirstResponder(launcher), "the launcher takes the keyboard, as Focus floating toolbar gives it")
        XCTAssertEqual(host.focused, "launcher")
        return host
    }

    /// Where the focus goes for `count` presses of Tab from the launcher, then for `count` presses
    /// of Shift-Tab from the launcher again.
    @MainActor private func cycle(_ state: ToolbarViewState, count: Int) throws -> (forward: [String], backward: [String]) {
        let host = try host(ToolbarRow(state: state))
        defer { host.close() }
        var forward: [String] = []
        for _ in 0..<count { host.tab(); forward.append(host.focused) }
        let launcher = try XCTUnwrap(host.control("launcher"))
        XCTAssertTrue(host.window.makeFirstResponder(launcher))
        var backward: [String] = []
        for _ in 0..<count { host.shiftTab(); backward.append(host.focused) }
        // The row moves the focus itself, so AppKit's loop, and Full Keyboard Access with it, is
        // never asked.
        XCTAssertEqual(host.window.keyViewSelections, 0, "Tab and Shift-Tab never reach AppKit's key-view loop "
                       + "(Full Keyboard Access \(NSApp.isFullKeyboardAccessEnabled ? "on" : "off"), launcher canBecomeKeyView "
                       + "\(host.control("launcher")?.canBecomeKeyView == true))")
        return (forward, backward)
    }

    private func draw(_ anchor: ToolbarAnchor = .bottom, enabled: Bool = true) -> ToolbarViewState {
        ToolbarViewState(name: "draw", tier: .revealed, anchor: anchor, mode: .draw, isActionEnabled: enabled, accessory: .tools)
    }

    /// Draw's row: the launcher, the next action, Tools and More, and round again.
    @MainActor func testTabCyclesARowWithTools() throws {
        let (forward, backward) = try cycle(draw(), count: 4)
        XCTAssertEqual(forward, ["primary", "accessory", "more", "launcher"], "Tab from the launcher")
        XCTAssertEqual(backward, ["more", "accessory", "primary", "launcher"], "Shift-Tab from the launcher")
    }

    /// Read has no accessory: Tab goes from the next action straight to More.
    @MainActor func testTabCyclesARowWithoutAnAccessory() throws {
        let (forward, backward) = try cycle(ToolbarViewState(name: "read", tier: .revealed, mode: .read), count: 3)
        XCTAssertEqual(forward, ["primary", "more", "launcher"])
        XCTAssertEqual(backward, ["more", "primary", "launcher"])
    }

    /// An accessory that waits in More is not in the row, so it is not in the cycle either.
    @MainActor func testAnAccessoryWaitingInMoreIsSkipped() throws {
        var state = draw(); state.showsAccessory = false
        let (forward, backward) = try cycle(state, count: 3)
        XCTAssertEqual(forward, ["primary", "more", "launcher"])
        XCTAssertEqual(backward, ["more", "primary", "launcher"])
    }

    /// A disabled next action is passed over both ways.
    @MainActor func testTabSkipsADisabledPrimary() throws {
        let (forward, backward) = try cycle(draw(enabled: false), count: 3)
        XCTAssertEqual(forward, ["accessory", "more", "launcher"])
        XCTAssertEqual(backward, ["more", "accessory", "launcher"])
    }

    /// A right-hand dock mirrors the row on screen, More first and the launcher last, but the
    /// keyboard keeps the launcher, next action, accessory, More order.
    @MainActor func testAMirroredRowKeepsTheLogicalOrder() throws {
        for anchor in ToolbarAnchor.allCases where anchor.growsLeftward && !anchor.isVertical {
            let host = try host(ToolbarRow(state: draw(anchor)))
            let onScreen = Host.buttons(host.view).filter { $0.accessibilityIdentifier().hasPrefix("toolbar.") }
                .sorted { $0.convert($0.bounds, to: host.view).minX < $1.convert($1.bounds, to: host.view).minX }
                .map { $0.accessibilityIdentifier() }
            host.close()
            XCTAssertEqual(onScreen, ["toolbar.more", "toolbar.accessory", "toolbar.primary", "toolbar.launcher"], "\(anchor) mirrors")
            let (forward, backward) = try cycle(draw(anchor), count: 4)
            XCTAssertEqual(forward, ["primary", "accessory", "more", "launcher"], "\(anchor)")
            XCTAssertEqual(backward, ["more", "accessory", "primary", "launcher"], "\(anchor)")
        }
    }

    /// Reached by Tab, the accessory opens once for each of Return, keypad Enter, Space and Down,
    /// keeps the focus, and Escape leaves keyboard interaction without opening anything.
    @MainActor func testTheAccessoryReachedByTabOpensOnceForEachKey() throws {
        var admissions = 0, escapes = 0
        let host = try host(ToolbarRow(state: draw(), menuBegan: { _ in admissions += 1; return false }, escape: { escapes += 1 }))
        defer { host.close() }
        host.tab(); host.tab()
        XCTAssertEqual(host.focused, "accessory", "two Tabs from the launcher reach Tools")
        let down = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
        for (name, code, characters, flags) in [("Return", UInt16(36), "\r", NSEvent.ModifierFlags()), ("Enter", 76, "\u{3}", .numericPad),
                                               ("Space", 49, " ", []), ("Down", 125, down, [.numericPad, .function])] {
            let before = admissions
            host.press(code, characters, flags)
            XCTAssertEqual(admissions, before + 1, "\(name) asks to open Tools once")
            XCTAssertEqual(host.focused, "accessory", "and the focus stays on it after \(name)")
        }
        host.press(53, "\u{1b}")
        XCTAssertEqual(escapes, 1, "Escape leaves keyboard interaction")
        XCTAssertEqual(admissions, 4, "and opens nothing")
    }

    /// With Full Keyboard Access off, AppKit counts none of the row's buttons as a key view
    /// (`canBecomeKeyView` is false for each, whatever `acceptsFirstResponder` says), which is why
    /// Tab never left the launcher. The cycle reaches all four anyway. Forcing the setting for this
    /// process through the argument domain does not change what AppKit reports, so the check
    /// instead proves that the cycle never asks AppKit's loop (above, in every traversal).
    @MainActor func testTheCycleWorksWhereAppKitCountsNoButtonAsAKeyView() throws {
        let host = try host(ToolbarRow(state: draw()))
        defer { host.close() }
        let controls = ["launcher", "primary", "accessory", "more"].compactMap { host.control($0) }
        XCTAssertEqual(controls.count, 4)
        guard !NSApp.isFullKeyboardAccessEnabled else { return }
        XCTAssertTrue(controls.allSatisfy { $0.acceptsFirstResponder && !$0.canBecomeKeyView },
                      "with Full Keyboard Access off, each control takes the focus but is no key view")
        var visited: [String] = []
        for _ in controls { host.tab(); visited.append(host.focused) }
        XCTAssertEqual(visited, ["primary", "accessory", "more", "launcher"], "and Tab still visits every one")
    }
}
