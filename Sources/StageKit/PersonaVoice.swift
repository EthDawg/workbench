import Accelerate
import AppKit
import AVFoundation
import VoiceAppearance

/// One moment of the presenter's voice, as the outline shows it. Nothing about
/// the sound itself survives: a frame says whether a voice is present and how
/// loud it is against the presenter's own usual level.
struct PersonaVoiceFrame: Equatable {
    /// How loud the voice is against the presenter's usual speaking level:
    /// about 0.5 is their usual voice, 1 one raised by 8 dB. 0 when no voice is heard.
    var level: Float
    /// A voice is present: voiced sound above the room, held through the short
    /// gaps between words.
    var speaking: Bool
    /// The stretch of audio this frame measured.
    var seconds: Double
    /// Its loudness in dBFS, for measurement receipts only.
    var decibels: Float = -120
    /// How much sound this frame holds while a voice is present, 0...1, for
    /// the wave's height: about 0.85 at the presenter's usual level, less for
    /// the softer sounds inside a word, and 0 in the gaps and in silence.
    var energy: Float = 0
    /// The voice's spectrum while a voice is present, low to high, 0...1 each
    /// against the presenter's usual voice: the ring's bars are these. Empty
    /// when nothing is heard.
    var bands: [Float] = []

    static let quiet = PersonaVoiceFrame(level: 0, speaking: false, seconds: 0)
    func lasting(_ seconds: Double) -> PersonaVoiceFrame { var frame = self; frame.seconds = seconds; return frame }
    /// This frame as the shared voice appearance reads it.
    var sample: VoiceSample { VoiceSample(voiced: speaking, level: Double(level), energy: Double(energy)) }
}

