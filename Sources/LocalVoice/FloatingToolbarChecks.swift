import AppKit
import StageKit

@MainActor
enum FloatingToolbarChecks {
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("Floating toolbar: " + name) }
            count += 1
        }
        var state = FloatingToolbarInteraction()
        try check(state.disclosure == .collapsed, "first launch is a quiet indicator")
        state.enter()
        try check(state.disclosure == .hovered, "hover reveals actions")
        state.menuOpen = true; state.leave()
        try check(state.disclosure == .hovered && !state.canCollapse, "moving into the native menu retains actions")
        state.menuOpen = false; state.dragging = true
        try check(!state.canCollapse, "dragging outside the toolbar retains actions")
        state.dragging = false; state.pinned = true
        try check(state.disclosure == .expanded && !state.canCollapse, "explicit expansion stays open")
        state.enter(); state.collapse(); state.enter()
        try check(state.disclosure == .collapsed, "collapse does not immediately reopen under the pointer")
        state.leave(); state.enter()
        try check(state.disclosure == .hovered, "a fresh hover works after collapse")
        state.keyboardFocused = true; state.leave()
        try check(state.disclosure == .expanded && !state.canCollapse, "keyboard focus is independent of hover")
        state.suspend()
        try check(state.disclosure == .collapsed, "operation changes discard transient state")
        state.collapse(); state.enter()
        try check(state.disclosure == .hovered, "Escape outside the toolbar permits the next hover")

        let domain = "workbench.toolbar.checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let controls = CaptureHUDControls(defaults: defaults)
        var inside = false
        controls.pointerInside = { inside }
        inside = true; controls.hover(true)
        inside = false; controls.hover(false)
        try check(controls.toolbarDisclosure == .hovered, "exit grace period retains click targets")
        inside = true; controls.hover(true)
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(controls.toolbarDisclosure == .hovered, "rapid re-entry cancels delayed collapse")
        controls.beginMenu(NSMenu())
        inside = false; controls.hover(false)
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(controls.toolbarDisclosure == .hovered, "an open menu survives an extended pointer exit")
        controls.endMenu()
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(controls.toolbarDisclosure == .collapsed, "menu dismissal outside returns to resting")
        inside = true; controls.hover(true); controls.setDragging(true)
        inside = false; controls.hover(false)
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(controls.toolbarDisclosure == .hovered, "dragging locks the actual presentation size")
        controls.setDragging(false)
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(controls.toolbarDisclosure == .collapsed, "drag completion releases the idle reveal")
        controls.expandToolbar()
        try check(CaptureHUDControls(defaults: defaults).toolbarDisclosure == .expanded, "explicit expansion persists across relaunch")
        controls.collapseToolbar()
        try check(CaptureHUDControls(defaults: defaults).toolbarDisclosure == .collapsed, "explicit collapse persists across relaunch")
        controls.focusToolbar()
        try check(controls.toolbarDisclosure == .expanded && !CapturePanel().canBecomeKey,
                  "keyboard reveal does not make ordinary mouse panels focusable")
        inside = true; controls.hover(true); controls.unfocusToolbar()
        try check(controls.toolbarDisclosure == .hovered, "releasing keyboard focus restores a current hover")
        controls.suspendToolbar()
        try check(controls.toolbarDisclosure == .collapsed, "active capture cannot inherit keyboard expansion")
        controls.hover(true); controls.isExpanded = true; controls.collapseToolbar()
        try check(controls.isExpanded, "idle disclosure never mutates recording detail")

        let screen = NSRect(x: -1440, y: 30, width: 1440, height: 900)
        for anchor in FloatingControlAnchor.allCases {
            let rest = CaptureHUDGeometry.frame(size: FloatingToolbarDisclosure.collapsed.size, anchor: anchor,
                previous: nil, screens: [screen], preferred: screen)
            for disclosure in [FloatingToolbarDisclosure.hovered, .expanded] {
                let revealed = CaptureHUDGeometry.frame(size: disclosure.size, anchor: anchor,
                    previous: rest, screens: [screen], preferred: screen)
                let collapsed = CaptureHUDGeometry.frame(size: FloatingToolbarDisclosure.collapsed.size,
                    anchor: anchor, previous: revealed, screens: [screen], preferred: screen)
                try check(revealed.contains(rest) && collapsed == rest,
                          "reveal retains the hover target and anchor: " + anchor.title)
            }
        }
        var shortcut = VoiceShortcut(keyCode: 18)
        try check(FloatingToolbar.shortcutLabel(shortcut, failure: nil) == shortcut.label, "configured shortcut is shown")
        try check(FloatingToolbar.shortcutLabel(shortcut, failure: "In use") == "Shortcut unavailable", "failed binding is not advertised")
        shortcut.enabled = false
        try check(FloatingToolbar.shortcutLabel(shortcut, failure: nil) == "Shortcut off", "disabled binding is not advertised")
        print("FLOATING_TOOLBAR_CHECKS_OK: \(count) checks passed")
    }
}
