import AppKit

/// Direct manipulation for a floating persona. A small grab handle above its
/// top edge moves it; corner and edge handles resize it, keeping its shape.
/// Each handle is its own small window that takes the pointer only inside
/// itself, so locked artwork keeps passing clicks through and the voice
/// outline's transparent room never blocks the app beneath. Handles appear as
/// the pointer approaches; Position and Size in the Persona menu remain the
/// keyboard and precise route.
enum PersonaHandle: CaseIterable {
    case move, topLeft, topRight, bottomLeft, bottomRight, left, right, bottom

    var resizes: Bool { self != .move }
    var title: String { self == .move ? "Move persona" : "Resize persona" }
}

/// The handles' geometry and the resize arithmetic, shared by the windows and
/// the checks. Everything is in screen points.
enum PersonaManipulation {
    /// A press becomes a drag only after the pointer travels this far: the
    /// same four points the floating toolbar uses.
    static let dragThreshold: CGFloat = 4
    /// The handles appear when the pointer comes this close to the artwork and
    /// stays there this long, so a pointer passing by does not flash them.
    static let revealDistance: CGFloat = 24
    static let revealDelay: TimeInterval = 0.15
    /// Hit areas: the grab handle, a corner, and an edge (length × thickness).
    static let grab = CGSize(width: 44, height: 18)
    static let corner: CGFloat = 18
    static let edge = CGSize(width: 30, height: 12)

    /// Whether `point` is close enough to the visible artwork to show its handles.
    static func reveals(_ point: CGPoint, around visible: CGRect) -> Bool {
        visible.insetBy(dx: -revealDistance, dy: -revealDistance).contains(point)
    }

    /// Each handle's window around the visible artwork, moved inside `screen`
    /// where it would cross the edge. Edge handles are left out of a side too
    /// short to hold them between its corners.
    static func frames(around visible: CGRect, within screen: CGRect) -> [PersonaHandle: CGRect] {
        func centred(_ size: CGSize, at point: CGPoint) -> CGRect {
            let frame = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
            guard screen.width >= frame.width, screen.height >= frame.height else { return frame }
            return frame.offsetBy(dx: min(0, screen.maxX - frame.maxX) + max(0, screen.minX - frame.minX),
                                  dy: min(0, screen.maxY - frame.maxY) + max(0, screen.minY - frame.minY))
        }
        let out = corner / 2 - 5, square = CGSize(width: corner, height: corner)
        var frames: [PersonaHandle: CGRect] = [
            .move: centred(CGSize(width: min(grab.width, max(28, visible.width * 0.5)), height: grab.height), at: CGPoint(x: visible.midX, y: visible.maxY + grab.height / 2 - 2)),
            .topLeft: centred(square, at: CGPoint(x: visible.minX - out, y: visible.maxY + out)),
            .topRight: centred(square, at: CGPoint(x: visible.maxX + out, y: visible.maxY + out)),
            .bottomLeft: centred(square, at: CGPoint(x: visible.minX - out, y: visible.minY - out)),
            .bottomRight: centred(square, at: CGPoint(x: visible.maxX + out, y: visible.minY - out))
        ]
        let room = corner * 2 + edge.width
        if visible.height >= room {
            let upright = CGSize(width: edge.height, height: edge.width)
            frames[.left] = centred(upright, at: CGPoint(x: visible.minX - edge.height / 2 + 2, y: visible.midY))
            frames[.right] = centred(upright, at: CGPoint(x: visible.maxX + edge.height / 2 - 2, y: visible.midY))
        }
        if visible.width >= room {
            frames[.bottom] = centred(edge, at: CGPoint(x: visible.midX, y: visible.minY - edge.height / 2 + 2))
        }
        return frames
    }

