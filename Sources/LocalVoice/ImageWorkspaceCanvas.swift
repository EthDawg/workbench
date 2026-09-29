import AppKit
import SwiftUI

struct ImageWorkspaceCanvas: NSViewRepresentable {
    @ObservedObject var editing: ImageWorkspaceEditing
    func makeNSView(context: Context) -> ImageWorkspaceScrollView {
        let view = ImageWorkspaceScrollView(editing: editing); editing.canvas = view; return view
    }
    func updateNSView(_ view: ImageWorkspaceScrollView, context: Context) { view.refresh() }
}

@MainActor
final class ImageWorkspaceScrollView: NSScrollView {
    let canvas: ImageWorkspaceCanvasView
    private var fitting = true
    private var previousSize = CGSize.zero
    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    init(editing: ImageWorkspaceEditing) {
        canvas = ImageWorkspaceCanvasView(editing: editing)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        contentView = ImageWorkspaceClipView()
        backgroundColor = .underPageBackgroundColor; drawsBackground = true
        hasHorizontalScroller = true; hasVerticalScroller = true; autohidesScrollers = true
        allowsMagnification = true; documentView = canvas
        NotificationCenter.default.addObserver(self, selector: #selector(pinched), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var fitScale: CGFloat {
        CaptureImageZoom.fit(image: canvas.frame.size, in: NSScrollView.contentSize(forFrameSize: frame.size,
            horizontalScrollerClass: nil, verticalScrollerClass: nil, borderType: borderType, controlSize: .regular, scrollerStyle: scrollerStyle))
    }
    func refresh() {
        let pixels = SnapRendering.outputSize(image: canvas.editing.imageSize, edit: canvas.editing.displayEdit)
        let size = CaptureImageZoom.actualSize(pixels: pixels, backingScale: scale)
        if size != previousSize {
            previousSize = size; canvas.frame = NSRect(origin: .zero, size: size)
            if fitting { fit() }
        }
        canvas.needsDisplay = true
    }
    func fit() { fitting = true; minMagnification = CaptureImageZoom.smallest(fit: fitScale); maxMagnification = 8; magnification = fitScale; report() }
    func zoom(to value: CGFloat) {
        fitting = false
        minMagnification = CaptureImageZoom.smallest(fit: fitScale); maxMagnification = 8
        let visible = contentView.documentVisibleRect
        setMagnification(CaptureImageZoom.clamp(value, fit: fitScale), centeredAt: NSPoint(x: visible.midX, y: visible.midY)); report()
    }
    private func report() {
        let value = CaptureImageZoom.percent(magnification)
        // AppKit layout can run while SwiftUI is updating this representable.
        DispatchQueue.main.async { [weak self] in if let self, self.canvas.editing.percent != value { self.canvas.editing.percent = value } }
    }
    @objc private func pinched() { fitting = false; report() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); if fitting { fit() } }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); refresh() }
}

private final class ImageWorkspaceClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let size = documentView?.frame.size else { return rect }
        if rect.width > size.width { rect.origin.x = (size.width - rect.width) / 2 }
        if rect.height > size.height { rect.origin.y = (size.height - rect.height) / 2 }
        return rect
    }
}

