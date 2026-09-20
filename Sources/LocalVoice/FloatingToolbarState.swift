import AppKit
import SwiftUI

/// Idle disclosure is independent of recording detail and microphone ownership.
enum FloatingToolbarDisclosure: Equatable {
    case collapsed, hovered, expanded

    var size: NSSize {
        switch self {
        case .collapsed: return NSSize(width: 76, height: 28)
        case .hovered: return NSSize(width: 368, height: 60)
        case .expanded: return NSSize(width: 480, height: 116)
        }
    }
}

struct FloatingToolbarInteraction {
    var pinned = false
    var hovered = false
    var menuOpen = false
    var dragging = false
    var keyboardFocused = false
    // A collapse click must work even while the pointer remains over the pill.
    var suppressHoverUntilExit = false

    var disclosure: FloatingToolbarDisclosure {
        if pinned || keyboardFocused { return .expanded }
        return !suppressHoverUntilExit && (hovered || menuOpen || dragging) ? .hovered : .collapsed
    }
    var canCollapse: Bool { !pinned && !hovered && !menuOpen && !dragging && !keyboardFocused }

    mutating func enter() { hovered = true }
    mutating func leave() { hovered = false; suppressHoverUntilExit = false }
    mutating func collapse() { pinned = false; keyboardFocused = false; suppressHoverUntilExit = hovered }
    mutating func suspend() {
        hovered = false; menuOpen = false; dragging = false; keyboardFocused = false
        suppressHoverUntilExit = false
    }
}

/// Native menus stay alive while the pointer leaves their owning toolbar.
/// AppKit provides keyboard navigation, Escape and selected-item checkmarks.
struct FloatingToolbarMenu: NSViewRepresentable {
    let title: String
    let symbol: String
    let help: String
    let controls: CaptureHUDControls
    var enabled = true
    var focusOnReveal = false
    let makeMenu: () -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = ToolbarMenuButton(title: title, target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.onCancel = { controls.collapseToolbar() }
        button.bezelStyle = .recessed
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.toolTip = help
        button.isEnabled = enabled
        button.setAccessibilityLabel(help)
        if focusOnReveal {
            controls.focusFirstControl = { [weak button] in
                guard let button else { return }
                button.window?.makeFirstResponder(button)
            }
        }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: FloatingToolbarMenu
        init(_ parent: FloatingToolbarMenu) { self.parent = parent }
        @objc func open(_ sender: NSButton) {
            guard parent.enabled else { return }
            let menu = parent.makeMenu()
            parent.controls.beginMenu(menu)
            defer { parent.controls.endMenu() }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }
    }
}

final class ToolbarMenuButton: NSButton {
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 || event.keyCode == 49 { performClick(nil) }
        else { super.keyDown(with: event) }
    }
}

/// Each item retains its action for the duration of native menu tracking.
final class ToolbarMenuAction: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(performAction), keyEquivalent: "")
        target = self; state = checked ? .on : .off; isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func performAction() { run() }
}
