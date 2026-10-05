import Foundation

/// A voice's own spectrum in motion, for a surface that draws it as a ring of
/// bars. Each bar belongs to one part of the voice's range and stays where it
/// is: it rises as the voice puts sound there and falls back as the sound
/// leaves. A pitch raises a comb of bars, a vowel the groups its mouth shape
/// favours, an "s" the far end, so the ring looks like what is being said and
/// no two moments look alike. Nothing moves on its own: without a voice every
/// band is at rest, the clock stops and display updates rest.
///
/// It is decided only by received bands and the clock, so the same code runs
/// on screen and in the checks. It never sees audio: a source measures the
/// bands, 0...1 each, and hands them over.
public struct VoiceSpectrum: Equatable, Sendable {
    /// Time constants in seconds: up fast so a syllable shows as it is spoken,
    /// down slowly so bars sink back and never flicker.
    public static let rise = 0.015, fall = 0.18
    /// The bands move on in steps this long, whatever the display's rate.
    static let step = 1.0 / 120
    /// Spectra that arrive together (a microphone's buffer holds several) are
    /// played in turn; a backlog longer than this is dropped, never queued.
    static let backlog = 0.15
    /// The bands a source measures unless it has reason for another number.
    public static let usualCount = 128

    /// How many bands it holds, low to high.
    public let count: Int
    /// How long a source may send nothing before the bands settle.
    public let starvation: Double
    /// Each band's height now, 0...1, low to high.
    public private(set) var bands: [Double]
    private var goal: [Double]
    private struct Due: Equatable, Sendable { var time: Double, bands: [Double] }
    private var queue: [Due] = []
    private var clock: Double?
    private var lastReceipt: Double?
    private var remainder = 0.0

    public init(count: Int = VoiceSpectrum.usualCount, starvation: Double = VoiceEnvelope.starvation) {
        self.count = max(2, count); self.starvation = starvation
        bands = [Double](repeating: 0, count: self.count); goal = bands
    }

    /// Still holding or easing a voice: display updates keep running. At
    /// rest nothing moves, so updates stop.
    public var isMoving: Bool { !queue.isEmpty || goal.contains { $0 > 0 } || bands.contains { $0 > 0 } }

    /// Spectra measured `spacing` seconds apart since the last delivery,
    /// received together at `time`. They play in turn from now, so a buffer
    /// of several keeps the shape of its syllables. Each holds `count` bands;
    /// an empty one is silence.
    public mutating func receive(_ spectra: [[Double]], spacing: Double, at time: Double) {
        guard !spectra.isEmpty else { return }
        // Waking from rest, the clock starts at this delivery.
        if !isMoving { clock = time; remainder = 0 }
        lastReceipt = time
        var start = time
        if let last = queue.last {
            start = last.time + spacing
            if start > time + Self.backlog || start < time { queue.removeAll(); start = time }
        }
        for (index, spectrum) in spectra.enumerated() {
            var bands = [Double](repeating: 0, count: count)
            for band in 0..<min(count, spectrum.count) where spectrum[band].isFinite { bands[band] = min(1, max(0, spectrum[band])) }
            queue.append(Due(time: start + Double(index) * max(0, spacing), bands: bands))
        }
    }

    /// Moves the bands on to `time`. Returns whether they are still moving.
    /// Calling it again for the same time changes nothing.
    @discardableResult public mutating func advance(to time: Double) -> Bool {
        guard isMoving, let clock else { self.clock = time; remainder = 0; return false }
        var owed = min(0.25, max(0, time - clock)) + remainder
        var now = time - owed
        self.clock = time
        let up = 1 - exp(-Self.step / Self.rise), down = 1 - exp(-Self.step / Self.fall)
        while owed >= Self.step {
            owed -= Self.step; now += Self.step
            while let next = queue.first, next.time <= now { goal = next.bands; queue.removeFirst() }
            if let lastReceipt, queue.isEmpty, now - lastReceipt > starvation { goal = [Double](repeating: 0, count: count) }
            for band in 0..<count {
                let next = bands[band] + (goal[band] - bands[band]) * (goal[band] > bands[band] ? up : down)
                bands[band] = abs(next - goal[band]) < 0.004 ? goal[band] : next
            }
        }
        remainder = owed
        return isMoving
    }

    /// The height of the part of the spectrum from `from` to `to`, 0 low ...
    /// 1 high: the tallest band inside it, or between two bands when it is
    /// narrower than one, so a ring of any number of bars keeps every peak.
    public func height(from: Double, to: Double) -> Double {
        let low = min(1, max(0, min(from, to))) * Double(count - 1), high = min(1, max(0, max(from, to))) * Double(count - 1)
        let first = Int(low.rounded(.up)), last = Int(high.rounded(.down))
        func between(_ index: Double) -> Double {
            let lower = Int(index.rounded(.down)), upper = min(count - 1, lower + 1)
            return bands[lower] + (bands[upper] - bands[lower]) * (index - Double(lower))
        }
        var tallest = max(between(low), between(high))
        if first <= last { for band in first...last { tallest = max(tallest, bands[band]) } }
        return tallest
    }

    /// Back to rest at once.
    public mutating func reset() { self = VoiceSpectrum(count: count, starvation: starvation) }

    /// A spoken vowel's spectrum at `energy`, for sources that measure only
    /// how loud a voice is: a pitch's comb of harmonics under the vowel's
    /// formants, falling away toward the high bands.
    public static func vowel(_ energy: Double, count: Int = VoiceSpectrum.usualCount) -> [Double] {
        (0..<count).map { band in
            let position = Double(band) / Double(max(1, count - 1))
            let formants = exp(-pow((position - 0.16) / 0.11, 2)) + 0.75 * exp(-pow((position - 0.4) / 0.09, 2)) + 0.3 * exp(-pow((position - 0.68) / 0.1, 2))
            let comb = pow(0.5 + 0.5 * cos(position * 2 * .pi * 17 + 4 * position * position), 1.5)
            return min(1, max(0, energy * formants * (0.25 + 0.75 * comb)))
        }
    }
}
