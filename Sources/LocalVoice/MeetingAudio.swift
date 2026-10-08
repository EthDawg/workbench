import AVFoundation
import CoreAudio
import Darwin
import Foundation

/// Host-clock helpers. Both capture paths report mach absolute times, so the
/// two originals keep a shared timeline instead of being assumed simultaneous.
enum MeetingClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func now() -> UInt64 { mach_absolute_time() }

    static func seconds(_ ticks: UInt64) -> Double {
        let info = timebase
        guard info.denom != 0 else { return 0 }
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    static func interval(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? seconds(end - start) : -seconds(start - end)
    }
}

struct MeetingCaptureRequest {
    /// The session's `tracks` directory. The capture writes only inside it.
    var tracksDirectory: URL
    /// nil means the person explicitly chose microphone only.
    var app: MeetingAudioApp?
    var includeMicrophone: Bool
    var onAudio: (@Sendable (MeetingAudioChunk) -> Void)? = nil
    /// Dictate supplies its existing recoverable WAV destination.
    var microphoneFileURL: URL? = nil
}

struct MeetingAudioChunk: Sendable {
    var source: MeetingTrackSource
    var samples: [Float]
    var sampleRate: Double
    var startSeconds: Double
}

struct MeetingCaptureReport {
    var tracks: [MeetingTrack] = []
    var seconds: Double = 0
    /// Why the capture stopped itself, if it did. Recorded audio is still kept.
    var failure: String?
    var gaps: [String] = []
    var liveAudioComplete: Bool = true
}

/// The capture the meeting owner drives. A synthetic implementation stands in
/// for checks; nothing here is started before an explicit Start.
protocol MeetingCapture: AnyObject {
    func start(_ request: MeetingCaptureRequest) async throws
    /// Flushes both originals and closes every owned resource on the lifecycle
    /// queue. A pending synchronous macOS access/start call must return first.
    /// Safe to call more than once.
    func finish() async -> MeetingCaptureReport
    /// Immediately invalidates a pending permission/start; finish awaits teardown.
    func requestStop()
    var elapsedSeconds: Double { get }
    /// Set as soon as the capture loses its source or cannot write.
    var stopReason: String? { get }
    func pause() async throws
    func resume() async throws
    var isPaused: Bool { get }
    var recoveryMessage: String? { get }
}

extension MeetingCapture {
    func pause() async throws { throw MeetingError.message("This recording cannot be paused.") }
    func resume() async throws { throw MeetingError.message("This recording cannot be resumed.") }
    var isPaused: Bool { false }
    var recoveryMessage: String? { nil }
}

/// The first received sample establishes one host-clock origin for both tracks.
/// The timing sidecar is committed before its first audio block is written.
final class MeetingCaptureTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: UInt64?
    func observe(_ hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if origin == nil { origin = hostTime }
    }
    func offset(_ hostTime: UInt64) -> Double {
        lock.lock(); defer { lock.unlock() }
        return max(0, MeetingClock.interval(from: origin ?? hostTime, to: hostTime))
    }
    var elapsed: Double {
        lock.lock(); defer { lock.unlock() }
        return origin.map { max(0, MeetingClock.interval(from: $0, to: MeetingClock.now())) } ?? 0
    }
}

struct MeetingTrackTiming: Codable {
    var source: MeetingTrackSource
    var startSeconds: Double
    var sampleRate: Double
    var gaps: [MeetingAudioGap]? = nil
}

struct MeetingAudioGap: Codable, Equatable, Sendable {
    var startSeconds: Double
    var seconds: Double
    var reason: String
}

/// Live delivery has its own bounded queue. A slow consumer cannot hold the
/// audio callback or disk writer; any omitted preview audio is reported.
final class MeetingAudioFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ethdawg.workbench.meeting.live", qos: .userInitiated)
    private let lock = NSLock()
    private let callback: @Sendable (MeetingAudioChunk) -> Void
    private var pending: [MeetingAudioChunk] = []
    private var pendingSeconds: Double = 0
    private var running = false
    private var closed = false
    private var omitted = false

    init(_ callback: @escaping @Sendable (MeetingAudioChunk) -> Void) { self.callback = callback }

    func append(_ chunk: MeetingAudioChunk) {
        lock.lock()
        let seconds = Double(chunk.samples.count) / chunk.sampleRate
        guard !closed else { lock.unlock(); return }
        guard pendingSeconds + seconds <= MeetingDiskBudget.captureBufferSeconds else {
            omitted = true; lock.unlock(); return
        }
        pending.append(chunk); pendingSeconds += seconds
        let launch = !running
        running = true
        lock.unlock()
        if launch { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else { running = false; lock.unlock(); return }
            let chunk = pending.removeFirst()
            pendingSeconds -= Double(chunk.samples.count) / chunk.sampleRate
            lock.unlock()
            callback(chunk)
        }
    }

    /// Normal consumers simply enqueue work and finish immediately. An
    /// unresponsive consumer cannot prevent the original recording closing.
    func finish() -> Bool {
        lock.lock(); closed = true; lock.unlock()
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        if done.wait(timeout: .now() + 1) == .timedOut {
            lock.lock(); omitted = true; pending.removeAll(); pendingSeconds = 0; lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }; return omitted
    }
}

