import AppKit
import SwiftUI

/// A named capability control, built from its current live owner when opened.
struct StageLiveMenu: NSViewRepresentable {
    let title: String
    let menu: () -> NSMenu
    func makeNSView(context: Context) -> MenuButton { MenuButton() }
    func updateNSView(_ button: MenuButton, context: Context) {
        button.title = title; button.setAccessibilityLabel(title); button.makeMenu = menu
    }
    final class MenuButton: NSButton {
        var makeMenu: (() -> NSMenu)?
        override init(frame: NSRect) {
            super.init(frame: frame); bezelStyle = .rounded; controlSize = .small
            target = self; action = #selector(open)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func open() {
            makeMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
        }
    }
}
