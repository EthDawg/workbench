import AppKit

/// Native menus carry a snapshot of choices, while actions return to the live
/// owner. A menu never becomes a second presentation or persona state store.
final class StageMenuAction: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self; state = checked ? .on : .off; isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { if isEnabled { run() } }
}

extension NSMenu {
    func addSubmenu(_ title: String, items: [NSMenuItem]) {
        let child = NSMenu(title: title); child.autoenablesItems = false
        items.forEach { child.addItem($0) }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = child; addItem(parent)
    }
}

/// The same absolute 6–40% width contract used by the persona sizing controls.
/// Dragging stays in the current menu, so a presenter can make a small adjustment.
final class PersonaSizeMenuView: NSView {
    private let slider: NSSlider
    private let label = NSTextField(labelWithString: "")
    private let change: (Double) -> Void
    init(width: Double, enabled: Bool = true, change: @escaping (Double) -> Void) {
        self.change = change
        slider = NSSlider(value: width, minValue: 0.06, maxValue: 0.40, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 258, height: 38))
        label.frame = NSRect(x: 16, y: 10, width: 72, height: 18)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        slider.frame = NSRect(x: 88, y: 7, width: 150, height: 24)
        slider.target = self; slider.action = #selector(changed); slider.isContinuous = true
        slider.isEnabled = enabled; slider.setAccessibilityLabel("Persona Size")
        slider.setAccessibilityIdentifier("persona.shared.size")
        addSubview(label); addSubview(slider); updateLabel()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { updateLabel(); change(slider.doubleValue) }
    private func updateLabel() { label.stringValue = "Size \(Int((slider.doubleValue * 100).rounded()))%" }
}

/// All ink entry points use macOS's shared picker and the same SettingsStore.
/// The AppCoordinator retains this receiver for the colour panel's lifetime.
final class InkColourPicker: NSObject {
    private weak var app: AppCoordinator?
    init(app: AppCoordinator) { self.app = app }
    func show() {
        guard let app, app.canUseAnnotationMenuAction(.color1) else { return }
        let panel = NSColorPanel.shared
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        panel.showsAlpha = false; panel.color = app.settings.value.color.nsColor
        panel.setTarget(self); panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true; panel.orderFront(nil)
    }
    @objc private func changed(_ sender: NSColorPanel) {
        guard let app, app.canUseAnnotationMenuAction(.color1) else { return }
        app.settings.value.color = InkColor(sender.color)
    }
}