/// Audio callbacks copy into a bounded packet queue. Conversion, timeline gap
/// padding, metadata and disk IO run only on the writer queue. The original
/// file keeps its initial sample rate even when a new route has another rate.
final class MeetingTrackRecorder: @unchecked Sendable {
    private struct Packet {
        var samples: [Float]
        var sampleRate: Double
        var hostTime: UInt64
    }
    let source: MeetingTrackSource
    let url: URL
    let sampleRate: Double
    private let metadataURL: URL
    private let timeline: MeetingCaptureTimeline
    private let allowsDiscontinuities: Bool
    private let feed: MeetingAudioFeed?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [Packet] = []
    private var pendingSeconds: Double = 0
    private var writtenFrames = 0
    private var droppedSeconds: Double = 0
    private var peakValue: Float = 0
    private var firstHostTime: UInt64?
    private var lastHostTime: UInt64?
    private var writeFailure: String?
    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var timingSaved = false
    private var discontinuityReason: String?
    private var savedGaps: [MeetingAudioGap] = []
    private var previewOmitted = false
    private var converter: AVAudioConverter?
    private var converterRate: Double?
    private var lastInputEnd: Double?

    init(source: MeetingTrackSource, directory: URL, sampleRate: Double, timeline: MeetingCaptureTimeline,
         allowsDiscontinuities: Bool = false, onAudio: (@Sendable (MeetingAudioChunk) -> Void)? = nil,
         explicitFileURL: URL? = nil) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw MeetingError.message("This audio source reports an unusable sample rate.")
        }
        self.source = source; self.sampleRate = sampleRate; self.timeline = timeline
        self.allowsDiscontinuities = allowsDiscontinuities
        feed = onAudio.map(MeetingAudioFeed.init)
        url = explicitFileURL ?? directory.appendingPathComponent("\(source.rawValue).caf")
        metadataURL = directory.appendingPathComponent("\(source.rawValue).json")
        queue = DispatchQueue(label: "com.ethdawg.workbench.meeting.write.\(source.rawValue)", qos: .utility)
    }

    func open() throws {
        try MeetingStore.rejectSymbolicLinks(in: url)
        try MeetingStore.rejectSymbolicLinks(in: metadataURL)
        guard !FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: metadataURL.path),
              FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MeetingError.message("The original audio file could not be created safely.")
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume(); self.timer = timer
    }

    func append(_ samples: UnsafePointer<Float>, count: Int, hostTime: UInt64, sourceRate: Double? = nil) {
        let rate = sourceRate ?? sampleRate
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed, writeFailure == nil else { return }
        guard count <= 65_536, rate.isFinite, (8_000...192_000).contains(rate) else {
            writeFailure = "The audio source supplied an unusable buffer. Audio already recorded was kept."
            return
        }
        let seconds = Double(count) / rate
        guard pendingSeconds + seconds <= MeetingDiskBudget.captureBufferSeconds else {
            droppedSeconds += seconds
            writeFailure = "The disk could not keep up with recording. Audio already written was kept."
            return
        }
        timeline.observe(hostTime)
        if firstHostTime == nil { firstHostTime = hostTime }
        lastHostTime = hostTime
        pending.append(Packet(samples: Array(UnsafeBufferPointer(start: samples, count: count)), sampleRate: rate, hostTime: hostTime))
        pendingSeconds += seconds
    }

    func markDiscontinuity(_ reason: String) {
        lock.lock(); discontinuityReason = reason; lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else { lock.unlock(); return }
            let packet = pending.removeFirst()
            pendingSeconds -= Double(packet.samples.count) / packet.sampleRate
            let reason = discontinuityReason
            let first = firstHostTime!
            lock.unlock()
            do { try write(packet, first: first, reason: reason) }
            catch {
                lock.lock()
                if writeFailure == nil { writeFailure = "The recording could not be saved. \(error.localizedDescription)" }
                droppedSeconds += Double(packet.samples.count) / packet.sampleRate + pendingSeconds
                pending.removeAll(); pendingSeconds = 0
                lock.unlock()
                return
            }
        }
    }

    private func write(_ packet: Packet, first: UInt64, reason: String?) throws {
        guard let file else { return }
        if let converterRate, converterRate != packet.sampleRate { try finishConversion(first: first) }
        let inputStart = MeetingClock.interval(from: first, to: packet.hostTime)
        let position = Int((max(0, inputStart) * sampleRate).rounded())
        // A resampler may retain a small filter tail. Compare source clocks,
        // not its currently emitted frames, when detecting a route gap.
        let delta = inputStart - (lastInputEnd ?? inputStart)
        let discontinuous = abs(delta) > (allowsDiscontinuities ? 0.025 : 0.25)
        if discontinuous && !allowsDiscontinuities {
            throw MeetingError.message("An audio source was interrupted. Recording stopped to preserve the timing of the audio already received.")
        }
        if position > Int((MeetingSegmentPlan.maximumMeetingSeconds - timeline.offset(first)) * sampleRate) {
            throw MeetingError.message("The two-hour recording limit was reached.")
        }
        if discontinuous {
            try finishConversion(first: first)
            if delta > 0 {
                let gap = MeetingAudioGap(startSeconds: timeline.offset(first) + Double(writtenFrames) / sampleRate,
                                          seconds: Double(max(0, position - writtenFrames)) / sampleRate,
                                          reason: reason ?? "The audio source temporarily stopped supplying samples.")
                lock.lock()
                let canSave = savedGaps.count < 256
                if canSave { savedGaps.append(gap) }
                if discontinuityReason == reason { discontinuityReason = nil }
                lock.unlock()
                guard canSave else { throw MeetingError.message("This audio source was interrupted too often to keep a reliable recording.") }
                try saveTiming(first: first)
                try writeSilence(max(0, position - writtenFrames), to: file)
            } else {
                // Never silently splice a clock that has gone backwards.
                throw MeetingError.message("The audio source returned overlapping timestamps. Audio already recorded was kept.")
            }
        }
        if !timingSaved { try saveTiming(first: first) }
        let samples = try convert(packet)
        let remaining = max(0, Int((MeetingSegmentPlan.maximumMeetingSeconds - timeline.offset(first)) * sampleRate) - writtenFrames)
        guard samples.count <= remaining else { throw MeetingError.message("The two-hour recording limit was reached.") }
        try commit(samples, first: first)
        lastInputEnd = inputStart + Double(packet.samples.count) / packet.sampleRate
    }

    private func convert(_ packet: Packet) throws -> [Float] {
        if packet.sampleRate == sampleRate { converter = nil; converterRate = nil; return packet.samples }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: packet.sampleRate, channels: 1, interleaved: false),
              let outputFormat = file?.processingFormat,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(packet.samples.count)) else {
            throw MeetingError.message("The changed audio route could not be converted.")
        }
        if converterRate != packet.sampleRate {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.primeMethod = .none
            converterRate = packet.sampleRate
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(packet.samples.count) * sampleRate / packet.sampleRate) + 256)),
              let inputSamples = input.floatChannelData?[0] else {
            throw MeetingError.message("The changed audio route could not be converted.")
        }
        input.frameLength = AVAudioFrameCount(packet.samples.count)
        packet.samples.withUnsafeBufferPointer { inputSamples.update(from: $0.baseAddress!, count: $0.count) }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error, let values = output.floatChannelData?[0] else {
            throw MeetingError.message("The changed audio route could not be converted.")
        }
        return Array(UnsafeBufferPointer(start: values, count: Int(output.frameLength)))
    }

    private func saveTiming(first: UInt64) throws {
        lock.lock(); let gaps = savedGaps; lock.unlock()
        let timing = MeetingTrackTiming(source: source, startSeconds: timeline.offset(first), sampleRate: sampleRate,
                                        gaps: gaps.isEmpty ? nil : gaps)
        try MeetingStore.writePrivate(JSONEncoder().encode(timing), to: metadataURL)
        timingSaved = true
    }

    private func writeSamples(_ samples: [Float], to file: AVAudioFile) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw MeetingError.message("The audio writer could not allocate its next buffer. Original audio already written was kept.")
        }
        var peak: Float = 0
        for index in samples.indices {
            let value = samples[index].isFinite ? max(-1, min(1, samples[index])) : 0
            channel[index] = value; peak = max(peak, abs(value))
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
        lock.lock(); writtenFrames += samples.count; peakValue = max(peakValue, peak); lock.unlock()
    }

    private func commit(_ samples: [Float], first: UInt64) throws {
        guard let file, !samples.isEmpty else { return }
        let start = timeline.offset(first) + Double(writtenFrames) / sampleRate
        try writeSamples(samples, to: file)
        feed?.append(MeetingAudioChunk(source: source, samples: samples, sampleRate: sampleRate, startSeconds: start))
    }

    private func finishConversion(first: UInt64) throws {
        guard let converter, let format = file?.processingFormat else { return }
        defer { self.converter = nil; converterRate = nil }
        for _ in 0..<16 {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
                throw MeetingError.message("The audio conversion could not finish.")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            if let error { throw error }
            guard status != .error else { throw MeetingError.message("The audio conversion could not finish.") }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                try commit(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))), first: first)
            }
            if status == .endOfStream || output.frameLength == 0 { return }
        }
        throw MeetingError.message("The audio conversion did not finish within its buffer limit.")
    }

    private func writeSilence(_ count: Int, to file: AVAudioFile) throws {
        let block = [Float](repeating: 0, count: min(count, 16_384))
        var remaining = count
        while remaining > 0 {
            let take = min(remaining, block.count)
            try writeSamples(take == block.count ? block : Array(block.prefix(take)), to: file)
            remaining -= take
        }
    }

    /// Called from the capture lifecycle queue, never the main actor.
    func close() -> MeetingTrack {
        lock.lock(); closed = true; lock.unlock()
        queue.sync {
            timer?.cancel(); timer = nil; drain()
            if let first = firstHostTime {
                do { try finishConversion(first: first) }
                catch { lock.lock(); if writeFailure == nil { writeFailure = error.localizedDescription }; lock.unlock() }
            }
            file = nil; converter = nil
        }
        let omitted = feed?.finish() ?? false
        lock.lock(); previewOmitted = previewOmitted || omitted; defer { lock.unlock() }
        return MeetingTrack(source: source, file: "\(MeetingStore.tracksDirectory)/\(source.rawValue).caf",
                            startSeconds: firstHostTime.map { timeline.offset($0) } ?? 0,
                            seconds: Double(writtenFrames) / sampleRate, sampleRate: sampleRate,
                            peak: Double(peakValue), droppedSeconds: droppedSeconds)
    }

    var gaps: [String] {
        lock.lock(); defer { lock.unlock() }
        var notes = savedGaps.map { "\(source.rawValue): \($0.reason) Gap at \(String(format: "%.2f", $0.startSeconds))s for \(String(format: "%.2f", $0.seconds))s; the saved timeline includes silence." }
        if previewOmitted { notes.append("Live preview could not keep up; the original audio was preserved for transcription.") }
        return notes
    }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return writeFailure }
    var liveAudioComplete: Bool { lock.lock(); defer { lock.unlock() }; return !previewOmitted }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    var secondsSinceLastBuffer: Double? {
        lock.lock(); defer { lock.unlock() }
        return lastHostTime.map { max(0, MeetingClock.interval(from: $0, to: MeetingClock.now())) }
    }
}

