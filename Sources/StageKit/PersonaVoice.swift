import Accelerate
import AppKit
import AVFoundation

/// One moment of the presenter's voice, as the ring shows it. Nothing about the
/// sound itself survives: a frame is how loud the presenter is against their
/// own room, and the rough balance from low to high pitch.
struct PersonaVoiceFrame: Equatable {
    static let bandCount = 6
    /// 0 is the room's own noise, 1 the presenter's recent speaking peak.
    var level: Float
    /// Low to high pitch, each 0...level.
    var bands: [Float]
    /// Stays true through the short gaps between words.
    var speaking: Bool
    /// The stretch of audio this frame measured.
    var seconds: Double

    static let quiet = PersonaVoiceFrame(level: 0, bands: Array(repeating: 0, count: bandCount), speaking: false, seconds: 0)
    func lasting(_ seconds: Double) -> PersonaVoiceFrame { var frame = self; frame.seconds = seconds; return frame }
}

/// Microphone samples in, ring frames out. Quiet and loud microphones both fill
/// the ring because loudness is measured against the room's noise floor and the
/// presenter's own recent peak, not against fixed decibels. Samples are measured
/// and discarded; only the numbers in each frame leave.
final class PersonaVoiceAnalyzer {
    /// Voice lives between a man's lowest fundamental and the top of "s".
    static let bandEdges: [Double] = [80, 200, 450, 1_000, 2_200, 4_500, 8_000]
    let sampleRate: Double
    /// About 20 ms of audio, a power of two for the FFT.
    let chunk: Int
    /// dBFS. The quietest the room has been lately.
    private(set) var noiseFloor: Float = -62
    /// dBFS. The loudest the presenter has been lately.
    private(set) var voicePeak: Float = -26
    private var shortTerm: Float?
    /// Recent short-term loudness. Its minimum is the room: a speaker breathes
    /// within any three seconds, so speech never becomes the floor.
    private var recent: [Float]
    private var recentIndex = 0
    private var recentCount = 0
    private var quietFor: Double = 1
    private var pending: [Float] = []
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var power: [Float]
    private let bandBins: [Range<Int>]

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate >= 8_000 ? sampleRate : 48_000
        self.sampleRate = rate
        let exponent = min(11, max(8, Int((log2(rate * 0.02)).rounded())))
        chunk = 1 << exponent
        log2n = vDSP_Length(exponent)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var hann = [Float](repeating: 0, count: chunk)
        vDSP_hann_window(&hann, vDSP_Length(chunk), Int32(vDSP_HANN_NORM))
        window = hann
        windowed = [Float](repeating: 0, count: chunk)
        real = [Float](repeating: 0, count: chunk / 2)
        imaginary = [Float](repeating: 0, count: chunk / 2)
        power = [Float](repeating: 0, count: chunk / 2)
        let binWidth = rate / Double(chunk), nyquist = chunk / 2
        bandBins = (0..<Self.bandEdges.count - 1).map { band in
            let low = max(1, Int((Self.bandEdges[band] / binWidth).rounded()))
            let high = min(nyquist, max(low + 1, Int((Self.bandEdges[band + 1] / binWidth).rounded())))
            return low < nyquist ? low..<high : nyquist..<nyquist
        }
        recent = [Float](repeating: 0, count: max(1, Int((3 * rate / Double(chunk)).rounded(.up))))
        pending.reserveCapacity(chunk * 24)
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
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(chunk))
        // A device starting up delivers exact zeros. They say nothing about the
        // room, so they must not drag the floor down.
        guard meanSquare > 1e-10 else { quietFor += seconds; return .quiet.lasting(seconds) }
        let decibels = 10 * log10(meanSquare)

        let smoothing = Float(1 - exp(-seconds / 0.06))
        let smoothed = shortTerm.map { $0 + (decibels - $0) * smoothing } ?? decibels
        shortTerm = smoothed
        recent[recentIndex] = smoothed
        recentIndex = (recentIndex + 1) % recent.count
        recentCount = min(recent.count, recentCount + 1)
        let quietest = recent[0..<recentCount].min() ?? smoothed
        // The floor drops to a quieter room at once and rises to a noisier one
        // within a second or two, but never to the presenter's voice.
        let follow = Float(1 - exp(-seconds / (quietest < noiseFloor || recentCount < 8 ? 0.08 : 0.8)))
        noiseFloor = min(-30, max(-96, noiseFloor + (quietest - noiseFloor) * follow))
        if decibels > voicePeak { voicePeak = decibels } else { voicePeak -= Float(seconds * 1.5) }
        voicePeak = min(0, max(noiseFloor + 20, voicePeak))

        let gate = noiseFloor + 9
        let level = min(1, max(0, (decibels - gate) / max(12, voicePeak - gate)))
        quietFor = level > 0.18 ? 0 : quietFor + seconds
        let speaking = quietFor < 0.3
        return PersonaVoiceFrame(level: level, bands: bands(samples, level: level), speaking: speaking, seconds: seconds)
    }

    /// The balance between bands, relative to the loudest one, scaled by level.
    private func bands(_ samples: UnsafePointer<Float>, level: Float) -> [Float] {
        guard level > 0 else { return Array(repeating: 0, count: PersonaVoiceFrame.bandCount) }
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(chunk))
        real.withUnsafeMutableBufferPointer { realPart in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPart in
                var split = DSPSplitComplex(realp: realPart.baseAddress!, imagp: imaginaryPart.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: chunk / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(chunk / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(chunk / 2))
            }
        }
        let energy = bandBins.map { bins -> Float in
            guard !bins.isEmpty else { return -120 }
            var sum: Float = 0
            power.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + bins.lowerBound, 1, &sum, vDSP_Length(bins.count)) }
            return 10 * log10(max(sum, 1e-12))
        }
        let loudest = energy.max() ?? -120
        return energy.map { level * (0.3 + 0.7 * min(1, max(0, ($0 - (loudest - 30)) / 30))) }
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

