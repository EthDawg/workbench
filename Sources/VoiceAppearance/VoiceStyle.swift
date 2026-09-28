import AppKit

/// Workbench's one stroke character for a voice: a fine, rounded line in the
/// Workbench accent, quiet at rest, that speech brightens and weights a little
/// and a raised voice lights further. Every voice surface maps the shared
/// `VoiceEnvelope` through these same values; only its geometry differs.
public enum VoiceStyle {
    /// How a stroke reads at one moment.
    public struct Stroke: Equatable, Sendable {
        /// Of the voice colour: quiet at rest, full while a voice is present.
        public var opacity: Double
        /// 0 at rest, 0.5 for a usual voice, 1 raised: how far toward its
        /// heaviest weight the stroke is.
        public var weight: Double
        /// 0...1: the bounded highlight of a raised voice, where a surface has one.
        public var glow: Double
    }

    /// The resting line's opacity: quiet contrast, stronger with Increase Contrast.
    public static func restOpacity(increaseContrast: Bool) -> Double { increaseContrast ? 0.7 : 0.45 }

    /// The stroke for the envelope's current state. With Reduce Motion the
    /// geometry stays fixed: presence alone brightens it, with no weight or glow.
    public static func stroke(_ envelope: VoiceEnvelope, reduceMotion: Bool, increaseContrast: Bool) -> Stroke {
        stroke(intensity: envelope.intensity, presence: envelope.presence, reduceMotion: reduceMotion, increaseContrast: increaseContrast)
    }
    public static func stroke(intensity: Double, presence: Double, reduceMotion: Bool, increaseContrast: Bool) -> Stroke {
        let rest = restOpacity(increaseContrast: increaseContrast)
        if reduceMotion { return Stroke(opacity: rest + (1 - rest) * min(1, max(0, presence)), weight: 0, glow: 0) }
        // Rest to a usual voice brightens and weights; beyond it, a raised voice
        // weights a little more and glows.
        let voice = min(1, max(0, intensity / 0.75)), raised = min(1, max(0, (intensity - 0.75) / 0.25))
        return Stroke(opacity: rest + (1 - rest) * voice, weight: (voice + raised) / 2, glow: raised)
    }

    /// The voice colour over content Workbench does not own, such as a
    /// floating persona over someone's slides: the accent as this appearance
    /// shows it, with a rim of the same accent as the opposite appearance shows
    /// it, so the line reads on light and dark content alike without another hue.
    public static func overlayColors(_ accent: NSColor, in appearance: NSAppearance) -> (line: CGColor, rim: CGColor) {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let opposite = NSAppearance(named: dark ? .aqua : .darkAqua) ?? appearance
        return (resolved(accent, in: appearance), resolved(accent, in: opposite))
    }

    /// `color` as `appearance` draws it.
    public static func resolved(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        var result = color.cgColor
        appearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}