// MARK: - CoreAudio process metadata

/// Read-only CoreAudio process metadata. No audio is read here: only the
/// process list, its PID, bundle identifier and whether it is running IO.
enum MeetingCoreAudio {
    static var isProcessMetadataAvailable: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    static var unavailableReason: String {
        "Meeting audio needs macOS 14.2 or later. This Mac cannot list audio apps or record another app's sound."
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func processObjects() -> [AudioObjectID] { (try? processObjectsChecked()) ?? [] }

    static func processObjectsChecked() throws -> [AudioObjectID] {
        guard isProcessMetadataAvailable else { throw MeetingError.message(unavailableReason) }
        var property = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr,
              size <= 1_048_576 else { throw MeetingError.message("Core Audio process metadata is unavailable.") }
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = objects.withUnsafeMutableBytes { raw -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { throw MeetingError.message("Core Audio process metadata is unavailable (\(status)).") }
        return objects.filter { $0 != kAudioObjectUnknown }
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        guard isProcessMetadataAvailable else { return nil }
        var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var value = pid
        var object = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &value) { qualifier -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                                       UInt32(MemoryLayout<pid_t>.size), qualifier, &size, &object)
        }
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    static func processID(of object: AudioObjectID) -> pid_t? {
        guard isProcessMetadataAvailable else { return nil }
        var property = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    static func bundleID(of object: AudioObjectID) -> String? {
        guard isProcessMetadataAvailable else { return nil }
        var property = address(kAudioProcessPropertyBundleID)
        var raw: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &raw) { pointer -> OSStatus in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer)
        }
        guard status == noErr, let raw else { return nil }
        let value = raw.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    static func activity(_ object: AudioObjectID, input: Bool) throws -> Bool {
        guard isProcessMetadataAvailable else { throw MeetingError.message(unavailableReason) }
        var property = address(input ? kAudioProcessPropertyIsRunningInput : kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
        guard status == noErr else { throw MeetingError.message("Audio activity is unavailable (\(status)).") }
        return value != 0
    }

    static func defaultOutputDeviceUID() -> String? {
        defaultDeviceUID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputDeviceUID() -> String? {
        defaultDeviceUID(kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func defaultDeviceUID(_ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var uidProperty = address(kAudioDevicePropertyDeviceUID)
        var raw: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &raw) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &uidProperty, 0, nil, &uidSize, pointer)
        }
        guard status == noErr, let raw else { return nil }
        return raw.takeRetainedValue() as String
    }

    @available(macOS 14.2, *)
    static func tapUID(_ tap: AudioObjectID) -> String? {
        var property = address(kAudioTapPropertyUID)
        var raw: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &raw) { pointer -> OSStatus in
            AudioObjectGetPropertyData(tap, &property, 0, nil, &size, pointer)
        }
        guard status == noErr, let raw else { return nil }
        return raw.takeRetainedValue() as String
    }

    @available(macOS 14.2, *)
    static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var property = address(kAudioTapPropertyFormat)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &value) == noErr, value.mSampleRate > 0 else { return nil }
        return value
    }
}

