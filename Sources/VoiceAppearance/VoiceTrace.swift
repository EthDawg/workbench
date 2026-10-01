import AppKit
import QuartzCore
import SwiftUI

/// The compact voice trace's geometry: a 4-point recording dot, a 4-point gap,
/// and a short waveform of seven rounded bars in at most 28 × 12 points,
/// tallest in the middle and thinning out to each side. The bars are the
/// voice itself: the middle one shows what the microphone hears now and each
/// bar further out what it heard a moment before, so every syllable swells
/// from the middle and runs out to both ends. In silence the bars rest as a
/// row of small dots, and nothing moves on its own.
public enum VoiceTraceGeometry {
    /// The trace's box.
    public static let trace = CGSize(width: 28, height: 12)
    /// The recording dot, and the gap between it and the trace.
    public static let dot: CGFloat = 4, gap: CGFloat = 4
    /// The whole mark: dot, gap and trace.
    public static let size = CGSize(width: dot + gap + trace.width, height: trace.height)
    /// The bars, each this wide, with round ends. At rest each is a dot of this size.
    public static let bars = 7
    public static let barWidth: CGFloat = 2
    /// How long a syllable takes to run from the middle to either end, in seconds.
    public static let travel = 0.14
    /// How much of the box's height each bar may take: all of it in the
    /// middle, thinning out to the sides.
    public static let taper: [CGFloat] = [0.3, 0.55, 0.82, 1, 0.82, 0.55, 0.3]
    /// A waveform's grain: neighbouring bars differ as a voice's own do, and
    /// the difference drifts along the row so no pattern repeats.
    public static let grain = [VoiceWave.Harmonic(cycles: 3.1, speed: 2.3, weight: 0.6),
                               VoiceWave.Harmonic(cycles: 7.3, speed: -3.1, weight: 0.4, offset: 1.3)]
    /// How much of a bar's height the grain may take away.
    public static let grainDepth = 0.45
    /// With Reduce Motion the bars hold this share of their tapered height: a still waveform.
    public static let stillShare: CGFloat = 0.6

    /// The dot and trace boxes for the mark centred in `bounds`.
    public static func layout(in bounds: CGRect) -> (dot: CGRect, trace: CGRect) {
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        let dotBox = CGRect(x: origin.x, y: bounds.midY - dot / 2, width: dot, height: dot)
        return (dotBox, CGRect(origin: CGPoint(x: origin.x + dot + gap, y: origin.y), size: trace))
    }

    /// Each bar's height for the voice `wave` holds, first beside the dot:
    /// from a dot in silence to its share of the box for the loudest voice.
    public static func heights(_ wave: VoiceWave, reduceMotion: Bool) -> [CGFloat] {
        if reduceMotion { return taper.map { max(barWidth, trace.height * $0 * stillShare) } }
        return (0..<bars).map { bar in
            let along = Double(bar) / Double(bars - 1)
            // 0 in the middle, 1 at either end.
            let out = abs(2 * along - 1)
            let grain = 1 - grainDepth + grainDepth * wave.shape(Self.grain, at: along)
            return max(barWidth, trace.height * taper[bar] * CGFloat(wave.level(ago: out * travel) * grain))
        }
    }

