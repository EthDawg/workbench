import AppKit
import QuartzCore

/// The edge the voice ring hugs, in the artwork's own proportions: x runs 0...1
/// across its width and y runs up its height in the same unit, so a circle
/// stays round at any size. A round badge gets its circle, so a hat or label
/// breaking out of the badge sits in front of the ring; anything else gets the
/// rounded rectangle of its visible pixels.
enum PersonaVoiceOutline: Equatable {
    case circle(center: CGPoint, radius: CGFloat)
    case roundedRect(CGRect, radius: CGFloat)

    /// This outline over artwork drawn in `rect`, which keeps the artwork's shape.
    func placed(in rect: CGRect) -> PersonaVoiceOutline {
        let scale = rect.width
        switch self {
        case .circle(let center, let radius):
            return .circle(center: CGPoint(x: rect.minX + center.x * scale, y: rect.minY + center.y * scale), radius: radius * scale)
        case .roundedRect(let box, let radius):
            return .roundedRect(CGRect(x: rect.minX + box.minX * scale, y: rect.minY + box.minY * scale,
                                       width: box.width * scale, height: box.height * scale), radius: radius * scale)
        }
    }

    /// The outline and a ring colour that belongs to this artwork.
    static func analyze(_ image: CGImage) -> (outline: PersonaVoiceOutline, tint: NSColor) {
        let aspect = CGFloat(image.height) / CGFloat(max(1, image.width))
        let whole = PersonaVoiceOutline.roundedRect(CGRect(x: 0, y: 0, width: 1, height: aspect), radius: 0)
        guard image.width > 0, image.height > 0, let pixels = Pixels(image, longest: 128) else { return (whole, fallbackTint) }
        return (pixels.outline() ?? whole, pixels.tint())
    }

    /// Workbench mint, bright enough to read on dark and light screens.
    static let fallbackTint = NSColor(srgbRed: 0.43, green: 0.89, blue: 0.73, alpha: 1)

    /// A small RGBA copy of the artwork, rows bottom-up like AppKit.
    private struct Pixels {
        let width: Int, height: Int
        let rgba: [UInt8]

        init?(_ image: CGImage, longest: Int) {
            let scale = min(1, CGFloat(longest) / CGFloat(max(image.width, image.height)))
            let columns = max(1, Int((CGFloat(image.width) * scale).rounded()))
            let rows = max(1, Int((CGFloat(image.height) * scale).rounded()))
            var bytes = [UInt8](repeating: 0, count: columns * rows * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                              bytesPerRow: columns * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
                return true
            }
            guard drawn else { return nil }
            width = columns; height = rows; rgba = bytes
        }

        /// Memory holds the top row first; callers count rows from the bottom.
        func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[((height - 1 - y) * width + x) * 4 + 3] }
        func opaque(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && alpha(x, y) >= 128
        }

