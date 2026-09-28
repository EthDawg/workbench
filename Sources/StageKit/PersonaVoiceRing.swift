import AppKit
import QuartzCore

/// Where the voice outline sits around artwork drawn in one rectangle: a
/// continuous line just outside the artwork's visible edge. Sizes follow the
/// artwork, so a small corner persona and a large one look alike.
struct PersonaVoiceRingGeometry {
    /// The artwork's visible edge, placed in the window.
    let outline: PersonaArtworkOutline
    /// Clear space between the artwork's edge and the line's inner edge.
    let gap: CGFloat
    /// The line at rest; speech widens it outward to at most `maximumWidth`.
    let lineWidth: CGFloat
    let maximumWidth: CGFloat
    /// The soft glow around the line when the voice is raised.
    let glowRadius: CGFloat
    /// How far the outline, its dark edge and its glow can reach beyond the
    /// artwork's rectangle on each side.
    let outsets: NSEdgeInsets

    /// The dark edge each side of the line, so it reads on white slides too.
    static func edgeWidth(increaseContrast: Bool) -> CGFloat { increaseContrast ? 1.5 : 1 }
    /// Speech widens the line by this share of its resting width, and a raised voice by as much again.
    static let voiceWidening: CGFloat = 0.45

    init(outline unit: PersonaArtworkOutline, artwork rect: CGRect) {
        outline = unit.placed(in: rect)
        let bounds = outline.bounds
        let reference: CGFloat
        switch outline {
        case .circle(_, let radius): reference = radius * 2
        case .roundedRect(let box, _): reference = min(box.width, box.height)
        }
        lineWidth = min(3, max(1.25, reference * 0.01))
        maximumWidth = lineWidth * (1 + 2 * Self.voiceWidening)
        gap = min(4, max(2, reference * 0.012))
        glowRadius = min(5, max(2.5, reference * 0.015))
        // The line only grows outward, so its inner edge never moves toward the artwork.
        let reach = gap + maximumWidth + Self.edgeWidth(increaseContrast: true) + glowRadius * 1.5 + 1
        let extent = rect.union(bounds.insetBy(dx: -reach, dy: -reach))
        outsets = NSEdgeInsets(top: max(0, extent.maxY - rect.maxY).rounded(.up), left: max(0, rect.minX - extent.minX).rounded(.up),
                               bottom: max(0, rect.minY - extent.minY).rounded(.up), right: max(0, extent.maxX - rect.maxX).rounded(.up))
    }

    /// The centre line of a stroke `width` wide whose inner edge keeps the gap.
    func path(width: CGFloat) -> CGPath { outline.path(outset: gap + width / 2) }
}

/// What the voice outline shows, decided only by received frames and the clock,
/// so the same code runs on screen and in the latency checks. A voice brings
/// the outline up at once; the end of speech settles it within a fraction of a
/// second. A raised voice brightens and widens it further.
struct PersonaVoiceRingState: Equatable {
    /// What a person sees: the resting line, the line lit by a voice, or lit
    /// further by a raised voice.
    enum Visible: String { case quiet, normal, loud }
    /// Intensity at which the change from rest is plainly visible, and at which
    /// the outline is back to its resting look.
    static let normalAt = 0.3, quietBelow = 0.08
    static let loudAt = 0.9, loudBelow = 0.82
    /// Frames that stop arriving settle the outline rather than freeze it.
    static let starvation = 0.35
    /// Time constants in seconds: up fast so a first syllable shows, down fast
    /// so a pause reads as a pause, and loudness eased so one strong syllable
    /// does not read as a raised voice.
    static let rise = 0.025, fall = 0.04
    static let louder = 0.15, softer = 0.4

    /// 0 at rest, 1 while a voice is present.
    private(set) var presence = 0.0
    /// 0 soft ... 0.5 usual ... 1 raised, eased.
    private(set) var loudness = 0.0
    private(set) var visible = Visible.quiet
    private var speaking = false
    private var loudnessTarget = 0.0
    private var lastReceipt: Double?
    private var clock: Double?

    /// How lit the outline is: 0 at rest, about 0.75 for a usual voice, 1 raised.
    var intensity: Double { presence * (0.5 + 0.5 * loudness) }
    /// Still easing or holding a voice: the display link keeps running.
    var isMoving: Bool { speaking || presence > 0 || loudness > 0 }

    /// Frames measured since the last delivery, received at `time`. The newest
    /// frame says whether a voice is present; the voiced ones how loud.
    mutating func receive(_ frames: [PersonaVoiceFrame], at time: Double) {
        guard let newest = frames.last else { return }
        let resting = !isMoving
        // Waking from rest, the clock starts at this delivery.
        if resting { clock = time }
        lastReceipt = time
        speaking = newest.speaking
        let voiced = frames.filter { $0.speaking && $0.level > 0 }.map { Double($0.level) }
        let heard = voiced.isEmpty ? nil : voiced.reduce(0, +) / Double(voiced.count)
        loudnessTarget = speaking ? heard ?? loudnessTarget : 0
        // A first syllable lights at its own loudness; only changes within speech ease.
        if resting && speaking { loudness = loudnessTarget }
    }

