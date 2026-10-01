import AVFoundation
import Foundation

/// Audio a reading plays from: a finished file, or a Mac voice still rendering.
protocol ReadingAudioSource: AnyObject {
    /// Float frames at the rendered sample rate.
    var format: AVAudioFormat { get }
    var availableFrames: AVAudioFramePosition { get }
    var isComplete: Bool { get }
    func read(from frame: AVAudioFramePosition, count: AVAudioFrameCount) throws -> AVAudioPCMBuffer?
}

/// A 16-bit mono WAV that a Mac voice appends to while it renders. Playback can
/// read any frame already written; `finish()` completes the header, so replay,
/// seeking and Save audio use the same ordinary file afterwards.
final class ReadingAudioFile: ReadingAudioSource {
    static let headerLength: UInt64 = 44
    let url: URL
    let format: AVAudioFormat
    private let writer: FileHandle
    private let reader: FileHandle
    private var pending = Data()
    private var writtenFrames: AVAudioFramePosition = 0
    private(set) var availableFrames: AVAudioFramePosition = 0
    private(set) var isComplete = false
    private var closed = false

    init(url: URL, sampleRate: Double) throws {
        guard sampleRate >= 8_000, sampleRate <= 192_000,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw VoiceError.message("This voice produced audio in an unsupported format. Choose another voice.")
        }
        self.url = url
        self.format = format
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate, dataBytes: 0),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw VoiceError.message("Could not create temporary reading audio.")
        }
        writer = try FileHandle(forWritingTo: url)
        try writer.seekToEnd()
        reader = try FileHandle(forReadingFrom: url)
    }

    deinit { close() }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard !isComplete, !closed else { return }
        guard buffer.format.sampleRate == format.sampleRate else {
            throw VoiceError.message("The voice changed its audio format partway through. Try Listen again.")
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var samples = [Int16](repeating: 0, count: frames)
        if let channel = buffer.floatChannelData?[0] {
            let stride = buffer.stride
            for index in 0..<frames {
                let value = (channel[index * stride] * 32_768).rounded()
                samples[index] = Int16(max(-32_768, min(32_767, value))).littleEndian
            }
        } else if let channel = buffer.int16ChannelData?[0] {
            let stride = buffer.stride
            for index in 0..<frames { samples[index] = channel[index * stride].littleEndian }
        } else {
            throw VoiceError.message("This voice produced audio in an unsupported format. Choose another voice.")
        }
        samples.withUnsafeBytes { pending.append(contentsOf: $0) }
        availableFrames += AVAudioFramePosition(frames)
        if pending.count >= 64 * 1024 { try flush() }
    }

    func finish() throws {
        guard !isComplete, !closed else { return }
        try flush()
        let dataBytes = UInt32(clamping: writtenFrames * 2)
        try writer.seek(toOffset: 4)
        try writer.write(contentsOf: Self.littleEndian(36 + dataBytes))
        try writer.seek(toOffset: 40)
        try writer.write(contentsOf: Self.littleEndian(dataBytes))
        try writer.close()
        isComplete = true
    }

    func read(from frame: AVAudioFramePosition, count: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard !closed else { return nil }
        let start = max(0, frame)
        let frames = min(AVAudioFramePosition(count), availableFrames - start)
        guard frames > 0 else { return nil }
        if start + frames > writtenFrames { try flush() }
        try reader.seek(toOffset: Self.headerLength + UInt64(start) * 2)
        guard let data = try reader.read(upToCount: Int(frames) * 2), data.count == Int(frames) * 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else {
            throw VoiceError.message("Could not read the reading audio.")
        }
        var samples = [Int16](repeating: 0, count: Int(frames))
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        for index in 0..<Int(frames) { channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768 }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    func close() {
        guard !closed else { return }
        closed = true
        if !isComplete { try? writer.close() }
        try? reader.close()
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        try writer.write(contentsOf: pending)
        writtenFrames += AVAudioFramePosition(pending.count / 2)
        pending.removeAll(keepingCapacity: true)
    }

    private static func header(sampleRate: Double, dataBytes: UInt32) -> Data {
        let rate = UInt32(sampleRate.rounded())
        var data = Data("RIFF".utf8)
        data.append(littleEndian(36 + dataBytes)); data.append(Data("WAVEfmt ".utf8))
        data.append(littleEndian(UInt32(16))); data.append(littleEndian(UInt16(1))); data.append(littleEndian(UInt16(1)))
        data.append(littleEndian(rate)); data.append(littleEndian(rate * 2)); data.append(littleEndian(UInt16(2))); data.append(littleEndian(UInt16(16)))
        data.append(Data("data".utf8)); data.append(littleEndian(dataBytes))
        return data
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

/// A finished audio file: Speko's WAV, a `say` rendering, or reused audio.
final class ReadingFileSource: ReadingAudioSource {
    private let file: AVAudioFile
    let format: AVAudioFormat
    let availableFrames: AVAudioFramePosition
    let isComplete = true

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        format = file.processingFormat
        availableFrames = file.length
        guard availableFrames > 0 else { throw VoiceError.message("This voice produced no audio. Choose another installed voice and try again.") }
    }

    func read(from frame: AVAudioFramePosition, count: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        let start = max(0, frame)
        guard start < availableFrames else { return nil }
        let frames = AVAudioFrameCount(min(AVAudioFramePosition(count), availableFrames - start))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        file.framePosition = start
        try file.read(into: buffer, frameCount: frames)
        return buffer.frameLength > 0 ? buffer : nil
    }
}

/// A voice on this Mac that is still making a reading: a Mac voice or a neural voice.
/// Playback reads the growing audio while it renders the rest.
@MainActor
protocol ReadingRenderer: AnyObject {
    var audio: ReadingAudioFile? { get }
    /// Where each word, or for a neural voice each sentence, starts in the audio.
    var marks: ReadingMarks { get }
    var isFinished: Bool { get }
    /// New audio exists. Called for every rendered buffer, so keep it cheap.
    var onAudio: (() -> Void)? { get set }
    /// Called once, when the reading has completely rendered or failed.
    var onFinish: ((Error?) -> Void)? { get set }
    func ready(complete: Bool) async throws
    func cancel()
}

/// One rendered reading: its audio, the text it was made from and, for a voice on
/// this Mac, where each word or sentence starts. It is reused while its signature matches.
@MainActor
final class ReadingTrack {
    let url: URL
    let source: ReadingAudioSource
    let text: String
    let signature: String
    /// Set while a voice on this Mac is still rendering this track.
    private(set) var renderer: (any ReadingRenderer)?
    private var finishedMarks: ReadingMarks?

    init(url: URL, source: ReadingAudioSource, text: String, signature: String, renderer: (any ReadingRenderer)? = nil) {
        self.url = url
        self.source = source
        self.text = text
        self.signature = signature
        self.renderer = renderer
        if let renderer, renderer.isFinished { finishedRendering() }
    }

    var marks: ReadingMarks? { renderer?.marks ?? finishedMarks }
    var isRendering: Bool { renderer != nil }
    var isComplete: Bool { source.isComplete }

    func finishedRendering() {
        guard let renderer, renderer.isFinished else { return }
        finishedMarks = renderer.marks
        self.renderer = nil
    }

    /// Stops any rendering and removes the audio.
    func discard() {
        renderer?.cancel()
        renderer = nil
        AudioRenderer.remove(url)
    }
}

/// Where each spoken word starts in the rendered audio, and which displayed
/// characters it belongs to.
struct ReadingMarks: Equatable {
    private(set) var frames: [AVAudioFramePosition] = []
    private(set) var ranges: [NSRange] = []

    var isEmpty: Bool { frames.isEmpty }

    /// Words inside one replaced element share its range; keep only the first.
    mutating func append(frame: AVAudioFramePosition, range: NSRange?) {
        guard let range, range.location != NSNotFound, range.length > 0, ranges.last != range else { return }
        frames.append(max(frame, frames.last ?? 0))
        ranges.append(range)
    }

    /// The word being spoken at `frame`: the last one that started at or before it.
    func range(at frame: AVAudioFramePosition) -> NSRange? {
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle] <= frame { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : ranges[low - 1]
    }
}

/// Plays a reading through AVAudioEngine, scheduling a few seconds ahead of the
/// playhead from its source. A source that is still rendering can be played,
/// paused and sought within what exists; if playback catches up, it waits and
/// then continues from the same frame. `offline` renders without any audio
/// device, for checks.
@MainActor
final class ReadingPlayer {
    enum Output { case device, offline }
    static let lookaheadSeconds = 4.0
    static let chunkSeconds = 0.5

    let source: ReadingAudioSource
    let output: Output
    /// Called once when playback reaches the end, or cannot continue.
    var onFinish: ((ReadingPlayer, Bool) -> Void)?
    private(set) var isPlaying = false
    private(set) var isFinished = false
    /// Why the source could not be read: it threw, or a finished source had no
    /// audio where it said there was. It is never read again, and the next
    /// `tick()` reports the failure once through `onFinish`.
    private(set) var readFailure: Error?
    /// Playing, but caught up with a Mac voice that is still rendering.
    var isWaitingForAudio: Bool { isPlaying && !advancing && !isFinished }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var baseFrame: AVAudioFramePosition = 0
    private var scheduledEnd: AVAudioFramePosition = 0
    private var heldFrame: AVAudioFramePosition = 0
    private var lastFrame: AVAudioFramePosition = 0
    private var advancing = false
    private var configurationObserver: NSObjectProtocol?

    init(source: ReadingAudioSource, output: Output = .device) throws {
        self.source = source
        self.output = output
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: source.format)
        if output == .offline {
            try engine.enableManualRenderingMode(.offline, format: source.format, maximumFrameCount: 4_096)
        } else {
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recoverOutput() }
            }
        }
        engine.prepare()
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    var sampleRate: Double { source.format.sampleRate }
    /// What exists so far: the whole reading once rendering has finished.
    var duration: TimeInterval { Double(source.availableFrames) / sampleRate }
    var currentTime: TimeInterval {
        get { Double(positionFrame) / sampleRate }
        set { seek(toFrame: AVAudioFramePosition((newValue * sampleRate).rounded(.down))) }
    }

    /// The frame being played now, measured by the engine's playback clock.
    var positionFrame: AVAudioFramePosition {
        guard advancing else { return heldFrame }
        guard let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid, playerTime.sampleRate > 0 else {
            return lastFrame
        }
        let played = AVAudioFramePosition((Double(max(0, playerTime.sampleTime)) * sampleRate / playerTime.sampleRate).rounded(.down))
        lastFrame = min(baseFrame + played, scheduledEnd)
        return lastFrame
    }

    func play() -> Bool {
        guard !isFinished else { return false }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        isPlaying = true
        startAdvancing(from: heldFrame)
        return true
    }

    func pause() {
        guard isPlaying else { return }
        heldFrame = positionFrame
        stopNode()
        isPlaying = false
        if output == .device { engine.pause() }
    }

    func stop() {
        stopNode()
        engine.stop()
        isPlaying = false
        isFinished = true
    }

    /// Moves within the audio that exists. A paused reading stays paused.
    func seek(toFrame frame: AVAudioFramePosition) {
        guard !isFinished else { return }
        let target = min(max(0, frame), max(0, source.availableFrames - 1))
        stopNode()
        heldFrame = target
        lastFrame = target
        if isPlaying { startAdvancing(from: target) }
    }

    /// Keeps audio scheduled ahead of the playhead, and notices the end, an
    /// underrun while a Mac voice is still rendering, or audio that could not
    /// be read. Call it often.
    func tick() {
        guard !isFinished else { return }
        // Reported here, never from inside play() or seeking, so the owner
        // learns of it once, whether the reading was playing or just paused.
        if readFailure != nil { finish(false); return }
        guard isPlaying else { return }
        // Sleep or a lost output can stop the engine without a configuration
        // notice; continue from the same frame rather than stall silently.
        if output == .device, !engine.isRunning { recoverOutput(); return }
        if advancing {
            let position = positionFrame
            guard position >= scheduledEnd else { schedule(from: position); return }
            // Everything scheduled has played.
            if source.isComplete && scheduledEnd >= source.availableFrames { finish(true); return }
            heldFrame = scheduledEnd
            stopNode()
        }
        if source.availableFrames > heldFrame { startAdvancing(from: heldFrame) }
        else if source.isComplete { finish(true) }
    }

    /// Renders the next frames without an audio device (`offline` only).
    func renderOffline(_ frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard output == .offline, let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames) else {
            throw VoiceError.message("Offline rendering is only available to checks.")
        }
        if !engine.isRunning { try engine.start() }
        _ = try engine.renderOffline(frames, to: buffer)
        return buffer
    }

    private func startAdvancing(from frame: AVAudioFramePosition) {
        stopNode()
        baseFrame = frame
        scheduledEnd = frame
        heldFrame = frame
        lastFrame = frame
        schedule(from: frame)
        // Nothing rendered here yet: tick() starts once it exists. After a
        // read failure, tick() ends the reading instead.
        guard readFailure == nil, scheduledEnd > frame else { return }
        node.play()
        advancing = true
    }

    private func schedule(from position: AVAudioFramePosition) {
        guard readFailure == nil else { return }
        let chunk = AVAudioFramePosition(Self.chunkSeconds * sampleRate)
        let target = min(position + AVAudioFramePosition(Self.lookaheadSeconds * sampleRate), source.availableFrames)
        while scheduledEnd < target {
            let buffer: AVAudioPCMBuffer?
            do { buffer = try source.read(from: scheduledEnd, count: AVAudioFrameCount(min(chunk, target - scheduledEnd))) }
            catch { readFailure = error; return }
            guard let buffer, buffer.frameLength > 0 else {
                // A voice still rendering has not written this far yet: wait.
                // A finished source never will, so that is a failure too.
                if source.isComplete { readFailure = VoiceError.message("The reading audio ended before its expected length.") }
                return
            }
            node.scheduleBuffer(buffer, completionHandler: nil)
            scheduledEnd += AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func stopNode() {
        if advancing { lastFrame = positionFrame }
        node.stop()
        advancing = false
    }

    private func finish(_ success: Bool) {
        guard !isFinished else { return }
        heldFrame = min(positionFrame, source.availableFrames)
        stop()
        onFinish?(self, success)
    }

    /// A new output device or format stops the engine: continue from the same
    /// frame, or report an interruption if the output cannot restart.
    private func recoverOutput() {
        guard !isFinished else { return }
        let wasAdvancing = advancing, wasPlaying = isPlaying
        stopNode()
        let position = wasAdvancing ? lastFrame : heldFrame
        heldFrame = position
        guard wasPlaying else { return }
        engine.connect(node, to: engine.mainMixerNode, format: source.format)
        do {
            try engine.start()
            startAdvancing(from: position)
        } catch {
            finish(false)
        }
    }
}
