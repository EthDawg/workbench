import Foundation

/// One moment of a voice, as Workbench's voice appearance shows it: whether a
/// voice is present, and how loud it is against the speaker's usual level.
/// Each source makes these its own way: the Persona analyser from its frames,
/// a recorder from its own level through `VoiceMeter`. The appearance never
/// sees audio.
public struct VoiceSample: Equatable, Sendable {
    /// A voice is present, held through the short gaps between words.
    public var voiced: Bool
    /// About 0.5 for the speaker's usual voice and 1 for a raised one; 0 when
    /// no voice is heard, including the held gaps between words.
    public var level: Double

    public init(voiced: Bool, level: Double) { self.voiced = voiced; self.level = level }

    public static let silent = VoiceSample(voiced: false, level: 0)
    /// Sources hold a voice through gaps this long, so words run together.
    public static let hold = 0.18
}

/// What a voice appearance shows, decided only by received samples and the
/// clock, so the same code runs on screen and in the checks, for every surface
/// that shows a voice. A voice brings it up at once; the end of speech settles
/// it within a fraction of a second; a raised voice lights it further. The
/// Persona outline and the toolbar's voice trace both read this, and differ
/// only in geometry.
///
/// Targets, measured from when samples are received: visible within 150 ms of
/// the first voice, back to rest within 500 ms of the last.
public struct VoiceEnvelope: Equatable, Sendable {
    /// What a person sees: rest, lit by a voice, or lit further by a raised voice.
    public enum Visible: String, Sendable { case quiet, normal, loud }
    /// Intensity at which the change from rest is plainly visible, and at which
    /// the look is back to rest.
    public static let normalAt = 0.3, quietBelow = 0.08
    public static let loudAt = 0.9, loudBelow = 0.82
    /// How long a source that can stop without saying so (a microphone that
    /// goes quiet) may send nothing before the appearance settles.
    public static let starvation = 0.35
    /// Time constants in seconds: up fast so a first syllable shows, down fast
    /// so a pause reads as a pause, and loudness eased so one strong syllable
    /// does not read as a raised voice.
    public static let rise = 0.025, fall = 0.04
    public static let louder = 0.15, softer = 0.4

    /// nil for a source that says itself when it stops, such as a recorder
    /// whose owner clears its level when capture ends.
    public let starvation: Double?
    /// 0 at rest, 1 while a voice is present.
    public private(set) var presence = 0.0
    /// 0 soft ... 0.5 usual ... 1 raised, eased.
    public private(set) var loudness = 0.0
    public private(set) var visible = Visible.quiet
    private var speaking = false
    private var loudnessTarget = 0.0
    private var lastReceipt: Double?
    private var clock: Double?

    public init(starvation: Double? = VoiceEnvelope.starvation) { self.starvation = starvation }

    /// How lit it is: 0 at rest, about 0.75 for a usual voice, 1 raised.
    public var intensity: Double { presence * (0.5 + 0.5 * loudness) }
    /// Still easing or holding a voice: display updates keep running. At rest
    /// nothing moves, so updates stop.
    public var isMoving: Bool { speaking || presence > 0 || loudness > 0 }

    /// Samples measured since the last delivery, received at `time`. The newest
    /// says whether a voice is present; the voiced ones how loud.
    public mutating func receive(_ samples: [VoiceSample], at time: Double) {
        guard let newest = samples.last else { return }
        let resting = !isMoving
        // Waking from rest, the clock starts at this delivery.
        if resting { clock = time }
        lastReceipt = time
        speaking = newest.voiced
        let voiced = samples.filter { $0.voiced && $0.level > 0 }.map(\.level)
        let heard = voiced.isEmpty ? nil : voiced.reduce(0, +) / Double(voiced.count)
        loudnessTarget = speaking ? heard ?? loudnessTarget : 0
        // A first syllable lights at its own loudness; only changes within speech ease.
        if resting && speaking { loudness = loudnessTarget }
    }

    /// Eases toward what was last received. Returns the visible state.
    /// Calling it again for the same time changes nothing.
    @discardableResult public mutating func advance(to time: Double) -> Visible {
        let seconds = clock.map { min(0.1, max(0, time - $0)) } ?? 0
        clock = time
        if let starvation, let lastReceipt, time - lastReceipt > starvation { speaking = false; loudnessTarget = 0 }
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

    /// Back to rest at once.
    public mutating func reset() { self = VoiceEnvelope(starvation: starvation) }
}

/// A recorder's own level as voice samples. The recorders meter their average
/// power over 55 dB as 0...1; sound from about −44 dBFS up counts as a voice,
/// held through the gaps between words for as long as the Persona analyser
/// holds it, and its loudness runs from soft at that threshold, through a
/// usual voice around −28 dBFS, to raised from about −11 dBFS. The recorder
/// keeps its metering; this only reads the level it already publishes.
public struct VoiceMeter: Equatable, Sendable {
    /// Where a voice begins on the recorder's 0...1 scale.
    public static let voiceAt = 0.2
    /// Where a usual and a raised voice sit on that scale.
    public static let usualAt = 0.5, raisedAt = 0.8
    private var heardAt: Double?

    public init() {}

    /// The sample for the recorder's `reading`, received at `time`. nil, when
    /// the recorder has no sample, is silence.
    public mutating func sample(_ reading: Double?, at time: Double) -> VoiceSample {
        guard let reading, reading.isFinite else { heardAt = nil; return .silent }
        if reading >= Self.voiceAt {
            heardAt = time
            let level = 0.5 + (reading - Self.usualAt) / (2 * (Self.raisedAt - Self.usualAt))
            return VoiceSample(voiced: true, level: min(1, max(0, level)))
        }
        if let heardAt, time - heardAt < VoiceSample.hold { return VoiceSample(voiced: true, level: 0) }
        heardAt = nil
        return .silent
    }

    /// When a held voice ends unless a louder reading arrives first.
    public var holdEnds: Double? { heardAt.map { $0 + VoiceSample.hold } }
}
