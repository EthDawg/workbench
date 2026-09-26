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
}

struct MeetingCaptureReport {
    var tracks: [MeetingTrack] = []
    var seconds: Double = 0
    /// Why the capture stopped itself, if it did. Recorded audio is still kept.
    var failure: String?
}

/// The capture the meeting owner drives. A synthetic implementation stands in
/// for checks; nothing here is started before an explicit Start.
protocol MeetingCapture: AnyObject {
    func start(_ request: MeetingCaptureRequest) async throws
    /// Stops deterministically, flushes both originals and closes every owned
    /// resource. Safe to call more than once.
    func finish() async -> MeetingCaptureReport
    /// Immediately invalidates a pending permission/start; finish awaits teardown.
    func requestStop()
    var elapsedSeconds: Double { get }
    /// Set as soon as the capture loses its source or cannot write.
    var stopReason: String? { get }
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
}

/// A bounded, mono original. Disk IO stays on the writer queue. Overflow or a
/// discontinuous source stops accepting samples instead of compressing time.
final class MeetingTrackRecorder: @unchecked Sendable {
    let source: MeetingTrackSource
    let url: URL
    let sampleRate: Double
    private let timeline: MeetingCaptureTimeline
    private let capacity: Int
    private let drainFrames: Int
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var ring: [Float]
    private var scratch: [Float]
    private var head = 0
    private var available = 0
    private var receivedFrames = 0
    private var droppedFrames = 0
    private var writtenFrames = 0
    private var peakValue: Float = 0
    private var firstHostTime: UInt64?
    private var lastHostTime: UInt64?
    private var writeFailure: String?
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var timingSaved = false

