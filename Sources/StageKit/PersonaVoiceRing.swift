import AppKit
import QuartzCore
import VoiceAppearance

/// Where the voice ring sits around artwork drawn in one rectangle: a ring of
/// small dots just outside the artwork's visible edge, each of which the
/// voice raises into a bar where it has sound. Sizes follow the artwork, so a
/// small corner persona and a large one look alike.
struct PersonaVoiceRingGeometry {
    /// The artwork's visible edge, placed in the window.
    let outline: PersonaArtworkOutline
    /// Clear space between the artwork's edge and the dots.
    let gap: CGFloat
    /// Each dot's size, and each bar's width: a bar is a dot drawn out, with round ends.
    let barWidth: CGFloat
    /// How far apart the dots stand along the edge, centre to centre.
    let barPitch: CGFloat
    /// How far the tallest bar reaches out from its dot.
    let barReach: CGFloat
    /// The dots around the edge.
    let barCount: Int
    /// How far the ring and its rim can reach beyond the artwork's rectangle on each side.
    let outsets: NSEdgeInsets

    /// The rim around each dot and bar, so they read on light and dark content alike.
    static func rimWidth(increaseContrast: Bool) -> CGFloat { increaseContrast ? 1.5 : 1 }
    /// How far out each dot's centre stands from the artwork's edge.
    var foot: CGFloat { gap + barWidth / 2 }

    init(outline unit: PersonaArtworkOutline, artwork rect: CGRect) {
        outline = unit.placed(in: rect)
        let bounds = outline.bounds
        let reference: CGFloat
        switch outline {
        case .circle(_, let radius): reference = radius * 2
        case .roundedRect(let box, _): reference = min(box.width, box.height)
        }
        gap = min(8, max(3, reference * 0.03))
        barWidth = min(3.5, max(2, reference * 0.014))
        barReach = min(34, max(10, reference * 0.14))
        let around = outline.perimeter(outset: gap + barWidth / 2).length
        barCount = max(24, Int(around / (barWidth * 2.3)))
        // The dots share the edge exactly, so the ring closes without a seam.
        barPitch = around / CGFloat(barCount)
        // Bars only grow outward, so nothing ever moves toward the artwork.
        let reach = gap + barWidth + barReach + Self.rimWidth(increaseContrast: true) + 1
        let extent = rect.union(bounds.insetBy(dx: -reach, dy: -reach))
        outsets = NSEdgeInsets(top: max(0, extent.maxY - rect.maxY).rounded(.up), left: max(0, rect.minX - extent.minX).rounded(.up),
                               bottom: max(0, rect.minY - extent.minY).rounded(.up), right: max(0, extent.maxX - rect.maxX).rounded(.up))
    }

    /// Which part of the voice's range the ring shows `around` of the way
    /// round, 0 low ... 1 high. The range wanders up and down as the ring goes
    /// round and returns to where it began, so neighbouring bars show
    /// neighbouring sounds, every sound has several places of different
    /// widths, and the ring has no seam and no one side that always leads.
    static func range(at around: Double) -> Double {
        let turn = 2 * Double.pi * around
        let wander = 0.52 * sin(2 * turn + 0.6) + 0.33 * sin(5 * turn + 2.1) + 0.15 * sin(9 * turn + 4.0)
        return min(1, max(0, 0.5 + 0.56 * wander))
    }

    /// How far bar `bar` reaches for the voice `spectrum` holds: the
    /// strongest sound in its part of the range. 0 is a dot.
    func height(_ bar: Int, _ spectrum: VoiceSpectrum) -> CGFloat {
        let share = spectrum.height(from: Self.range(at: Double(bar) / Double(barCount)), to: Self.range(at: Double(bar + 1) / Double(barCount)))
        return barReach * Self.grain(bar) * CGFloat(share)
    }
    /// Each bar keeps this share of its height, fixed for the bar, so
    /// neighbours never stand as one line repeated, even under a sound that
    /// fills its part of the range evenly.
    static func grain(_ bar: Int) -> CGFloat {
        let noise = sin(Double(bar) * 12.9898) * 43758.5453
        return 0.6 + 0.4 * CGFloat(noise - noise.rounded(.down))
    }

    /// The ring for the voice `spectrum` holds, to stroke `barWidth` wide
    /// with round caps: a dot where the voice has no sound, a bar where it
    /// has. nil draws the resting dots.
    func ring(_ spectrum: VoiceSpectrum?) -> CGPath {
        let path = CGMutablePath()
        let edge = outline.perimeter(outset: foot)
        guard edge.length > 0 else { return path }
        for bar in 0..<barCount {
            let (foot, outward, corner) = edge.point(at: 0.5 + (CGFloat(bar) + 0.5) / CGFloat(barCount))
            // Around a card's corner bars fan apart, so they stand shorter there.
            let height = max(Self.dot, (spectrum.map { self.height(bar, $0) } ?? 0) * (1 - Self.cornerDip * corner))
            path.move(to: foot)
            path.addLine(to: CGPoint(x: foot.x + outward.dx * height, y: foot.y + outward.dy * height))
        }
        return path
    }
    /// How much shorter a bar stands at the middle of a rounded corner.
    static let cornerDip: CGFloat = 0.65
    /// A dot is a bar this short: its round ends alone.
    static let dot: CGFloat = 0.01
}

