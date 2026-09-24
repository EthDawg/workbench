import AppKit
import Carbon

/// The native menu is a view of the coordinator, never another drawing owner.
final class AnnotationMenu: AnnotationShortcutMenu, NSMenuDelegate {
    private weak var coordinator: AppCoordinator?
    private let includeSettings: Bool

    init(coordinator: AppCoordinator, includeSettings: Bool = true) {
        self.coordinator = coordinator
        self.includeSettings = includeSettings
        super.init(title: "Annotate")
        autoenablesItems = false
        delegate = self
        refresh()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    func refresh() {
        removeAllItems()
        guard let app = coordinator else { return }

        addItem(command("Finish Drawing", id: "finish", enabled: app.isDrawing,
            help: "Return input to the presentation while keeping the current ink and board.") { [weak app] in
                app?.stopDrawing()
            })
        addItem(.separator())
        for tool in DrawingTool.allCases {
            guard let action = Action(rawValue: tool.rawValue) else { continue }
            let item = actionItem(action, checked: app.tool == tool)
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            addItem(item)
        }

        let colours = AnnotationShortcutMenu(title: "Ink Colour")
        colours.autoenablesItems = false
        for (index, color) in InkColor.presets.enumerated() {
            guard let action = Action(rawValue: "color\(index + 1)") else { continue }
            let item = actionItem(action, title: InkColor.presetName(at: index), checked: app.settings.value.color == color)
            item.image = colourSwatch(color)
            colours.addItem(item)
        }
        let black = command("Black", id: "black", enabled: app.canUseAnnotationMenuAction(.color1)) { [weak app] in
            guard let app, app.canUseAnnotationMenuAction(.color1) else { return }
            app.settings.value.color = .black
        }
        black.state = app.settings.value.color == .black ? .on : .off
        black.image = colourSwatch(.black)
        colours.addItem(black)
        if !InkColor.presets.contains(app.settings.value.color), app.settings.value.color != .black {
            let custom = NSMenuItem(title: "Custom \(app.settings.value.color.hex)", action: nil, keyEquivalent: "")
            custom.state = .on
            custom.image = colourSwatch(app.settings.value.color)
            custom.isEnabled = false
            colours.addItem(custom)
        }
        let colourItem = NSMenuItem(title: "Ink Colour", action: nil, keyEquivalent: "")
        colourItem.submenu = colours
        addItem(colourItem)
        addItem(command("Choose Colour…", id: "customColour", enabled: app.canUseAnnotationMenuAction(.color1)) { [weak app] in
            app?.inkColourPicker.show()
        })
        addItem(actionItem(.pointer, checked: app.pointerEnabled))
        addItem(actionItem(.fade, checked: app.settings.value.autoFade))

        addItem(.separator())
        let history = NSScreen.screens.isEmpty ? nil : app.history(for: app.currentID)
        addItem(actionItem(.undo, title: "Undo Annotation", available: history?.canUndo == true))
        addItem(actionItem(.redo, title: "Redo Annotation", available: history?.canRedo == true))
        addItem(actionItem(.clear))

        addItem(.separator())
        let board = NSScreen.screens.isEmpty ? nil : app.boards[app.currentID]
        addItem(actionItem(.whiteboard, checked: board == .white))
        addItem(actionItem(.blackboard, checked: board == .black))
        addItem(.separator())
        guard includeSettings else { return }
        addItem(command("Drawing Controls…", id: "controls", enabled: app.canUseAnnotationMenuAction(.controls)) { [weak app] in
            guard let app, app.canUseAnnotationMenuAction(.controls) else { return }
            app.stopDrawing()
            app.showControls(tab: "Drawing", preservingCanvas: true)
        })
        addItem(command("Keyboard Shortcuts…", id: "shortcuts", enabled: app.canUseAnnotationMenuAction(.controls)) { [weak app] in
            guard let app, app.canUseAnnotationMenuAction(.controls) else { return }
            app.stopDrawing()
            app.showControls(tab: "Shortcuts", preservingCanvas: true)
        })
    }

    private func actionItem(_ action: Action, title: String? = nil, checked: Bool = false, available: Bool = true) -> NSMenuItem {
        guard let app = coordinator else { return NSMenuItem() }
        let item = command(title ?? action.title, id: action.rawValue,
            enabled: available && app.canUseAnnotationMenuAction(action)) { [weak app] in
                guard let app, app.canUseAnnotationMenuAction(action) else { return }
                app.perform(action)
            }
        item.state = checked ? .on : .off
        let shortcut = app.settings.value.shortcut(for: action)
        if !shortcut.enabled {
            item.toolTip = "Shortcut off. Assign a key in Keyboard Shortcuts."
        } else if let failure = app.shortcutFailures[action] {
            item.title += " — Shortcut unavailable"
            item.toolTip = "\(shortcut.label): \(failure)"
        } else {
            item.keyEquivalent = Self.keyEquivalent(shortcut.keyCode)
            item.keyEquivalentModifierMask = Self.modifiers(shortcut.modifiers)
            item.toolTip = shortcut.label
            if action.tool != nil {
                item.toolTip = "Click to keep drawing; the shortcut uses \(app.settings.value.activation.rawValue.lowercased())."
            }
            if item.keyEquivalent.isEmpty { item.title += " · \(shortcut.label)" }
        }
        return item
    }

    private func command(_ title: String, id: String, enabled: Bool, help: String? = nil, perform: @escaping () -> Void) -> NSMenuItem {
        let item = AnnotationMenuCommand(title: title, perform: perform)
        item.identifier = NSUserInterfaceItemIdentifier("annotation.\(id)")
        item.isEnabled = enabled
        item.toolTip = help
        return item
    }

    private func colourSwatch(_ color: InkColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.nsColor.setFill()
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            circle.fill()
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return true
        }
    }

    private static func modifiers(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { result.insert(.command) }
        if carbon & UInt32(controlKey) != 0 { result.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { result.insert(.option) }
        if carbon & UInt32(shiftKey) != 0 { result.insert(.shift) }
        return result
    }

    private static func keyEquivalent(_ keyCode: UInt32) -> String {
        let special: [UInt32: Int] = [
            36: 13, 48: 9, 49: 32, 51: 8, 53: 27, 117: NSDeleteFunctionKey,
            123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
            125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
            122: NSF1FunctionKey, 120: NSF2FunctionKey, 99: NSF3FunctionKey,
            118: NSF4FunctionKey, 96: NSF5FunctionKey, 97: NSF6FunctionKey,
            98: NSF7FunctionKey, 100: NSF8FunctionKey, 101: NSF9FunctionKey,
            109: NSF10FunctionKey, 103: NSF11FunctionKey, 111: NSF12FunctionKey,
            105: NSF13FunctionKey, 107: NSF14FunctionKey, 113: NSF15FunctionKey,
            106: NSF16FunctionKey, 64: NSF17FunctionKey, 79: NSF18FunctionKey,
            80: NSF19FunctionKey, 90: NSF20FunctionKey
        ]
        if let value = special[keyCode], let scalar = UnicodeScalar(value) { return String(scalar) }
        let label = Shortcut.keyName(keyCode).lowercased()
        return label.count == 1 ? label : ""
    }
}

/// Show the existing global keys in the native shortcut column without adding
/// a second local key route that would latch a press-and-hold drawing tool.
class AnnotationShortcutMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
}

private final class AnnotationMenuCommand: NSMenuItem {
    private let perform: () -> Void
    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() {
        guard isEnabled else { return }
        perform()
    }
}
