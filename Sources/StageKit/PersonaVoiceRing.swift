import AppKit
import QuartzCore
import VoiceAppearance

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
    /// How far the outline, its rim and its glow can reach beyond the
    /// artwork's rectangle on each side.
    let outsets: NSEdgeInsets

    /// The rim each side of the line, so it reads on light and dark content alike.
    static func rimWidth(increaseContrast: Bool) -> CGFloat { increaseContrast ? 1.5 : 1 }
    /// Speech widens the line by this share of its resting width, and a raised voice by as much again.
    static let voiceWidening: CGFloat = 0.45
    /// The line's width for a stroke of the shared style.
    func width(_ stroke: VoiceStyle.Stroke) -> CGFloat { lineWidth * (1 + 2 * Self.voiceWidening * CGFloat(stroke.weight)) }

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
        let reach = gap + maximumWidth + Self.rimWidth(increaseContrast: true) + glowRadius * 1.5 + 1
        let extent = rect.union(bounds.insetBy(dx: -reach, dy: -reach))
        outsets = NSEdgeInsets(top: max(0, extent.maxY - rect.maxY).rounded(.up), left: max(0, rect.minX - extent.minX).rounded(.up),
                               bottom: max(0, rect.minY - extent.minY).rounded(.up), right: max(0, extent.maxX - rect.maxX).rounded(.up))
    }

    /// The centre line of a stroke `width` wide whose inner edge keeps the gap.
    func path(width: CGFloat) -> CGPath { outline.path(outset: gap + width / 2) }
}

/// Draws the voice outline behind the artwork, from the shared voice
/// appearance: a quiet, still line in the Workbench accent while listening,
/// which a voice brightens and weights outward, with the bounded glow for a
/// raised voice. Its time and stroke come from `VoiceEnvelope` and
/// `VoiceStyle`, exactly as the toolbar's voice trace does; only the geometry
/// differs. A rim of the same accent keeps it readable over light and dark
/// content; Increase Contrast strengthens both. With Reduce Motion its width
/// holds still and only its brightness says a voice is heard.
final class PersonaVoiceRingLayer: CALayer {
    /// The voice colour as this persona's appearance shows it, and its rim.
    var colors = VoiceStyle.overlayColors(WorkbenchPalette.nativeAccent, in: NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()) {
        didSet { applyStyle(); render() }
    }
    var geometry: PersonaVoiceRingGeometry? {
        didSet {
            drawn = nil
            guard geometry != nil else { rim.path = nil; line.path = nil; line.shadowPath = nil; return }
            applyStyle(); render()
        }
    }
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { didSet { if reduceMotion != oldValue { drawn = nil; render() } } }
    var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { didSet { if increaseContrast != oldValue { applyStyle(); render() } } }
    /// Measurement only: when the visible state changes, and the display time it
    /// changes at. The native check records it; nothing else depends on it.
    var onVisibleChange: ((VoiceEnvelope.Visible, CFTimeInterval) -> Void)?
    private(set) var state = VoiceEnvelope()
    private let rim = CAShapeLayer(), line = CAShapeLayer()
    /// What was last drawn, so a steady voice does not redraw every frame.
    private var drawn: (stroke: VoiceStyle.Stroke, width: CGFloat)?

    override init() {
        super.init()
        for layer in [rim, line] {
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
        for layer in [rim, line] { layer.frame = bounds; layer.contentsScale = contentsScale }
    }

    var isMoving: Bool { state.isMoving }
    var visible: VoiceEnvelope.Visible { state.visible }
    /// The stroke it draws now, from the shared style.
    var stroke: VoiceStyle.Stroke { VoiceStyle.stroke(state, reduceMotion: reduceMotion, increaseContrast: increaseContrast) }

    func receive(_ frames: [PersonaVoiceFrame], at time: CFTimeInterval) { state.receive(frames.map(\.sample), at: time) }
    func receive(_ samples: [VoiceSample], at time: CFTimeInterval) { state.receive(samples, at: time) }

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
        rim.strokeColor = colors.rim
        line.strokeColor = colors.line; line.shadowColor = colors.line
    }

    private func render() {
        guard let geometry else { return }
        let stroke = self.stroke, width = geometry.width(stroke)
        if let drawn, drawn.stroke == stroke, drawn.width == width { return }
        drawn = (stroke, width)
        let path = geometry.path(width: width)
        let rest = VoiceStyle.restOpacity(increaseContrast: increaseContrast)
        let lit = (stroke.opacity - rest) / (1 - rest)
        line.path = path; rim.path = path
        line.lineWidth = width
        line.opacity = Float(stroke.opacity)
        rim.lineWidth = width + 2 * PersonaVoiceRingGeometry.rimWidth(increaseContrast: increaseContrast)
        rim.opacity = Float((increaseContrast ? 0.95 : 0.7) * (0.8 + 0.2 * lit))
        line.shadowRadius = geometry.glowRadius
        line.shadowOpacity = Float(0.9 * stroke.glow)
        line.shadowPath = stroke.glow > 0 ? path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10) : nil
    }
}