/// Draws the voice ring behind the artwork, from the shared voice appearance:
/// a quiet ring of dots in the Workbench accent while listening, which a voice
/// brightens and raises into bars that stay where they are, each as tall as
/// the voice's sound in its own part of the range, so the ring's shape is
/// what is being said and it sinks back to dots between words. Its time and
/// brightness come from `VoiceEnvelope` and `VoiceStyle`, its bars from
/// `VoiceSpectrum`. The audience sees a quieter resting ring
/// than the recording trace. A rim of the same accent keeps it readable over
/// light and dark content; Increase Contrast strengthens both. With Reduce
/// Motion the dots hold still and only their brightness says a voice is heard.
final class PersonaVoiceRingLayer: CALayer {
    /// The ring's colour until the presenter chooses another: Workbench's mint.
    static let usualColor = InkColor.mint
    /// The ring's colour, and its rim.
    var colors = VoiceStyle.overlayColors(chosen: PersonaVoiceRingLayer.usualColor.nsColor.cgColor) {
        didSet { applyStyle(); render() }
    }
    var geometry: PersonaVoiceRingGeometry? {
        didSet {
            drawn = nil
            guard geometry != nil else { rim.path = nil; bars.path = nil; return }
            applyStyle(); render()
        }
    }
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { didSet { if reduceMotion != oldValue { drawn = nil; render() } } }
    var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { didSet { if increaseContrast != oldValue { applyStyle(); render() } } }
    /// Measurement only: when the visible state changes, and the display time it
    /// changes at. The native check records it; nothing else depends on it.
    var onVisibleChange: ((VoiceEnvelope.Visible, CFTimeInterval) -> Void)?
    private(set) var state = VoiceEnvelope()
    private(set) var spectrum = VoiceSpectrum()
    private let rim = CAShapeLayer(), bars = CAShapeLayer()
    /// What was last drawn at rest, so a still ring does not redraw every frame.
    private var drawn: VoiceStyle.Stroke?

    override init() {
        super.init()
        for layer in [rim, bars] {
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
        for layer in [rim, bars] { layer.frame = bounds; layer.contentsScale = contentsScale }
    }

    var isMoving: Bool { state.isMoving || spectrum.isMoving }
    var visible: VoiceEnvelope.Visible { state.visible }
    /// How bright it draws now, from the shared style.
    var stroke: VoiceStyle.Stroke { VoiceStyle.outlineStroke(state, reduceMotion: reduceMotion, increaseContrast: increaseContrast) }
    /// How far each bar reaches now, from the top toward the left. 0 is a dot.
    var heights: [CGFloat] {
        guard let geometry, !reduceMotion else { return [] }
        return (0..<geometry.barCount).map { geometry.height($0, spectrum) }
    }

    /// A microphone's buffer holds several frames: the ring lights on the
    /// newest, and its bars play each in turn so syllables keep their shape.
    func receive(_ frames: [PersonaVoiceFrame], at time: CFTimeInterval) {
        state.receive(frames.map(\.sample), at: time)
        spectrum.receive(frames.map { $0.bands.map(Double.init) }, spacing: frames.first?.seconds ?? 0, at: time)
    }
    /// A source that measures only how loud a voice is shows a vowel's spectrum at that energy.
    func receive(_ samples: [VoiceSample], at time: CFTimeInterval) {
        state.receive(samples, at: time)
        spectrum.receive(samples.map { VoiceSpectrum.vowel($0.energy, count: spectrum.count) }, spacing: 0, at: time)
    }

    /// Moves the ring on to `time`, the display time of the next frame.
    /// Returns false once it is at rest with nothing to show.
    @discardableResult func advance(to time: CFTimeInterval) -> Bool {
        let before = state.visible
        let after = state.advance(to: time)
        spectrum.advance(to: time)
        render()
        if after != before { onVisibleChange?(after, time) }
        return isMoving
    }

    /// Back to the resting dots at once.
    func reset() {
        let before = state.visible
        state.reset(); spectrum.reset(); drawn = nil; render()
        if before != .quiet { onVisibleChange?(.quiet, CACurrentMediaTime()) }
    }

    private func applyStyle() {
        drawn = nil
        rim.strokeColor = colors.rim
        bars.strokeColor = colors.line
    }

    private func render() {
        guard let geometry else { return }
        let stroke = self.stroke
        // Moving bars redraw every frame; resting dots only when their brightness changes.
        let moving = spectrum.isMoving && !reduceMotion
        if !moving, let drawn, drawn == stroke { return }
        drawn = moving ? nil : stroke
        let path = geometry.ring(moving ? spectrum : nil)
        let rest = VoiceStyle.outlineRestOpacity(increaseContrast: increaseContrast)
        let lit = (stroke.opacity - rest) / (1 - rest)
        bars.path = path; rim.path = path
        bars.lineWidth = geometry.barWidth
        bars.opacity = Float(stroke.opacity)
        rim.lineWidth = geometry.barWidth + 2 * PersonaVoiceRingGeometry.rimWidth(increaseContrast: increaseContrast)
        rim.opacity = Float((increaseContrast ? 0.95 : 0.7) * (0.3 + 0.7 * lit))
    }
}
