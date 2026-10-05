import Foundation

/// The motion of a voice, for every surface that draws one: a waveform that
/// flows while someone speaks, as tall as the voice is at that moment, and
/// that settles to stillness in silence. The waveform is made of the voice
/// itself. Each bar shows the energy heard a moment before the bar nearer the
/// waveform's start, so a syllable enters there and runs outward along the
/// row, and no two moments look alike. Nothing moves on its own: without a voice there is no
/// height, the clock stops and display updates rest.
///
/// It is decided only by received energies and the clock, so the same code
/// runs on screen and in the checks. The toolbar's trace and the Persona
/// outline share it; only their geometry differs.
public struct VoiceWave: Equatable, Sendable {
    /// The input trace follows each syllable promptly for the person speaking.
    /// A Persona's waveform falls a little more slowly, so an audience
    /// watching a shared screen sees it flow and not flicker.
    public enum Response: Sendable { case input, speaker }
    /// How much of the voice is remembered, in seconds: the longest a
    /// waveform's far end can trail its near end.
    public static let memory = 0.2
    /// Time constants in seconds: up fast so a syllable shows as it is spoken,
    /// down slower so the gaps inside a word do not flatten the wave.
    public static func rise(_ response: Response) -> Double { response == .input ? 0.025 : 0.035 }
    public static func fall(_ response: Response) -> Double { response == .input ? 0.13 : 0.2 }
    /// The wave moves on in steps this long, whatever the display's rate.
    static let step = 1.0 / 120
    /// Energies that arrive together (a microphone's buffer holds several) are
    /// played in turn; a backlog longer than this is dropped, never queued.
    static let backlog = 0.15

    public let response: Response
    /// nil for a source that says itself when it stops; otherwise how long a
    /// source may send nothing before the wave settles.
    public let starvation: Double?
    /// Seconds of travel so far. It advances only while there is a wave.
    public private(set) var phase = 0.0
    /// The followed energy every `step`, newest last.
    private var history: [Double]
    private var energy = 0.0, goal = 0.0
    private struct Due: Equatable, Sendable { var time: Double, energy: Double }
    private var queue: [Due] = []
    private var clock: Double?
    private var lastReceipt: Double?
    private var remainder = 0.0

    public init(starvation: Double? = VoiceEnvelope.starvation, response: Response = .speaker) {
        self.starvation = starvation; self.response = response
        history = [Double](repeating: 0, count: Int((Self.memory / Self.step).rounded(.up)) + 1)
    }

    /// Still holding, easing or remembering a voice: display updates keep
    /// running. At rest nothing moves, so updates stop.
    public var isMoving: Bool { goal > 0 || energy > 0 || !queue.isEmpty || history.contains { $0 > 0 } }

    /// The energy heard at `time`, 0...1.
    public mutating func receive(_ energy: Double, at time: Double) { receive([energy], spacing: 0, at: time) }

    /// Energies measured `spacing` seconds apart since the last delivery,
    /// received together at `time`. They play in turn from now, so a buffer of
    /// several keeps the shape of its syllables.
    public mutating func receive(_ energies: [Double], spacing: Double, at time: Double) {
        guard !energies.isEmpty else { return }
        // Waking from rest, the clock starts at this delivery.
        if !isMoving { clock = time; remainder = 0 }
        lastReceipt = time
        var start = time
        if let last = queue.last {
            start = last.time + spacing
            if start > time + Self.backlog || start < time { queue.removeAll(); start = time }
        }
        for (index, energy) in energies.enumerated() {
            let value = energy.isFinite ? min(1, max(0, energy)) : 0
            queue.append(Due(time: start + Double(index) * max(0, spacing), energy: value))
        }
    }

    /// Moves the wave on to `time`. Returns whether it is still moving.
    /// Calling it again for the same time changes nothing.
    @discardableResult public mutating func advance(to time: Double) -> Bool {
        guard isMoving, let clock else { self.clock = time; remainder = 0; return false }
        var owed = min(0.25, max(0, time - clock)) + remainder
        var now = time - owed
        self.clock = time
        while owed >= Self.step {
            owed -= Self.step; now += Self.step
            while let next = queue.first, next.time <= now { goal = next.energy; queue.removeFirst() }
            if let starvation, let lastReceipt, queue.isEmpty, now - lastReceipt > starvation { goal = 0 }
            let constant = goal > energy ? Self.rise(response) : Self.fall(response)
            energy += (goal - energy) * (1 - exp(-Self.step / constant))
            if abs(energy - goal) < 0.02 { energy = goal }
            history.removeFirst(); history.append(energy)
            phase += Self.step
        }
        remainder = owed
        return isMoving
    }

    /// The energy `seconds` ago, 0...1: the waveform's height that far along it.
    public func level(ago seconds: Double = 0) -> Double {
        let index = Double(history.count - 1) - min(Self.memory, max(0, seconds)) / Self.step
        let lower = Int(index.rounded(.down)), upper = min(history.count - 1, lower + 1)
        guard lower >= 0 else { return history[0] }
        return history[lower] + (history[upper] - history[lower]) * (index - Double(lower))
    }

    /// Back to rest at once.
    public mutating func reset() { self = VoiceWave(starvation: starvation, response: response) }

    /// One travelling sine of a waveform's grain: `cycles` along the whole
    /// row, passing any bar `speed` times a second (negative travels the
    /// other way), `weight` of the whole, starting `offset` radians in.
    public struct Harmonic: Equatable, Sendable {
        public var cycles: Double, speed: Double, weight: Double, offset: Double
        public init(cycles: Double, speed: Double, weight: Double, offset: Double = 0) {
            self.cycles = cycles; self.speed = speed; self.weight = weight; self.offset = offset
        }
    }

    /// The grain at `position` along the row, 0...1: between 0 and 1 when the
    /// weights sum to 1. Several harmonics at different speeds keep it from
    /// repeating like a single sine.
    public func shape(_ harmonics: [Harmonic], at position: Double) -> Double {
        harmonics.reduce(0) { $0 + $1.weight * (0.5 + 0.5 * sin(2 * .pi * ($1.cycles * position - $1.speed * phase) + $1.offset)) }
    }
}