/// Direct manipulation and export share SnapRendering. Transient drags are
/// drawn here and enter Undo once, on mouse-up.
@MainActor
final class ImageWorkspaceCanvasView: NSView {
    let editing: ImageWorkspaceEditing
    private var start: SnapPoint?
    private var points: [SnapPoint] = []
    private var transient: SnapEdit?
    private var movedMark: SnapMark?
    private var resizeAnchor: SnapPoint?
    private var arrowEndpoint: Int?
    private var movedCrop: SnapCrop?
    private var spaceHeld = false
    private var panStart: CGPoint?
    private var panOrigin = CGPoint.zero
    override var acceptsFirstResponder: Bool { true }
    init(editing: ImageWorkspaceEditing) {
        self.editing = editing; super.init(frame: .zero)
        setAccessibilityRole(.image); setAccessibilityLabel("Image canvas")
        setAccessibilityHelp("Select and drag a mark to move it. Drag a corner to resize. Text can be edited in the details panel. Hold Space and drag to pan.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }
    private var shownEdit: SnapEdit {
        if editing.showingOriginal { return SnapEdit() }
        var edit = transient ?? editing.draft.edit
        if editing.tool == .crop { edit.crop = .full }
        return edit
    }
    private func original(_ point: CGPoint) -> SnapPoint {
        ImageWorkspaceGeometry.originalPoint(CGPoint(x: point.x / max(1, bounds.width), y: point.y / max(1, bounds.height)),
                                              crop: shownEdit.crop, rotation: shownEdit.quarterTurns)
    }
    private func display(_ point: SnapPoint) -> CGPoint {
        let edit = shownEdit, crop = edit.crop
        let x = (point.x - crop.x) / crop.width, y = (point.y - crop.y) / crop.height
        let p: CGPoint
        switch edit.quarterTurns { case 1: p = CGPoint(x: y, y: 1 - x); case 2: p = CGPoint(x: 1 - x, y: 1 - y)
        case 3: p = CGPoint(x: 1 - y, y: x); default: p = CGPoint(x: x, y: y) }
        return CGPoint(x: p.x * bounds.width, y: p.y * bounds.height)
    }
    private func displayRect(_ rect: CGRect) -> CGRect {
        let a = display(.init(x: rect.minX, y: rect.minY)), b = display(.init(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
    private func cropRect(_ crop: SnapCrop) -> CGRect { displayRect(CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)) }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        SnapRendering.draw(editing.image, edit: shownEdit, in: context, size: bounds.size)
        guard !editing.showingOriginal else { return }
        let edit = transient ?? editing.draft.edit
        if editing.tool == .crop {
            let rect = cropRect(edit.crop)
            let path = NSBezierPath(rect: bounds); path.appendRect(rect); path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill(); path.fill()
            context.saveGState(); context.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor); context.setLineWidth(0.5 / zoom)
            for f in [1.0 / 3, 2.0 / 3] {
                context.move(to: CGPoint(x: rect.minX + rect.width * f, y: rect.minY)); context.addLine(to: CGPoint(x: rect.minX + rect.width * f, y: rect.maxY))
                context.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * f)); context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))
            }
            context.strokePath(); context.restoreGState(); selection(rect)
        } else if let mark = edit.marks.first(where: { $0.id == editing.selected }) {
            if mark.kind == .arrow { handles(mark.points.map(display)) }
            else { selection(displayRect(ImageWorkspaceGeometry.bounds(mark))) }
        }
    }
    private func selection(_ rect: CGRect) {
        NSColor.controlAccentColor.setStroke(); let outline = NSBezierPath(rect: rect); outline.lineWidth = 1.5 / zoom; outline.stroke()
        handles(corners(rect))
    }
    private func handles(_ points: [CGPoint]) {
        for p in points {
            let handle = NSBezierPath(roundedRect: CGRect(x: p.x - 4 / zoom, y: p.y - 4 / zoom, width: 8 / zoom, height: 8 / zoom), xRadius: 1 / zoom, yRadius: 1 / zoom)
            NSColor.white.setFill(); handle.fill(); NSColor.controlAccentColor.setStroke(); handle.lineWidth = 1 / zoom; handle.stroke()
        }
    }
    private func corners(_ rect: CGRect) -> [CGPoint] { [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY)] }
    private func oppositeHandle(in rect: CGRect, at p: CGPoint) -> SnapPoint? {
        let pairs = corners(rect)
        for (i, corner) in pairs.enumerated() where hypot(corner.x - p.x, corner.y - p.y) <= 10 / zoom { return original(pairs[i ^ 1]) }
        return nil
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if spaceHeld, let scroll = enclosingScrollView {
            panStart = event.locationInWindow; panOrigin = scroll.contentView.bounds.origin; return
        }
        guard !editing.showingOriginal else { return }
        let p = convert(event.locationInWindow, from: nil), point = original(p)
        start = point; points = [point]
        if editing.tool == .text { editing.addText(at: point); start = nil; return }
        if editing.tool == .select {
            if let mark = editing.selectedMark, mark.kind == .arrow,
               let endpoint = mark.points.firstIndex(where: { let d = display($0); return hypot(d.x - p.x, d.y - p.y) <= 10 / zoom }) {
                movedMark = mark; arrowEndpoint = endpoint; return
            }
            if let mark = editing.selectedMark, mark.kind != .pen, mark.kind != .arrow,
               let anchor = oppositeHandle(in: displayRect(ImageWorkspaceGeometry.bounds(mark)), at: p) {
                movedMark = mark; resizeAnchor = anchor; return
            }
            let mark = editing.draft.edit.marks.reversed().first {
                displayRect(ImageWorkspaceGeometry.bounds($0)).insetBy(dx: -6 / zoom, dy: -6 / zoom).contains(p)
            }
            editing.select(mark?.id); movedMark = mark
        } else if editing.tool == .crop {
            let crop = editing.draft.edit.crop
            resizeAnchor = oppositeHandle(in: cropRect(crop), at: p)
            if resizeAnchor == nil, crop != .full, cropRect(crop).contains(p) { movedCrop = crop }
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if let panStart, let scroll = enclosingScrollView {
            let p = event.locationInWindow
            scroll.contentView.scroll(to: CGPoint(x: panOrigin.x - (p.x - panStart.x) / zoom, y: panOrigin.y - (p.y - panStart.y) / zoom))
            scroll.reflectScrolledClipView(scroll.contentView); return
        }
        guard let start else { return }
        let p = original(convert(event.locationInWindow, from: nil))
        var edit = editing.draft.edit
        if editing.tool == .crop {
            if let crop = movedCrop {
                edit.crop.x = min(1 - crop.width, max(0, crop.x + p.x - start.x))
                edit.crop.y = min(1 - crop.height, max(0, crop.y + p.y - start.y))
            } else {
                let crop = ImageWorkspaceGeometry.crop(from: resizeAnchor ?? start, to: p,
                    aspect: editing.aspect.ratio(image: editing.imageSize, rotation: edit.quarterTurns), image: editing.imageSize)
                if crop.width * editing.imageSize.width >= 2, crop.height * editing.imageSize.height >= 2 { edit.crop = crop }
            }
        } else if let mark = movedMark, let index = edit.marks.firstIndex(where: { $0.id == mark.id }) {
            if let endpoint = arrowEndpoint {
                edit.marks[index].points[endpoint] = p
            } else if let anchor = resizeAnchor {
                let rect = ImageWorkspaceGeometry.crop(from: anchor, to: p, aspect: nil, image: editing.imageSize)
                if rect.width > 0.002, rect.height > 0.002 { edit.marks[index].points = [.init(x: rect.x, y: rect.y), .init(x: rect.x + rect.width, y: rect.y + rect.height)] }
            } else { edit.marks[index] = ImageWorkspaceGeometry.moved(mark, dx: p.x - start.x, dy: p.y - start.y) }
        } else if let kind = SnapMark.Kind(rawValue: editing.tool.rawValue), kind != .text {
            if kind == .pen { if points.count < 19_999 { points.append(p) } } else { points = [start, p] }
            let mark = SnapMark(kind: kind, points: points, colour: editing.colour, width: editing.lineWidth)
            if mark.isValid { edit.marks.append(mark) }
        }
        transient = edit; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let transient { editing.change(transient) }
        resetGesture()
    }
    private func resetGesture() { start = nil; points = []; transient = nil; movedMark = nil; movedCrop = nil; resizeAnchor = nil; arrowEndpoint = nil; panStart = nil; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = true; NSCursor.openHand.set(); return }
        if event.keyCode == 53, start != nil { resetGesture(); return }
        if [51, 117].contains(event.keyCode) { editing.removeSelected(); return }
        if let mark = editing.selectedMark, [123, 124, 125, 126].contains(event.keyCode) {
            let amount = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
            let displayX = event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0
            let displayY = event.keyCode == 125 ? -amount : event.keyCode == 126 ? amount : 0
            let delta = ImageWorkspaceGeometry.originalDelta(x: displayX, y: displayY, rotation: editing.draft.edit.quarterTurns)
            let dx = delta.x, dy = delta.y
            editing.updateSelected { $0 = ImageWorkspaceGeometry.moved(mark, dx: dx / editing.imageSize.width, dy: dy / editing.imageSize.height) }; return
        }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceHeld = false; NSCursor.arrow.set() } else { super.keyUp(with: event) } }
    override func resignFirstResponder() -> Bool { spaceHeld = false; resetGesture(); return super.resignFirstResponder() }
}