// MARK: - Private process tap

/// A private, unmuted CoreAudio process tap plus a private aggregate device.
/// Unmuted keeps the person's own playback audible in their headphones. The
/// default output device is never changed and no virtual driver is installed.
@available(macOS 14.2, *)
final class MeetingProcessTap: @unchecked Sendable {
    let format: AVAudioFormat
    private var tapID = kAudioObjectUnknown
    private var aggregateID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.ethdawg.workbench.meeting.tap", qos: .userInitiated)

    init(app: MeetingAudioApp) throws {
        guard let selected = MeetingCoreAudio.processObject(for: pid_t(app.id)),
              let bundle = MeetingCoreAudio.bundleID(of: selected),
              (MeetingAppCatalogue.known(bundle)?.bundleID ?? bundle) == app.bundleID,
              !MeetingAppCatalogue.isExcluded(bundle), app.id != ProcessInfo.processInfo.processIdentifier else {
            throw MeetingError.message("That app is not producing audio on this Mac right now. Start its call, then choose it again.")
        }
        let processes = try MeetingCoreAudio.processObjectsChecked().filter { object in
            guard let bundle = MeetingCoreAudio.bundleID(of: object) else { return false }
            return (MeetingAppCatalogue.known(bundle)?.bundleID ?? bundle) == app.bundleID
        }
        guard processes.contains(selected) else {
            throw MeetingError.message("The selected audio process changed before recording. Choose it again.")
        }
        let description = CATapDescription(monoMixdownOfProcesses: processes)
        description.name = "Workbench meeting capture"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = kAudioObjectUnknown
        var device = kAudioObjectUnknown
        // Local teardown: `self` is not fully initialised until `format` is set.
        func unwind() {
            if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
            if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        }

        let created = AudioHardwareCreateProcessTap(description, &tap)
        guard created == noErr, tap != kAudioObjectUnknown else {
            throw Self.startProblem(status: created)
        }

        guard var asbd = MeetingCoreAudio.tapFormat(tap),
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mChannelsPerFrame == 1,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            unwind()
            throw MeetingError.message("That app's audio format could not be read, so recording did not start.")
        }

