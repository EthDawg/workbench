import AppKit

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Menu-bar items and their menus must remain reachable while annotating.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        ignoresMouseEvents = true; acceptsMouseMovedEvents = true
        animationBehavior = .none
        title = "Workbench canvas"
        setAccessibilityRole(.window)
        setAccessibilitySubrole(.standardWindow)
        setAccessibilityLabel("Workbench screen canvas")
    }
}

enum InkRenderer {
    static func draw(_ annotation: Annotation, opacity: Double = 1) {
        guard opacity > 0, !annotation.points.isEmpty else { return }
        let color = annotation.color.nsColor.withAlphaComponent(opacity * (annotation.tool == .highlighter ? 0.3 : 1))
        color.setStroke(); color.setFill()
        let path = NSBezierPath()
        path.lineWidth = annotation.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch annotation.tool {
        case .text:
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            (annotation.text as NSString).draw(at: annotation.first, withAttributes: [
                .font: NSFont.systemFont(ofSize: annotation.fontSize, weight: .semibold),
                .foregroundColor: color, .paragraphStyle: paragraph
            ])
            return
        case .rectangle: path.appendRect(annotation.rect)
        case .ellipse: path.appendOval(in: annotation.rect)
        case .arrow:
            path.move(to: annotation.first); path.line(to: annotation.last)
            for point in Geometry.arrowHead(from: annotation.first, to: annotation.last, width: annotation.width) {
                path.move(to: point); path.line(to: annotation.last)
            }
        case .line: path.move(to: annotation.first); path.line(to: annotation.last)
        case .pen, .highlighter:
            let points = annotation.points
            if points.count == 1 {
                NSBezierPath(ovalIn: CGRect(x: annotation.first.x - annotation.width / 2, y: annotation.first.y - annotation.width / 2,
                                           width: annotation.width, height: annotation.width)).fill()
                return
            }
            if annotation.pressureSensitive && annotation.tool == .pen {
                for (a, b) in zip(points, points.dropFirst()) {
                    let segment = NSBezierPath(); segment.lineCapStyle = .round
                    segment.lineWidth = annotation.width * (0.25 + 0.75 * (a.pressure + b.pressure) / 2)
                    segment.move(to: a.point); segment.line(to: b.point); segment.stroke()
                }
                return
            }
            path.move(to: points[0].point)
            // Interpolating cubic curves preserve corners and avoid jagged event-to-event lines.
            for i in 0..<(points.count - 1) {
                let p0 = points[max(0, i - 1)].point, p1 = points[i].point
                let p2 = points[i + 1].point, p3 = points[min(points.count - 1, i + 2)].point
                path.curve(to: p2, controlPoint1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                           controlPoint2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            }
        case .eraser: return
        }
        path.stroke()
    }
}

struct ClickRipple {
    var location: CGPoint
    var began: TimeInterval
}

final class AnnotationView: NSView {
    weak var coordinator: AppCoordinator?
    let displayID: String
    var screenFrame: CGRect
    var draft: Annotation?
    private var tracking: NSTrackingArea?
    private var editor: AnnotationTextView?
    private var editorLocked = false
    private var textOrigin = CGPoint.zero
    var pointer = CGPoint(x: -1000, y: -1000)
    var pointerVisible = false
    var ripples: [ClickRipple] = []
    var laserTrail: [(CGPoint, TimeInterval)] = []
    var lastInteraction = Date.timeIntervalSinceReferenceDate
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // The overlay is deliberately nonactivating. Opt into click-through so
    // AppKit delivers the first stroke instead of consuming it to focus the panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        coordinator?.isDrawing == true || board != nil
    }
    var history: CanvasHistory? { coordinator?.history(for: displayID) }
    var board: BoardStyle? { coordinator?.boards[displayID] }
    init(frame: CGRect, displayID: String, screenFrame: CGRect) {
        self.displayID = displayID; self.screenFrame = screenFrame
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.layoutArea)
        setAccessibilityLabel("Drawing canvas. Escape returns to your demo.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func localPoint(_ global: CGPoint) -> CGPoint { CGPoint(x: global.x - screenFrame.minX, y: screenFrame.maxY - global.y) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func resetCursorRects() {
        if coordinator?.isDrawing == true {
            let cursor = coordinator?.tool == .text ? NSCursor.iBeam : NSCursor.crosshair
            addCursorRect(bounds, cursor: cursor)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        guard let app = coordinator else { return }
        let settings = app.settings.value
        if let board {
            BoardImageExport.background(board).setFill()
            dirtyRect.fill()
        }
        let time = Date.timeIntervalSinceReferenceDate
        let fade: Double? = settings.autoFade && board == nil && !app.screenshotHandoffActive ? settings.fadeDelay : nil
        for annotation in history?.annotations ?? [] where annotation.bounds.intersects(dirtyRect) {
            InkRenderer.draw(annotation, opacity: annotation.opacity(at: time, fadeDelay: fade))
        }
        if let draft { InkRenderer.draw(draft) }
        if !app.isDrawing && app.pointerEnabled {
            drawPointer(settings, now: time)
        } else if app.isDrawing && bounds.contains(pointer) && editor == nil {
            drawIndicator(settings, tool: app.tool)
        }
    }
    private func drawIndicator(_ settings: Preferences, tool: DrawingTool) {
        settings.color.nsColor.setStroke(); settings.color.nsColor.setFill()
        switch settings.indicator {
        case .none: return
        case .dot: NSBezierPath(ovalIn: CGRect(x: pointer.x + 9, y: pointer.y + 9, width: 5, height: 5)).fill()
        case .scaled:
            let width = tool == .highlighter ? settings.highlighterWidth : (tool == .eraser ? 24 : settings.lineWidth)
            let path = NSBezierPath(ovalIn: CGRect(x: pointer.x - width / 2, y: pointer.y - width / 2, width: width, height: width))
            path.lineWidth = 1.5; path.stroke()
        case .crosshair:
            let path = NSBezierPath(); path.lineWidth = 1.5
            path.move(to: CGPoint(x: pointer.x - 9, y: pointer.y)); path.line(to: CGPoint(x: pointer.x + 9, y: pointer.y))
            path.move(to: CGPoint(x: pointer.x, y: pointer.y - 9)); path.line(to: CGPoint(x: pointer.x, y: pointer.y + 9)); path.stroke()
        case .tool:
            NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)?.draw(in: CGRect(x: pointer.x + 12, y: pointer.y + 12, width: 18, height: 18))
        }
    }
    private func drawPointer(_ settings: Preferences, now: TimeInterval) {
        let appearance = settings.pointerAppearance, radius = settings.pointerAppearance.radius
        let circle = CGRect(x: pointer.x - radius, y: pointer.y - radius, width: radius * 2, height: radius * 2)
        if pointerVisible {
            appearance.color.nsColor.withAlphaComponent(appearance.opacity).setStroke()
            appearance.color.nsColor.withAlphaComponent(appearance.opacity).setFill()
            switch settings.pointerStyle {
            case .ring:
                let path = NSBezierPath(ovalIn: circle); path.lineWidth = 3; path.stroke()
            case .disc: NSBezierPath(ovalIn: circle).fill()
            case .spotlight:
                let mask = NSBezierPath(rect: bounds); mask.appendOval(in: circle); mask.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(appearance.opacity).setFill(); mask.fill()
            case .laser:
                for (point, began) in laserTrail {
                    let life = max(0, 1 - (now - began) / 0.35)
                    appearance.color.nsColor.withAlphaComponent(appearance.opacity * life * 0.65).setFill()
                    let r = radius * life * 0.75
                    NSBezierPath(ovalIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)).fill()
                }
                appearance.color.nsColor.withAlphaComponent(appearance.opacity).setFill()
                NSBezierPath(ovalIn: circle).fill()
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: circle.insetBy(dx: radius * 0.6, dy: radius * 0.6)).fill()
            }
        }
        for ripple in ripples {
            let progress = min(1, (now - ripple.began) / 0.55)
            let r = 10 + 36 * progress
            appearance.color.nsColor.withAlphaComponent((1 - progress) * 0.8).setStroke()
            let path = NSBezierPath(ovalIn: CGRect(x: ripple.location.x - r, y: ripple.location.y - r, width: r * 2, height: r * 2))
            path.lineWidth = 3 * (1 - progress) + 0.5; path.stroke()
        }
    }
    override func mouseMoved(with event: NSEvent) {
        movePointer(localPoint(NSEvent.mouseLocation)); lastInteraction = Date.timeIntervalSinceReferenceDate
        updateFloatingText()
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { movePointer(CGPoint(x: -1000, y: -1000)) }
    func movePointer(_ next: CGPoint) {
        let radius = max(60, coordinator?.settings.value.pointerAppearance.radius ?? 60) + 6
        let old = CGRect(x: pointer.x - radius, y: pointer.y - radius, width: radius * 2, height: radius * 2)
        pointer = next
        let new = CGRect(x: next.x - radius, y: next.y - radius, width: radius * 2, height: radius * 2)
        if coordinator?.settings.value.pointerStyle == .spotlight { needsDisplay = true }
        else { setNeedsDisplay(old.union(new)) }
    }
    private func inkPoint(_ event: NSEvent) -> InkPoint {
        let pressure = event.subtype == .tabletPoint || event.type == .tabletPoint ? Double(event.pressure) : 1
        return InkPoint(convert(event.locationInWindow, from: nil), pressure: pressure)
    }
    override func mouseDown(with event: NSEvent) {
        guard let app = coordinator, app.isDrawing || board != nil else { return }
        app.activeDisplayID = displayID
        if !app.isDrawing { app.startDrawing(app.tool, latched: true) }
        guard app.isDrawing else { return }
        lastInteraction = Date.timeIntervalSinceReferenceDate
        let point = inkPoint(event)
        if app.tool == .text {
            if editor == nil { startText(at: point.point) }
            if !editorLocked { textOrigin = point.point; editor?.setFrameOrigin(textOrigin); editorLocked = true }
            window?.makeKey(); window?.makeFirstResponder(editor)
            return
        }
        if app.tool == .eraser {
            history?.beginTransaction(); history?.erase(at: point.point, radius: 12); needsDisplay = true
            return
        }
        let settings = app.settings.value
        draft = Annotation(tool: app.tool, color: settings.color,
                           width: app.tool == .highlighter ? settings.highlighterWidth : settings.lineWidth,
                           points: [point], fontSize: settings.fontSize,
                           pressureSensitive: settings.penPressure && event.subtype == .tabletPoint)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let app = coordinator else { return }
        lastInteraction = Date.timeIntervalSinceReferenceDate
        let point = inkPoint(event); movePointer(point.point)
        if app.tool == .eraser { history?.erase(at: point.point, radius: 12); needsDisplay = true; return }
        guard var annotation = draft else { return }
        let oldBounds = annotation.bounds
        if annotation.tool == .pen || annotation.tool == .highlighter {
            if hypot(point.x - annotation.last.x, point.y - annotation.last.y) > 0.6 {
                annotation.points.append(point)
            }
        } else {
            let end = event.modifierFlags.contains(.shift) ? Geometry.constrained(point.point, from: annotation.first, tool: annotation.tool) : point.point
            annotation.points = [annotation.points[0], InkPoint(end)]
        }
        draft = annotation; setNeedsDisplay(oldBounds.union(annotation.bounds))
    }
    override func mouseUp(with event: NSEvent) { finishStroke() }
    override func rightMouseDown(with event: NSEvent) { coordinator?.escape() }
    override func tabletProximity(with event: NSEvent) {
        if event.isEnteringProximity && event.pointingDeviceType == .eraser { coordinator?.startDrawing(.eraser, latched: true) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { coordinator?.escape(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            coordinator?.perform(event.modifierFlags.contains(.shift) ? .redo : .undo); return
        }
        super.keyDown(with: event)
    }
    func finishStroke() {
        if var annotation = draft {
            annotation.created = Date.timeIntervalSinceReferenceDate
            history?.append(annotation); draft = nil
        }
        history?.endTransaction(); coordinator?.canvasChanged(); needsDisplay = true
    }
    func startText(at point: CGPoint) {
        guard editor == nil, let app = coordinator else { return }
        textOrigin = clampedTextOrigin(point)
        let view = AnnotationTextView(frame: CGRect(origin: textOrigin, size: CGSize(width: min(900, bounds.width - textOrigin.x), height: 250)))
        view.backgroundColor = .clear; view.drawsBackground = false; view.isRichText = false
        view.font = .systemFont(ofSize: app.settings.value.fontSize, weight: .semibold)
        view.textColor = app.settings.value.color.nsColor; view.insertionPointColor = app.settings.value.color.nsColor
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: 10000, height: 10000)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.onCommit = { [weak self] in self?.commitText(); self?.startText(at: self?.pointer ?? .zero) }
        view.onEscape = { [weak self] in self?.coordinator?.escape() }
        view.onLock = { [weak self] in self?.editorLocked = true }
        view.onResize = { [weak self] delta in self?.resizeText(delta) }
        editor = view; editorLocked = false; addSubview(view)
        window?.makeKey(); window?.makeFirstResponder(view)
    }
    private func clampedTextOrigin(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(8, point.x), bounds.width - 180), y: min(max(8, point.y), bounds.height - 70))
    }
    func updateFloatingText() {
        guard let editor, !editorLocked else { return }
        textOrigin = clampedTextOrigin(localPoint(NSEvent.mouseLocation)); editor.setFrameOrigin(textOrigin)
    }
    func resizeText(_ delta: Double) {
        guard let app = coordinator else { return }
        app.settings.value.fontSize = max(12, min(144, app.settings.value.fontSize + delta))
        editor?.font = .systemFont(ofSize: app.settings.value.fontSize, weight: .semibold)
    }
    func commitText() {
        guard let editor, let app = coordinator else { return }
        let text = editor.string
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let annotation = Annotation(tool: .text, color: InkColor(editor.textColor ?? app.settings.value.color.nsColor), width: 1,
                                        points: [InkPoint(textOrigin)], text: text, fontSize: editor.font.map { Double($0.pointSize) } ?? app.settings.value.fontSize)
            history?.append(annotation)
        }
        editor.removeFromSuperview(); self.editor = nil; editorLocked = false
        window?.makeFirstResponder(self); coordinator?.canvasChanged(); needsDisplay = true
    }
}

final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onLock: (() -> Void)?
    var onResize: ((Double) -> Void)?
    override func mouseDown(with event: NSEvent) { onLock?(); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) && !hasMarkedText() { onCommit?(); return }
        if event.modifierFlags.contains(.command) {
            if ["+", "="].contains(event.charactersIgnoringModifiers ?? "") { onResize?(2); return }
            if event.charactersIgnoringModifiers == "-" { onResize?(-2); return }
        }
        super.keyDown(with: event)
    }
}
