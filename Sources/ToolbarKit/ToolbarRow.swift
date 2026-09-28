import AppKit
import SwiftUI
import ToolbarCore

public struct ToolbarDragActions {
    public var begin: () -> Void
    public var move: () -> Void
    public var end: () -> Void
    public var cancel: () -> Void
    public var isCancelled: () -> Bool
    public init(begin: @escaping () -> Void = {}, move: @escaping () -> Void = {}, end: @escaping () -> Void = {}, cancel: @escaping () -> Void = {},
                isCancelled: @escaping () -> Bool = { false }) {
        self.begin = begin; self.move = move; self.end = end
        self.cancel = cancel; self.isCancelled = isCancelled
    }
}

public extension ToolbarAnchor {
    /// Where the row sits inside its window: against the docked edge, never
    /// centred. The window is sometimes briefly the wrong size, placed before a
    /// new row has been measured or while a collapse animates. A centred row then
    /// moves the resting element out from under the pointer by half the
    /// difference, which can carry the pointer outside and start a collapse.
    var contentAlignment: Alignment {
        let horizontal: HorizontalAlignment = growsLeftward ? .trailing : .leading
        switch self {
        case .topLeft, .top, .topRight: return Alignment(horizontal: horizontal, vertical: .top)
        case .left, .right: return Alignment(horizontal: horizontal, vertical: .center)
        case .bottomLeft, .bottom, .bottomRight: return Alignment(horizontal: horizontal, vertical: .bottom)
        }
    }
}

public extension View {
    /// Hold toolbar content against its dock whatever size the window is. Apply
    /// outside any measurement of the row, so the row still reports its own size.
    func pinnedToDock(_ anchor: ToolbarAnchor) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor.contentAlignment)
    }
}

/// The production look and the gallery are the same view, fed one frozen value.
///
/// At rest the toolbar is one element, `[mode glyph][next action]`: click the
/// label to do it, click the glyph for the menu, drag anywhere to move. Revealed,
/// the same element stays where it is and the row grows inward from the dock
/// with a divider, the other modes as chips, and the mode's accessory.
public struct ToolbarRow: View {
    public let state: ToolbarViewState
    private let action: () -> Void
    private let selectMode: (ToolbarMode) -> Void
    private let makeMenu: () -> NSMenu
    private let menuBegan: (NSMenu) -> Bool
    private let menuEnded: () -> Void
    private let focusButton: (NSButton) -> Void
    private let escape: () -> Void
    private let drag: ToolbarDragActions
    private let textScale: CGFloat
    private let accent: Color
    private let makeAccessoryMenu: () -> NSMenu
    /// When set, the accessory opens the host's own surface anchored to the
    /// button instead of popping up `makeAccessoryMenu`'s menu.
    private let openAccessory: ((NSView) -> Void)?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var systemScale: CGFloat = 1

    public init(state: ToolbarViewState, textScale: CGFloat = 1, accent: Color = .accentColor,
                makeAccessoryMenu: @escaping () -> NSMenu = { NSMenu() },
                openAccessory: ((NSView) -> Void)? = nil,
                action: @escaping () -> Void = {}, selectMode: @escaping (ToolbarMode) -> Void = { _ in },
                makeMenu: @escaping () -> NSMenu = { NSMenu() },
                menuBegan: @escaping (NSMenu) -> Bool = { _ in true }, menuEnded: @escaping () -> Void = {},
                focusButton: @escaping (NSButton) -> Void = { _ in }, escape: @escaping () -> Void = {},
                drag: ToolbarDragActions = ToolbarDragActions()) {
        self.state = state; self.textScale = textScale; self.accent = accent; self.action = action
        self.selectMode = selectMode; self.makeMenu = makeMenu
        self.menuBegan = menuBegan; self.menuEnded = menuEnded; self.focusButton = focusButton
        self.escape = escape; self.drag = drag
        self.makeAccessoryMenu = makeAccessoryMenu
        self.openAccessory = openAccessory
    }
    private var scale: CGFloat { textScale * systemScale }
    private var side: CGFloat { 36 * scale }