/// Microphone samples in, voice frames out. A voice is recognised by its pitch
/// (the regular repetition of voiced sound), or at the start of a word by an
/// "s" well above a room already heard, so a fan, hiss, typing or mains hum
/// never counts as speech, while a first syllable counts at once, even when
/// someone is already talking as the outline turns on. The room is learned
/// only from steady sound, so talking without pause never becomes the room.
/// Loudness is measured against the presenter's own usual level, so quiet and
/// loud microphones read alike. Samples are measured and discarded; only the
/// numbers in each frame leave.
final class PersonaVoiceAnalyzer {
    /// A voice's harmonics are looked for here, clear of rumble and hiss.
    static let voiceBand = 150.0...4_000.0
    /// The pitch of a speaking voice, low man to high child.
    static let pitchRange = 70.0...400.0
    /// Voiced sound at least this far above the room counts.
    static let margin: Float = 6
    /// Pitch this clear starts speech; a little less continues it.
    static let startingPitch: Float = 0.7, continuingPitch: Float = 0.5
    /// Speech is held through gaps this long, so words run together: the same
    /// hold every source of the shared voice appearance uses.
    static let hold = VoiceSample.hold
    /// A room that has not been heard yet: a quiet office.
    static let assumedRoom: Float = -62
    let sampleRate: Double
    /// About 20 ms of audio, a power of two.
    let chunk: Int
    /// dBFS. The room's own steady sound: a quiet office, a fan or hum.
    private(set) var noiseFloor: Float = PersonaVoiceAnalyzer.assumedRoom
    /// dBFS. The presenter's usual speaking level, once heard.
    private(set) var speakingLevel: Float?
    /// Voiced frames heard so far, up to the first half second.
    private var voicedFrames = 0
    /// How clearly the newest frame repeats at a voice's pitch, 0...1.
    private(set) var periodicity: Float = 0
    private var sinceVoice = Double.infinity
    /// Loudness eased over a few frames, for learning the room.
    private var smoothed: Float?
    /// The room has been heard steady at least once, so hiss that rises well
    /// above it can be told from it.
    private var roomHeard = false
    /// Consecutive frames that sound like an "s".
    private var hissing = 0
    /// Energy near the voice's middle, in the sibilant band and overall, from the latest spectrum.
    private var spectrum: (middle: Float, sibilant: Float, overall: Float) = (0, 0, 0)
    /// Recent frames for recognising steady sound.
    private var recent: [(decibels: Float, pitch: Float, lag: Int)] = []
    private let steadyCount: Int, longSteadyCount: Int
    private var pending: [Float] = []
    // Pitch: autocorrelation over the last ~40 ms, from a zero-padded FFT.
    private let window: Int, fftSize: Int, log2n: vDSP_Length
    private let setup: FFTSetup
    private let hann: [Float]
    /// The Hann window's own autocorrelation, normalised, so a steady tone reads 1.
    private var hannCorrelation: [Float] = []
    private let lags: ClosedRange<Int>
    private let band: ClosedRange<Int>
    /// FFT bins for 1–3 kHz, 4–8 kHz (an "s") and 80 Hz–8 kHz.
    private let bands: (middle: ClosedRange<Int>, sibilant: ClosedRange<Int>, overall: ClosedRange<Int>)
    private var history: [Float]
    private var padded: [Float]
    private var real: [Float], imaginary: [Float]
    /// The latest frame's power at each FFT bin, and where in the bins each
    /// of the ring's bands is read: spaced as the ear hears pitch, from below
    /// a low voice's fundamental to the body of an "s".
    private var power: [Float]
    private let bandBins: [(from: Float, to: Float)]
    /// Decibels added to each band, so a voice's quieter high sounds stand as tall as its low ones.
    private let bandLift: [Float]
    static let waveBand = 80.0...6_500.0
    /// A band this far (in dB) below the frame's strongest is at rest, so
    /// only the sounds that make up the voice stand, with dots between them.
    static let bandRange: Float = 16
    /// Above 1, the strongest of those stand clear of the rest.
    static let bandContrast: Float = 1.35
    /// The frame's strongest band stands this much taller than its energy,
    /// so a usual voice's tallest bars are nearly full.
    static let bandGain: Float = 1.3

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate >= 8_000 ? sampleRate : 48_000
        self.sampleRate = rate
        let exponent = min(11, max(8, Int((log2(rate * 0.02)).rounded())))
        chunk = 1 << exponent
        let windowExponent = max(exponent + 1, Int(log2(rate * 0.04).rounded(.up)))
        window = 1 << windowExponent
        fftSize = window * 2
        log2n = vDSP_Length(windowExponent + 1)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var taper = [Float](repeating: 0, count: window)
        vDSP_hann_window(&taper, vDSP_Length(window), Int32(vDSP_HANN_NORM))
        hann = taper
        history = [Float](repeating: 0, count: window)
        padded = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imaginary = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        let binWidth = rate / Double(fftSize)
        func mel(_ hertz: Double) -> Double { 2595 * log10(1 + hertz / 700) }
        func hertz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }
        let lowest = mel(Self.waveBand.lowerBound), highest = mel(min(Self.waveBand.upperBound, rate / 2 * 0.95))
        let count = VoiceSpectrum.usualCount
        var read: [(from: Float, to: Float)] = [], lift: [Float] = []
        for index in 0..<count {
            let from = hertz(lowest + (highest - lowest) * Double(index) / Double(count))
            let to = hertz(lowest + (highest - lowest) * Double(index + 1) / Double(count))
            read.append((Float(from / binWidth), Float(to / binWidth)))
            // A voice falls about 5 dB an octave above 300 Hz.
            lift.append(Float(5 * max(0, log2((from + to) / 2 / 300))))
        }
        bandBins = read; bandLift = lift
        band = max(1, Int((Self.voiceBand.lowerBound / binWidth).rounded(.up)))...min(fftSize / 2 - 1, Int(Self.voiceBand.upperBound / binWidth))
        let top = window - 1
        func bins(_ low: Double, _ high: Double) -> ClosedRange<Int> {
            min(top, max(1, Int(low / binWidth)))...min(top, max(1, Int(high / binWidth)))
        }
        bands = (bins(1_000, 3_000), bins(4_000, 8_000), bins(80, 8_000))
        lags = Int(rate / Self.pitchRange.upperBound)...min(Int((rate / Self.pitchRange.lowerBound).rounded(.up)), window / 3)
        let frameSeconds = Double(chunk) / rate
        steadyCount = max(4, Int((0.25 / frameSeconds).rounded()))
        longSteadyCount = max(steadyCount, Int((1.0 / frameSeconds).rounded()))
        pending.reserveCapacity(chunk * 24)
        for index in 0..<window { padded[index] = hann[index] }
        let own = autocorrelate(band: nil)
        hannCorrelation = own.map { own[0] > 0 ? $0 / own[0] : 0 }
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// Accepts any buffer length; a remainder waits for the next buffer.
    func process(_ samples: UnsafeBufferPointer<Float>) -> [PersonaVoiceFrame] {
        pending.append(contentsOf: samples)
        var frames: [PersonaVoiceFrame] = []
        var start = 0
        while pending.count - start >= chunk {
            frames.append(pending.withUnsafeBufferPointer { analyze($0.baseAddress! + start) })
            start += chunk
        }
        pending.removeFirst(start)
        return frames
    }

    private func analyze(_ samples: UnsafePointer<Float>) -> PersonaVoiceFrame {
        let seconds = Double(chunk) / sampleRate
        history.removeFirst(chunk)
        history.append(contentsOf: UnsafeBufferPointer(start: samples, count: chunk))
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(chunk))
        sinceVoice += seconds
        // A device starting up delivers exact zeros. They say nothing about the
        // room, so they must not move the floor.
        guard meanSquare > 1e-10 else {
            periodicity = 0
            return PersonaVoiceFrame(level: 0, speaking: sinceVoice < Self.hold, seconds: seconds)
        }
        let decibels = 10 * log10(meanSquare)
        let (pitch, lag) = voicing()
        periodicity = pitch
        let floor = noiseFloor
        let continuing = sinceVoice < Self.hold
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(chunk))
        // An "s" starting a word: hiss well above a room already heard, high
        // in pitch, smooth rather than a click, for two frames running.
        let sibilant = roomHeard && decibels >= floor + 12 && spectrum.sibilant >= 0.5 * spectrum.overall
            && spectrum.sibilant >= 4 * spectrum.middle && peak <= 5 * meanSquare.squareRoot()
        hissing = sibilant ? hissing + 1 : 0
        let voiced = pitch >= (continuing ? Self.continuingPitch : Self.startingPitch) && decibels >= floor + Self.margin
        var level: Float = 0
        if voiced {
            sinceVoice = 0
            // The usual level settles near the loudest fifth of voiced frames,
            // quickly over the first half second so a soft first sound does not
            // make everything after it read as raised.
            var usual = speakingLevel ?? decibels
            let settling = voicedFrames < Int(0.5 / seconds)
            if settling { voicedFrames += 1; usual = max(usual, decibels - 3) }
            speakingLevel = usual + (decibels > usual ? (settling ? 32 : 4) : (settling ? -8 : -1)) * Float(seconds)
            level = min(1, max(0, 0.5 + (decibels - usual) / 16))
        } else if hissing >= 2 {
            // An "s" opens speech at the usual loudness; hiss never sets that level.
            sinceVoice = 0
            level = 0.5
        }
        learnRoom(decibels, pitch: pitch, lag: lag, seconds: seconds)
        let speaking = sinceVoice < Self.hold
        return PersonaVoiceFrame(level: level, speaking: speaking, seconds: seconds, decibels: decibels,
                                 energy: speaking ? energy(decibels, above: floor) : 0,
                                 bands: speaking ? bands(energy(decibels, above: floor)) : [])
    }

    /// The latest spectrum as the ring's bands: each band against the
    /// frame's strongest, at the frame's `energy`. A pitch's harmonics stand
    /// as separate peaks, a vowel's formants as groups of them, an "s" at the
    /// far end, with dots between; a louder voice stands taller throughout.
    private func bands(_ energy: Float) -> [Float] {
        guard energy > 0 else { return [] }
        let top = power.count - 1
        var levels = [Float](repeating: -200, count: bandBins.count), strongest: Float = -200
        for (index, bins) in bandBins.enumerated() {
            var found: Float
            if bins.to - bins.from < 1 {
                // Narrower than a bin: read between the two nearest.
                let centre = min(Float(top), max(1, (bins.from + bins.to) / 2))
                let lower = Int(centre), upper = min(top, lower + 1)
                found = power[lower] + (power[upper] - power[lower]) * (centre - Float(lower))
            } else {
                found = 0
                for bin in max(1, Int(bins.from))...min(top, max(1, Int(bins.to))) { found = max(found, power[bin]) }
            }
            levels[index] = 10 * log10(max(1e-20, found)) + bandLift[index]
            strongest = max(strongest, levels[index])
        }
        return levels.map { min(1, Self.bandGain * energy) * pow(min(1, max(0, 1 + ($0 - strongest) / Self.bandRange)), Self.bandContrast) }
    }

    /// The wave's height for a frame within speech: its loudness between the
    /// quietest sound that still belongs to a word and a little over the
    /// presenter's usual level. Consonants and soft syllables are lower and
    /// the gaps between words fall to the room, so the wave follows speech's
    /// own rhythm. Before a usual level is known, an opening "s" shows as a
    /// middling wave.
    static let waveSpan: Float = 22, waveHeadroom: Float = 4
    private func energy(_ decibels: Float, above floor: Float) -> Float {
        guard let usual = speakingLevel else { return 0.5 }
        let low = max(floor + 3, usual - Self.waveSpan)
        return min(1, max(0, (decibels - low) / max(6, usual + Self.waveHeadroom - low)))
    }

    /// The room is what stays steady. A quieter room is learned at once; steady
    /// sound (a fan, hiss or hum) within a quarter to a whole second; anything
    /// else only creeps in, so a voice never becomes the room. Steady voiced
    /// sound, such as a drawn-out "uhhh", never lifts the room to within 12 dB
    /// of the presenter's usual level, so the outline stays lit through it.
    private func learnRoom(_ decibels: Float, pitch: Float, lag: Int, seconds: Double) {
        recent.append((decibels, pitch, lag))
        if recent.count > longSteadyCount { recent.removeFirst(recent.count - longSteadyCount) }
        let eased = smoothed.map { $0 + (decibels - $0) * Float(1 - exp(-seconds / 0.06)) } ?? decibels
        smoothed = eased
        func steady(_ count: Int, spread limit: Float, range: Float) -> (Bool, mean: Float) {
            guard recent.count >= count else { return (false, 0) }
            let values = recent.suffix(count).map(\.decibels)
            let mean = values.reduce(0, +) / Float(count)
            let spread = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(count)).squareRoot()
            return (spread <= limit && (values.max()! - values.min()!) <= range, mean)
        }
        let short = steady(steadyCount, spread: 1.5, range: 6)
        let loose = steady(steadyCount, spread: 2.5, range: 9)
        let latest = recent.suffix(steadyCount)
        let unvoiced = latest.allSatisfy { $0.pitch < Self.startingPitch }
        let heldLags = latest.map(\.lag)
        // A hum holds one pitch; a voice's pitch keeps moving.
        let tone = latest.allSatisfy { $0.pitch >= Self.continuingPitch } && (heldLags.max() ?? 0) - (heldLags.min() ?? 0) <= max(2, (heldLags.min() ?? 0) / 50)
        let long = steady(longSteadyCount, spread: 1.5, range: 6)
        if (loose.0 && unvoiced) || short.0 { roomHeard = true }
        if eased < noiseFloor {
            noiseFloor += (eased - noiseFloor) * Float(1 - exp(-seconds / 0.06))
        } else if loose.0 && unvoiced {
            noiseFloor += (loose.mean - noiseFloor) * Float(1 - exp(-seconds / 0.2))
        } else if short.0 && tone {
            noiseFloor += max(0, voicedCeiling(short.mean) - noiseFloor) * Float(1 - exp(-seconds / 0.2))
        } else if long.0 {
            let target = unvoiced ? long.mean : voicedCeiling(long.mean)
            noiseFloor += max(0, target - noiseFloor) * Float(1 - exp(-seconds / 0.2))
        } else {
            noiseFloor += min(eased - noiseFloor, 0.25 * Float(seconds))
        }
        noiseFloor = min(-20, max(-100, noiseFloor))
    }
    /// How high steady voiced sound may lift the room: 12 dB below the
    /// presenter's usual level once it is known.
    private func voicedCeiling(_ level: Float) -> Float { speakingLevel.map { min(level, $0 - 12) } ?? level }

    /// How clearly the last ~40 ms repeats at a speaking pitch: 1 for a steady
    /// voiced tone, well under a half for noise, clicks and whispering.
    private func voicing() -> (Float, Int) {
        var mean: Float = 0
        vDSP_meanv(history, 1, &mean, vDSP_Length(window))
        for index in 0..<window { padded[index] = (history[index] - mean) * hann[index] }
        let heard = autocorrelate(band: band)
        guard heard[0] > 0 else { return (0, 0) }
        var best: Float = 0, bestLag = 0
        for lag in lags where hannCorrelation[lag] > 0.05 {
            let value = heard[lag] / heard[0] / hannCorrelation[lag]
            if value > best { best = value; bestLag = lag }
        }
        return (min(1, best), bestLag)
    }

    /// Autocorrelation of the first `window` samples of `padded`, zero-padded so
    /// it does not wrap, optionally keeping only the frequencies in `band`
    /// (FFT bins). Index is the lag in samples; the scale is arbitrary.
    private func autocorrelate(band: ClosedRange<Int>?) -> [Float] {
        for index in window..<fftSize { padded[index] = 0 }
        var result = [Float](repeating: 0, count: window)
        real.withUnsafeMutableBufferPointer { realPart in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPart in
                var split = DSPSplitComplex(realp: realPart.baseAddress!, imagp: imaginaryPart.baseAddress!)
                padded.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Bin 0 packs the DC term (real) and the Nyquist term (imaginary).
                let keepEnds = band == nil
                realPart[0] = keepEnds ? realPart[0] * realPart[0] : 0
                imaginaryPart[0] = keepEnds ? imaginaryPart[0] * imaginaryPart[0] : 0
                var middle: Float = 0, sibilant: Float = 0, overall: Float = 0
                for bin in 1..<fftSize / 2 {
                    let magnitude = realPart[bin] * realPart[bin] + imaginaryPart[bin] * imaginaryPart[bin]
                    if band != nil { power[bin] = magnitude }
                    if bands.middle.contains(bin) { middle += magnitude }
                    if bands.sibilant.contains(bin) { sibilant += magnitude }
                    if bands.overall.contains(bin) { overall += magnitude }
                    realPart[bin] = band.map { $0.contains(bin) } ?? true ? magnitude : 0
                    imaginaryPart[bin] = 0
                }
                if band != nil { spectrum = (middle, sibilant, overall) }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                // The inverse leaves lag 2k in real[k] and lag 2k+1 in imaginary[k].
                for lag in 0..<window { result[lag] = lag % 2 == 0 ? realPart[lag / 2] : imaginaryPart[lag / 2] }
            }
        }
        return result
    }
}