    /// The artwork's rectangle after dragging `handle` by `offset`. The
    /// opposite corner or edge of the visible artwork stays put, the shape is
    /// kept, and the width stays within `widths`.
    static func resized(_ artwork: CGRect, visible: CGRect, handle: PersonaHandle, by offset: CGVector, widths: ClosedRange<CGFloat>) -> CGRect {
        guard handle.resizes, artwork.width > 0, visible.width > 0, visible.height > 0 else { return artwork }
        let grabbed: CGPoint, anchor: CGPoint
        switch handle {
        case .topLeft: grabbed = CGPoint(x: visible.minX, y: visible.maxY); anchor = CGPoint(x: visible.maxX, y: visible.minY)
        case .topRight: grabbed = CGPoint(x: visible.maxX, y: visible.maxY); anchor = CGPoint(x: visible.minX, y: visible.minY)
        case .bottomLeft: grabbed = CGPoint(x: visible.minX, y: visible.minY); anchor = CGPoint(x: visible.maxX, y: visible.maxY)
        case .bottomRight: grabbed = CGPoint(x: visible.maxX, y: visible.minY); anchor = CGPoint(x: visible.minX, y: visible.maxY)
        case .left: grabbed = CGPoint(x: visible.minX, y: visible.midY); anchor = CGPoint(x: visible.maxX, y: visible.midY)
        case .right: grabbed = CGPoint(x: visible.maxX, y: visible.midY); anchor = CGPoint(x: visible.minX, y: visible.midY)
        case .bottom: grabbed = CGPoint(x: visible.midX, y: visible.minY); anchor = CGPoint(x: visible.midX, y: visible.maxY)
        case .move: return artwork
        }
        // The dragged corner follows the pointer along the artwork's diagonal;
        // an edge follows it across.
        let reach = CGVector(dx: grabbed.x - anchor.x, dy: grabbed.y - anchor.y)
        let moved = CGVector(dx: reach.dx + offset.dx, dy: reach.dy + offset.dy)
        let length = reach.dx * reach.dx + reach.dy * reach.dy
        guard length > 0 else { return artwork }
        var scale = (moved.dx * reach.dx + moved.dy * reach.dy) / length
        scale = min(widths.upperBound / artwork.width, max(widths.lowerBound / artwork.width, scale))
        return CGRect(x: anchor.x + (artwork.minX - anchor.x) * scale, y: anchor.y + (artwork.minY - anchor.y) * scale,
                      width: artwork.width * scale, height: artwork.height * scale)
    }
}

/// What a handle asks of the persona it belongs to.
protocol PersonaHandleOwner: AnyObject {
    func handleBegan(_ handle: PersonaHandle)
    func handleMoved(_ handle: PersonaHandle, by offset: CGVector)
    func handleEnded(_ handle: PersonaHandle)
}

/// The eight small handle windows of one persona. They exist only while shown.
final class PersonaHandleSet {
    weak var owner: PersonaHandleOwner?
    private var panels: [PersonaHandle: NSPanel] = [:]
    private(set) var isShown = false

    init(owner: PersonaHandleOwner) { self.owner = owner }

    /// The handles' windows, for checks.
    var windows: [PersonaHandle: NSWindow] { panels }

    /// Shows handles at `frames`, just above `window`. Already shown handles
    /// only move, so following the pointer never reorders windows.
    func show(_ frames: [PersonaHandle: CGRect], above window: NSWindow) {
        for handle in PersonaHandle.allCases {
            guard let frame = frames[handle] else { panels.removeValue(forKey: handle)?.close(); continue }
            let panel = panels[handle] ?? makePanel(handle)
            panels[handle] = panel
            if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
            guard !panel.isVisible else { continue }
            panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
            panel.order(.above, relativeTo: window.windowNumber)
            if panel.alphaValue < 1 { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 } }
        }
        isShown = true
    }
    /// Keeps shown handles on the artwork as it moves or resizes.
    func move(_ frames: [PersonaHandle: CGRect]) {
        guard isShown else { return }
        for (handle, panel) in panels { if let frame = frames[handle] { panel.setFrame(frame, display: true) } }
    }
    func hide() {
        guard isShown || panels.values.contains(where: \.isVisible) else { return }
        isShown = false
        panels.values.forEach { $0.orderOut(nil) }
    }
    func shutdown() { hide(); panels.values.forEach { $0.close() }; panels.removeAll() }

    private func makePanel(_ handle: PersonaHandle) -> NSPanel {
        let panel = PersonaHandlePanel(contentRect: CGRect(x: 0, y: 0, width: 18, height: 18), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "Workbench persona handle"
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        // A clear panel passes clicks on its transparent pixels through by default,
        // which would leave only the thin drawn mark to grab. The panel is exactly
        // the handle's hit region, so it takes every click inside it.
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = PersonaHandleView(handle: handle)
        view.owner = owner
        panel.contentView = view
        return panel
    }
}

private final class PersonaHandlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One handle: a small light mark with a dark edge, readable on light and
/// dark screens. A press becomes a drag after four points; a click does nothing.
final class PersonaHandleView: NSView {
    let handle: PersonaHandle
    weak var owner: PersonaHandleOwner?
    private var start: CGPoint?
    private var dragging = false
    private let edgeLayer = CAShapeLayer(), markLayer = CAShapeLayer()