    /// The bars across `box` at `heights`, centred on its middle line. Fill it.
    public static func path(in box: CGRect, heights: [CGFloat]) -> CGPath {
        let path = CGMutablePath()
        let pitch = heights.count > 1 ? (box.width - barWidth) / CGFloat(heights.count - 1) : 0
        for (bar, height) in heights.enumerated() {
            let height = min(box.height, max(barWidth, height))
            let rect = CGRect(x: box.minX + CGFloat(bar) * pitch, y: box.midY - height / 2, width: barWidth, height: height)
            path.addRoundedRect(in: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
        }
        return path
    }
}

/// The compact voice trace for a capture in progress: the recording dot and the
/// waveform, drawn from the recorder's own level through the shared envelope,
/// wave and brightness. It takes no clicks and no focus, keeps its size, and
/// updates the display only while there is a voice to show: in silence it
/// draws its row of dots once and rests.
public final class VoiceTraceView: NSView {
    /// The voice colour, resolved for this view's appearance: Workbench's accent.
    public var color: CGColor = NSColor.systemGreen.cgColor { didSet { if color != oldValue { needsDisplay = true } } }
    public var reduceMotion = false { didSet { if reduceMotion != oldValue { needsDisplay = true } } }
    public var increaseContrast = false { didSet { if increaseContrast != oldValue { needsDisplay = true } } }
    /// Measurement only: when the visible state changes, at which display time.
    public var onVisibleChange: ((VoiceEnvelope.Visible, CFTimeInterval) -> Void)?
    public private(set) var envelope = VoiceEnvelope(starvation: nil, response: .input)
    public private(set) var wave = VoiceWave(starvation: nil, response: .input)
    private var meter = VoiceMeter()
    private var reading: Double?
    private var link: CADisplayLink?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var intrinsicContentSize: NSSize { VoiceTraceGeometry.size }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var acceptsFirstResponder: Bool { false }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { link?.invalidate(); link = nil } else if isMoving { tick() }
    }
    public override func viewDidUnhide() { super.viewDidUnhide(); if isMoving { tick() } }
    /// A voice is still being shown: lit, moving or settling.
    public var isMoving: Bool { envelope.isMoving || wave.isMoving }
    /// Display updates run only while the trace moves and can be seen.
    private var onScreen: Bool { window?.isVisible == true && !isHiddenOrHasHiddenAncestor }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    /// The recorder's latest level, 0...1, or nil when it has none.
    public func show(level: Double?) { receive(level: level, at: CACurrentMediaTime()) }
    public func receive(level: Double?, at time: Double) {
        reading = level
        receive([meter.sample(level, at: time)], at: time)
    }
    public func receive(_ samples: [VoiceSample], at time: Double) {
        envelope.receive(samples, at: time)
        wave.receive(samples.map(\.energy), spacing: 0, at: time)
        if isMoving { tick() }
    }
    /// Moves the trace on to `time`, the display time of the next frame.
    /// Returns false once it is at rest.
    @discardableResult public func advance(to time: Double) -> Bool {
        // A held voice ends on time even when the level has stopped changing.
        if let ends = meter.holdEnds, time >= ends { envelope.receive([meter.sample(reading, at: time)], at: time) }
        let before = envelope.visible, drawn = (envelope.intensity, envelope.presence), waving = wave.isMoving
        let after = envelope.advance(to: time)
        wave.advance(to: time)
        // A moving waveform redraws every frame; with Reduce Motion only its brightness changes.
        if drawn != (envelope.intensity, envelope.presence) || (waving && !reduceMotion) { needsDisplay = true }
        if after != before { onVisibleChange?(after, time) }
        return isMoving
    }

    /// How bright it draws now, from the shared style.
    public var stroke: VoiceStyle.Stroke { VoiceStyle.stroke(envelope, reduceMotion: reduceMotion, increaseContrast: increaseContrast) }
    /// Each bar's height now, first beside the dot.
    public var heights: [CGFloat] { VoiceTraceGeometry.heights(wave, reduceMotion: reduceMotion) }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        render(in: context)
    }
    /// Draws the dot and trace for the current state into `context`, in this view's bounds.
    public func render(in context: CGContext) {
        let layout = VoiceTraceGeometry.layout(in: bounds)
        context.saveGState()
        context.setFillColor(VoiceStyle.resolved(.systemRed, in: effectiveAppearance))
        context.fillEllipse(in: layout.dot)
        context.addPath(VoiceTraceGeometry.path(in: layout.trace, heights: heights))
        context.setFillColor(color.copy(alpha: color.alpha * CGFloat(stroke.opacity)) ?? color)
        context.fillPath()
        context.restoreGState()
    }

    private func tick() {
        guard onScreen else { return }
        if link == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }
    @objc private func step(_ link: CADisplayLink) {
        if !advance(to: link.targetTimestamp) || !onScreen { link.isPaused = true }
    }
}

/// The compact voice trace for SwiftUI: the recording dot and the waveform, fed
/// the recorder's own level. Pass the toolbar's accent; the trace resolves it
/// for the current appearance, and follows Reduce Motion and Increase Contrast.
public struct VoiceTrace: NSViewRepresentable {
    /// The recorder's latest level, 0...1, or nil when it has none.
    public var level: Double?
    public var accent: Color

    public init(level: Double?, accent: Color) { self.level = level; self.accent = accent }

    public func makeNSView(context: Context) -> VoiceTraceView {
        VoiceTraceView(frame: CGRect(origin: .zero, size: VoiceTraceGeometry.size))
    }
    public func updateNSView(_ view: VoiceTraceView, context: Context) {
        view.color = accent.resolve(in: context.environment).cgColor
        view.reduceMotion = context.environment.accessibilityReduceMotion
        view.increaseContrast = context.environment.colorSchemeContrast == .increased
        view.show(level: level)
    }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: VoiceTraceView, context: Context) -> CGSize? {
        VoiceTraceGeometry.size
    }
}
