import AppKit
import AVFoundation
import VoiceAppearance

/// The voice outline's response, measured offline. Deterministic speech-like
/// sound runs through the real analyser and the real outline state with a
/// simulated clock: microphone buffers arrive as macOS delivers them (about
/// 100 ms at a time), the display draws at 60 frames a second, and each
/// utterance's onset and return to quiet are measured from the arrival of its
/// first and last speech frames. Time macOS takes to hand a buffer over is
/// not part of these numbers; the native check reports it separately.
final class PersonaVoiceLatencyTests {
    static let onsetTarget = 0.150, releaseTarget = 0.500

    // MARK: Synthetic sound

    /// Deterministic noise.
    struct Random {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        /// Uniform in -1...1.
        mutating func white() -> Float { Float(next() % 20_001) / 10_000 - 1 }
        /// Uniform in 0..<1.
        mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
    }

    struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        static func bandpass(_ center: Double, q: Double, rate: Double) -> Biquad {
            let w = 2 * Double.pi * min(center, rate * 0.45) / rate, alpha = sin(w) / (2 * q), a0 = 1 + alpha
            return Biquad(b0: Float(alpha / a0), b1: 0, b2: Float(-alpha / a0), a1: Float(-2 * cos(w) / a0), a2: Float((1 - alpha) / a0))
        }
        static func highpass(_ cutoff: Double, rate: Double) -> Biquad {
            let w = 2 * Double.pi * min(cutoff, rate * 0.45) / rate, alpha = sin(w) / (2 * 0.707), a0 = 1 + alpha, c = cos(w)
            return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0), a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
        }
        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// A syllable: an optional hissed consonant, then a voiced vowel.
    struct Syllable {
        enum Consonant { case none, s, sh, f }
        var consonant = Consonant.none
        var vowel: (Double, Double, Double) = (730, 1_090, 2_440)
        var seconds = 0.16
        var gap = 0.06
        /// dB against the phrase's level.
        var emphasis: Float = 0
        /// A held vowel ("uhhh"): one steady pitch instead of a spoken glide.
        var held = false
    }
    static let vowels: [(Double, Double, Double)] = [(730, 1_090, 2_440), (270, 2_290, 3_010), (300, 870, 2_240), (530, 1_840, 2_480), (570, 840, 2_410)]

    /// Room, speech and the truth about where the speech is.
    struct Fixture {
        var name: String
        let rate: Double
        var samples: [Float] = []
        /// Sample ranges where the speaker makes sound, where the voiced part of
        /// each utterance starts, and whether it opens on an "sh" or "f", which
        /// the outline shows from its vowel.
        var utterances: [(speech: Range<Int>, firstVoiced: Int, hissedStart: Bool, fromVowel: Bool)] = []
        /// Sample ranges spoken with a raised voice.
        var raised: [Range<Int>] = []
        var random: Random
        private var pinkState: (Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0)
        private var brown: Float = 0

        init(_ name: String, rate: Double = 48_000, seed: UInt64 = 0x2545_F491_4F6C_DD1D) {
            self.name = name; self.rate = rate; random = Random(seed)
        }

        static func amplitude(_ decibels: Float) -> Float { pow(10, decibels / 20) }

        /// Pink noise, the colour of a quiet room, before scaling.
        mutating func pink() -> Float {
            let w = random.white()
            var p = pinkState
            p.0 = 0.99886 * p.0 + w * 0.0555179; p.1 = 0.99332 * p.1 + w * 0.0750759; p.2 = 0.96900 * p.2 + w * 0.1538520
            p.3 = 0.86650 * p.3 + w * 0.3104856; p.4 = 0.55000 * p.4 + w * 0.5329522; p.5 = -0.7616 * p.5 - w * 0.0168980
            let out = p.0 + p.1 + p.2 + p.3 + p.4 + p.5 + p.6 + w * 0.5362
            p.6 = w * 0.115926; pinkState = p
            return out
        }
        /// `count` samples of `make`, scaled so their RMS is exactly `decibels` dBFS.
        static func scaled(_ values: [Float], to decibels: Float) -> [Float] {
            let rms = (values.reduce(0) { $0 + $1 * $1 } / Float(max(1, values.count))).squareRoot()
            let gain = amplitude(decibels) / max(1e-12, rms)
            return values.map { $0 * gain }
        }
        mutating func roomNoise(_ count: Int, _ decibels: Float) -> [Float] {
            Self.scaled((0..<count).map { _ in pink() }, to: decibels)
        }
        mutating func room(_ seconds: Double, _ decibels: Float, zeros: Bool = false) {
            let count = Int(seconds * rate)
            samples += zeros ? [Float](repeating: 0, count: count) : roomNoise(count, decibels)
        }
        /// A fan: rumble and broadband air with a faint blade tone.
        mutating func fan(_ seconds: Double, _ decibels: Float) {
            let start = samples.count
            let air = Self.scaled((0..<Int(seconds * rate)).map { _ in pink() }, to: -3)
            let sound = air.indices.map { index -> Float in
                brown = 0.995 * brown + 0.1 * random.white()
                return air[index] + 0.5 * brown + 0.03 * Float(sin(2 * .pi * 118 * Double(start + index) / rate))
            }
            samples += Self.scaled(sound, to: decibels)
        }
        /// Hiss: flat noise, like an air vent or a noisy input.
        mutating func hiss(_ seconds: Double, _ decibels: Float) {
            samples += Self.scaled((0..<Int(seconds * rate)).map { _ in random.white() }, to: decibels)
        }
        /// Mains hum with its harmonics, over a quiet room.
        mutating func hum(_ seconds: Double, _ decibels: Float, mains: Double, room: Float) {
            let start = samples.count, count = Int(seconds * rate)
            let tone = Self.scaled((0..<count).map { index -> Float in
                let time = Double(start + index) / rate
                var value = 0.0
                for harmonic in 1...8 { value += sin(2 * .pi * mains * Double(harmonic) * time) / Double(harmonic) }
                return Float(value)
            }, to: decibels)
            let floor = roomNoise(count, room)
            samples += zip(tone, floor).map { $0 + $1 }
        }
        /// A periodic sound that is not speech, over a quiet room: partials at
        /// `frequencies` with `weights`, shaped by `envelope`. Its loudest 50 ms
        /// sits at `decibels` dBFS. Returns where it starts and ends.
        @discardableResult mutating func periodic(_ seconds: Double, _ decibels: Float, room: Float, frequencies: [Double], weights: [Double],
                                                  envelope: (Double) -> Double) -> Range<Int> {
            let start = samples.count, count = Int(seconds * rate)
            var tone = (0..<count).map { index -> Float in
                let time = Double(index) / rate
                var value = 0.0
                for (frequency, weight) in zip(frequencies, weights) { value += weight * sin(2 * .pi * frequency * time) }
                return Float(value * envelope(time))
            }
            let window = Int(0.05 * rate)
            let loudest = stride(from: 0, to: max(1, count - window), by: window / 2).map { offset in
                tone[offset..<min(count, offset + window)].reduce(0) { $0 + $1 * $1 } / Float(window)
            }.max() ?? 1
            let gain = Self.amplitude(decibels) / max(1e-9, loudest.squareRoot())
            tone = tone.map { $0 * gain }
            let floor = roomNoise(count, room)
            samples += zip(tone, floor).map { $0 + $1 }
            return start..<start + count
        }
        /// A struck chime: inharmonic partials of 880 Hz dying away.
        @discardableResult mutating func chime(_ decibels: Float, room: Float) -> Range<Int> {
            periodic(2, decibels, room: room, frequencies: [880, 880 * 2.76, 880 * 5.4], weights: [1, 0.6, 0.35]) { min(1, $0 / 0.002) * exp(-$0 / 0.45) }
        }
        /// A notification beep: 1 kHz for a fifth of a second.
        @discardableResult mutating func beep(_ decibels: Float, room: Float) -> Range<Int> {
            periodic(0.2, decibels, room: room, frequencies: [1_000], weights: [1]) { min(1, $0 / 0.005, (0.2 - $0) / 0.005) }
        }
        /// A held C major chord of rich tones.
        @discardableResult mutating func chord(_ seconds: Double, _ decibels: Float, room: Float) -> Range<Int> {
            let roots = [261.63, 329.63, 392.0]
            let partials = roots.flatMap { root in (1...6).map { root * Double($0) } }
            let weights = roots.flatMap { _ in (1...6).map { 1 / Double($0) } }
            return periodic(seconds, decibels, room: room, frequencies: partials, weights: weights) { min(1, $0 / 0.02, (seconds - $0) / 0.05) }
        }
        /// A short tune: eight notes of a rich tone, 0.3 s each.
        @discardableResult mutating func melody(_ decibels: Float, room: Float) -> Range<Int> {
            let start = samples.count
            for note in [392.0, 440, 493.88, 523.25, 493.88, 440, 392, 329.63] {
                periodic(0.3, decibels, room: room, frequencies: (1...6).map { note * Double($0) }, weights: (1...6).map { 1 / Double($0) }) { min(1, $0 / 0.01, (0.3 - $0) / 0.02) }
            }
            return start..<samples.count
        }
        /// Keyboard clicks over a quiet room.
        mutating func typing(_ seconds: Double, quiet: Float, click: Float) {
            let start = samples.count
            room(seconds, quiet)
            var time = 0.1
            while time < seconds - 0.05 {
                let at = start + Int(time * rate)
                for index in 0..<Int(0.004 * rate) where at + index < samples.count {
                    samples[at + index] += random.white() * Self.amplitude(click) * 4 * Float(exp(-Double(index) / (0.001 * rate)))
                }
                time += 0.1 + random.unit() * 0.08
            }
        }

        /// A phrase of syllables at `decibels` dBFS over a room at `room`.
        /// `from` starts part-way into the phrase, as when the outline turns
        /// on mid-sentence.
        mutating func speak(_ syllables: [Syllable], _ decibels: Float, room: Float, pitch: Double = 120, from offset: Double = 0) {
            var sound: [Float] = [], active: [Bool] = [], voicedAt: Int?, raisedRanges: [Range<Int>] = []
            var phase = 0.0
            let base = samples.count
            for (index, syllable) in syllables.enumerated() {
                let emphasisGain = Self.amplitude(syllable.emphasis)
                let raisedStart = sound.count
                // The hissed consonant.
                if syllable.consonant != .none {
                    let count = Int(0.09 * rate)
                    var filters: [Biquad]
                    let level: Float
                    switch syllable.consonant {
                    case .s: filters = [.highpass(4_500, rate: rate), .highpass(4_500, rate: rate)]; level = 0.35
                    case .sh: filters = [.bandpass(3_000, q: 1.5, rate: rate)]; level = 0.3
                    default: filters = [.bandpass(2_500, q: 0.4, rate: rate)]; level = 0.08
                    }
                    for sample in 0..<count {
                        var value = random.white()
                        for filter in filters.indices { value = filters[filter].run(value) }
                        let envelope = Float(min(1, Double(sample) / (0.012 * rate), Double(count - sample) / (0.012 * rate)))
                        sound.append(value * level * envelope * emphasisGain * 3)
                        active.append(envelope > 0.3)
                    }
                }
                // The voiced vowel: a buzzing source shaped by three formants.
                var formants = [Biquad.bandpass(syllable.vowel.0, q: 6, rate: rate), .bandpass(syllable.vowel.1, q: 8, rate: rate), .bandpass(syllable.vowel.2, q: 10, rate: rate)]
                let count = Int(syllable.seconds * rate)
                let start = pitch * (1 + 0.08 * sin(Double(index) * 1.7)), end = syllable.held ? start : start * (0.92 + 0.05 * cos(Double(index)))
                if voicedAt == nil { voicedAt = sound.count }
                for sample in 0..<count {
                    let progress = Double(sample) / Double(count)
                    phase += (start + (end - start) * progress) / rate
                    if phase >= 1 { phase -= 1 }
                    let buzz = Float(2 * phase - 1)
                    let voice = formants[0].run(buzz) + 0.5 * formants[1].run(buzz) + 0.25 * formants[2].run(buzz)
                    let envelope = Float(min(1, Double(sample) / (0.015 * rate), Double(count - sample) / (0.04 * rate)))
                    sound.append(voice * envelope * emphasisGain)
                    active.append(envelope > 0.3)
                }
                if syllable.emphasis >= 6 { raisedRanges.append(raisedStart..<sound.count) }
                sound += [Float](repeating: 0, count: Int(syllable.gap * rate))
                active += [Bool](repeating: false, count: Int(syllable.gap * rate))
            }
            // Level: the phrase's voiced sound at `decibels` dBFS RMS.
            var energy: Float = 0, counted = 0
            for (value, on) in zip(sound, active) where on { energy += value * value; counted += 1 }
            let gain = Self.amplitude(decibels) / max(1e-9, (energy / Float(max(1, counted))).squareRoot())
            let skip = Int(offset * rate)
            let floor = roomNoise(sound.count - skip, room)
            for index in skip..<sound.count { samples.append(sound[index] * gain + floor[index - skip]) }
            let heard = active.enumerated().filter { $0.offset >= skip && $0.element }.map(\.offset)
            guard let first = heard.first, let last = heard.last else { return }
            let hissed = syllables.first?.consonant != Syllable.Consonant.none && offset == 0
            let opening = syllables.first?.consonant
            utterances.append((base + first - skip..<base + last - skip + 1, base + max(skip, voicedAt ?? first) - skip, hissed,
                               (opening == .f || opening == .sh) && offset == 0))
            raised += raisedRanges.map { base + $0.lowerBound - skip..<base + $0.upperBound - skip }
        }
    }

    /// A sentence of about `seconds`: syllables with short gaps between words.
    static func sentence(_ seconds: Double, seed: UInt64, start: Syllable.Consonant = .none, gaps: ClosedRange<Double> = 0.03...0.14) -> [Syllable] {
        var random = Random(seed)
        var syllables: [Syllable] = [], total = 0.0
        while total < seconds {
            var syllable = Syllable()
            syllable.vowel = vowels[Int(random.next() % UInt64(vowels.count))]
            syllable.seconds = 0.11 + random.unit() * 0.1
            syllable.gap = gaps.lowerBound + random.unit() * (gaps.upperBound - gaps.lowerBound)
            syllable.emphasis = Float(random.unit() * 6 - 3)
            let hiss = random.unit()
            syllable.consonant = syllables.isEmpty ? start : hiss < 0.15 ? .s : hiss < 0.22 ? .f : hiss < 0.27 ? .sh : .none
            syllables.append(syllable)
            total += (syllable.consonant == .none ? 0 : 0.09) + syllable.seconds + syllable.gap
        }
        return syllables
    }

    // MARK: Simulation

    struct Measurement {
        struct Utterance { var onset: Double?; var onsetFromVoice: Double?; var release: Double?; var litShare: Double; var litShareLast3s: Double; var hissedStart: Bool; var fromVowel: Bool }
        var utterances: [Utterance] = []
        /// Display frames that were lit outside speech and the half second after it.
        var strayCues = 0
        var loudShareInRaised = 0.0
        var loudShareElsewhere = 0.0
        var transitions: [(time: Double, state: VoiceEnvelope.Visible)] = []
        var receipts: [Double] = []
    }

    /// Plays `fixture` through the analyser in `buffer`-second deliveries and the outline state at `displayRate`.
    static func measure(_ fixture: Fixture, buffer: Double = 0.1, displayRate: Double = 60) -> Measurement {
        let analyzer = PersonaVoiceAnalyzer(sampleRate: fixture.rate)
        var ring = VoiceEnvelope()
        var result = Measurement()
        var frameEnds: [Int] = []
        var ticks: [(time: Double, state: VoiceEnvelope.Visible)] = []
        let bufferSamples = Int(buffer * fixture.rate)
        var start = 0, tick = 0.0, produced = 0
        func advanceDisplay(to time: Double) {
            while tick + 1 / displayRate <= time {
                tick += 1 / displayRate
                let before = ring.visible
                let state = ring.advance(to: tick)
                ticks.append((tick, state))
                if state != before { result.transitions.append((tick, state)) }
            }
        }
        while start < fixture.samples.count {
            let end = min(fixture.samples.count, start + bufferSamples)
            let received = Double(end) / fixture.rate
            advanceDisplay(to: received)
            let frames = fixture.samples[start..<end].withUnsafeBufferPointer { analyzer.process($0) }
            for _ in frames { produced += 1; frameEnds.append(produced * analyzer.chunk); result.receipts.append(received) }
            ring.receive(frames.map(\.sample), at: received)
            start = end
        }
        advanceDisplay(to: Double(fixture.samples.count) / fixture.rate + 1)
        /// When the frame holding `sample` (and most of that frame's sound) arrived.
        func arrival(ofFrameCovering sample: Int, firstHalf: Bool) -> Double? {
            let chunk = analyzer.chunk
            // A frame counts as speech when at least half of it is.
            var index = sample / chunk
            if firstHalf, sample % chunk > chunk / 2 { index += 1 }
            if !firstHalf, sample % chunk < chunk / 2 { index -= 1 }
            return result.receipts.indices.contains(index) ? result.receipts[index] : nil
        }
        func lit(_ state: VoiceEnvelope.Visible) -> Bool { state != .quiet }
        for utterance in fixture.utterances {
            guard let first = arrival(ofFrameCovering: utterance.speech.lowerBound, firstHalf: true),
                  let voiced = arrival(ofFrameCovering: utterance.firstVoiced, firstHalf: true),
                  let last = arrival(ofFrameCovering: utterance.speech.upperBound - 1, firstHalf: false) else { continue }
            let on = ticks.first { $0.time >= first && lit($0.state) }?.time
            let onVoice = ticks.first { $0.time >= voiced && lit($0.state) }?.time
            let off = ticks.first { $0.time >= last && !lit($0.state) }?.time
            let during = ticks.filter { $0.time >= (on ?? last) && $0.time <= last }
            let late = during.filter { $0.time >= last - 3 }
            result.utterances.append(.init(onset: on.map { $0 - first }, onsetFromVoice: onVoice.map { $0 - voiced }, release: off.map { $0 - last },
                                           litShare: during.isEmpty ? 0 : Double(during.filter { lit($0.state) }.count) / Double(during.count),
                                           litShareLast3s: late.isEmpty ? 0 : Double(late.filter { lit($0.state) }.count) / Double(late.count),
                                           hissedStart: utterance.hissedStart, fromVowel: utterance.fromVowel))
        }
        // Speech begins a little before it is 6 dB above the room, so a cue
        // up to 0.15 s ahead of that belongs to the utterance.
        let spans = fixture.utterances.map { (Double($0.speech.lowerBound) / fixture.rate - 0.15, Double($0.speech.upperBound) / fixture.rate + buffer + 0.6) }
        result.strayCues = ticks.filter { tick in lit(tick.state) && !spans.contains { tick.time >= $0.0 && tick.time <= $0.1 } }.count
        let raisedSpans = fixture.raised.map { (Double($0.lowerBound) / fixture.rate + buffer + 0.1, Double($0.upperBound) / fixture.rate) }
        let inRaised = ticks.filter { tick in raisedSpans.contains { tick.time >= $0.0 && tick.time <= $0.1 } }
        result.loudShareInRaised = inRaised.isEmpty ? 0 : Double(inRaised.filter { $0.state == .loud }.count) / Double(inRaised.count)
        let speaking = ticks.filter { tick in lit(tick.state) && !fixture.raised.contains { tick.time >= Double($0.lowerBound) / fixture.rate - 0.1 && tick.time <= Double($0.upperBound) / fixture.rate + 0.7 } }
        result.loudShareElsewhere = speaking.isEmpty ? 0 : Double(speaking.filter { $0.state == .loud }.count) / Double(speaking.count)
        return result
    }

    private static func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.0f", $0 * 1_000) } ?? "never" }
    private static func worst(_ values: [Double?]) -> Double? { values.contains { $0 == nil } ? nil : values.compactMap { $0 }.max() }

    /// Runs a fixture at each of five alignments against the buffers, so a
    /// first syllable lands early, midway and late in a delivery.
    static func measured(_ make: (Double) -> Fixture, buffer: Double = 0.1) -> [Measurement] {
        [0, 0.021, 0.042, 0.063, 0.084].map { measure(make($0), buffer: buffer) }
    }

    /// Asserts the targets for every utterance and prints the worst case.
    @discardableResult static func expectTargets(_ name: String, _ runs: [Measurement], line: UInt = #line) -> (onset: Double?, release: Double?) {
        let utterances = runs.flatMap(\.utterances)
        XCTAssertTrue(!utterances.isEmpty, "\(name): speech was synthesised", line: line)
        for utterance in utterances {
            // A word opening on "sh" or "f" shows from its vowel: that hiss sounds
            // like breath, paper and air, which must never light the outline.
            let onset = utterance.fromVowel ? utterance.onsetFromVoice : utterance.onset
            XCTAssertTrue((onset ?? .infinity) <= onsetTarget, "\(name): onset within 150 ms (\(milliseconds(onset)) ms)", line: line)
            XCTAssertTrue((utterance.release ?? .infinity) <= releaseTarget, "\(name): back to quiet within 500 ms (\(milliseconds(utterance.release)) ms)", line: line)
        }
        let onset = worst(utterances.filter { !$0.fromVowel }.map(\.onset)), release = worst(utterances.map(\.release))
        let voice = worst(utterances.map(\.onsetFromVoice))
        var line = "Voice outline \(name): onset ≤ \(milliseconds(onset)) ms from the first speech frame, ≤ \(milliseconds(voice)) ms from the first voiced frame; back to quiet ≤ \(milliseconds(release)) ms (\(utterances.count) utterances)"
        let hissed = utterances.filter(\.fromVowel)
        if !hissed.isEmpty { line += "; words opening on sh or f: ≤ \(milliseconds(worst(hissed.map(\.onsetFromVoice)))) ms from the vowel, ≤ \(milliseconds(worst(hissed.map(\.onset)))) ms from the hiss" }
        print(line)
        return (onset, release)
    }

    // MARK: Checks

    /// The ticket's cases: speech at once after turning on, soft and usual voices,
    /// headsets, and other sample rates, all within 150 ms and 500 ms.
    func testOutlineRespondsWithinTargetsToSpeechOfEveryKind() {
        // Already talking when the outline turns on: the device's start-up
        // zeros, then speech from mid-sentence. The room has never been heard.
        let immediate = Self.measured { lead in
            var fixture = Fixture("immediate")
            fixture.room(0.1 + lead, -62, zeros: true)
            fixture.speak(Self.sentence(3, seed: 11), -28, room: -62, from: 0.35)
            fixture.room(1.5, -62)
            return fixture
        }
        Self.expectTargets("immediate speech after turning on", immediate)
        // Turned on just as a word starts: its first syllable must count.
        let firstWord = Self.measured { lead in
            var fixture = Fixture("first word")
            fixture.room(0.1, -62, zeros: true)
            fixture.room(lead, -62)
            fixture.speak(Self.sentence(2, seed: 12, start: .s), -28, room: -62)
            fixture.room(1.5, -62)
            return fixture
        }
        Self.expectTargets("a first word opening on an s", firstWord)

        func phrases(_ name: String, speech: Float, room: Float, rate: Double = 48_000, pitch: Double = 120) -> [Measurement] {
            Self.measured { lead in
                var fixture = Fixture(name, rate: rate)
                fixture.room(1.5 + lead, room)
                for (index, start) in [Syllable.Consonant.none, .s, .sh, .f, .none].enumerated() {
                    fixture.speak(Self.sentence(1.6, seed: 20 + UInt64(index), start: start), speech, room: room, pitch: index % 2 == 0 ? pitch : pitch * 1.8)
                    fixture.room(1.2, room)
                }
                return fixture
            }
        }
        Self.expectTargets("usual voice, built-in microphone", phrases("usual", speech: -28, room: -62))
        Self.expectTargets("soft voice", phrases("soft", speech: -48, room: -64))
        Self.expectTargets("loud headset", phrases("headset", speech: -14, room: -54))
        Self.expectTargets("44.1 kHz interface", phrases("44.1 kHz", speech: -30, room: -60, rate: 44_100))
        Self.expectTargets("16 kHz Bluetooth headset", phrases("16 kHz", speech: -24, room: -56, rate: 16_000, pitch: 150))
        for run in phrases("usual", speech: -28, room: -62) { XCTAssertEqual(run.strayCues, 0, "Pauses between phrases rest") }
    }

    /// More than ten seconds without a pause: the room must not learn the voice,
    /// which was the old estimator's failure, so the outline stays lit to the end.
    func testLongSpeechNeverBecomesTheRoom() {
        for (name, speech, room) in [("usual", Float(-28), Float(-62)), ("soft", -46, -66)] {
            var floors: [Float] = []
            let runs = Self.measured { lead in
                var fixture = Fixture("continuous \(name)")
                fixture.room(1 + lead, room)
                fixture.speak(Self.sentence(12, seed: 31, gaps: 0.03...0.12), speech, room: room)
                fixture.room(1.5, room)
                // The floor the analyser settles on by the end of the speech.
                let analyzer = PersonaVoiceAnalyzer(sampleRate: fixture.rate)
                let end = fixture.utterances.last?.speech.upperBound ?? fixture.samples.count
                _ = fixture.samples[0..<end].withUnsafeBufferPointer { analyzer.process($0) }
                floors.append(analyzer.noiseFloor)
                return fixture
            }
            Self.expectTargets("more than 10 s of continuous \(name) speech", runs)
            for run in runs {
                XCTAssertTrue((run.utterances.first?.litShare ?? 0) >= 0.97, "\(name): lit throughout long speech (\(run.utterances.first?.litShare ?? 0))")
                XCTAssertTrue((run.utterances.first?.litShareLast3s ?? 0) >= 0.97, "\(name): still lit in its last 3 s (\(run.utterances.first?.litShareLast3s ?? 0))")
            }
            XCTAssertTrue(floors.allSatisfy { $0 <= room + 4 }, "\(name): after 12 s of speech the room is still the room (\(floors) against \(room))")
        }
    }

    /// Silence and steady background sound never light the outline, even when
    /// they are there from the moment it turns on.
    func testSteadyNoiseTypingAndHumNeverLightTheOutline() {
        var cases: [(String, Fixture)] = []
        var fixture = Fixture("silence"); fixture.room(0.1, -62, zeros: true); fixture.room(10, -62); cases.append(("silence", fixture))
        fixture = Fixture("fan"); fixture.fan(10, -48); cases.append(("a fan from the start", fixture))
        fixture = Fixture("loud fan"); fixture.fan(10, -40); cases.append(("a loud fan from the start", fixture))
        fixture = Fixture("hiss"); fixture.hiss(10, -46); cases.append(("hiss from the start", fixture))
        fixture = Fixture("mains"); fixture.hum(10, -46, mains: 50, room: -62); cases.append(("50 Hz mains hum", fixture))
        fixture = Fixture("mains 60"); fixture.hum(10, -46, mains: 60, room: -62); cases.append(("60 Hz mains hum", fixture))
        fixture = Fixture("typing"); fixture.typing(10, quiet: -64, click: -30); cases.append(("typing", fixture))
        fixture = Fixture("fan on"); fixture.room(3, -66); fixture.fan(9, -46); cases.append(("a fan switched on", fixture))
        fixture = Fixture("hiss on"); fixture.room(3, -66); fixture.hiss(9, -46); cases.append(("hiss switched on", fixture))
        for (name, fixture) in cases {
            XCTAssertEqual(Self.measure(fixture).transitions.count, 0, "\(name) never lights the outline")
        }
        print("Voice outline: silence, fans, hiss, mains hum and typing lit it on 0 display frames")
    }

    /// A raised voice reads as loud; a usual voice as lit but not loud.
    func testRaisedVoiceShowsLoudAndUsualVoiceShowsNormal() {
        var shares: [(Double, Double)] = []
        let runs = Self.measured { lead in
            var fixture = Fixture("raised")
            fixture.room(1 + lead, -62)
            var syllables = Self.sentence(3, seed: 41)
            var loud = Self.sentence(1.2, seed: 42)
            for index in loud.indices { loud[index].emphasis = 9; loud[index].gap = 0.05 }
            syllables += loud
            syllables += Self.sentence(1.5, seed: 43)
            fixture.speak(syllables, -30, room: -62)
            fixture.room(1.5, -62)
            return fixture
        }
        for run in runs {
            shares.append((run.loudShareInRaised, run.loudShareElsewhere))
            XCTAssertTrue(run.loudShareInRaised >= 0.5, "A raised voice shows the loud outline (\(run.loudShareInRaised))")
            XCTAssertTrue(run.loudShareElsewhere <= 0.15, "A usual voice rarely reads as loud (\(run.loudShareElsewhere))")
        }
        print("Voice outline: loud for \(Int((shares.map(\.0).min() ?? 0) * 100))% or more of a raised phrase, at most \(Int((shares.map(\.1).max() ?? 0) * 100))% of usual speech")
    }

    /// A drawn-out vowel or filler mid-sentence ("sooo", "uhhh") is speech,
    /// not the room: the outline stays lit through it and the room stays
    /// well below the voice. Without the ceiling on steady voiced sound, a
    /// vowel held a second lifted the room to the voice and dimmed it.
    func testHeldVowelKeepsTheOutlineLit() {
        for seconds in [0.6, 1.0, 1.5] {
            var floors: [Float] = []
            let runs = Self.measured { lead in
                var fixture = Fixture("held vowel")
                fixture.room(1 + lead, -62)
                var held = Syllable(); held.vowel = Self.vowels[0]; held.seconds = seconds; held.held = true; held.gap = 0.06
                let syllables = Self.sentence(2, seed: 51, gaps: 0.03...0.1) + [held] + Self.sentence(1.5, seed: 52, gaps: 0.03...0.1)
                fixture.speak(syllables, -28, room: -62)
                let analyzer = PersonaVoiceAnalyzer(sampleRate: fixture.rate)
                _ = fixture.samples.withUnsafeBufferPointer { analyzer.process($0) }
                floors.append(analyzer.noiseFloor)
                fixture.room(1.5, -62)
                return fixture
            }
            Self.expectTargets("a vowel held \(seconds) s mid-sentence", runs)
            for run in runs {
                XCTAssertTrue((run.utterances.first?.litShare ?? 0) >= 0.97, "Lit through a vowel held \(seconds) s (\(run.utterances.first?.litShare ?? 0))")
            }
            // The phrase is at -28 dBFS: the room stays well below the voice.
            XCTAssertTrue(floors.allSatisfy { $0 <= -38 }, "A held vowel does not become the room (\(floors))")
        }
    }

    /// Periodic sound that is not speech (a chime, a beep, a held chord, a
    /// tune) is voiced to the analyser, so it lights the outline as a voice
    /// would; steady tones are learned as the room, and everything settles.
    func testChimesBeepsAndMusicLightItOnlyWhileTheySound() {
        func lit(_ run: Measurement, from: Double, to: Double) -> Double {
            var total = 0.0, previous: (time: Double, lit: Bool)?
            let changes = run.transitions.map { ($0.time, $0.state != .quiet) }
            var state = false
            for change in changes where change.0 <= to {
                if let previous, previous.lit { total += max(0, min(change.0, to) - max(previous.time, from)) }
                previous = (change.0, change.1); state = change.1
            }
            if let previous, previous.lit || state { total += max(0, to - max(previous.time, from)) }
            return total
        }
        func settled(_ run: Measurement, after end: Double) -> Double? {
            guard let last = run.transitions.last else { return 0 }
            return last.state == .quiet ? max(0, last.time - end) : nil
        }
        var report: [String] = []
        // A chime, alone and after speech.
        for afterSpeech in [false, true] {
            var fixture = Fixture("chime")
            fixture.room(1, -62)
            if afterSpeech { fixture.speak(Self.sentence(2, seed: 61), -28, room: -62); fixture.room(1, -62) }
            let chime = fixture.chime(-30, room: -62)
            fixture.room(1.5, -62)
            let run = Self.measure(fixture)
            let start = Double(chime.lowerBound) / fixture.rate, end = start + 2
            let shown = lit(run, from: start, to: end + 1.5)
            report.append(String(format: "chime%@ %.2f s", afterSpeech ? " after speech" : "", shown))
            XCTAssertTrue(shown <= 1.2, "A chime lights it at most briefly (\(shown) s)")
            XCTAssertTrue(settled(run, after: start) != nil, "After a chime the outline is at rest")
        }
        // A beep.
        var beeps = Fixture("beep"); beeps.room(1, -62); let beep = beeps.beep(-30, room: -62); beeps.room(1.5, -62)
        let beepRun = Self.measure(beeps)
        let beepShown = lit(beepRun, from: Double(beep.lowerBound) / 48_000, to: Double(beep.upperBound) / 48_000 + 1.5)
        report.append(String(format: "beep %.2f s", beepShown))
        XCTAssertTrue(beepShown <= 0.6, "A beep lights it for a moment (\(beepShown) s)")
        // A held chord: learned as the room while it sounds, alone or after speech.
        for afterSpeech in [false, true] {
            var fixture = Fixture("chord")
            fixture.room(1, -62)
            if afterSpeech { fixture.speak(Self.sentence(2, seed: 62), -28, room: -62); fixture.room(1, -62) }
            let chord = fixture.chord(4, -30, room: -62)
            fixture.room(1.5, -62)
            let run = Self.measure(fixture)
            let start = Double(chord.lowerBound) / fixture.rate
            let shown = lit(run, from: start, to: start + 4 + 1.5)
            report.append(String(format: "4 s chord%@ %.2f s", afterSpeech ? " after speech" : "", shown))
            XCTAssertTrue(lit(run, from: start + 2, to: start + 4) == 0, "A held chord settles to rest while it sounds (\(shown) s lit)")
            XCTAssertTrue(settled(run, after: start) != nil)
        }
        // A tune lights it while it plays, like a voice, and settles after.
        var tune = Fixture("melody"); tune.room(1, -62); let melody = tune.melody(-30, room: -62); tune.room(1.5, -62)
        let tuneRun = Self.measure(tune)
        let tuneEnd = Double(melody.upperBound) / 48_000
        let tuneShown = lit(tuneRun, from: Double(melody.lowerBound) / 48_000, to: tuneEnd)
        report.append(String(format: "2.4 s tune %.2f s", tuneShown))
        XCTAssertTrue(settled(tuneRun, after: tuneEnd).map { $0 <= 0.5 } ?? false, "After a tune it settles within half a second")
        print("Voice outline, periodic sound that is not speech, lit for: " + report.joined(separator: "; "))
    }

    /// The outline's state never waits on the display: a delivery lights it
    /// by the next frame, and without deliveries it settles instead of freezing.
    func testOutlineStateEasesAndSettlesWithoutFrames() {
        var state = VoiceEnvelope()
        XCTAssertFalse(state.isMoving)
        let voice = PersonaVoiceFrame(level: 0.5, speaking: true, seconds: 0.021)
        state.receive([PersonaVoiceFrame.quiet.lasting(0.021), voice].map(\.sample), at: 10)
        XCTAssertTrue(state.isMoving, "A voice wakes the display link")
        XCTAssertEqual(state.advance(to: 10 + 1.0 / 60), .normal, "Lit by the next display frame")
        for step in 2...12 { state.advance(to: 10 + Double(step) / 60) }
        XCTAssertEqual(state.intensity, 0.75, accuracy: 0.01)
        var lastDelivery = 10.0
        for step in 13...60 {
            let time = 10 + Double(step) / 60
            if step % 6 == 0 { state.receive([PersonaVoiceFrame(level: 1, speaking: true, seconds: 0.021).sample], at: time); lastDelivery = time }
            state.advance(to: time)
        }
        XCTAssertEqual(state.visible, .loud, "A raised voice reads as loud")
        // The microphone stops sending: the outline settles, it does not freeze.
        var settledAt: Double?
        for step in 61...150 where settledAt == nil {
            let time = 10 + Double(step) / 60
            if state.advance(to: time) == .quiet { settledAt = time }
        }
        XCTAssertTrue(settledAt.map { $0 - lastDelivery <= VoiceEnvelope.starvation + 0.15 } ?? false, "Settles once frames stop (\(settledAt.map { $0 - lastDelivery } ?? -1))")
        for step in 151...230 { state.advance(to: 10 + Double(step) / 60) }
        XCTAssertFalse(state.isMoving, "At rest the display link sleeps")
        XCTAssertEqual(state.intensity, 0, accuracy: 0.0001)
    }

    /// Set WORKBENCH_VOICE_SAY=1 to measure sentences spoken by the Mac's own
    /// voices, written to a temporary folder with `say -o` and never played.
    func testSpokenSentencesFromSay() throws {
        guard ProcessInfo.processInfo.environment["WORKBENCH_VOICE_SAY"] == "1", FileManager.default.isExecutableFile(atPath: "/usr/bin/say") else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaVoiceSay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sentences = ["So, here is the plan.", "Okay, let us begin.", "Now look at this chart.", "Sure, that works for me.",
                         "The numbers went up.", "Seven of them are ready.", "Hello everyone.", "First, open the settings."]
        var speech: [[Float]] = []
        for (index, text) in sentences.enumerated() {
            for voice in ["Samantha", "Daniel", "Fred", "Karen"] {
                let file = folder.appendingPathComponent("\(index)-\(voice).wav")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["-v", voice, "--file-format=WAVE", "--data-format=LEF32@48000", "-o", file.path, text]
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0, let audio = try? AVAudioFile(forReading: file),
                      let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else { continue }
                try audio.read(into: buffer)
                guard let channel = buffer.floatChannelData?[0] else { continue }
                speech.append(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
            }
        }
        XCTAssertTrue(!speech.isEmpty, "The Mac's voices wrote sentences")
        for (label, level, room) in [("usual", Float(-28), Float(-62)), ("soft", -46, -66)] {
            var results: [Measurement] = []
            for samples in speech {
                results += Self.measured { lead in
                    var fixture = Fixture("say")
                    fixture.room(1 + lead, room)
                    fixture.recorded(samples, level, room: room)
                    fixture.room(1.5, room)
                    return fixture
                }
            }
            let utterances = results.flatMap(\.utterances)
            let onsets = utterances.compactMap(\.onset).sorted(), releases = utterances.compactMap(\.release).sorted()
            func at(_ values: [Double], _ share: Double) -> String { values.isEmpty ? "none" : Self.milliseconds(values[min(values.count - 1, Int(Double(values.count) * share))]) }
            print("Voice outline, Mac voices, \(label): onset median \(at(onsets, 0.5)) · p95 \(at(onsets, 0.95)) · max \(at(onsets, 1)) ms; from the first voiced frame max \(Self.milliseconds(Self.worst(utterances.map(\.onsetFromVoice)))) ms; back to quiet median \(at(releases, 0.5)) · max \(at(releases, 1)) ms (\(utterances.count) runs)")
            for utterance in utterances {
                XCTAssertTrue((utterance.onsetFromVoice ?? .infinity) <= Self.onsetTarget, "Mac voice \(label): lit within 150 ms of the first voiced frame")
                XCTAssertTrue((utterance.release ?? .infinity) <= Self.releaseTarget, "Mac voice \(label): quiet within 500 ms")
            }
            XCTAssertTrue(results.allSatisfy { $0.strayCues == 0 }, "Mac voice \(label): no cue outside speech")
            XCTAssertTrue(results.allSatisfy { $0.loudShareElsewhere <= 0.15 }, "Mac voice \(label): a usual voice rarely reads as loud (\(results.map(\.loudShareElsewhere).max() ?? 0))")
        }
    }
}

