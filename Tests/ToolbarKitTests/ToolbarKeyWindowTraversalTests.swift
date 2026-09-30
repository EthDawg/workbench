import AppKit
import SwiftUI
import XCTest
import ToolbarCore
@testable import ToolbarKit

/// The one path the offscreen traversal checks cannot take (#223): a key, on-screen,
/// non-activating panel, as the production host is after Window › Focus floating toolbar, with
/// Tab and Shift-Tab routed by NSApplication itself (`NSApp.sendEvent`) to the key window's first
/// responder. It takes the keyboard from whatever app is in front, so it runs only when asked:
/// `TOOLBAR_KEY_WINDOW_TESTS=1 swift test --filter ToolbarKeyWindowTraversalTests`.
final class ToolbarKeyWindowTraversalTests: XCTestCase {
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    @MainActor func testTabCyclesTheRowInAKeyPanelThroughTheApplication() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOOLBAR_KEY_WINDOW_TESTS"] == "1",
                          "On-screen and key: run with TOOLBAR_KEY_WINDOW_TESTS=1 while nobody else needs the Mac.")
        let app = NSApplication.shared
        // A process without a bundle can take activation, and so a key window, only as a regular app.
        // Afterwards the policy it had comes back, and the activation events all this queued are
        // handled now: a pointer test's click tracking that met a stale "deactivated" would stop.
        let policy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        defer {
            app.deactivate(); app.setActivationPolicy(policy)
            while let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.3), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
        }
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        var runs: [String: [String]] = [:]
        for (name, state) in [("Draw with Tools", ToolbarViewState(name: "draw", tier: .revealed, mode: .draw, accessory: .tools)),
                              ("Read, no accessory", ToolbarViewState(name: "read", tier: .revealed, mode: .read)),
                              ("Draw at the right-hand dock", ToolbarViewState(name: "draw", tier: .revealed, anchor: .right, mode: .draw, accessory: .tools))] {
            let view = NSHostingView(rootView: ToolbarRow(state: state))
            let panel = KeyPanel(contentRect: NSRect(origin: NSPoint(x: 240, y: 240), size: view.fittingSize),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = view
            defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
            app.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            XCTAssertTrue(panel.isKeyWindow, "\(name): the panel is key, as Focus floating toolbar makes the host")
            let launcher = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
            XCTAssertTrue(panel.makeFirstResponder(launcher))
            func focused() -> String {
                guard let view = panel.firstResponder as? NSView else { return "\(String(describing: panel.firstResponder))" }
                return String(view.accessibilityIdentifier().dropFirst("toolbar.".count))
            }
            func tab(backward: Bool) {
                let characters = backward ? "\u{19}" : "\t"
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    app.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: backward ? .shift : [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                                                   characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 48)!)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            let count = state.accessory == nil ? 2 : 3
            var path: [String] = []
            for _ in 0..<count { tab(backward: false); path.append(focused()) }
            XCTAssertTrue(panel.makeFirstResponder(launcher))
            for _ in 0..<count { tab(backward: true); path.append(focused()) }
            runs[name] = path
        }
        XCTAssertEqual(runs["Draw with Tools"], ["primary", "accessory", "launcher", "accessory", "primary", "launcher"])
        XCTAssertEqual(runs["Read, no accessory"], ["primary", "launcher", "primary", "launcher"])
        XCTAssertEqual(runs["Draw at the right-hand dock"], ["primary", "accessory", "launcher", "accessory", "primary", "launcher"])
    }
}