/// Loudness for a persona's voice ring. It measures level only: nothing is
/// recorded, kept or sent. It runs only while the person has turned the ring on
/// and the persona it frames is showing, so macOS shows its microphone indicator
/// exactly then.
protocol PersonaVoiceSource: AnyObject {
    /// Called on the main thread with the frames measured since the last call.
    var onFrames: (([PersonaVoiceFrame]) -> Void)? { get set }
    /// Called on the main thread when the microphone cannot be used.
    var onUnavailable: ((String) -> Void)? { get set }
    /// Called on the main thread when the input device changes.
    var onDevice: ((String?) -> Void)? { get set }
    /// The input the ring is listening to, while it runs.
    var deviceName: String? { get }
    func start() throws
    func stop()
}

/// A microphone that never opens, for renders of a refusal: starting it is the refusal.
final class PersonaSilentVoiceSource: PersonaVoiceSource {
    var onFrames: (([PersonaVoiceFrame]) -> Void)?
    var onUnavailable: ((String) -> Void)?
    var onDevice: ((String?) -> Void)?
    var deviceName: String? { nil }
    func start() throws { throw PersonaVoiceError.microphoneDenied }
    func stop() {}
}

enum PersonaVoiceError: LocalizedError {
    case microphoneDenied
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            // Dictate's words for the same refusal, so one word set names it on every surface.
            return "Microphone access is off. Open System Settings › Privacy & Security › Microphone and allow \(Workbench.displayName)."
        case .unavailable(let reason):
            return "React to my voice stopped: \(reason)"
        }
    }
}

