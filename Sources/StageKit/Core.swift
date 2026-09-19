import AppKit

enum DrawingTool: String, CaseIterable, Codable, Identifiable {
    case pen, highlighter, arrow, line, rectangle, ellipse, text, eraser
    var id: String { rawValue }
    var title: String { rawValue == "ellipse" ? "Oval" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .text: return "textformat"
        case .eraser: return "eraser"
        }
    }
}

struct InkColor: Codable, Equatable, Hashable {
    var r: Double; var g: Double; var b: Double
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .systemRed
        self.init(c.redComponent, c.greenComponent, c.blueComponent)
    }
    static let coral = InkColor(1, 0.29, 0.31)
    static let amber = InkColor(1, 0.77, 0.22)
    static let mint = InkColor(0.24, 0.89, 0.66)
    static let blue = InkColor(0.29, 0.62, 1)
    static let violet = InkColor(0.72, 0.48, 1)
    static let white = InkColor(1, 1, 1)
    static let black = InkColor(0.09, 0.11, 0.16)
    static let presets = [coral, amber, mint, blue, violet, white]
}

struct InkPoint: Codable, Equatable {
    var x: Double; var y: Double; var pressure: Double = 1
    var point: CGPoint { CGPoint(x: x, y: y) }
    init(_ point: CGPoint, pressure: Double = 1) {
        x = point.x; y = point.y; self.pressure = max(0.15, min(1, pressure))
    }
}

struct Annotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var tool: DrawingTool
    var color: InkColor
    var width: Double
    var points: [InkPoint]
    var text = ""
    var fontSize: Double = 32
    var created = Date.timeIntervalSinceReferenceDate
    var pressureSensitive = false
    var first: CGPoint { points.first?.point ?? .zero }
    var last: CGPoint { points.last?.point ?? first }
    var rect: CGRect {
        CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
               width: abs(last.x - first.x), height: abs(last.y - first.y))
    }
    var textBounds: CGRect {
        let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)])
        return CGRect(origin: first, size: CGSize(width: max(8, size.width), height: max(fontSize, size.height)))
    }
    var bounds: CGRect {
        if tool == .text { return textBounds.insetBy(dx: -5, dy: -5) }
        let xs = points.map(\.x), ys = points.map(\.y)
        let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                         width: (xs.max() ?? 0) - (xs.min() ?? 0),
                         height: (ys.max() ?? 0) - (ys.min() ?? 0))
        return box.insetBy(dx: -max(width, 24), dy: -max(width, 24))
    }
    func opacity(at time: TimeInterval, fadeDelay: Double?) -> Double {
        guard let delay = fadeDelay else { return 1 }
        return min(1, max(0, 1 - (time - created - delay) / 0.8))
    }
    func hitTest(_ point: CGPoint, radius: Double = 8) -> Bool {
        let tolerance = radius + width / 2
        if tool == .text { return textBounds.insetBy(dx: -radius, dy: -radius).contains(point) }
        if tool == .rectangle {
            let r = rect
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && !r.insetBy(dx: tolerance, dy: tolerance).contains(point)
        }
        if tool == .ellipse {
            let r = rect
            guard r.width > 0, r.height > 0 else { return Geometry.distance(point, first, last) <= tolerance }
            let dx = point.x - r.midX, dy = point.y - r.midY
            let outer = pow(dx / (r.width / 2 + tolerance), 2) + pow(dy / (r.height / 2 + tolerance), 2)
            let rx = r.width / 2 - tolerance, ry = r.height / 2 - tolerance
            let inner = rx > 0 && ry > 0 ? pow(dx / rx, 2) + pow(dy / ry, 2) : 2
            return outer <= 1 && inner >= 1
        }
        if tool == .arrow {
            let head = Geometry.arrowHead(from: first, to: last, width: width)
            if head.contains(where: { Geometry.distance(point, $0, last) <= tolerance }) { return true }
        }
        if points.count < 2 { return hypot(point.x - first.x, point.y - first.y) <= tolerance }
        return zip(points, points.dropFirst()).contains { Geometry.distance(point, $0.point, $1.point) <= tolerance }
    }
}

enum Geometry {
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
    static func constrained(_ p: CGPoint, from start: CGPoint, tool: DrawingTool) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        if tool == .rectangle || tool == .ellipse {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }
    static func arrowHead(from a: CGPoint, to b: CGPoint, width: Double) -> [CGPoint] {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let size = min(max(14, width * 3.5), hypot(b.x - a.x, b.y - a.y) * 0.55)
        return [-0.5, 0.5].map { CGPoint(x: b.x - cos(angle + $0) * size, y: b.y - sin(angle + $0) * size) }
    }
}

/// History is scoped to one canvas. Erasing a drag is one undoable transaction.
final class CanvasHistory {
    private(set) var annotations: [Annotation]
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var transaction: [Annotation]?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    init(_ annotations: [Annotation] = []) { self.annotations = annotations }
    func beginTransaction() { if transaction == nil { transaction = annotations } }
    func endTransaction() {
        guard let before = transaction else { return }
        transaction = nil
        if before != annotations { checkpoint(before) }
    }
    private func checkpoint(_ before: [Annotation]) {
        undoStack.append(before)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    func append(_ annotation: Annotation) {
        if transaction == nil { checkpoint(annotations) }
        annotations.append(annotation)
    }
    func erase(at point: CGPoint, radius: Double) {
        guard let index = annotations.lastIndex(where: { $0.hitTest(point, radius: radius) }) else { return }
        if transaction == nil { checkpoint(annotations) }
        annotations.remove(at: index)
    }
    func clear() {
        guard !annotations.isEmpty else { return }
        checkpoint(annotations); annotations.removeAll()
    }
    func undo() {
        endTransaction()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations); annotations = previous
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations); annotations = next
    }
    func expire(at time: TimeInterval, delay: Double) {
        annotations.removeAll { $0.opacity(at: time, fadeDelay: delay) <= 0 }
        // Expired ink must not be resurrected by an unrelated undo.
        undoStack = undoStack.map { $0.filter { $0.opacity(at: time, fadeDelay: delay) > 0 } }
        redoStack = redoStack.map { $0.filter { $0.opacity(at: time, fadeDelay: delay) > 0 } }
    }
    func pauseFade(by duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        func shifted(_ values: [Annotation]) -> [Annotation] {
            values.map { value in var copy = value; copy.created += duration; return copy }
        }
        annotations = shifted(annotations)
        undoStack = undoStack.map(shifted)
        redoStack = redoStack.map(shifted)
        if let transaction { self.transaction = shifted(transaction) }
    }
}

struct Countdown {
    private(set) var deadline: Date?
    private(set) var remainingWhenPaused: TimeInterval = 300
    private(set) var duration: TimeInterval = 300
    var isRunning: Bool { deadline != nil }
    func remaining(at now: Date = Date()) -> TimeInterval { max(0, deadline?.timeIntervalSince(now) ?? remainingWhenPaused) }
    mutating func start(seconds: TimeInterval, now: Date = Date()) {
        duration = max(1, seconds); remainingWhenPaused = duration; deadline = now.addingTimeInterval(duration)
    }
    mutating func pause(now: Date = Date()) { remainingWhenPaused = remaining(at: now); deadline = nil }
    mutating func resume(now: Date = Date()) {
        guard remainingWhenPaused > 0 else { return }
        deadline = now.addingTimeInterval(remainingWhenPaused)
    }
    mutating func reset(seconds: TimeInterval) { duration = max(1, seconds); remainingWhenPaused = duration; deadline = nil }
    static func formatted(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