    public var body: some View {
        HStack(spacing: 6 * scale) {
            if state.anchor.growsLeftward {
                if state.tier == .revealed { accessory; strip; divider }
                primary; glyph
            } else {
                glyph; primary
                if state.tier == .revealed { divider; strip; accessory }
            }
        }
        .padding(state.anchor.growsLeftward ? .leading : .trailing, 8 * scale)
        .padding(state.anchor.growsLeftward ? .trailing : .leading, 0)
        .frame(minHeight: side).fixedSize()
        // Empty chrome is a handle too: a drag that starts beside or between the controls
        // moves the row. The controls sit above it and keep their own clicks.
        .background { ToolbarDragRegion(drag: drag, showsHandCursor: false) }
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)) }
            else { RoundedRectangle(cornerRadius: 12).fill(.regularMaterial) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12))
        }
        .tint(accent)
        .environment(\.controlActiveState, .active)
        .onExitCommand(perform: escape)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workbench floating toolbar")
    }

    @ViewBuilder private var accessory: some View {
        if let accessoryTitle = state.accessoryTitle {
            ToolbarAccessory(title: accessoryTitle, makeMenu: makeAccessoryMenu, openPanel: openAccessory, began: menuBegan, ended: menuEnded)
                .frame(width: 64 * scale, height: 30 * scale)
        }
    }

    /// The seam between the resting element and the rest of the row. Empty
    /// space here is a handle: the row can be dragged by it.
    private var divider: some View {
        Divider().frame(height: 18 * scale)
            .padding(.horizontal, 2 * scale)
            .overlay { ToolbarDragRegion(drag: drag) }
    }

    private var strip: some View {
        ToolbarModeStrip(chips: state.switcher, size: 24 * scale, symbolSize: 15 * scale, accent: accent, select: selectMode)
            .frame(width: 24 * scale * CGFloat(state.switcher.count) + 3 * scale * CGFloat(max(0, state.switcher.count - 1)),
                   height: 24 * scale)
    }

    private var primary: some View {
        ToolbarPrimary(title: state.actionTitle, hint: state.actionHint, isEnabled: state.isActionEnabled,
                       fontSize: 13 * scale, minimumTitles: state.minimumTitles, accent: accent,
                       action: action, drag: drag)
            .fixedSize()
    }

    private var glyph: some View {
        ToolbarGlyph(state: state, size: 15 * scale, accent: accent, makeMenu: makeMenu, began: menuBegan,
                     ended: menuEnded, focus: focusButton, escape: escape, drag: drag)
            .frame(width: side, height: side)
            .overlay(alignment: .trailing) {
                if state.tier == .revealed {
                    Image(systemName: "chevron.down").font(.system(size: 6 * scale, weight: .semibold))
                        .foregroundStyle(.secondary).padding(.trailing, 2 * scale).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if state.isBusy { Circle().fill(.tint).frame(width: 4, height: 4).padding(.bottom, 3).allowsHitTesting(false) }
            }
    }
}

/// The next action. A native button so a drag that starts on it moves the
/// window, exactly as it does from the glyph, and a click does the action.
private struct ToolbarPrimary: NSViewRepresentable {
    let title: String
    let hint: String?
    let isEnabled: Bool
    let fontSize: CGFloat
    let minimumTitles: [String]
    let accent: Color
    let action: () -> Void
    let drag: ToolbarDragActions
    func makeNSView(context: Context) -> PrimaryButton {
        let view = PrimaryButton()
        view.bezelStyle = .rounded
        view.controlSize = .small
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }
    func updateNSView(_ view: PrimaryButton, context: Context) {
        view.title = title
        view.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        view.bezelColor = NSColor(accent)
        view.isEnabled = isEnabled
        view.toolTip = hint
        view.minimumWidth = minimumTitles.map { PrimaryButton.width(of: $0, like: view) }.max() ?? 0
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier("toolbar.primary")
        view.run = action; view.drag = drag
        view.invalidateIntrinsicContentSize()
    }
    final class PrimaryButton: NSButton {
        var run: (() -> Void)?
        var drag = ToolbarDragActions()
        /// The widest idle verb sets the floor, so switching modes at rest never
        /// moves the strip under the pointer.
        var minimumWidth: CGFloat = 0
        override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(runAction) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func runAction() { run?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// Tab from the glyph reaches the action.
        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width = max(size.width, minimumWidth)
            return size
        }
        /// The exact width this button would have with another title, cached
        /// per font size because the style never changes.
        nonisolated(unsafe) private static var widths: [String: CGFloat] = [:]
        static func width(of title: String, like button: NSButton) -> CGFloat {
            let key = "\(button.font?.pointSize ?? 0)|\(title)"
            if let cached = widths[key] { return cached }
            let probe = NSButton()
            probe.bezelStyle = button.bezelStyle; probe.controlSize = button.controlSize
            probe.font = button.font; probe.title = title
            let width = probe.intrinsicContentSize.width
            widths[key] = width
            return width
        }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            trackToolbarDrag(view: self, event: event, actions: drag, click: { [weak self] in self?.run?() })
        }
        override func performClick(_ sender: Any?) { if isEnabled { run?() } }
    }
}