/// The system pieces the voice ring needs, injected so checks never touch a
/// real microphone, permission prompt or saved preference.
struct PersonaVoiceAccess {
    enum Permission { case allowed, undecided, denied }
    var permission: () -> Permission
    /// Asks macOS once; the answer arrives on the main thread.
    var requestPermission: (@escaping (Bool) -> Void) -> Void
    var makeSource: () -> any PersonaVoiceSource
    /// The presenter's remembered on/off choice.
    var savedChoice: () -> Bool
    var saveChoice: (Bool) -> Void
    /// The presenter's remembered ring colour; nil until one is chosen.
    var savedColor: () -> InkColor? = { nil }
    var saveColor: (InkColor) -> Void = { _ in }
    /// Microphone Settings…: Privacy & Security › Microphone, the door Dictate and Meetings
    /// open beside the same refusal. Checks replace it so none opens System Settings.
    var openMicrophoneSettings: () -> Void = {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    static var system: PersonaVoiceAccess {
        let key = "persona.voiceRing", colorKey = "persona.voiceColor"
        return PersonaVoiceAccess(
            permission: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return .allowed
                case .notDetermined: return .undecided
                default: return .denied
                }
            },
            requestPermission: { answer in
                AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { answer(granted) } }
            },
            makeSource: { PersonaMicrophoneLevel() },
            savedChoice: { Workbench.stageDefaults.bool(forKey: key) },
            saveChoice: { Workbench.stageDefaults.set($0, forKey: key) },
            savedColor: {
                guard let parts = Workbench.stageDefaults.array(forKey: colorKey) as? [Double], parts.count == 3,
                      parts.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
                return InkColor(parts[0], parts[1], parts[2])
            },
            saveColor: { Workbench.stageDefaults.set([$0.r, $0.g, $0.b], forKey: colorKey) })
    }
}

