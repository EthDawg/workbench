import AppKit
import Combine

/// Sanitized presentation data only. There is no group name, private library
/// name, or unfiltered library reference in this controller's input.
struct PersonaHUDItem {
    let id: UUID
    let label: String
    let image: NSImage?
    static func make(persona: SavedPersona, ordinal: Int, image: NSImage?) -> Self {
        let label = persona.card?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(id: persona.id, label: label.isEmpty ? "Persona \(ordinal)" : label, image: image)
    }
}

private struct PersonaHUDPlacement: Codable {
    var version = 1
    var position = PresentationControlPlacement(anchor: .bottom)
    var screenID: UInt32?
    func validated() throws -> Self {
        guard version == 1 else { throw PersonaError.invalidSettings }
        var copy = self; copy.position = try position.validated(); return copy
    }
}

private final class PersonaHUDPanel: NSPanel {
    var keyboardMode = false
    override var canBecomeKey: Bool { keyboardMode }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); keyboardMode = false }
    override func cancelOperation(_ sender: Any?) { resignKey() }
}

final class PersonaHUDController: NSWindowController {
    var onSelect: ((UUID) -> Void)?
    var onStep: ((Int) -> Void)?
    var onHide: (() -> Void)?
    var onLock: ((Bool) -> Void)?
    var onSizeChange: ((Double) -> Void)?
    var onSetSize: ((Double) -> Void)?
    private(set) var notice: String?
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let options = NSPopUpButton(frame: .zero, pullsDown: true)
    private let previous = NSButton()
    private let next = NSButton()
    private let dismiss = NSButton()
    private let dragHandle = PersonaHUDDragHandle()
    private var locked = false
    private var placement = PersonaHUDPlacement()
    private var savedData: Data?
    private let url: URL
    private let allowsSaving: Bool
    private var storageBlocked = false
    private var screens: AnyCancellable?
    private var guides: FloatingControlGuideController?
    private var legacyContent: NSView?
    private var sessionContent: NSView?
    private var sessionModel: PersonaSessionHUDModel?
    private var sessionMenu: NSMenu?
    private let sessionButton = NSButton()
    private let sessionDragHandle = PersonaHUDDragHandle()
    private let sizeSlider = NSSlider(value: 0.16, minValue: 0.06, maxValue: 0.40, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "Size 16%")
    private let sessionSizeSlider = NSSlider(value: 0.16, minValue: 0.06, maxValue: 0.40, target: nil, action: nil)
    private let sessionSizeLabel = NSTextField(labelWithString: "Size 16%")
    private let addButton = NSButton(title: "Add…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)

    init(root: URL, allowsSaving: Bool = true) {
        url = root.appendingPathComponent("persona-controls.json")
        self.allowsSaving = allowsSaving
        let panel = PersonaHUDPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        do {
            savedData = try PersonaStorage.read(url)
            if let savedData { placement = try JSONDecoder().decode(PersonaHUDPlacement.self, from: savedData).validated() }
        } catch { storageBlocked = true; notice = "The previous persona control position is preserved. This session uses a temporary position." }
        panel.title = "Persona controls"; panel.isFloatingPanel = true; panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let material = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 12; material.layer?.masksToBounds = true
        panel.contentView = material
        legacyContent = material
        configureButton(previous, symbol: "chevron.left", label: "Previous available persona", action: #selector(previousPersona))
        configureButton(next, symbol: "chevron.right", label: "Next available persona", action: #selector(nextPersona))
        configureButton(dismiss, symbol: "xmark", label: "Hide persona and controls", action: #selector(hidePersona))
        picker.target = self; picker.action = #selector(choosePersona)
        picker.setAccessibilityLabel("Choose an available persona")
        picker.cell?.lineBreakMode = .byTruncatingTail
        options.setAccessibilityLabel("Persona options")
        configureSize(sizeSlider, label: sizeLabel)
        sizeSlider.setAccessibilityIdentifier("persona.single.size")
        let actions = NSStackView(views: [dragHandle, previous, picker, next, options, dismiss])
        actions.orientation = .horizontal; actions.spacing = 4; actions.alignment = .centerY
        let sizing = NSStackView(views: [sizeLabel, sizeSlider])
        sizing.orientation = .horizontal; sizing.spacing = 8; sizing.alignment = .centerY
        let row = NSStackView(views: [actions, sizing])
        row.orientation = .vertical; row.spacing = 2; row.alignment = .centerX
        row.translatesAutoresizingMaskIntoConstraints = false; material.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -7),
            row.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 22), dragHandle.heightAnchor.constraint(equalToConstant: 32),
            picker.widthAnchor.constraint(equalToConstant: 154), picker.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            options.widthAnchor.constraint(equalToConstant: 32), options.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
        dragHandle.onDrag = { [weak self] in self?.previewDrag() }
        dragHandle.onEnd = { [weak self] in self?.finishDrag() }
        screens = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }; self.hideGuides(); self.dragHandle.cancel(); self.sessionDragHandle.cancel()
                if self.window?.isVisible == true { self.position(near: nil) }
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(items: [PersonaHUDItem], selectedID: UUID, locked: Bool, width: Double = 0.16, near artwork: CGRect?) {
        guard !items.isEmpty, items.contains(where: { $0.id == selectedID }) else { hide(); return }
        if sessionModel != nil || window?.contentView !== legacyContent {
            sessionMenu?.cancelTracking(); sessionMenu = nil; sessionModel = nil
            window?.contentView = legacyContent
        }
        resizeControl(width: 440, height: 76)
        updateSize(sizeSlider, label: sizeLabel, width: width)
        self.locked = locked
        picker.removeAllItems()
        for item in items {
            let menuItem = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
            menuItem.representedObject = item.id
            if let image = item.image?.copy() as? NSImage { image.size = CGSize(width: 28, height: 28); menuItem.image = image }
            picker.menu?.addItem(menuItem)
        }
        if let index = items.firstIndex(where: { $0.id == selectedID }) { picker.selectItem(at: index) }
        previous.isEnabled = items.count > 1; next.isEnabled = items.count > 1
        picker.isEnabled = items.count > 1
        picker.setAccessibilityLabel(items.count > 1 ? "Choose an available persona" : "Displayed persona")
        picker.setAccessibilityHelp(items.count > 1
            ? "\(items.count) personas were frozen when this card was shown."
            : "Only the displayed persona is available.")
        rebuildOptions()
        if window?.isVisible != true { position(near: artwork); window?.orderFrontRegardless() }
    }
    func hide() {
        picker.menu?.cancelTracking(); options.menu?.cancelTracking()
        sessionMenu?.cancelTracking(); sessionMenu = nil; sessionModel = nil
        dragHandle.cancel(); sessionDragHandle.cancel(); hideGuides(); window?.orderOut(nil)
        (window as? PersonaHUDPanel)?.keyboardMode = false
    }
    func shutdown() {
        hide(); screens = nil
        MainActor.assumeIsolated { guides?.shutdown() }; guides = nil
        onSelect = nil; onStep = nil; onHide = nil; onLock = nil; onSizeChange = nil; onSetSize = nil
    }
    /// Called only through an explicit keyboard-access control in preparation.
    func focusControls() {
        guard let panel = window as? PersonaHUDPanel, panel.isVisible else { return }
        panel.keyboardMode = true; panel.makeKey()
        panel.makeFirstResponder(sessionModel == nil ? (picker.isEnabled ? picker : options) : sessionButton)
    }

    /// A deliberately small, click-based entry to native menu navigation. The
    /// model contains only the explicitly prepared audience-safe session.
    func showSession(viewModel: PersonaSessionHUDModel, near artwork: CGRect?) {
        guard viewModel.state.phase != .idle else { hide(); return }
        sessionModel = viewModel
        if sessionContent == nil {
            let material = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 124, height: 44))
            material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
            material.wantsLayer = true; material.layer?.cornerRadius = 12; material.layer?.masksToBounds = true
            sessionButton.isBordered = false; sessionButton.bezelStyle = .regularSquare
            sessionButton.font = .systemFont(ofSize: 13, weight: .medium); sessionButton.imagePosition = .imageLeading
            sessionButton.target = self; sessionButton.action = #selector(openSessionMenu)
            sessionButton.setAccessibilityIdentifier("persona.session.controls")
            configureSize(sessionSizeSlider, label: sessionSizeLabel)
            sessionSizeSlider.setAccessibilityIdentifier("persona.session.size")
            addButton.target = self; addButton.action = #selector(addOverlay)
            addButton.bezelStyle = .rounded; addButton.toolTip = "Add a persona from this prepared set"
            addButton.setAccessibilityIdentifier("persona.session.add")
            removeButton.target = self; removeButton.action = #selector(removeOverlay)
            removeButton.bezelStyle = .rounded
            removeButton.toolTip = "Remove the selected on-screen copy; keep the saved persona"
            removeButton.setAccessibilityIdentifier("persona.session.remove")
            let row = NSStackView(views: [sessionDragHandle, sessionButton, sessionSizeLabel, sessionSizeSlider, addButton, removeButton])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 2
            row.translatesAutoresizingMaskIntoConstraints = false; material.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 5),
                row.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
                row.centerYAnchor.constraint(equalTo: material.centerYAnchor),
                sessionDragHandle.widthAnchor.constraint(equalToConstant: 20),
                sessionDragHandle.heightAnchor.constraint(equalToConstant: 32),
                sessionButton.heightAnchor.constraint(equalToConstant: 34),
                sessionButton.widthAnchor.constraint(lessThanOrEqualToConstant: 140)
            ])
            sessionButton.cell?.lineBreakMode = .byTruncatingTail
            sessionDragHandle.onDrag = { [weak self] in self?.previewDrag() }
            sessionDragHandle.onEnd = { [weak self] in self?.finishDrag() }
            sessionContent = material
        }
        window?.contentView = sessionContent
        let paused = viewModel.state.phase == .paused
        let visible = viewModel.state.instances.filter(\.visible).count
        sessionButton.title = viewModel.state.feedback != nil ? "Notice  ›" : (paused ? "Hidden  ›" : "\(visible) cards  ›")
        sessionButton.image = NSImage(systemSymbolName: viewModel.state.feedback != nil ? "info.circle" : (paused ? "eye.slash" : "rectangle.on.rectangle"), accessibilityDescription: nil)
        sessionButton.setAccessibilityLabel(viewModel.state.feedback ?? (paused ? "Overlays hidden. Open presentation controls" : "\(visible) overlays shown. Open presentation controls"))
        sessionButton.toolTip = "Click to choose the card to resize or remove, change sets, Hide all or End."
        let selected = viewModel.state.selectedInstance
        if viewModel.state.feedback == nil, !paused, let selected {
            sessionButton.title = "\(String(selected.label.prefix(14)))  ›"
        }
        updateSize(sessionSizeSlider, label: sessionSizeLabel, width: selected?.width ?? 0.16)
        sessionSizeSlider.isEnabled = selected != nil
        sessionSizeLabel.stringValue = selected == nil ? "Size —" : sessionSizeLabel.stringValue
        removeButton.isEnabled = selected != nil
        removeButton.setAccessibilityLabel(selected.map { "Remove \($0.label) from this set" } ?? "Remove selected overlay")
        sessionSizeSlider.setAccessibilityLabel(selected.map { "Size of \($0.label)" } ?? "Size of selected overlay")
        addButton.isEnabled = !viewModel.state.candidates.isEmpty && viewModel.state.instances.count < PersonaSessionController.maximumOverlays
        resizeControl(width: 466)
        if window?.isVisible != true { position(near: artwork); window?.orderFrontRegardless() }
    }

    private func resizeControl(width: CGFloat, height: CGFloat = 44) {
        guard let window, window.frame.size != CGSize(width: width, height: height) else { return }
        let current = window.frame
        let screen = screen(near: current)
        window.setContentSize(CGSize(width: width, height: height))
        if let screen {
            let frame = placement.position.anchor.map {
                FloatingControlGeometry.frame(anchor: $0, size: window.frame.size, visibleFrame: screen.visibleFrame)
            } ?? FloatingControlGeometry.clamp(CGRect(origin: current.origin, size: window.frame.size), to: screen.visibleFrame)
            window.setFrame(frame, display: true)
        }
    }

    @objc private func openSessionMenu() {
        guard let model = sessionModel else { return }
        let state = model.state
        let menu = NSMenu(title: "Overlay controls"); menu.autoenablesItems = false
        func command(_ title: String, _ action: PersonaSessionAction, enabled: Bool = true, checked: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(performSessionCommand(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action; item.isEnabled = enabled; item.state = checked ? .on : .off
            return item
        }
        func submenu(_ title: String, _ children: [NSMenuItem]) {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let list = NSMenu(title: title); list.autoenablesItems = false; children.forEach { list.addItem($0) }
            root.submenu = list; menu.addItem(root)
        }
        let currentIndex = state.groups.firstIndex { $0.id == state.currentGroupID } ?? 0
        let heading = NSMenuItem(title: "Set \(currentIndex + 1) of \(state.groups.count)", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        if let feedback = state.feedback {
            let receipt = NSMenuItem(title: feedback, action: nil, keyEquivalent: "")
            receipt.isEnabled = false; menu.addItem(receipt)
            menu.addItem(command("Dismiss notice", .dismissFeedback)); menu.addItem(.separator())
        }
        if state.groups.count > 1 {
            menu.addItem(command("Previous set", .stepGroup(-1)))
            menu.addItem(command("Next set", .stepGroup(1)))
            submenu("Choose set", state.groups.map { command($0.label, .selectGroup($0.id), checked: $0.id == state.currentGroupID) })
        }
        menu.addItem(.separator())
        submenu("Choose overlay", state.instances.enumerated().map { index, item in
            command("\(index + 1). \(item.label)\(item.visible ? "" : " · hidden")", .selectInstance(item.id), checked: item.id == state.selectedInstanceID)
        })
        if let item = state.instances.first(where: { $0.id == state.selectedInstanceID }) {
            menu.addItem(command(item.visible ? "Hide selected overlay" : "Show selected overlay", .visible(item.id, !item.visible)))
            menu.addItem(command("Lock selected · clicks pass through", .locked(item.id, !item.placement.locked), checked: item.placement.locked))
            let positions: [(String, Double, Double)] = [("Top left", 0.02, 0.98), ("Top centre", 0.5, 0.98), ("Top right", 0.98, 0.98), ("Left centre", 0.02, 0.5), ("Right centre", 0.98, 0.5), ("Bottom left", 0.02, 0.02), ("Bottom centre", 0.5, 0.02), ("Bottom right", 0.98, 0.02)]
            submenu("Position selected", positions.map { command($0.0, .position(item.id, $0.1, $0.2)) })
            submenu("Size and order", [
                command("Smaller", .width(item.id, item.placement.width - 0.02), enabled: item.placement.width > 0.06),
                command("Larger", .width(item.id, item.placement.width + 0.02), enabled: item.placement.width < 0.4),
                .separator(),
                command("Bring forward", .move(item.id, 1)), command("Send backward", .move(item.id, -1)),
                command("Add another copy", .add(item.personaID), enabled: state.instances.count < 8),
                command("Remove from this set", .remove(item.id))
            ])
            submenu("Replace selected", state.candidates.map { command($0.label, .replace(instanceID: item.id, personaID: $0.id), checked: $0.id == item.personaID) })
        }
        submenu("Add overlay", state.candidates.map { command($0.label, .add($0.id), enabled: state.instances.count < 8) })
        menu.addItem(.separator())
        menu.addItem(command(state.phase == .paused ? "Show again" : "Hide all temporarily", .pauseResume))
        menu.addItem(command("Save this layout for next time", .saveLayout, enabled: state.hasUnsavedLayout && state.canSaveLayout))
        let positions = NSMenu(title: "Control position"); positions.autoenablesItems = false
        for anchor in FloatingControlAnchor.allCases {
            let option = NSMenuItem(title: anchor.title, action: #selector(choosePosition(_:)), keyEquivalent: "")
            option.target = self; option.representedObject = anchor.rawValue
            option.state = placement.position.anchor == anchor ? .on : .off; positions.addItem(option)
        }
        let position = NSMenuItem(title: "Control position", action: nil, keyEquivalent: ""); position.submenu = positions; menu.addItem(position)
        menu.addItem(.separator()); menu.addItem(command("End overlays", .end))
        sessionMenu = menu
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sessionButton.bounds.maxY + 4), in: sessionButton)
        sessionMenu = nil
    }
    @objc private func performSessionCommand(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? PersonaSessionAction else { return }
        sessionModel?.perform(action)
    }

    private func configureSize(_ slider: NSSlider, label: NSTextField) {
        slider.target = self; slider.action = #selector(setSize(_:)); slider.isContinuous = true
        slider.setAccessibilityLabel("Persona size")
        slider.toolTip = "Width as a percentage of the display; tall cards may be height-limited"
        slider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.widthAnchor.constraint(equalToConstant: 62).isActive = true
    }
    private func updateSize(_ slider: NSSlider, label: NSTextField, width: Double) {
        slider.doubleValue = width
        label.stringValue = "Size \(Int((width * 100).rounded()))%"
    }
    @objc private func setSize(_ sender: NSSlider) {
        if sender === sessionSizeSlider {
            guard let id = sessionModel?.state.selectedInstanceID else { return }
            sessionModel?.perform(.width(id, sender.doubleValue))
        } else { onSetSize?(sender.doubleValue) }
    }
    @objc private func removeOverlay() {
        guard let id = sessionModel?.state.selectedInstanceID else { return }
        sessionModel?.perform(.remove(id))
    }
    @objc private func addOverlay() {
        guard let model = sessionModel, addButton.isEnabled else { return }
        let menu = NSMenu(title: "Add persona"); menu.autoenablesItems = false
        for candidate in model.state.candidates {
            let item = NSMenuItem(title: candidate.label, action: #selector(performSessionCommand(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = PersonaSessionAction.add(candidate.id)
            menu.addItem(item)
        }
        sessionMenu = menu
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: addButton.bounds.maxY + 4), in: addButton)
        sessionMenu = nil
    }

    private func configureButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly; button.bezelStyle = .regularSquare; button.isBordered = false
        button.target = self; button.action = action; button.toolTip = label; button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }
    private func rebuildOptions() {
        options.removeAllItems(); options.addItem(withTitle: "•••")
        let lock = NSMenuItem(title: "Lock artwork · clicks pass through", action: #selector(toggleLock), keyEquivalent: "")
        lock.target = self; lock.state = locked ? .on : .off; options.menu?.addItem(lock)
        for (title, delta) in [("Smaller persona", -0.02), ("Larger persona", 0.02)] {
            let item = NSMenuItem(title: title, action: #selector(changeSize(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = delta; options.menu?.addItem(item)
        }
        let positions = NSMenu(title: "Control position")
        for anchor in FloatingControlAnchor.allCases {
            let item = NSMenuItem(title: anchor.title, action: #selector(choosePosition(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = anchor.rawValue
            item.state = placement.position.anchor == anchor ? .on : .off; positions.addItem(item)
        }
        let menuItem = NSMenuItem(title: "Control position", action: nil, keyEquivalent: "")
        menuItem.submenu = positions; options.menu?.addItem(menuItem)
    }
    @objc private func previousPersona() { onStep?(-1) }
    @objc private func nextPersona() { onStep?(1) }
    @objc private func hidePersona() { onHide?() }
    @objc private func choosePersona() { if let id = picker.selectedItem?.representedObject as? UUID { onSelect?(id) } }
    @objc private func toggleLock() { onLock?(!locked) }
    @objc private func changeSize(_ sender: NSMenuItem) { if let delta = sender.representedObject as? Double { onSizeChange?(delta) } }
    @objc private func choosePosition(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let anchor = FloatingControlAnchor(rawValue: name) else { return }
        hideGuides(); dragHandle.cancel(); placement.position.anchor = anchor; position(near: nil); save(); rebuildOptions()
    }
    private static func screenID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private func screen(near rect: CGRect?) -> NSScreen? {
        if let rect, let best = NSScreen.screens.max(by: { overlap(rect, $0.visibleFrame) < overlap(rect, $1.visibleFrame) }), overlap(rect, best.visibleFrame) > 0 { return best }
        return NSScreen.screens.first { Self.screenID($0) == placement.screenID && placement.screenID != nil }
            ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs); return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    private func position(near rect: CGRect?) {
        guard let window, let screen = screen(near: placement.screenID == nil ? rect : nil) else { return }
        placement.screenID = Self.screenID(screen)
        window.setFrame(placement.position.frame(size: window.frame.size, in: screen.visibleFrame), display: true)
    }
    private func previewDrag() {
        guard let window, let screen = screen(near: window.frame) else { return }
        let active = FloatingControlGeometry.nearestAnchor(to: window.frame, in: screen.visibleFrame)
        MainActor.assumeIsolated {
            if guides == nil { guides = FloatingControlGuideController() }
            guides?.show(controlFrame: window.frame, visibleFrame: screen.visibleFrame, activeAnchor: active, below: window)
        }
    }
    private func finishDrag() {
        defer { hideGuides() }
        guard let window, let screen = screen(near: window.frame) else { return }
        let anchor = FloatingControlGeometry.nearestAnchor(to: window.frame, in: screen.visibleFrame)
        let frame = anchor.map { FloatingControlGeometry.frame(anchor: $0, size: window.frame.size, visibleFrame: screen.visibleFrame) }
            ?? FloatingControlGeometry.clamp(window.frame, to: screen.visibleFrame)
        placement.position.move(to: frame, in: screen.visibleFrame, anchor: anchor)
        placement.screenID = Self.screenID(screen); window.setFrame(frame, display: true); save(); rebuildOptions()
    }
    private func hideGuides() { MainActor.assumeIsolated { guides?.hide() } }
    private func save() {
        guard allowsSaving, !storageBlocked else { return }
        do { savedData = try PersonaStorage.write(placement.validated(), to: url, expected: savedData) }
        catch { storageBlocked = true; notice = "Persona controls could not save their position. The previous file is preserved." }
    }
}

private final class PersonaHUDDragHandle: NSView {
    var onDrag: (() -> Void)?
    var onEnd: (() -> Void)?
    private var start: CGPoint?
    private var origin: CGPoint?
    private var dragging = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Drag persona controls; named positions are available in options")
        toolTip = "Drag to move controls. Use Control position for named locations."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .draw(in: bounds.insetBy(dx: 4, dy: 10))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }; start = window.convertPoint(toScreen: event.locationInWindow); origin = window.frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start, let origin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        guard dragging || hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        dragging = true; window.setFrameOrigin(CGPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y)); onDrag?()
    }
    override func mouseUp(with event: NSEvent) { if dragging { onEnd?() }; cancel() }
    func cancel() { start = nil; origin = nil; dragging = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