    init(source: MeetingTrackSource, directory: URL, sampleRate: Double, timeline: MeetingCaptureTimeline) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw MeetingError.message("This audio source reports an unusable sample rate.")
        }
        self.source = source; self.sampleRate = sampleRate; self.timeline = timeline
        url = directory.appendingPathComponent("\(source.rawValue).caf")
        capacity = max(4_096, Int(sampleRate * MeetingDiskBudget.captureBufferSeconds))
        drainFrames = max(1_024, Int(sampleRate / 2))
        queue = DispatchQueue(label: "com.ethdawg.workbench.meeting.write.\(source.rawValue)", qos: .utility)
        ring = [Float](repeating: 0, count: capacity)
        scratch = [Float](repeating: 0, count: drainFrames)
    }

    func open() throws {
        try MeetingStore.rejectSymbolicLinks(in: url)
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MeetingError.message("The original audio file could not be created safely.")
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let audio = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let staging = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(drainFrames)) else {
            throw MeetingError.message("The recording buffer could not be prepared.")
        }
        file = audio; buffer = staging
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume(); timer = source
    }

    func append(_ samples: UnsafePointer<Float>, count: Int, hostTime: UInt64) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed, writeFailure == nil else { return }
        timeline.observe(hostTime)
        if firstHostTime == nil { firstHostTime = hostTime }
        let interval = MeetingClock.interval(from: firstHostTime!, to: hostTime)
        let expected = Double(receivedFrames) / sampleRate
        guard abs(interval - expected) < 0.25 else {
            droppedFrames += count
            writeFailure = "An audio source was interrupted. Recording stopped to preserve the timing of the audio already received."
            return
        }
        lastHostTime = hostTime
        let maximum = Int(max(0, MeetingSegmentPlan.maximumMeetingSeconds - timeline.offset(firstHostTime!)) * sampleRate)
        let accepted = min(count, capacity - available, max(0, maximum - receivedFrames))
        if accepted < count {
            droppedFrames += count - accepted
            writeFailure = receivedFrames + count > maximum
                ? "The two-hour recording limit was reached."
                : "The disk could not keep up with recording. Audio already written was kept."
        }
        for index in 0..<accepted {
            let sample = samples[index].isFinite ? max(-1, min(1, samples[index])) : 0
            ring[(head + available + index) % capacity] = sample
            peakValue = max(peakValue, abs(sample))
        }
        available += accepted; receivedFrames += accepted
    }

    private func drain() {
        while true {
            lock.lock()
            let count = min(available, drainFrames)
            for index in 0..<count { scratch[index] = ring[(head + index) % capacity] }
            head = (head + count) % capacity; available -= count
            let first = firstHostTime
            lock.unlock()
            guard count > 0, let file, let buffer, let channel = buffer.floatChannelData?[0] else { return }
            do {
                if !timingSaved, let first {
                    let timing = MeetingTrackTiming(source: source, startSeconds: timeline.offset(first), sampleRate: sampleRate)
                    let metadata = url.deletingPathExtension().appendingPathExtension("json")
                    guard !FileManager.default.fileExists(atPath: metadata.path) else {
                        throw MeetingError.message("The original track's timing record already exists.")
                    }
                    try MeetingStore.writePrivate(JSONEncoder().encode(timing), to: metadata)
                    timingSaved = true
                }
                buffer.frameLength = AVAudioFrameCount(count)
                scratch.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: count) }
                try file.write(from: buffer)
                lock.lock(); writtenFrames += count; lock.unlock()
            } catch {
                lock.lock()
                writeFailure = "The recording could not be saved. \(error.localizedDescription)"
                droppedFrames += count + available; available = 0
                lock.unlock()
                return
            }
        }
    }

    /// Called from the capture lifecycle queue, never the main actor.
    func close() -> MeetingTrack {
        lock.lock(); closed = true; lock.unlock()
        queue.sync { timer?.cancel(); timer = nil; drain(); file = nil; buffer = nil }
        lock.lock(); defer { lock.unlock() }
        return MeetingTrack(source: source, file: "\(MeetingStore.tracksDirectory)/\(source.rawValue).caf",
                            startSeconds: firstHostTime.map { timeline.offset($0) } ?? 0,
                            seconds: Double(writtenFrames) / sampleRate, sampleRate: sampleRate,
                            peak: Double(peakValue), droppedSeconds: Double(droppedFrames) / sampleRate)
    }

    var failure: String? { lock.lock(); defer { lock.unlock() }; return writeFailure }
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
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
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
            throw MeetingError.message("Workbench could not listen to that app's audio (CoreAudio error \(created)). Check Privacy & Security → Audio Recording.")
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
            throw MeetingError.message("Workbench could not prepare its private capture device (CoreAudio error \(aggregated)).")
        }
        self.format = format
        self.tapID = tap
        self.aggregateID = device
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
        let started = AudioDeviceStart(aggregateID, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
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
    private var startedHost: UInt64?
    private var reason: String?
    private var report: MeetingCaptureReport?
    private var stopping = false
    private var chosenApp: MeetingAudioApp?
    private var outputUID: String?
    private var microphoneIncluded = false
    private var remoteScratch = [Float](repeating: 0, count: 65_536)
    private var localScratch = [Float](repeating: 0, count: 65_536)

    var elapsedSeconds: Double { timeline.elapsed }
    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    var stopReason: String? {
        lock.lock()
        let prior = reason, remote = remote, local = local, app = chosenApp
        let output = outputUID, microphone = microphoneIncluded, start = startedHost
        lock.unlock()
        if let prior { return prior }
        if let failure = remote?.failure ?? local?.failure { return failure }
        if microphone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            return "Microphone access was removed. The audio already recorded was kept."
        }
        if let app {
            guard let object = MeetingCoreAudio.processObject(for: app.id),
                  let bundle = MeetingCoreAudio.bundleID(of: object),
                  (MeetingAppCatalogue.known(bundle)?.bundleID ?? bundle) == app.bundleID else {
                return "The selected app's audio process ended or changed. Choose it again for a new recording."
            }
            if MeetingCoreAudio.defaultOutputDeviceUID() != output {
                return "The Mac audio output changed. Recording stopped; select the new route before starting again."
            }
        }
        if let start, MeetingClock.interval(from: start, to: MeetingClock.now()) > 12 {
            if remote != nil, (remote?.secondsSinceLastBuffer ?? 13) > 12 {
                return "The selected app stopped supplying audio samples. The recording may be incomplete."
            }
            if local != nil, (local?.secondsSinceLastBuffer ?? 13) > 12 {
                return "The microphone stopped supplying audio samples. The recording may be incomplete."
            }
        }
        return nil
    }

    private func note(_ text: String) {
        lock.lock(); if reason == nil { reason = text }; lock.unlock()
    }

    func requestStop() { lock.lock(); stopping = true; lock.unlock() }

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
        try MeetingStore.createPrivateDirectory(request.tracksDirectory)
        try MeetingDiskBudget.checkStartSpace(at: request.tracksDirectory)
        lock.lock()
        chosenApp = request.app; microphoneIncluded = request.includeMicrophone
        outputUID = MeetingCoreAudio.defaultOutputDeviceUID()
        lock.unlock()
        if let app = request.app {
            guard #available(macOS 14.2, *) else { throw MeetingError.message(MeetingCoreAudio.unavailableReason) }
            let tap = try MeetingProcessTap(app: app)
            tapBox = tap
            try checkStart()
            let recorder = try MeetingTrackRecorder(source: .remote, directory: request.tracksDirectory,
                                                    sampleRate: tap.format.sampleRate, timeline: timeline)
            try recorder.open()
            lock.lock(); remote = recorder; lock.unlock()
            try tap.begin { [weak self, recorder] buffers, time in
                guard let self, !self.isStopping, !recorder.isClosed else { return }
                // A tap-only aggregate has no physical microphone input. Refuse
                // any unexpected additional stream instead of recording it.
                guard buffers.pointee.mNumberBuffers == 1, buffers.pointee.mBuffers.mNumberChannels == 1 else {
                    self.note("The selected app's audio format changed. Recording stopped."); return
                }
                let frames = MeetingMono.fill(from: buffers, into: &self.remoteScratch)
                guard frames > 0 else { return }
                let host = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : MeetingClock.now()
                self.remoteScratch.withUnsafeBufferPointer { recorder.append($0.baseAddress!, count: frames, hostTime: host) }
            }
            try checkStart()
        }
        if request.includeMicrophone { try startMicrophone(request) }
        try checkStart()
        lock.lock(); startedHost = MeetingClock.now(); lock.unlock()
    }

    private func startMicrophone(_ request: MeetingCaptureRequest) throws {
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
        let recorder = try MeetingTrackRecorder(source: .local, directory: request.tracksDirectory,
                                                sampleRate: format.sampleRate, timeline: timeline)
        try recorder.open()
        lock.lock(); local = recorder; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self, recorder] buffer, time in
            guard let self, !self.isStopping, !recorder.isClosed else { return }
            let frames = MeetingMono.fill(from: buffer, into: &self.localScratch)
            guard frames > 0 else { return }
            let host = time.isHostTimeValid ? time.hostTime : MeetingClock.now()
            self.localScratch.withUnsafeBufferPointer { recorder.append($0.baseAddress!, count: frames, hostTime: host) }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audio, queue: nil) { [weak self] _ in
                self?.note("The microphone device changed. Recording stopped; the audio already recorded was kept.")
            }
        engine = audio
        audio.prepare()
        try checkStart()
        do { try audio.start() }
        catch { throw MeetingError.message("The microphone could not start. \(error.localizedDescription)") }
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
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        if #available(macOS 14.2, *), let tap = tapBox as? MeetingProcessTap { tap.destroy() }
        tapBox = nil
        lock.lock(); let recorders = [remote, local].compactMap { $0 }; lock.unlock()
        let tracks = recorders.map { $0.close() }.filter { $0.seconds > 0 }
        lock.lock()
        let failure = reason ?? recorders.compactMap { $0.failure }.first
        let result = MeetingCaptureReport(tracks: tracks,
                                          seconds: tracks.map { $0.startSeconds + $0.seconds }.max() ?? 0,
                                          failure: failure)
        report = result; remote = nil; local = nil; startedHost = nil
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
