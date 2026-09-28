import AppKit

/// The visible edge of a persona's artwork, in the artwork's own proportions:
/// x runs 0...1 across its width and y runs up its height in the same unit, so
/// a circle stays round at any size. The voice outline follows it, and so do
/// the move and resize handles, so both agree with what the audience sees. A
/// round badge gets its circle, so a hat or label breaking out of the badge
/// sits in front of the outline; anything else gets the rounded rectangle of
/// its visible pixels. An appearance that knows its own shape can pass it in
/// instead of measuring the pixels.
enum PersonaArtworkOutline: Equatable {
    case circle(center: CGPoint, radius: CGFloat)
    case roundedRect(CGRect, radius: CGFloat)

    /// This outline over artwork drawn in `rect`, which keeps the artwork's shape.
    func placed(in rect: CGRect) -> PersonaArtworkOutline {
        let scale = rect.width
        switch self {
        case .circle(let center, let radius):
            return .circle(center: CGPoint(x: rect.minX + center.x * scale, y: rect.minY + center.y * scale), radius: radius * scale)
        case .roundedRect(let box, let radius):
            return .roundedRect(CGRect(x: rect.minX + box.minX * scale, y: rect.minY + box.minY * scale,
                                       width: box.width * scale, height: box.height * scale), radius: radius * scale)
        }
    }

    /// The smallest rectangle holding the outline.
    var bounds: CGRect {
        switch self {
        case .circle(let center, let radius): return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case .roundedRect(let box, _): return box
        }
    }

    /// The outline moved outward by `distance`, as a path. A rectangle's corners
    /// round by the same distance, as a true offset does.
    func path(outset distance: CGFloat) -> CGPath {
        switch self {
        case .circle(let center, let radius):
            let r = max(0, radius + distance)
            return CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
        case .roundedRect(let box, let radius):
            let grown = box.insetBy(dx: -distance, dy: -distance)
            guard grown.width > 0, grown.height > 0 else { return CGPath(rect: .zero, transform: nil) }
            let corner = min(min(grown.width, grown.height) / 2, max(0, radius + distance))
            return CGPath(roundedRect: grown, cornerWidth: corner, cornerHeight: corner, transform: nil)
        }
    }

    /// Whether a point lies on the visible artwork: inside the circle, or inside
    /// the rounded rectangle including its rounded corners.
    func contains(_ point: CGPoint) -> Bool {
        switch self {
        case .circle(let center, let radius):
            return hypot(point.x - center.x, point.y - center.y) <= radius
        case .roundedRect(let box, let radius):
            guard box.contains(point) else { return false }
            let r = min(radius, min(box.width, box.height) / 2)
            guard r > 0 else { return true }
            let x = min(max(point.x, box.minX + r), box.maxX - r), y = min(max(point.y, box.minY + r), box.maxY - r)
            return hypot(point.x - x, point.y - y) <= r
        }
    }

    /// The outline and a colour that belongs to this artwork.
    static func analyze(_ image: CGImage) -> (outline: PersonaArtworkOutline, tint: NSColor) {
        let aspect = CGFloat(image.height) / CGFloat(max(1, image.width))
        let whole = PersonaArtworkOutline.roundedRect(CGRect(x: 0, y: 0, width: 1, height: aspect), radius: 0)
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

        func outline() -> PersonaArtworkOutline? {
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
                // Faces are the commonest colour in a headshot and a poor outline.
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

    /// Deterministic, so the same artwork always gets the same outline.
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