    init(handle: PersonaHandle) {
        self.handle = handle
        super.init(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        wantsLayer = true
        for layer in [edgeLayer, markLayer] {
            layer.fillColor = nil; layer.lineCap = .round; layer.lineJoin = .round
            layer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            self.layer?.addSublayer(layer)
        }
        edgeLayer.strokeColor = NSColor.black.withAlphaComponent(0.5).cgColor
        markLayer.strokeColor = NSColor.white.withAlphaComponent(0.96).cgColor
        markLayer.shadowColor = NSColor.black.cgColor; markLayer.shadowOpacity = 0.25; markLayer.shadowRadius = 1.5; markLayer.shadowOffset = .zero
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel(handle.title)
        toolTip = handle == .move ? "Drag to move" : "Drag to resize"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        let path = CGMutablePath(), box = bounds, width: CGFloat
        switch handle {
        case .move:
            let length = min(28, box.width - 12)
            path.move(to: CGPoint(x: box.midX - length / 2, y: box.midY)); path.addLine(to: CGPoint(x: box.midX + length / 2, y: box.midY))
            width = 5
        case .left, .right:
            path.move(to: CGPoint(x: box.midX, y: box.midY - 8)); path.addLine(to: CGPoint(x: box.midX, y: box.midY + 8))
            width = 4
        case .bottom:
            path.move(to: CGPoint(x: box.midX - 8, y: box.midY)); path.addLine(to: CGPoint(x: box.midX + 8, y: box.midY))
            width = 4
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // An L just outside the corner, its arms running along the artwork's edges.
            let sx: CGFloat = handle == .topLeft || handle == .bottomLeft ? -1 : 1
            let sy: CGFloat = handle == .topLeft || handle == .topRight ? 1 : -1
            let vertex = CGPoint(x: box.midX + 3 * sx, y: box.midY + 3 * sy), arm: CGFloat = 8
            path.move(to: CGPoint(x: vertex.x - arm * sx, y: vertex.y))
            path.addLine(to: vertex)
            path.addLine(to: CGPoint(x: vertex.x, y: vertex.y - arm * sy))
            width = 3.5
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [edgeLayer, markLayer] { layer.frame = bounds; layer.path = path; layer.contentsScale = window?.backingScaleFactor ?? 2 }
        markLayer.lineWidth = width; edgeLayer.lineWidth = width + 2
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        start = screenPoint(event); dragging = false
        cursor(pressed: true).set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let point = screenPoint(event) else { return }
        if !dragging {
            guard hypot(point.x - start.x, point.y - start.y) >= PersonaManipulation.dragThreshold else { return }
            dragging = true; owner?.handleBegan(handle)
        }
        owner?.handleMoved(handle, by: CGVector(dx: point.x - start.x, dy: point.y - start.y))
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { owner?.handleEnded(handle) }
        start = nil; dragging = false
        cursor(pressed: false).set()
    }
    private func screenPoint(_ event: NSEvent) -> CGPoint? { window.map { $0.convertPoint(toScreen: event.locationInWindow) } }
    override func mouseEntered(with event: NSEvent) { cursor(pressed: false).set() }
    override func mouseExited(with event: NSEvent) { if start == nil { NSCursor.arrow.set() } }

    private func cursor(pressed: Bool) -> NSCursor {
        if handle == .move { return pressed ? .closedHand : .openHand }
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch handle {
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            case .left: position = .left
            case .right: position = .right
            default: position = .bottom
            }
            return .frameResize(position: position, directions: .all)
        }
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}

/// Anyone following the pointer for the persona handles.
protocol PersonaPointerClient: AnyObject {
    func pointerMoved(to point: CGPoint)
}

/// Where the pointer is, for the persona handles and click-through.
protocol PersonaPointerTracking: AnyObject {
    var location: CGPoint { get }
    func add(_ client: PersonaPointerClient)
    func remove(_ client: PersonaPointerClient)
}

/// Follows the pointer while any persona shows, without Accessibility
/// permission: a global monitor sees it over other apps (including through
/// click-through artwork) and a local monitor over Workbench's own windows.
/// No key events are watched.
final class PersonaPointerTracker: PersonaPointerTracking {
    static let shared = PersonaPointerTracker()
    private let clients = NSHashTable<AnyObject>.weakObjects()
    private var monitors: [Any] = []

    var location: CGPoint { NSEvent.mouseLocation }

    func add(_ client: PersonaPointerClient) {
        clients.add(client)
        guard monitors.isEmpty else { return }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in self?.moved() }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in self?.moved(); return event }) { monitors.append(local) }
    }
    func remove(_ client: PersonaPointerClient) {
        clients.remove(client)
        guard clients.allObjects.isEmpty else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
    private func moved() {
        let point = NSEvent.mouseLocation
        for case let client as PersonaPointerClient in clients.allObjects { client.pointerMoved(to: point) }
    }
}