        let uid = MeetingCoreAudio.tapUID(tap) ?? description.uuid.uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Workbench Meeting Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: uid]]
        ]
        let aggregated = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard aggregated == noErr, device != kAudioObjectUnknown else {
            unwind()
            if aggregated == kAudioDevicePermissionsError { throw Self.startProblem(status: aggregated) }
            throw MeetingError.message("Workbench could not prepare its private capture device (CoreAudio error \(aggregated)).")
        }
        self.format = format
        self.tapID = tap
        self.aggregateID = device
    }

    static func startProblem(status: OSStatus) -> MeetingProblem {
        // AudioHardwareBase.h explicitly defines this as a process permission
        // refusal. Generic 'nope' and other statuses do not establish TCC denial.
        status == kAudioDevicePermissionsError ? .appAudioPermission(status) : .appAudioUnknown(status)
    }

    func begin(_ handler: @escaping (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void) throws {
        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, inputTime, _, _ in
            handler(input, inputTime)
        }
        guard created == noErr, let procID else {
            throw MeetingError.message("Workbench could not attach to the app's audio (CoreAudio error \(created)).")
        }
        ioProcID = procID
        // This synchronous HAL call may wait for macOS's audio-consent UI.
        // Cancellation prevents later samples; teardown waits for its return.
        let started = AudioDeviceStart(aggregateID, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
            if started == kAudioDevicePermissionsError { throw Self.startProblem(status: started) }
            throw MeetingError.message("Workbench could not start the app's audio capture (CoreAudio error \(started)).")
        }
    }

    /// Deterministic teardown in creation order's reverse. Safe to call twice.
    func destroy() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit { destroy() }
}

// MARK: - Mono conversion helpers

enum MeetingMono {
    /// Copies one IO cycle into a mono scratch buffer. Handles the interleaved
    /// and planar layouts a tap or input node can present.
    static func fill(from list: UnsafePointer<AudioBufferList>, into scratch: inout [Float]) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count > 0, let first = buffers[0].mData else { return 0 }
        let channels = max(1, Int(buffers[0].mNumberChannels))
        let frames = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return 0 }
        guard scratch.count >= frames else { return 0 }
        let source = first.assumingMemoryBound(to: Float.self)
        if buffers.count == 1 && channels == 1 {
            scratch.withUnsafeMutableBufferPointer { $0.baseAddress?.update(from: source, count: frames) }
            return frames
        }
        if buffers.count == 1 {
            for frame in 0..<frames {
                var total: Float = 0
                for channel in 0..<channels { total += source[frame * channels + channel] }
                scratch[frame] = total / Float(channels)
            }
            return frames
        }
        for frame in 0..<frames { scratch[frame] = source[frame] }
        var used = 1
        for index in 1..<buffers.count {
            guard let data = buffers[index].mData, Int(buffers[index].mNumberChannels) == 1,
                  Int(buffers[index].mDataByteSize) / MemoryLayout<Float>.size >= frames else { continue }
            let channel = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames { scratch[frame] += channel[frame] }
            used += 1
        }
        if used > 1 {
            let scale = 1 / Float(used)
            for frame in 0..<frames { scratch[frame] *= scale }
        }
        return frames
    }

    static func fill(from buffer: AVAudioPCMBuffer, into scratch: inout [Float]) -> Int {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return 0 }
        guard scratch.count >= frames else { return 0 }
        let channels = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved {
            let source = data[0]
            for frame in 0..<frames {
                var total: Float = 0
                for channel in 0..<channels { total += source[frame * channels + channel] }
                scratch[frame] = total / Float(max(channels, 1))
            }
            return frames
        }
        for frame in 0..<frames { scratch[frame] = data[0][frame] }
        if channels > 1 {
            for channel in 1..<channels {
                for frame in 0..<frames { scratch[frame] += data[channel][frame] }
            }
            let scale = 1 / Float(channels)
            for frame in 0..<frames { scratch[frame] *= scale }
        }
        return frames
    }
}

// MARK: - System capture