        func outline() -> PersonaVoiceOutline? {
            var minX = width, minY = height, maxX = -1, maxY = -1
            var edge: [CGPoint] = []
            for y in 0..<height {
                for x in 0..<width where opaque(x, y) {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    if !opaque(x - 1, y) || !opaque(x + 1, y) || !opaque(x, y - 1) || !opaque(x, y + 1) {
                        edge.append(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            let unit = CGFloat(width)
            if let circle = circle(edge, box: box) {
                return .circle(center: CGPoint(x: circle.center.x / unit, y: circle.center.y / unit), radius: circle.radius / unit)
            }
            return .roundedRect(CGRect(x: box.minX / unit, y: box.minY / unit, width: box.width / unit, height: box.height / unit),
                                radius: cornerRadius(box) / unit)
        }

        /// A filled circle that most of the edge follows, found by consensus so
        /// a label or hat breaking out of the badge cannot pull it off centre.
        private func circle(_ edge: [CGPoint], box: CGRect) -> (center: CGPoint, radius: CGFloat)? {
            guard edge.count >= 24 else { return nil }
            let tolerance = max(1.2, 0.015 * CGFloat(max(width, height)))
            let smallest = 0.3 * min(box.width, box.height), largest = 0.75 * max(box.width, box.height)
            var random = SplitMix(seed: 0x9E37_79B9)
            var best: (center: CGPoint, radius: CGFloat, count: Int)?
            for _ in 0..<300 {
                let a = edge[random.next(edge.count)], b = edge[random.next(edge.count)], c = edge[random.next(edge.count)]
                guard let candidate = Self.circumcircle(a, b, c), candidate.radius >= smallest, candidate.radius <= largest else { continue }
                let count = edge.reduce(0) { abs(hypot($1.x - candidate.center.x, $1.y - candidate.center.y) - candidate.radius) <= tolerance ? $0 + 1 : $0 }
                if count > (best?.count ?? 0) { best = (candidate.center, candidate.radius, count) }
            }
            guard let best else { return nil }
            let inliers = edge.filter { abs(hypot($0.x - best.center.x, $0.y - best.center.y) - best.radius) <= tolerance * 1.5 }
            let refined = Self.leastSquaresCircle(inliers) ?? (best.center, best.radius)
            // Most of the way round, filled inside, and mostly within the picture.
            var covered = Set<Int>()
            for point in inliers {
                let angle = atan2(point.y - refined.center.y, point.x - refined.center.x)
                covered.insert(Int(((angle + .pi) / (2 * .pi) * 36).rounded(.down)) % 36)
            }
            guard covered.count >= 18 else { return nil }
            let filled = (0..<72).filter { step in
                let angle = CGFloat(step) / 72 * 2 * .pi
                return opaque(Int(refined.center.x + cos(angle) * refined.radius * 0.8), Int(refined.center.y + sin(angle) * refined.radius * 0.8))
            }.count
            guard filled >= 61 else { return nil }
            // A badge's circle spans the artwork and sits across its middle; the
            // rounded end of a cut-out's shoulders does neither.
            guard refined.radius * 2 >= box.width * 0.8, abs(refined.center.x - box.midX) <= box.width * 0.1 else { return nil }
            let slack = refined.radius * 0.06
            guard refined.center.x - refined.radius >= -slack, refined.center.x + refined.radius <= CGFloat(width) + slack,
                  refined.center.y - refined.radius >= -slack, refined.center.y + refined.radius <= CGFloat(height) + slack
            else { return nil }
            return refined
        }

        /// Walks in from each corner of the visible box to its first opaque pixel.
        private func cornerRadius(_ box: CGRect) -> CGFloat {
            let (x0, y0, x1, y1) = (Int(box.minX), Int(box.minY), Int(box.maxX) - 1, Int(box.maxY) - 1)
            let limit = Int(min(box.width, box.height) / 2)
            let corners = [(x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)]
            let radii = corners.map { corner -> CGFloat in
                var step = 0
                while step < limit && !opaque(corner.0 + corner.2 * step, corner.1 + corner.3 * step) { step += 1 }
                // A corner arc of radius r lies r(√2 − 1) along the diagonal.
                return CGFloat(step) * 2.squareRoot() / (2.squareRoot() - 1)
            }.sorted()
            return min(min(box.width, box.height) / 2, (radii[1] + radii[2]) / 2)
        }

        /// A colour from the artwork itself: its most prominent vivid hue, made
        /// bright enough to read. Skin and muddy photos fall back to mint.
        func tint() -> NSColor {
            var weight = [CGFloat](repeating: 0, count: 24)
            var sums = [(CGFloat, CGFloat, CGFloat)](repeating: (0, 0, 0), count: 24)
            var opaqueCount: CGFloat = 0
            for index in stride(from: 0, to: rgba.count, by: 4) where rgba[index + 3] >= 200 {
                opaqueCount += 1
                let alpha = CGFloat(rgba[index + 3]) / 255
                let (r, g, b) = (CGFloat(rgba[index]) / 255 / alpha, CGFloat(rgba[index + 1]) / 255 / alpha, CGFloat(rgba[index + 2]) / 255 / alpha)
                let high = max(r, g, b), low = min(r, g, b)
                guard high > 0 else { continue }
                let saturation = (high - low) / high
                guard saturation >= 0.35, high >= 0.3, high > low else { continue }
                var hue: CGFloat
                if high == r { hue = (g - b) / (high - low) } else if high == g { hue = 2 + (b - r) / (high - low) } else { hue = 4 + (r - g) / (high - low) }
                hue = (hue / 6).truncatingRemainder(dividingBy: 1); if hue < 0 { hue += 1 }
                // Faces are the commonest colour in a headshot and a poor ring.
                if hue > 10 / 360, hue < 50 / 360, saturation < 0.5 { continue }
                let bin = min(23, Int(hue * 24)), vivid = saturation * high
                weight[bin] += vivid
                sums[bin].0 += r * vivid; sums[bin].1 += g * vivid; sums[bin].2 += b * vivid
            }
            guard opaqueCount > 0, let top = weight.indices.max(by: { weight[$0] < weight[$1] }),
                  weight[top] >= 0.05 * opaqueCount else { return fallbackTint }
            let chosen = [(top + 23) % 24, top, (top + 1) % 24]
            let total = chosen.reduce(0) { $0 + weight[$1] }
            let color = NSColor(srgbRed: chosen.reduce(0) { $0 + sums[$1].0 } / total,
                                green: chosen.reduce(0) { $0 + sums[$1].1 } / total,
                                blue: chosen.reduce(0) { $0 + sums[$1].2 } / total, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return NSColor(hue: hue, saturation: min(0.9, max(0.45, saturation)), brightness: max(0.82, brightness), alpha: 1)
                .usingColorSpace(.sRGB) ?? fallbackTint
        }

        static func circumcircle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> (center: CGPoint, radius: CGFloat)? {
            let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
            guard abs(d) > 1e-6 else { return nil }
            let (a2, b2, c2) = (a.x * a.x + a.y * a.y, b.x * b.x + b.y * b.y, c.x * c.x + c.y * c.y)
            let center = CGPoint(x: (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
                                 y: (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
            return (center, hypot(a.x - center.x, a.y - center.y))
        }

        /// Kåsa's algebraic fit: x² + y² + Dx + Ey + F = 0 by least squares.
        static func leastSquaresCircle(_ points: [CGPoint]) -> (center: CGPoint, radius: CGFloat)? {
            guard points.count >= 3 else { return nil }
            var m = [[Double]](repeating: [0, 0, 0, 0], count: 3)
            for point in points {
                let (x, y) = (Double(point.x), Double(point.y)), z = -(x * x + y * y)
                let row = [x, y, 1.0]
                for i in 0..<3 { for j in 0..<3 { m[i][j] += row[i] * row[j] }; m[i][3] += row[i] * z }
            }
            for column in 0..<3 {
                guard let pivot = (column..<3).max(by: { abs(m[$0][column]) < abs(m[$1][column]) }), abs(m[pivot][column]) > 1e-9 else { return nil }
                m.swapAt(column, pivot)
                for row in 0..<3 where row != column {
                    let factor = m[row][column] / m[column][column]
                    for k in column..<4 { m[row][k] -= factor * m[column][k] }
                }
            }
            let (d, e, f) = (m[0][3] / m[0][0], m[1][3] / m[1][1], m[2][3] / m[2][2])
            let squared = (d * d + e * e) / 4 - f
            guard squared > 0 else { return nil }
            return (CGPoint(x: -d / 2, y: -e / 2), CGFloat(squared.squareRoot()))
        }
    }

    /// Deterministic, so the same artwork always gets the same ring.
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
    }
}

/// Where the ring's bars stand around artwork drawn in one rectangle. Sizes
/// follow the artwork, so a small corner persona and a large one look alike.
struct PersonaVoiceRingGeometry {
    struct Anchor {
        var point: CGPoint
        var normal: CGVector
        /// 0...1 clockwise from the top.
        var turn: CGFloat
    }
    let anchors: [Anchor]
    let barWidth: CGFloat
    let reach: CGFloat
    let lineWidth: CGFloat
    /// The quiet line that shows the ring is on, just outside the artwork's edge.
    let line: CGPath
    /// How far the ring can reach beyond the artwork's rectangle on each side.
    let outsets: NSEdgeInsets

    init(outline unit: PersonaVoiceOutline, artwork rect: CGRect) {
        let outline = unit.placed(in: rect)
        // A circle carries long rays; a card's long straight edges read better
        // with shorter, sparser bars that ripple along them.
        let reference: CGFloat, round: Bool
        switch outline {
        case .circle(_, let radius): reference = radius * 2; round = true
        case .roundedRect(let box, _): reference = min(box.width, box.height); round = false
        }
        barWidth = min(7, max(2, reference * 0.022))
        reach = min(64, max(10, reference * (round ? 0.16 : 0.12)))
        lineWidth = max(1.25, barWidth * 0.42)
        let gap = barWidth * 1.2, spacing = barWidth * (round ? 2.3 : 2.7)
        switch outline {
        case .circle(let center, let radius):
            let ring = radius + gap
            let count = min(120, max(36, Int(2 * .pi * ring / spacing)))
            anchors = (0..<count).map { index in
                let turn = CGFloat(index) / CGFloat(count), angle = .pi / 2 - turn * 2 * .pi
                let normal = CGVector(dx: cos(angle), dy: sin(angle))
                return Anchor(point: CGPoint(x: center.x + normal.dx * ring, y: center.y + normal.dy * ring), normal: normal, turn: turn)
            }
            let lineRadius = radius + gap * 0.45
            line = CGPath(ellipseIn: CGRect(x: center.x - lineRadius, y: center.y - lineRadius, width: lineRadius * 2, height: lineRadius * 2), transform: nil)
        case .roundedRect(let box, let radius):
            // A sharp corner still gets a gentle turn, so no corner is left bare.
            let corner = min(min(box.width, box.height) / 2, max(radius, reference * 0.06))
            anchors = Self.walk(box.insetBy(dx: -gap, dy: -gap), radius: corner + gap, spacing: spacing)
            let lineBox = box.insetBy(dx: -gap * 0.45, dy: -gap * 0.45), lineRadius = min(min(lineBox.width, lineBox.height) / 2, corner + gap * 0.45)
            line = CGPath(roundedRect: lineBox, cornerWidth: lineRadius, cornerHeight: lineRadius, transform: nil)
        }
        var bounds = rect.union(line.boundingBoxOfPath.insetBy(dx: -lineWidth, dy: -lineWidth))
        let tip = reach + barWidth / 2 + 1.5
        for anchor in anchors {
            let end = CGPoint(x: anchor.point.x + anchor.normal.dx * tip, y: anchor.point.y + anchor.normal.dy * tip)
            bounds = bounds.union(CGRect(origin: end, size: .zero))
        }
        outsets = NSEdgeInsets(top: max(0, bounds.maxY - rect.maxY).rounded(.up), left: max(0, rect.minX - bounds.minX).rounded(.up),
                               bottom: max(0, rect.minY - bounds.minY).rounded(.up), right: max(0, bounds.maxX - rect.maxX).rounded(.up))
    }

    /// Evenly spaced points on a rounded rectangle, clockwise from the top centre.
    private static func walk(_ box: CGRect, radius: CGFloat, spacing: CGFloat) -> [Anchor] {
        let r = min(radius, min(box.width, box.height) / 2)
        let straightX = box.width - 2 * r, straightY = box.height - 2 * r, arc = CGFloat.pi / 2 * r
        let perimeter = 2 * straightX + 2 * straightY + 4 * arc
        guard perimeter > 0 else { return [] }
        let count = min(160, max(36, Int(perimeter / spacing)))
        let (left, right, bottom, top) = (box.minX + r, box.maxX - r, box.minY + r, box.maxY - r)
        // Clockwise from the top centre: top, corner, right side, corner, bottom, corner, left side, corner, top.
        let pieces: [(CGFloat, (CGFloat) -> (CGPoint, CGVector))] = [
            (straightX / 2, { s in (CGPoint(x: box.midX + s, y: box.maxY), CGVector(dx: 0, dy: 1)) }),
            (arc, { s in Self.arc(CGPoint(x: right, y: top), r, from: .pi / 2, by: -s / max(r, 0.001)) }),
            (straightY, { s in (CGPoint(x: box.maxX, y: top - s), CGVector(dx: 1, dy: 0)) }),
            (arc, { s in Self.arc(CGPoint(x: right, y: bottom), r, from: 0, by: -s / max(r, 0.001)) }),
            (straightX, { s in (CGPoint(x: right - s, y: box.minY), CGVector(dx: 0, dy: -1)) }),
            (arc, { s in Self.arc(CGPoint(x: left, y: bottom), r, from: -.pi / 2, by: -s / max(r, 0.001)) }),
            (straightY, { s in (CGPoint(x: box.minX, y: bottom + s), CGVector(dx: -1, dy: 0)) }),
            (arc, { s in Self.arc(CGPoint(x: left, y: top), r, from: .pi, by: -s / max(r, 0.001)) }),
            (straightX / 2, { s in (CGPoint(x: left + s, y: box.maxY), CGVector(dx: 0, dy: 1)) })
        ]
        return (0..<count).map { index in
            let turn = CGFloat(index) / CGFloat(count)
            var distance = turn * perimeter
            for (length, point) in pieces {
                if distance <= length {
                    let (position, normal) = point(distance)
                    return Anchor(point: position, normal: normal, turn: turn)
                }
                distance -= length
            }
            let (position, normal) = pieces[pieces.count - 1].1(pieces[pieces.count - 1].0)
            return Anchor(point: position, normal: normal, turn: turn)
        }
    }
    private static func arc(_ center: CGPoint, _ radius: CGFloat, from start: CGFloat, by sweep: CGFloat) -> (CGPoint, CGVector) {
        let angle = start + sweep
        return (CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius), CGVector(dx: cos(angle), dy: sin(angle)))
    }
}

/// Draws the ring behind the artwork: a quiet line while listening, and bars
/// that swell with the presenter's voice. Motion flows around the ring rather
/// than flickering, reads at a meeting app's low frame rate, and stays within
/// a dark edge so it shows over white slides and dark editors alike. Reduce
/// Motion keeps the bars away and lets the line brighten instead.
final class PersonaVoiceRingLayer: CALayer {
    var tint = PersonaVoiceOutline.fallbackTint { didSet { applyStyle() } }
    var geometry: PersonaVoiceRingGeometry? { didSet { applyStyle(); render() } }
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { didSet { render() } }
    var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { didSet { applyStyle() } }
    private let lineEdge = CAShapeLayer(), lineLayer = CAShapeLayer()
    private let barEdge = CAShapeLayer(), bars = CAShapeLayer()
    private var queue: [PersonaVoiceFrame] = []
    private var playhead: Double = 0
    private var starved: Double = 0
    private var target = PersonaVoiceFrame.quiet
    private var level: Float = 0
    private var bands = [Float](repeating: 0, count: PersonaVoiceFrame.bandCount)
    private var phases: (CGFloat, CGFloat, CGFloat) = (0, 2.1, 4.2)

    override init() {
        super.init()
        for layer in [lineEdge, lineLayer, barEdge, bars] {
            layer.fillColor = nil; layer.lineCap = .round; layer.lineJoin = .round
            layer.actions = ["path": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
            addSublayer(layer)
        }
        actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSublayers() {
        super.layoutSublayers()
        for layer in [lineEdge, lineLayer, barEdge, bars] { layer.frame = bounds; layer.contentsScale = contentsScale }
    }

    func enqueue(_ frames: [PersonaVoiceFrame]) {
        queue.append(contentsOf: frames)
        // Never fall behind the voice: keep at most a fifth of a second queued.
        var queued = queue.reduce(0) { $0 + $1.seconds }
        while queued > 0.2, queue.count > 1 { queued -= queue.removeFirst().seconds }
        starved = 0
    }

    /// Back to the quiet line at once.
    func reset() {
        queue.removeAll(); playhead = 0; target = .quiet; level = 0
        bands = Array(repeating: 0, count: PersonaVoiceFrame.bandCount)
        render()
    }

    /// Plays measured frames at the pace they were heard and eases toward them.
    /// Returns false once the ring is quiet and nothing is waiting.
    @discardableResult func advance(by seconds: Double) -> Bool {
        playhead += seconds
        while let next = queue.first, playhead >= next.seconds {
            playhead -= next.seconds; target = queue.removeFirst()
        }
        if queue.isEmpty {
            playhead = 0; starved += seconds
            // A microphone that stops sending lets the ring settle, not freeze.
            if starved > 0.4 { target = .quiet }
        }
        let calm = reduceMotion
        func ease(_ value: Float, _ goal: Float) -> Float {
            let time = goal > value ? (calm ? 0.16 : 0.045) : (calm ? 0.45 : 0.17)
            return value + (goal - value) * Float(1 - exp(-seconds / time))
        }
        level = ease(level, target.level)
        for index in bands.indices { bands[index] = ease(bands[index], index < target.bands.count ? target.bands[index] : 0) }
        let pace = CGFloat(seconds) * (1 + CGFloat(level) * 3)
        phases = (phases.0 + pace * 0.55, phases.1 + pace * 0.8, phases.2 + pace * 1.2)
        render()
        return !queue.isEmpty || target.level > 0 || level > 0.002
    }

    private func applyStyle() {
        guard let geometry else { return }
        let edge = NSColor.black.withAlphaComponent(increaseContrast ? 0.55 : 0.24).cgColor
        lineEdge.strokeColor = edge; barEdge.strokeColor = edge
        lineLayer.strokeColor = tint.cgColor; bars.strokeColor = tint.cgColor
        let line = geometry.lineWidth * (reduceMotion ? 1.6 : 1)
        lineLayer.lineWidth = line; lineEdge.lineWidth = line + 1.5
        bars.lineWidth = geometry.barWidth; barEdge.lineWidth = geometry.barWidth + 1.5
        lineLayer.path = geometry.line; lineEdge.path = geometry.line
    }

    private func render() {
        guard let geometry else { return }
        let loud = CGFloat(level)
        let quietOpacity: CGFloat = increaseContrast ? 0.6 : 0.38
        lineLayer.opacity = Float(quietOpacity + (1 - quietOpacity) * loud)
        lineEdge.opacity = lineLayer.opacity
        guard !reduceMotion, loud > 0.004 else { bars.path = nil; barEdge.path = nil; return }
        let low = CGFloat(bands[0] + bands[1]) / 2, middle = CGFloat(bands[2] + bands[3]) / 2, high = CGFloat(bands[4] + bands[5]) / 2
        let total = max(0.0001, low + middle + high)
        let path = CGMutablePath()
        for (index, anchor) in geometry.anchors.enumerated() {
            // Three slow waves travel around the ring: broad swells for vowels,
            // finer ripples for consonants, turning faster as the voice rises.
            // Their blend is stretched so crests and troughs stay distinct.
            let angle = anchor.turn * 2 * .pi
            let blend = (low * sin(3 * angle + phases.0) + middle * sin(5 * angle - phases.1) + high * sin(9 * angle + phases.2)) / total
            let wave = 0.5 + 0.5 * min(1, max(-1, blend * 1.7))
            let texture = 0.86 + 0.14 * CGFloat((index &* 2_654_435_761) % 1_000) / 1_000
            let length = geometry.reach * loud * (0.18 + 0.82 * wave) * texture
            guard length > 0.5 else { continue }
            path.move(to: anchor.point)
            path.addLine(to: CGPoint(x: anchor.point.x + anchor.normal.dx * length, y: anchor.point.y + anchor.normal.dy * length))
        }
        bars.path = path; barEdge.path = path
    }
}
