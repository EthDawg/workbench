import AppKit
import QuartzCore
import SwiftUI

/// The compact voice trace's geometry: a 4-point recording dot, a 4-point gap,
/// and a short continuous trace at most 24 × 10 points whose three shallow
/// rounded lobes rise and fall with the voice in place. They never travel
/// sideways or move on their own, and in silence the trace is a thin line.
public enum VoiceTraceGeometry {
    /// The trace's box.
    public static let trace = CGSize(width: 24, height: 10)
    /// The recording dot, and the gap between it and the trace.
    public static let dot: CGFloat = 4, gap: CGFloat = 4
    /// The whole mark: dot, gap and trace.
    public static let size = CGSize(width: dot + gap + trace.width, height: trace.height)
    /// The stroke at rest, and at its heaviest for a raised voice.
    public static let stroke: CGFloat = 1.5, heaviest: CGFloat = 1.9
    /// How far the tallest lobe reaches from the centre line: shallow, and
    /// with the heaviest stroke's round ends well inside the box, so no peak
    /// is ever clipped.
    public static let reach: CGFloat = 3
    /// With Reduce Motion the lobes hold still at this share of their reach.
    public static let stillShare: CGFloat = 0.5
    /// How the trace's weight follows the shared stroke.
    public static func width(_ stroke: VoiceStyle.Stroke) -> CGFloat { Self.stroke + (heaviest - Self.stroke) * CGFloat(stroke.weight) }
    /// How far its lobes reach for the envelope's state.
    public static func amplitude(_ envelope: VoiceEnvelope, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? reach * stillShare : reach * CGFloat(min(1, max(0, envelope.intensity)))
    }

    /// The dot and trace boxes for the mark centred in `bounds`.
    public static func layout(in bounds: CGRect) -> (dot: CGRect, trace: CGRect) {
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        let dotBox = CGRect(x: origin.x, y: bounds.midY - dot / 2, width: dot, height: dot)
        return (dotBox, CGRect(origin: CGPoint(x: origin.x + dot + gap, y: origin.y), size: trace))
    }

    /// The lobes' shape across the trace, `u` from 0 to 1: a shallow dip, a
    /// taller rise in the middle and a shallow dip, meeting the centre line
    /// at both ends. The middle lobe reaches 1.
    public static func shape(_ u: CGFloat) -> CGFloat {
        let u = min(1, max(0, u))
        return -sin(3 * .pi * u) * pow(sin(.pi * u), 0.6)
    }

    /// The trace across `box`, reaching `amplitude` points from its centre line.
    /// Stroke it with round caps and joins; 0 draws a straight line.
    public static func path(in box: CGRect, amplitude: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let inset = heaviest / 2, left = box.minX + inset, span = max(0, box.width - 2 * inset)
        let steps = 96
        for step in 0...steps {
            let u = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: left + span * u, y: box.midY + amplitude * shape(u))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// The compact voice trace for a capture in progress: the recording dot and the
/// trace, drawn from the recorder's own level through the shared envelope and
/// stroke. It takes no clicks and no focus, keeps its size, and updates the
/// display only while the trace is moving: in silence, and whenever the level
/// stops changing, it draws once and rests.
public final class VoiceTraceView: NSView {
    /// The voice colour, resolved for this view's appearance: Workbench's accent.
    public var color: CGColor = NSColor.systemGreen.cgColor { didSet { if color != oldValue { needsDisplay = true } } }
    public var reduceMotion = false { didSet { if reduceMotion != oldValue { needsDisplay = true } } }
    public var increaseContrast = false { didSet { if increaseContrast != oldValue { needsDisplay = true } } }
    /// Measurement only: when the visible state changes, at which display time.
    public var onVisibleChange: ((VoiceEnvelope.Visible, CFTimeInterval) -> Void)?
    public private(set) var envelope = VoiceEnvelope(starvation: nil, response: .input)
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
        if window == nil { link?.invalidate(); link = nil } else if envelope.isMoving { tick() }
    }
    public override func viewDidUnhide() { super.viewDidUnhide(); if envelope.isMoving { tick() } }
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
        if envelope.isMoving { tick() }
    }
    /// Moves the trace on to `time`, the display time of the next frame.
    /// Returns false once it is at rest.
    @discardableResult public func advance(to time: Double) -> Bool {
        // A held voice ends on time even when the level has stopped changing.
        if let ends = meter.holdEnds, time >= ends { envelope.receive([meter.sample(reading, at: time)], at: time) }
        let before = envelope.visible, drawn = (envelope.intensity, envelope.presence)
        let after = envelope.advance(to: time)
        if drawn != (envelope.intensity, envelope.presence) { needsDisplay = true }
        if after != before { onVisibleChange?(after, time) }
        return envelope.isMoving
    }

    /// The stroke it draws now, from the shared style.
    public var stroke: VoiceStyle.Stroke { VoiceStyle.stroke(envelope, reduceMotion: reduceMotion, increaseContrast: increaseContrast) }
    public var lineWidth: CGFloat { VoiceTraceGeometry.width(stroke) }
    public var amplitude: CGFloat { VoiceTraceGeometry.amplitude(envelope, reduceMotion: reduceMotion) }

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
        let stroke = self.stroke
        context.addPath(VoiceTraceGeometry.path(in: layout.trace, amplitude: amplitude))
        context.setStrokeColor(color.copy(alpha: color.alpha * CGFloat(stroke.opacity)) ?? color)
        context.setLineWidth(VoiceTraceGeometry.width(stroke))
        context.setLineCap(.round); context.setLineJoin(.round)
        context.strokePath()
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

/// The compact voice trace for SwiftUI: the recording dot and the trace, fed
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