/// When one microphone buffer was heard and handed over, in seconds on the
/// `CACurrentMediaTime` clock. For measurement receipts only.
struct PersonaVoiceTiming {
    /// The buffer's first sample reached the input, when macOS reports it.
    var captured: Double?
    /// The buffer reached the analyser.
    var tapped: Double
    /// Length of the buffer.
    var seconds: Double
}

final class PersonaMicrophoneLevel: PersonaVoiceSource {
    var onFrames: (([PersonaVoiceFrame]) -> Void)?
    var onUnavailable: ((String) -> Void)?
    var onDevice: ((String?) -> Void)?
    /// Measurement only: called on the main thread before the frames each buffer made.
    var onTiming: ((PersonaVoiceTiming) -> Void)?
    private(set) var deviceName: String?
    /// A new engine for every start, as Meetings does: after a device change an engine keeps the
    /// formats it was connected with, so a tap reinstalled on it can carry the old sample rate,
    /// which AVFAudio refuses with an exception nothing can catch.
    private var engine: AVAudioEngine?
    private var running = false
    private var configurationObserver: NSObjectProtocol?

    func start() throws {
        guard !running else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw PersonaVoiceError.microphoneDenied }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PersonaVoiceError.unavailable("No microphone input is available.")
        }
        // The analyzer belongs to this tap's thread; a restart makes a new one.
        let analyzer = PersonaVoiceAnalyzer(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(analyzer.chunk), format: format) { [weak self] buffer, when in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let timing = PersonaVoiceTiming(captured: when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil,
                                            tapped: CACurrentMediaTime(), seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
            let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
            let frames: [PersonaVoiceFrame]
            if channelCount == 1 {
                frames = analyzer.process(UnsafeBufferPointer(start: channels[0], count: count))
            } else {
                // An interface may carry the voice on its second input: mix them.
                var mixed = [Float](repeating: 0, count: count)
                mixed.withUnsafeMutableBufferPointer { sum in
                    for channel in 0..<channelCount {
                        vDSP_vadd(sum.baseAddress!, 1, channels[channel], 1, sum.baseAddress!, 1, vDSP_Length(count))
                    }
                    var scale = 1 / Float(channelCount)
                    vDSP_vsmul(sum.baseAddress!, 1, &scale, sum.baseAddress!, 1, vDSP_Length(count))
                }
                frames = mixed.withUnsafeBufferPointer { analyzer.process($0) }
            }
            guard !frames.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.onTiming?(timing)
                self.onFrames?(frames)
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw PersonaVoiceError.unavailable(error.localizedDescription)
        }
        self.engine = engine
        running = true
        deviceName = AVCaptureDevice.default(for: .audio)?.localizedName
        // A new headset or a lost device stops the engine silently. Restart on the new input,
        // or turn the ring off rather than freeze it at a stale level. The handler only schedules
        // that: the engine must not be torn down or released inside its own notification, which
        // AVFAudio delivers from an internal queue and can deadlock on (AVAudioEngine.h).
        let changed = ObjectIdentifier(engine)
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.restart(after: changed) }
        }
    }

    func stop() { halt(); deviceName = nil }

    /// On the main queue, after the notification has returned: a change from an engine that has
    /// since been replaced or stopped is ignored.
    private func restart(after changed: ObjectIdentifier) {
        guard running, let engine, ObjectIdentifier(engine) == changed else { return }
        halt()
        do { try start(); onDevice?(deviceName) }
        catch { deviceName = nil; onUnavailable?(error.localizedDescription) }
    }

    private func halt() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard running, let engine else { running = false; return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        running = false
    }
}