extension PersonaVoiceLatencyTests.Fixture {
    /// Recorded speech (for example from `say`) at `decibels` over a room, with
    /// its speech and first voiced sound found from the recording itself.
    mutating func recorded(_ speech: [Float], _ decibels: Float, room: Float) {
        let frame = 256
        func level(_ slice: ArraySlice<Float>) -> Float { 10 * log10(max(1e-18, slice.reduce(0) { $0 + $1 * $1 } / Float(max(1, slice.count)))) }
        let levels = stride(from: 0, to: max(0, speech.count - frame), by: frame).map { level(speech[$0..<$0 + frame]) }
        guard let peak = levels.max() else { return }
        let loud = levels.enumerated().filter { $0.element > peak - 35 }.map(\.offset)
        var energy: Float = 0, count = 0
        for index in loud { for value in speech[(index * frame)..<(index * frame + frame)] { energy += value * value; count += 1 } }
        let gain = Self.amplitude(decibels) / max(1e-9, (energy / Float(max(1, count))).squareRoot())
        let base = samples.count, floor = roomNoise(speech.count, room)
        for (index, value) in speech.enumerated() { samples.append(value * gain + floor[index]) }
        // Speech: sound at least 6 dB above the room.
        let threshold = room + 6
        let heard = levels.enumerated().filter { $0.element + 20 * log10(gain) > threshold }.map(\.offset)
        guard let first = heard.first, let last = heard.last else { return }
        // The voiced start: the first frame the analyser would call periodic, on the clean recording.
        let analyzer = PersonaVoiceAnalyzer(sampleRate: rate)
        var voiced = first * frame, position = 0
        let scaled = speech.map { $0 * gain }
        while position + analyzer.chunk <= scaled.count {
            let frames = scaled[position..<position + analyzer.chunk].withUnsafeBufferPointer { analyzer.process($0) }
            if analyzer.periodicity >= PersonaVoiceAnalyzer.startingPitch, let made = frames.last, made.decibels > threshold { voiced = max(first * frame, position); break }
            position += analyzer.chunk
        }
        utterances.append((base + first * frame..<base + (last + 1) * frame, base + voiced, false, true))
    }
}
