import AppKit
import SwiftUI
import ToolbarCore

/// The capsule's native target. Hover changes its ink, never its size or hit region.
/// The toolbar's outer tracking view remains the only source of reducer crossings.
class ToolbarIconButton: NSButton {
    // NSButton's optical insets depend on the symbol. The pill owns an exact target
    // rectangle; a tall microphone or stacked card must not enlarge it outside the host.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    var hints: ToolbarHintController?
    var hint = "" {
        didSet { if hint != oldValue { hints?.refresh(from: self) } }
    }
    var symbolSize: CGFloat = 15
    private var hoverArea: NSTrackingArea?
    private(set) var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        contentTintColor = .white
        focusRingType = .exterior
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ name: String, size: CGFloat) {
        symbolSize = size
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ value: Bool) {
        hovered = value; needsDisplay = true
        if value { hints?.show(from: self) } else { hints?.leave(from: self) }
    }
    func dismissHint() { hints?.hide(from: self) }
    /// Native menu tracking can consume the exit. The hover colour must follow the real
    /// pointer again when it returns, without reopening a hint from a stale crossing.
    func reconcileHover() {
        guard let window else { setHovered(false); return }
        hovered = bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        needsDisplay = true
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, window?.isKeyWindow == true { hints?.show(from: self, delay: 0) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { dismissHint() }
        return resigned
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { setHovered(false); dismissHint() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func mouseDown(with event: NSEvent) {
        dismissHint()
        super.mouseDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        if (hovered && isEnabled) || isHighlighted {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.24 : 0.13).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 7, yRadius: 7).fill()
    }
}

/// One read-only hint for the row, outside the capsule so it never increases its hit target.
/// Its panel ignores every mouse event and cannot become key. The command remains a button;
/// there is deliberately no shortcut editor here.
@MainActor final class ToolbarHintController {
    var anchor: ToolbarAnchor = .bottom
    private(set) var panel: NSPanel?
    private(set) weak var source: ToolbarIconButton?
    private var pending: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private var revision = 0
    private var shownText: String?
    private weak var hoveredSource: ToolbarIconButton?
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    var isReady = true {
        didSet {
            guard isReady != oldValue else { return }
            if !isReady { hide() }
            else if let button = hoveredSource, let window = button.window,
                    (window.isKeyWindow && window.firstResponder === button) ||
                    button.bounds.contains(button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) {
                show(from: button)
            }
        }
    }
    nonisolated static let dwell: TimeInterval = 0.18
    static let handoffGrace: TimeInterval = 0.08

    init(schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.schedule = schedule
    }

    func show(from button: ToolbarIconButton, delay: TimeInterval = dwell) {
        hoveredSource = button
        guard isReady else { return }
        guard !button.hint.isEmpty else { return }
        pendingHide?.cancel(); pendingHide = nil
        pending?.cancel(); revision += 1
        if source === button, panel?.isVisible == true { refresh(from: button); return }
        let current = revision
        source = button
        // Moving between buttons changes the same hint without another dwell.
        let wait = panel?.isVisible == true ? 0 : delay
        let task = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button, self.revision == current, self.source === button else { return }
            self.present(button)
        }
        pending = task
        schedule(wait, task)
    }
    func refresh(from button: ToolbarIconButton) {
        guard source === button, panel?.isVisible == true else { return }
        present(button)
    }
    /// Briefly bridge the gap between adjacent targets. A new enter cancels this hide
    /// and updates the existing panel. Actions, collapse and detachment use hide().
    func leave(from button: ToolbarIconButton) {
        if hoveredSource === button { hoveredSource = nil }
        guard source === button else { return }
        pending?.cancel(); pending = nil
        pendingHide?.cancel(); revision += 1
        let current = revision
        let task = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button, self.revision == current, self.source === button else { return }
            self.hide(from: button)
        }
        pendingHide = task
        schedule(Self.handoffGrace, task)
    }
    func hide(from button: ToolbarIconButton? = nil) {
        if let button, source !== button { return }
        pending?.cancel(); pending = nil
        pendingHide?.cancel(); pendingHide = nil
        revision += 1; source = nil
        guard let panel else { return }
        shownText = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func present(_ button: ToolbarIconButton) {
        guard isReady, let parent = button.window, parent.isVisible, !button.isHiddenOrHasHiddenAncestor,
              let visible = parent.screen?.visibleFrame else { return }
        let label = ToolbarHintLabel(text: button.hint, size: max(11, button.symbolSize * 0.75))
        let host = NSHostingView(rootView: label)
        let size = host.fittingSize
        let frame = Self.frame(size: size, target: parent.frame, visible: visible, anchor: anchor)
        if shownText == button.hint, panel?.isVisible == true, panel?.frame == frame { return }
        if observedWindow !== parent {
            observers.forEach(NotificationCenter.default.removeObserver)
            observedWindow = parent
            observers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hide() }
                }
            }
        }
        let panel = self.panel ?? {
            let window = Self.makePanel(frame: frame)
            self.panel = window
            return window
        }()
        let wasVisible = panel.isVisible
        let fades = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Replace the words on one rail. Resizing an old text layer during a crossfade
        // made adjacent hints rewrap and jump before the new label had settled.
        panel.contentView = host
        shownText = button.hint
        panel.setFrame(frame, display: true)
        panel.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
        if panel.parent !== parent { panel.parent?.removeChildWindow(panel); parent.addChildWindow(panel, ordered: .above) }
        panel.alphaValue = wasVisible || !fades ? 1 : 0
        panel.orderFrontRegardless()
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    static func makePanel(frame: NSRect) -> NSPanel {
        let window = ToolbarHintPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setAccessibilityElement(false)
        return window
    }

    /// All buttons share the row's rail. Reserve space for the longest hint before
    /// clamping its centre and choosing its side, so short/long text cannot move it.
    static func frame(size: NSSize, target: NSRect, visible: NSRect, anchor: ToolbarAnchor = .bottom) -> NSRect {
        let inset: CGFloat = 8, gap: CGFloat = 8
        let width = min(size.width, max(1, visible.width - 2 * inset))
        let height = min(size.height, max(1, visible.height - 2 * inset))
        if anchor.isVertical {
            var frame = ToolbarGeometry.sidePanelFrame(size: NSSize(width: width, height: height), toolbar: target, anchor: anchor, visible: visible)
            let railHeight = min(max(height, 90), max(1, visible.height - 2 * inset))
            let centre = min(max(target.midY, visible.minY + inset + railHeight / 2), visible.maxY - inset - railHeight / 2)
            frame.origin.y = centre - frame.height / 2
            return frame
        }
        let railWidth = min(324, max(1, visible.width - 2 * inset))
        let centre = min(max(target.midX, visible.minX + inset + railWidth / 2), visible.maxX - inset - railWidth / 2)
        let above = target.maxY + gap + max(height, 90) <= visible.maxY - inset
        return NSRect(x: centre - width / 2,
            y: min(max(above ? target.maxY + gap : target.minY - gap - height, visible.minY + inset), visible.maxY - inset - height),
            width: width, height: height)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

private final class ToolbarHintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct ToolbarHintLabel: View {
    let text: String
    var size: CGFloat = 11
    var body: some View {
        Text(text).font(.system(size: size, weight: .medium)).foregroundStyle(.white)
            .multilineTextAlignment(.center).lineLimit(3)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 300)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.09)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.13), lineWidth: 1))
            .fixedSize().allowsHitTesting(false).accessibilityHidden(true)
    }
}