    /// Eases toward what was last received. Returns the visible state.
    @discardableResult mutating func advance(to time: Double) -> Visible {
        let seconds = clock.map { min(0.1, max(0, time - $0)) } ?? 0
        clock = time
        if let lastReceipt, time - lastReceipt > Self.starvation { speaking = false; loudnessTarget = 0 }
        func ease(_ value: Double, _ goal: Double, up: Double, down: Double) -> Double {
            let next = value + (goal - value) * (1 - exp(-seconds / (goal > value ? up : down)))
            return abs(next - goal) < 0.002 ? goal : next
        }
        presence = ease(presence, speaking ? 1 : 0, up: Self.rise, down: Self.fall)
        loudness = ease(loudness, loudnessTarget, up: Self.louder, down: Self.softer)
        if !speaking && presence == 0 { loudness = 0; loudnessTarget = 0 }
        let lit = intensity
        switch visible {
        case .quiet: if lit >= Self.normalAt { visible = lit >= Self.loudAt ? .loud : .normal }
        case .normal: if lit < Self.quietBelow { visible = .quiet } else if lit >= Self.loudAt { visible = .loud }
        case .loud: if lit < Self.quietBelow { visible = .quiet } else if lit < Self.loudBelow { visible = .normal }
        }
        return visible
    }

    mutating func reset() { self = PersonaVoiceRingState() }
}

/// Draws the voice outline behind the artwork: a quiet, still line while
/// listening that brightens and gently thickens outward while the presenter
/// speaks, with a soft glow for a raised voice. Nothing travels around it, so
/// Reduce Motion needs no other treatment. A dark edge keeps it readable over
/// white slides and dark editors alike; Increase Contrast strengthens it.
final class PersonaVoiceRingLayer: CALayer {
    var tint = PersonaArtworkOutline.fallbackTint { didSet { applyStyle(); render() } }
    var geometry: PersonaVoiceRingGeometry? {
        didSet {
            drawn = nil
            guard geometry != nil else { edge.path = nil; line.path = nil; line.shadowPath = nil; return }
            applyStyle(); render()
        }
    }
    /// The outline never travels, so Reduce Motion changes nothing; kept so the
    /// preference is visibly considered.
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { didSet { if increaseContrast != oldValue { applyStyle(); render() } } }
    /// Measurement only: when the visible state changes, and the display time it
    /// changes at. The native check records it; nothing else depends on it.
    var onVisibleChange: ((PersonaVoiceRingState.Visible, CFTimeInterval) -> Void)?
    private(set) var state = PersonaVoiceRingState()
    private let edge = CAShapeLayer(), line = CAShapeLayer()
    /// What was last drawn, so a steady voice does not redraw every frame.
    private var drawn: (intensity: Double, width: CGFloat)?

    override init() {
        super.init()
        for layer in [edge, line] {
            layer.fillColor = nil; layer.lineCap = .round; layer.lineJoin = .round
            layer.actions = ["path": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull(),
                             "shadowPath": NSNull(), "shadowOpacity": NSNull(), "shadowRadius": NSNull(), "shadowColor": NSNull()]
            addSublayer(layer)
        }
        line.shadowOffset = .zero
        actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSublayers() {
        super.layoutSublayers()
        for layer in [edge, line] { layer.frame = bounds; layer.contentsScale = contentsScale }
    }

    var isMoving: Bool { state.isMoving }
    var visible: PersonaVoiceRingState.Visible { state.visible }

    func receive(_ frames: [PersonaVoiceFrame], at time: CFTimeInterval) { state.receive(frames, at: time) }

    /// Moves the outline on to `time`, the display time of the next frame.
    /// Returns false once it is at rest with nothing to show.
    @discardableResult func advance(to time: CFTimeInterval) -> Bool {
        let before = state.visible
        let after = state.advance(to: time)
        render()
        if after != before { onVisibleChange?(after, time) }
        return state.isMoving
    }

    /// Back to the resting line at once.
    func reset() {
        let before = state.visible
        state.reset(); render()
        if before != .quiet { onVisibleChange?(.quiet, CACurrentMediaTime()) }
    }

    private func applyStyle() {
        drawn = nil
        edge.strokeColor = NSColor.black.withAlphaComponent(increaseContrast ? 0.55 : 0.3).cgColor
        line.strokeColor = tint.cgColor; line.shadowColor = tint.cgColor
    }

    private func render() {
        guard let geometry else { return }
        if let drawn, drawn.intensity == state.intensity, drawn.width == geometry.lineWidth { return }
        drawn = (state.intensity, geometry.lineWidth)
        let lit = CGFloat(state.intensity)
        // Rest to a usual voice brightens and widens; beyond it, a raised voice
        // widens a little more and glows.
        let voice = min(1, lit / 0.75), raised = max(0, (lit - 0.75) / 0.25)
        let width = geometry.lineWidth * (1 + PersonaVoiceRingGeometry.voiceWidening * (voice + raised))
        let path = geometry.path(width: width)
        let rest: CGFloat = increaseContrast ? 0.7 : 0.45
        line.path = path; edge.path = path
        line.lineWidth = width
        line.opacity = Float(rest + (1 - rest) * voice)
        edge.lineWidth = width + 2 * PersonaVoiceRingGeometry.edgeWidth(increaseContrast: increaseContrast)
        edge.opacity = Float(0.8 + 0.2 * voice)
        line.shadowRadius = geometry.glowRadius
        line.shadowOpacity = Float(0.9 * raised)
        line.shadowPath = raised > 0 ? path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10) : nil
    }
}