/// The other modes, one native button each. Click switches; hover only tells.
/// These never activate the app: a click must leave the other app's field
/// focused so the next Dictate lands in it.
struct ToolbarModeStrip: NSViewRepresentable {
    let chips: [ToolbarModeChip]
    let size: CGFloat
    let symbolSize: CGFloat
    let accent: Color
    let select: (ToolbarMode) -> Void
    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        return stack
    }
    func updateNSView(_ stack: NSStackView, context: Context) {
        stack.spacing = 3 * size / 24
        let existing = stack.arrangedSubviews.compactMap { $0 as? ModeChipButton }
        if existing.map(\.mode) != chips.map(\.mode) {
            existing.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            for chip in chips {
                let button = ModeChipButton(mode: chip.mode)
                button.widthAnchor.constraint(equalToConstant: size).isActive = true
                button.heightAnchor.constraint(equalToConstant: size).isActive = true
                stack.addArrangedSubview(button)
            }
        }
        for (button, chip) in zip(stack.arrangedSubviews.compactMap { $0 as? ModeChipButton }, chips) {
            button.image = NSImage(systemSymbolName: chip.mode.symbol, accessibilityDescription: chip.mode.title)?
                .withSymbolConfiguration(.init(pointSize: symbolSize, weight: .medium))
            button.contentTintColor = chip.isBusy ? NSColor(accent) : .secondaryLabelColor
            button.accent = NSColor(accent)
            button.isBusy = chip.isBusy
            button.isEnabled = chip.isEnabled
            button.toolTip = "Switch to " + chip.mode.title + (chip.key.map { " · " + $0 } ?? "")
            button.setAccessibilityLabel("Switch to " + chip.mode.title)
            button.setAccessibilityIdentifier("toolbar.mode." + chip.mode.slug)
            button.select = select
            button.needsDisplay = true
        }
    }
    final class ModeChipButton: NSButton {
        let mode: ToolbarMode
        var select: ((ToolbarMode) -> Void)?
        var accent: NSColor = .controlAccentColor
        var isBusy = false
        init(mode: ToolbarMode) {
            self.mode = mode
            super.init(frame: .zero)
            isBordered = false; imagePosition = .imageOnly; imageScaling = .scaleProportionallyDown
            translatesAutoresizingMaskIntoConstraints = false
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            target = self; action = #selector(switchMode)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func switchMode() { select?(mode) }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard isBusy else { return }
            accent.setFill()
            // The dot sits at the bottom, where the glyph's dot is; the button is flipped.
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2, y: isFlipped ? bounds.maxY - 5 : bounds.minY + 1, width: 4, height: 4)).fill()
        }
    }
}

private struct ToolbarAccessory: NSViewRepresentable {
    let title: String
    let makeMenu: () -> NSMenu
    let openPanel: ((NSView) -> Void)?
    let began: (NSMenu) -> Bool
    let ended: () -> Void
    func makeNSView(context: Context) -> AccessoryButton { AccessoryButton() }
    func updateNSView(_ view: AccessoryButton, context: Context) {
        view.title = title + " ⌄"; view.isBordered = false; view.font = .systemFont(ofSize: 12)
        view.setAccessibilityLabel(title); view.setAccessibilityIdentifier("toolbar.accessory")
        view.open = { [weak view] in
            guard let view else { return }
            if let openPanel { openPanel(view); return }
            let menu = makeMenu(); guard began(menu) else { return }
            defer { ended() }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        }
    }
    final class AccessoryButton: NSButton {
        var open: (() -> Void)?
        override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(openMenu) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc private func openMenu() { open?() }
    }
}

