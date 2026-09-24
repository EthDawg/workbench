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

/// The production look and the gallery are the same view, fed one frozen value.
public struct ToolbarRow: View {
    public let state: ToolbarViewState
    private let action: () -> Void
    private let makeMenu: () -> NSMenu
    private let menuBegan: (NSMenu) -> Bool
    private let menuEnded: () -> Void
    private let focusButton: (NSButton) -> Void
    private let escape: () -> Void
    private let drag: ToolbarDragActions
    private let textScale: CGFloat
    private let accent: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var systemScale: CGFloat = 1

    public init(state: ToolbarViewState, textScale: CGFloat = 1, accent: Color = .accentColor,
                action: @escaping () -> Void = {}, makeMenu: @escaping () -> NSMenu = { NSMenu() },
                menuBegan: @escaping (NSMenu) -> Bool = { _ in true }, menuEnded: @escaping () -> Void = {},
                focusButton: @escaping (NSButton) -> Void = { _ in }, escape: @escaping () -> Void = {},
                drag: ToolbarDragActions = ToolbarDragActions()) {
        self.state = state; self.textScale = textScale; self.accent = accent; self.action = action; self.makeMenu = makeMenu
        self.menuBegan = menuBegan; self.menuEnded = menuEnded; self.focusButton = focusButton
        self.escape = escape; self.drag = drag
    }
    private var scale: CGFloat { textScale * systemScale }
    private var side: CGFloat { 36 * scale }

    public var body: some View {
        HStack(spacing: state.tier == .resting ? 0 : 8 * scale) {
            if !state.anchor.growsLeftward { glyph }
            if state.tier == .revealed {
                if state.anchor.growsLeftward { trailing }
                Button(state.actionTitle, action: action)
                    .font(.system(size: 13 * scale, weight: .medium))
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!state.isActionEnabled).fixedSize()
                    .accessibilityIdentifier("toolbar.primary")
                if !state.anchor.growsLeftward { trailing }
            }
            if state.anchor.growsLeftward { glyph }
        }
        .padding(state.anchor.growsLeftward ? .leading : .trailing, state.tier == .resting ? 0 : 12 * scale)
        .frame(minHeight: side).fixedSize()
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
    private var trailing: some View {
        Text(state.trailing.text).font(.system(size: 12 * scale))
            .foregroundStyle(.secondary).fixedSize()
            .help(state.trailing.text)
            .overlay { ToolbarDragRegion(drag: drag) }
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
        view.image = NSImage(systemSymbolName: state.tool.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        view.contentTintColor = state.isBusy ? NSColor(accent) : .labelColor
        view.setAccessibilityLabel(state.tool.title + " menu" + (state.isBusy ? ", active" : ""))
        view.setAccessibilityIdentifier("toolbar.menu")
        view.toolTip = state.tool.title + ". Click for tools and options; drag to move."
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
    override func performClick(_ sender: Any?) { open?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape?() }
        else if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 125 { open?() }
        else { super.keyDown(with: event) }
    }
}

private struct ToolbarDragRegion: NSViewRepresentable {
    let drag: ToolbarDragActions
    func makeNSView(context: Context) -> DragRegion { DragRegion() }
    func updateNSView(_ view: DragRegion, context: Context) { view.drag = drag }
}
private final class DragRegion: NSView {
    var drag = ToolbarDragActions()
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { trackToolbarDrag(view: self, event: event, actions: drag) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
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
        if !dragging && hypot(point.x - start.x, point.y - start.y) > 3 {
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