enum PersonaVoiceError: LocalizedError {
    case microphoneDenied
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "React to my voice needs microphone access. Allow Workbench in System Settings > Privacy & Security > Microphone."
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

    static var system: PersonaVoiceAccess {
        let key = "persona.voiceRing"
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
            saveChoice: { Workbench.stageDefaults.set($0, forKey: key) })
    }
}

final class PersonaMicrophoneLevel: PersonaVoiceSource {
    var onFrames: (([PersonaVoiceFrame]) -> Void)?
    var onUnavailable: ((String) -> Void)?
    var onDevice: ((String?) -> Void)?
    private(set) var deviceName: String?
    private let engine = AVAudioEngine()
    private var running = false
    private var configurationObserver: NSObjectProtocol?

    func start() throws {
        guard !running else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw PersonaVoiceError.microphoneDenied }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PersonaVoiceError.unavailable("No microphone input is available.")
        }
        // The analyzer belongs to this tap's thread; a restart makes a new one.
        let analyzer = PersonaVoiceAnalyzer(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(analyzer.chunk), format: format) { [weak self] buffer, _ in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
            let frames: [PersonaVoiceFrame]
            if channelCount == 1 {
                frames = analyzer.process(UnsafeBufferPointer(start: channels[0], count: count))
            } else {
                // An interface may carry the voice on its second input: mix them.
                var mixed = [Float](repeating: 0, count: count)
                for channel in 0..<channelCount { vDSP_vadd(mixed, 1, channels[channel], 1, &mixed, 1, vDSP_Length(count)) }
                var scale = 1 / Float(channelCount)
                vDSP_vsmul(mixed, 1, &scale, &mixed, 1, vDSP_Length(count))
                frames = mixed.withUnsafeBufferPointer { analyzer.process($0) }
            }
            guard !frames.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.onFrames?(frames)
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw PersonaVoiceError.unavailable(error.localizedDescription)
        }
        running = true
        deviceName = AVCaptureDevice.default(for: .audio)?.localizedName
        // A new headset or a lost device stops the engine silently. Restart on the
        // new input, or turn the ring off rather than freeze it at a stale level.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.halt()
            do { try self.start(); self.onDevice?(self.deviceName) }
            catch { self.deviceName = nil; self.onUnavailable?(error.localizedDescription) }
        }
    }

    func stop() { halt(); deviceName = nil }

    private func halt() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}