private struct ToolbarGlyph: NSViewRepresentable {
    let state: ToolbarViewState
    let size: CGFloat
    let accent: Color
    let makeMenu: () -> NSMenu
    let began: (NSMenu) -> Bool
    let ended: () -> Void
    let focus: (NSButton) -> Void
    let escape: () -> Void
    let drag: ToolbarDragActions
    func makeNSView(context: Context) -> GlyphButton {
        let view = GlyphButton()
        view.isBordered = false
        view.imagePosition = .imageOnly
        return view
    }
    func updateNSView(_ view: GlyphButton, context: Context) {
        view.image = NSImage(systemSymbolName: state.mode.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        view.contentTintColor = state.isBusy ? NSColor(accent) : .labelColor
        view.setAccessibilityLabel(state.mode.title + " menu" + (state.isBusy ? ", active" : ""))
        view.setAccessibilityIdentifier("toolbar.menu")
        view.toolTip = state.mode.title + ". Click for options; drag to move."
        view.escape = escape; view.drag = drag
        view.open = { [weak view] in
            guard let view else { return }
            let menu = makeMenu()
            guard began(menu) else { return }
            defer { ended() }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        }
        focus(view)
    }
}

private final class GlyphButton: NSButton {
    var open: (() -> Void)?
    var escape: (() -> Void)?
    var drag = ToolbarDragActions()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self; action = #selector(openMenu)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openMenu() { open?() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        trackToolbarDrag(view: self, event: event, actions: drag, click: { [weak self] in self?.open?() })
    }
    override func rightMouseDown(with event: NSEvent) { open?() }
    override func performClick(_ sender: Any?) { open?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape?() }
        else if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 125 { open?() }
        else { super.keyDown(with: event) }
    }
}

private struct ToolbarDragRegion: NSViewRepresentable {
    let drag: ToolbarDragActions
    var showsHandCursor = true
    func makeNSView(context: Context) -> DragRegion { DragRegion() }
    func updateNSView(_ view: DragRegion, context: Context) {
        view.drag = drag
        if view.showsHandCursor != showsHandCursor { view.showsHandCursor = showsHandCursor; view.window?.invalidateCursorRects(for: view) }
    }
}
private final class DragRegion: NSView {
    var drag = ToolbarDragActions()
    var showsHandCursor = true
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { trackToolbarDrag(view: self, event: event, actions: drag) }
    override func resetCursorRects() { if showsHandCursor { addCursorRect(bounds, cursor: .openHand) } }
}

@MainActor private func trackToolbarDrag(view: NSView, event: NSEvent, actions: ToolbarDragActions,
                                       click: (() -> Void)? = nil) {
    guard let window = view.window else { return }
    let start = window.convertPoint(toScreen: event.locationInWindow)
    var origin = window.frame.origin
    var dragging = false
    var endedNormally = false
    defer { if dragging { endedNormally ? actions.end() : actions.cancel() } }
    while window.isVisible {
        if dragging && actions.isCancelled() { break }
        guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .appKitDefined],
            until: Date(timeIntervalSinceNow: 0.1), inMode: .eventTracking, dequeue: true) else { continue }
        if dragging && actions.isCancelled() { break }
        if next.type == .appKitDefined {
            NSApp.sendEvent(next)
            if next.subtype == .applicationDeactivated { break }
            continue
        }
        let point = window.convertPoint(toScreen: next.locationInWindow)
        if !dragging && ToolbarDrag.isDrag(from: start, to: point) {
            actions.begin(); origin = window.frame.origin; dragging = true
        }
        if next.type == .leftMouseUp {
            endedNormally = true
            if !dragging && view.bounds.contains(view.convert(next.locationInWindow, from: nil)) { click?() }
            break
        }
        if dragging {
            window.setFrameOrigin(NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
            actions.move()
        }
    }
}