/// The serial lifecycle queue owns creation and teardown. A cancellation flag
/// is checked before every acquisition and inside both callbacks, including a
/// late return from macOS's system-audio permission prompt.
final class MeetingSystemCapture: MeetingCapture, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ethdawg.workbench.meeting.lifecycle", qos: .userInitiated)
    private let lock = NSLock()
    private let timeline = MeetingCaptureTimeline()
    private var remote: MeetingTrackRecorder?
    private var local: MeetingTrackRecorder?
    private var tapBox: AnyObject?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var routeTimer: DispatchSourceTimer?
    private var startedHost: UInt64?
    private var reason: String?
    private var recovery: String?
    private var report: MeetingCaptureReport?
    private var stopping = false
    private var paused = false
    private var recoveryQueued = false
    private var generation: UInt64 = 0
    private var request: MeetingCaptureRequest?
    private var chosenApp: MeetingAudioApp?
    private var outputUID: String?
    private var inputUID: String?
    private var microphoneIncluded = false
    private var recoveryStarted: UInt64?
    private var lastRecoveryAttempt: UInt64?

    var elapsedSeconds: Double { timeline.elapsed }
    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    var recoveryMessage: String? { lock.lock(); defer { lock.unlock() }; return recovery }

    var stopReason: String? {
        lock.lock(); let prior = reason, recorders = [remote, local]; lock.unlock()
        return prior ?? recorders.compactMap { $0?.failure }.first
    }

    private func note(_ text: String) {
        lock.lock(); if reason == nil { reason = text }; lock.unlock()
    }

    func requestStop() { lock.lock(); stopping = true; generation &+= 1; lock.unlock() }

    private func accepts(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopping && !paused && generation == token
    }

    func start(_ request: MeetingCaptureRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { try startNow(request); continuation.resume() }
                catch { _ = closeEverything(); continuation.resume(throwing: error) }
            }
        }
    }

    private func checkStart() throws {
        if isStopping { throw CancellationError() }
    }

    private func startNow(_ request: MeetingCaptureRequest) throws {
        try checkStart()
        guard request.app != nil || request.includeMicrophone else {
            throw MeetingError.message("Choose an app, the microphone, or both.")
        }
        guard self.request == nil else { throw MeetingError.message("This recording has already started.") }
        try MeetingStore.createPrivateDirectory(request.tracksDirectory)
        try MeetingDiskBudget.checkStartSpace(at: request.tracksDirectory)
        self.request = request
        chosenApp = request.app; microphoneIncluded = request.includeMicrophone
        try startRoutes()
        try checkStart()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.checkRoutes() }
        timer.resume(); routeTimer = timer
    }

    /// Only the explicitly chosen app's bundle may be rebound. A restarted
    /// process never broadens capture to all Mac audio or a different app.
    private func currentApp(_ original: MeetingAudioApp) throws -> MeetingAudioApp {
        func matches(_ object: AudioObjectID) -> Bool {
            guard let bundle = MeetingCoreAudio.bundleID(of: object), !MeetingAppCatalogue.isExcluded(bundle) else { return false }
            return (MeetingAppCatalogue.known(bundle)?.bundleID ?? bundle) == original.bundleID
        }
        if let object = MeetingCoreAudio.processObject(for: original.id), matches(object) { return original }
        for object in try MeetingCoreAudio.processObjectsChecked() where matches(object) {
            if let pid = MeetingCoreAudio.processID(of: object), pid != ProcessInfo.processInfo.processIdentifier {
                return MeetingAudioApp(id: pid, name: original.name, bundleID: original.bundleID)
            }
        }
        throw MeetingError.message("The selected app is not supplying audio on this Mac.")
    }

    private func startRoutes() throws {
        try checkStart()
        guard let request else { throw CancellationError() }
        lock.lock(); generation &+= 1; let token = generation; lock.unlock()
        outputUID = MeetingCoreAudio.defaultOutputDeviceUID()
        inputUID = MeetingCoreAudio.defaultInputDeviceUID()
        startedHost = MeetingClock.now()
        if let original = request.app {
            guard #available(macOS 14.2, *) else { throw MeetingError.message(MeetingCoreAudio.unavailableReason) }
            let app = try currentApp(original)
            let tap = try MeetingProcessTap(app: app)
            tapBox = tap; chosenApp = app
            try checkStart()
            let recorder: MeetingTrackRecorder
            if let existing = remote { recorder = existing }
            else {
                recorder = try MeetingTrackRecorder(source: .remote, directory: request.tracksDirectory,
                    sampleRate: tap.format.sampleRate, timeline: timeline, allowsDiscontinuities: true, onAudio: request.onAudio)
                try recorder.open()
                lock.lock(); remote = recorder; lock.unlock()
            }
            let rate = tap.format.sampleRate
            var scratch = [Float](repeating: 0, count: 65_536)
            try tap.begin { [weak self, recorder] buffers, time in
                guard let self, self.accepts(token), !recorder.isClosed else { return }
                guard buffers.pointee.mNumberBuffers == 1, buffers.pointee.mBuffers.mNumberChannels == 1 else {
                    self.requestRecovery("The app audio format changed.", token: token); return
                }
                let frames = MeetingMono.fill(from: buffers, into: &scratch)
                guard frames > 0 else { return }
                let host = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : MeetingClock.now()
                scratch.withUnsafeBufferPointer { recorder.append($0.baseAddress!, count: frames, hostTime: host, sourceRate: rate) }
            }
            try checkStart()
        }
        if microphoneIncluded { try startMicrophone(request, token: token) }
    }

    private func startMicrophone(_ request: MeetingCaptureRequest, token: UInt64) throws {
        try checkStart()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MeetingError.message("Microphone access is required for the selected recording.")
        }
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw MeetingError.message("No usable microphone input is available. Choose an input in Sound settings, or record the app only.")
        }
        let recorder: MeetingTrackRecorder
        if let existing = local { recorder = existing }
        else {
            recorder = try MeetingTrackRecorder(source: .local, directory: request.tracksDirectory,
                sampleRate: request.microphoneFileURL == nil ? format.sampleRate : MeetingSegmentPlan.sampleRate,
                timeline: timeline, allowsDiscontinuities: true,
                onAudio: request.onAudio, explicitFileURL: request.microphoneFileURL)
            try recorder.open()
            lock.lock(); local = recorder; lock.unlock()
        }
        let rate = format.sampleRate
        var scratch = [Float](repeating: 0, count: 65_536)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self, recorder] buffer, time in
            guard let self, self.accepts(token), !recorder.isClosed else { return }
            let frames = MeetingMono.fill(from: buffer, into: &scratch)
            guard frames > 0 else { return }
            let host = time.isHostTimeValid ? time.hostTime : MeetingClock.now()
            scratch.withUnsafeBufferPointer { recorder.append($0.baseAddress!, count: frames, hostTime: host, sourceRate: rate) }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audio, queue: nil) { [weak self] _ in
                self?.requestRecovery("The microphone device changed.", token: token)
            }
        engine = audio
        audio.prepare()
        try checkStart()
        do { try audio.start() }
        catch { throw MeetingError.message("The microphone could not start. \(error.localizedDescription)") }
    }

    private func requestRecovery(_ message: String, token: UInt64) {
        lock.lock()
        guard !stopping, !paused, generation == token, !recoveryQueued else { lock.unlock(); return }
        recoveryQueued = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.recoveryQueued = false; self.lock.unlock()
            if self.accepts(token) { self.beginRecovery(message) }
        }
    }

    private func beginRecovery(_ message: String) {
        guard !isStopping, !isPaused, stopReason == nil else { return }
        guard recoveryStarted == nil else { return }
        recoveryStarted = MeetingClock.now()
        lock.lock(); recovery = "Reconnecting audio. \(message)"; generation &+= 1; lock.unlock()
        remote?.markDiscontinuity(message); local?.markDiscontinuity(message)
        restoreRoutes()
    }

    private func restoreRoutes() {
        disconnectRoutes()
        guard !isStopping, !isPaused else { return }
        lastRecoveryAttempt = MeetingClock.now()
        do { try startRoutes() }
        catch {
            disconnectRoutes()
            if !isStopping {
                lock.lock(); recovery = "Reconnecting audio. \(error.localizedDescription)"; lock.unlock()
            }
        }
    }

    private func checkRoutes() {
        guard !isStopping, !isPaused, stopReason == nil else { return }
        if microphoneIncluded, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            note("Microphone access was removed. The audio already recorded was kept."); return
        }
        let now = MeetingClock.now()
        let recorders = [remote, local].compactMap { $0 }
        if let started = recoveryStarted {
            let sinceAttempt = lastRecoveryAttempt.map { MeetingClock.interval(from: $0, to: now) } ?? 0
            if !recorders.isEmpty, recorders.allSatisfy({ ($0.secondsSinceLastBuffer ?? .infinity) < min(1.5, sinceAttempt) }),
               engine != nil || !microphoneIncluded, tapBox != nil || request?.app == nil {
                recoveryStarted = nil; lastRecoveryAttempt = nil
                lock.lock(); recovery = nil; lock.unlock()
                return
            }
            if MeetingClock.interval(from: started, to: now) > 15 {
                note("The selected audio source could not reconnect. The recording was kept with its interruption marked.")
                return
            }
            if lastRecoveryAttempt.map({ MeetingClock.interval(from: $0, to: now) > 2 }) ?? true { restoreRoutes() }
            return
        }
        if request?.app != nil, MeetingCoreAudio.defaultOutputDeviceUID() != outputUID {
            beginRecovery("The Mac audio output changed."); return
        }
        if microphoneIncluded, MeetingCoreAudio.defaultInputDeviceUID() != inputUID {
            beginRecovery("The microphone device changed."); return
        }
        if let app = chosenApp, MeetingCoreAudio.processObject(for: app.id) == nil {
            beginRecovery("The selected app's audio process changed."); return
        }
        if let start = startedHost, MeetingClock.interval(from: start, to: now) > 12,
           recorders.contains(where: { ($0.secondsSinceLastBuffer ?? .infinity) > 12 }) {
            beginRecovery("An audio source stopped supplying samples.")
        }
    }

    func pause() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try checkStart()
                    guard request != nil else { throw MeetingError.message("This recording has not started.") }
                    guard !isPaused else { continuation.resume(); return }
                    lock.lock(); paused = true; generation &+= 1; recovery = nil; lock.unlock()
                    recoveryStarted = nil; lastRecoveryAttempt = nil
                    remote?.markDiscontinuity("Recording was paused."); local?.markDiscontinuity("Recording was paused.")
                    disconnectRoutes()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func resume() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try checkStart()
                    guard request != nil else { throw MeetingError.message("This recording has not started.") }
                    guard isPaused else { continuation.resume(); return }
                    lock.lock(); paused = false; lock.unlock()
                    beginRecovery("Resuming the selected audio sources.")
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func disconnectRoutes() {
        lock.lock(); generation &+= 1; lock.unlock()
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        if #available(macOS 14.2, *), let tap = tapBox as? MeetingProcessTap { tap.destroy() }
        tapBox = nil
    }

    func finish() async -> MeetingCaptureReport {
        requestStop()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: closeEverything()) }
        }
    }

    private func closeEverything() -> MeetingCaptureReport {
        if let report { return report }
        requestStop()
        routeTimer?.cancel(); routeTimer = nil
        disconnectRoutes()
        lock.lock(); let recorders = [remote, local].compactMap { $0 }; lock.unlock()
        let tracks = recorders.map { $0.close() }.filter { $0.seconds > 0 }
        lock.lock()
        let failure = reason ?? recorders.compactMap { $0.failure }.first
        let result = MeetingCaptureReport(tracks: tracks,
                                          seconds: tracks.map { $0.startSeconds + $0.seconds }.max() ?? 0,
                                          failure: failure, gaps: recorders.flatMap(\.gaps),
                                          liveAudioComplete: recorders.allSatisfy(\.liveAudioComplete))
        report = result; remote = nil; local = nil; startedHost = nil; recovery = nil
        lock.unlock()
        return result
    }
}

