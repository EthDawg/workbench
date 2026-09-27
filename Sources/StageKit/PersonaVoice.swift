import AppKit
import AVFoundation

/// Loudness for a persona's voice ring. It measures level only: nothing is
/// recorded, kept or sent. It runs only while the person has turned the ring on
/// and a persona overlay is showing, so macOS shows its microphone indicator
/// exactly then.
protocol PersonaVoiceSource: AnyObject {
    /// Called on the main thread with a smoothed level from 0 (quiet) to 1.
    var onLevel: ((CGFloat) -> Void)? { get set }
    /// Called on the main thread when the microphone cannot be used.
    var onUnavailable: ((String) -> Void)? { get set }
    func start() throws
    func stop()
}

enum PersonaVoiceError: LocalizedError {
    case microphoneDenied
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "The voice ring needs microphone access. Allow Workbench in System Settings > Privacy & Security > Microphone."
        case .unavailable(let reason):
            return "The voice ring could not start. \(reason)"
        }
    }
}

final class PersonaMicrophoneLevel: PersonaVoiceSource {
    var onLevel: ((CGFloat) -> Void)?
    var onUnavailable: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private var wanted = false
    private var running = false
    private var configurationObserver: NSObjectProtocol?
    // Touched only on the audio tap's thread.
    private var smoothed: Float = 0
    private var lastDelivery: CFAbsoluteTime = 0

    func start() throws {
        wanted = true
        guard !running else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.wanted else { return }
                    if !granted { self.onUnavailable?(PersonaVoiceError.microphoneDenied.localizedDescription); return }
                    do { try self.start() } catch { self.onUnavailable?(error.localizedDescription) }
                }
            }
            return
        default:
            throw PersonaVoiceError.microphoneDenied
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PersonaVoiceError.unavailable("No microphone input is available.")
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in self?.measure(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw PersonaVoiceError.unavailable(error.localizedDescription)
        }
        running = true
        // A new headset or a lost device stops the engine silently. Restart on the
        // new input, or turn the ring off rather than freeze it at a stale level.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.halt()
            do { try self.start() } catch { self.wanted = false; self.onUnavailable?(error.localizedDescription) }
        }
    }

    func stop() {
        wanted = false
        halt()
    }

    private func halt() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    /// Root-mean-square loudness mapped from about -50 dBFS (quiet room) to
    /// -10 dBFS (close speech), rising quickly and falling gently, delivered
    /// at most 30 times a second.
    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let level = min(1, max(0, (20 * log10(max(rms, 1e-7)) + 50) / 40))
        smoothed += (level - smoothed) * (level > smoothed ? 0.6 : 0.15)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDelivery >= 1.0 / 30 else { return }
        lastDelivery = now
        let value = CGFloat(smoothed)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.onLevel?(value)
        }
    }
}

/// Draws bars around the persona that follow the speaker's voice. The artwork
/// is inset to make room, never covered. Reduce Motion keeps the bars still and
/// shows loudness through their opacity instead.
enum PersonaVoiceRing {
    static let barCount = 72

    static func margin(for bounds: CGRect) -> CGFloat { max(6, min(bounds.width, bounds.height) * 0.1) }

    /// The artwork's rectangle inside the ring, keeping its aspect ratio.
    static func artworkRect(in bounds: CGRect) -> CGRect {
        let margin = margin(for: bounds)
        let scale = max(0.01, min((bounds.width - margin * 2) / bounds.width, (bounds.height - margin * 2) / bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func draw(in bounds: CGRect, level: CGFloat, phase: CGFloat, reduceMotion: Bool, color: NSColor = WorkbenchPalette.nativeAccent) {
        let margin = margin(for: bounds)
        let artwork = artworkRect(in: bounds)
        let base = artwork.insetBy(dx: -margin * 0.3, dy: -margin * 0.3)
        let center = CGPoint(x: base.midX, y: base.midY)
        let (rx, ry) = (base.width / 2, base.height / 2)
        let clamped = min(1, max(0, level))
        for index in 0..<barCount {
            let angle = CGFloat(index) / CGFloat(barCount) * 2 * .pi
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let start = CGPoint(x: center.x + direction.x * rx, y: center.y + direction.y * ry)
            let alpha = reduceMotion ? 0.3 + 0.7 * clamped : 0.85
            if clamped < 0.05 || index % 2 == 1 {
                // A quiet dotted baseline shows the ring is on and listening.
                color.withAlphaComponent(0.45).setFill()
                NSBezierPath(ovalIn: CGRect(x: start.x - 1.2, y: start.y - 1.2, width: 2.4, height: 2.4)).fill()
                if clamped < 0.05 { continue }
            }
            let wave = reduceMotion ? 1 : 0.55 + 0.45 * sin(CGFloat(index) * 0.9 + phase) * cos(CGFloat(index) * 0.37 - phase * 0.6)
            let length = margin * 0.65 * max(0.12, clamped * wave)
            let end = CGPoint(x: start.x + direction.x * length, y: start.y + direction.y * length)
            let bar = NSBezierPath()
            bar.move(to: start); bar.line(to: end)
            bar.lineWidth = max(1.5, margin * 0.12); bar.lineCapStyle = .round
            color.withAlphaComponent(alpha).setStroke()
            bar.stroke()
        }
    }
}