// MARK: - Offline mixing and segmenting

/// Resamples one preserved source in small blocks. Read/conversion errors are
/// failures, never silently converted into a claim of complete audio.
final class MeetingTrackReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let blockFrames: Int
    private var leadRemaining: Int
    private var pending = [Float]()
    private var pendingIndex = 0
    private var sourceExhausted = false
    private var finished = false
    private var readFailure: Error?

    init(url: URL, startSeconds: Double, blockFrames: Int) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MeetingSegmentPlan.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: output) else {
            throw MeetingError.message("An original audio track cannot be converted. Its file was left unchanged.")
        }
        self.file = file; self.converter = converter; self.outputFormat = output
        self.blockFrames = blockFrames
        leadRemaining = max(0, Int((startSeconds * MeetingSegmentPlan.sampleRate).rounded()))
    }

    func read(_ count: Int, into destination: inout [Float]) throws {
        var produced = 0
        while produced < count {
            if leadRemaining > 0 {
                let silence = min(leadRemaining, count - produced)
                for index in 0..<silence { destination[produced + index] = 0 }
                leadRemaining -= silence; produced += silence
                continue
            }
            if pendingIndex >= pending.count { try fillPending() }
            if pendingIndex >= pending.count {
                for index in produced..<count { destination[index] = 0 }
                return
            }
            let take = min(pending.count - pendingIndex, count - produced)
            for index in 0..<take { destination[produced + index] = pending[pendingIndex + index] }
            pendingIndex += take; produced += take
        }
    }

    private func fillPending() throws {
        guard !finished else { return }
        pending.removeAll(keepingCapacity: true); pendingIndex = 0
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(blockFrames)) else {
            throw MeetingError.message("The audio conversion buffer could not be allocated.")
        }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] _, outStatus in
            guard !sourceExhausted, file.framePosition < file.length else {
                sourceExhausted = true; outStatus.pointee = .endOfStream; return nil
            }
            let requested = AVAudioFrameCount(min(Int64(blockFrames), file.length - file.framePosition))
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(blockFrames)) else {
                readFailure = MeetingError.message("The original audio buffer could not be allocated.")
                sourceExhausted = true; outStatus.pointee = .endOfStream; return nil
            }
            do { try file.read(into: input, frameCount: requested) }
            catch { readFailure = error; sourceExhausted = true; outStatus.pointee = .endOfStream; return nil }
            if input.frameLength == 0 { sourceExhausted = true; outStatus.pointee = .endOfStream; return nil }
            outStatus.pointee = .haveData
            return input
        }
        if let readFailure { throw readFailure }
        if status == .error { throw conversionError ?? MeetingError.message("Original audio conversion failed.") as NSError }
        let frames = Int(output.frameLength)
        if frames > 0, let channel = output.floatChannelData?[0] {
            pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        }
        if status == .endOfStream || (frames == 0 && sourceExhausted) { finished = true }
        if frames == 0, !finished { throw MeetingError.message("Original audio conversion made no progress.") }
    }
}

/// Both tracks share one host-time timeline. Generated WAV files are bounded,
/// atomic, and never replace an existing different segment.
enum MeetingMixer {
    static let blockFrames = 8_192

    static func writeSegments(tracks: [MeetingTrack], session: URL) throws -> [MeetingSegment] {
        let total = tracks.map { $0.startSeconds + $0.seconds }.max() ?? 0
        let windows = MeetingSegmentPlan.plan(totalSeconds: total)
        guard !windows.isEmpty else { return [] }
        let directory = session.appendingPathComponent(MeetingStore.segmentsDirectory, isDirectory: true)
        try MeetingStore.createPrivateDirectory(directory)
        let readers = try tracks.sorted { $0.source.rawValue < $1.source.rawValue }.map { track in
            let url = try MeetingStore.safeURL(session: session, relative: track.file)
            return try MeetingTrackReader(url: url, startSeconds: track.startSeconds, blockFrames: blockFrames)
        }
        guard !readers.isEmpty else { throw MeetingError.message("The recording has no readable original audio.") }
        var segments: [MeetingSegment] = []
        for window in windows {
            try Task.checkCancellation()
            let relative = MeetingSegmentPlan.filename(index: window.index)
            let destination = try MeetingStore.safeURL(session: session, relative: relative)
            let temporary = directory.appendingPathComponent(".segment-" + UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try write(window: window, readers: readers, to: temporary)
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= MeetingSegmentPlan.maximumSegmentBytes else {
                throw MeetingError.message("A recognition segment exceeded its size limit. Originals were preserved.")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try sameBytes(temporary, destination) else {
                    throw MeetingError.message("An existing recognition segment differs from the original tracks. Both were left unchanged.")
                }
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            segments.append(MeetingSegment(index: window.index, file: relative, startSeconds: window.start,
                                           seconds: window.seconds, bytes: size, text: nil))
        }
        return segments
    }

    private static func write(window: MeetingSegmentPlan.Window, readers: [MeetingTrackReader], to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MeetingError.message("A private recognition segment could not be created.")
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                       AVSampleRateKey: MeetingSegmentPlan.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(blockFrames)) else {
            throw MeetingError.message("A recognition segment buffer could not be allocated.")
        }
        var mixed = [Float](repeating: 0, count: blockFrames)
        var lane = [Float](repeating: 0, count: blockFrames)
        var remaining = Int((window.seconds * MeetingSegmentPlan.sampleRate).rounded())
        while remaining > 0 {
            try Task.checkCancellation()
            let count = min(blockFrames, remaining)
            for index in 0..<count { mixed[index] = 0 }
            for reader in readers {
                try reader.read(count, into: &lane)
                for index in 0..<count { mixed[index] += lane[index] / Float(readers.count) }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if let channel = buffer.floatChannelData?[0] {
                mixed.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: count) }
            }
            try file.write(from: buffer)
            remaining -= count
        }
    }

    private static func sameBytes(_ first: URL, _ second: URL) throws -> Bool {
        let left = try FileHandle(forReadingFrom: first), right = try FileHandle(forReadingFrom: second)
        defer { try? left.close(); try? right.close() }
        while true {
            try Task.checkCancellation()
            let a = try left.read(upToCount: 65_536) ?? Data()
            let b = try right.read(upToCount: 65_536) ?? Data()
            guard a == b else { return false }
            if a.isEmpty { return true }
        }
    }
}
