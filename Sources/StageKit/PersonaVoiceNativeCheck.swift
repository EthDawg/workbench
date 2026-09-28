import AppKit
import AVFoundation
import CoreAudio

/// React to my voice on this Mac's real microphone, for maintainers. Launch the
/// signed app through LaunchServices so macOS applies its own microphone
/// permission:
///
///     open -n -a "Workbench Preview.app" --args --check-persona-voice-native NEW_FOLDER [--speak]
///
/// It never asks for permission, uses a disposable library with synthetic
/// artwork, leaves the saved choice alone and keeps no audio: the recordings it
/// makes beside the ring go to temporary files that are measured and deleted.
/// `--speak` plays synthetic speech through the speakers so the outline's
/// response is measured through the air: a sentence at the usual volume, the
/// same sentence softly, a long passage without pauses, and a sentence already
/// under way when the outline is turned on. The receipt records every frame's
/// arrival and every change the outline shows, on one clock, and reports onset
/// and return to quiet against the 150 ms and 500 ms targets. The time macOS
/// takes to hand a buffer over is reported separately. The receipt and window
/// renders are written to NEW_FOLDER.
public enum PersonaVoiceNativeCheck {
    /// Awaits between steps, so the main queue delivers the ring's frames as it
    /// does in the running app.
    @MainActor public static func run(output: URL, speak: Bool) async throws -> String {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw PersonaVoiceError.unavailable("Microphone access is not allowed for this app. Open it with open -n -a so its own permission applies.")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw PersonaError.changedOnDisk }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaVoiceNative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let check = Run(root: root, output: output)
        defer { check.library.shutdown() }
        try await check.perform(speak: speak)
        let data = try JSONSerialization.data(withJSONObject: check.receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("receipt.json"))
        let summary = check.summary.joined(separator: "\n")
        try summary.write(to: output.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        guard check.failures.isEmpty else { throw PersonaVoiceError.unavailable("native check failed: " + check.failures.joined(separator: "; ")) }
        return summary
    }

    /// The real microphone source, observed. Times are `CACurrentMediaTime`,
    /// the display link's clock.
    private final class Observed: PersonaVoiceSource {
        let inner = PersonaMicrophoneLevel()
        var onFrames: (([PersonaVoiceFrame]) -> Void)?
        var onUnavailable: ((String) -> Void)? { get { inner.onUnavailable } set { inner.onUnavailable = newValue } }
        var onDevice: ((String?) -> Void)?
        var deviceName: String? { inner.deviceName }
        private(set) var deliveries: [(time: CFTimeInterval, frames: [PersonaVoiceFrame])] = []
        private(set) var timings: [(timing: PersonaVoiceTiming, received: CFTimeInterval)] = []
        private(set) var restarts = 0
        init() {
            inner.onTiming = { [weak self] timing in self?.timings.append((timing, CACurrentMediaTime())) }
            inner.onFrames = { [weak self] frames in
                guard let self else { return }
                self.deliveries.append((CACurrentMediaTime(), frames)); self.onFrames?(frames)
            }
            inner.onDevice = { [weak self] name in self?.restarts += 1; self?.onDevice?(name) }
        }
        func start() throws { try inner.start() }
        func stop() { inner.stop() }
    }

    /// When each synthetic utterance really started and finished playing.
    private final class Speaking: NSObject, AVSpeechSynthesizerDelegate {
        var started: CFTimeInterval?, finished: CFTimeInterval?
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { started = CACurrentMediaTime() }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished = CACurrentMediaTime() }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished = CACurrentMediaTime() }
    }

    @MainActor private final class Run {
        /// Every source the library made, in order.
        final class Made { var sources: [Observed] = [] }
        let library: PersonaLibrary
        let output: URL
        let root: URL
        private let made = Made()
        var receipt: [String: Any] = [:]
        var summary: [String] = []
        var failures: [String] = []
        /// What the outline showed and when it changed: `targetTimestamp` of the frame that shows it.
        var shown: [(time: CFTimeInterval, state: PersonaVoiceRingState.Visible)] = []
        /// dBFS a frame must reach to count as synthetic speech, set from the room.
        var speechThreshold: Float = -45

        init(root: URL, output: URL) {
            self.root = root; self.output = output
            let made = made, system = PersonaVoiceAccess.system
            let access = PersonaVoiceAccess(permission: system.permission, requestPermission: { $0(false) },
                                            makeSource: { let source = Observed(); made.sources.append(source); return source },
                                            savedChoice: { false }, saveChoice: { _ in })
            library = PersonaLibrary(root: root, sessionHUDEnabled: false, voice: access)
            library.usesSharedControls = true
        }
        private func libraryMadeSources() -> [Observed] { made.sources }

        func expect(_ passed: Bool, _ message: String) {
            summary.append((passed ? "PASS " : "FAIL ") + message)
            if !passed { failures.append(message) }
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        /// Milliseconds until the condition holds, or nil after the limit.
        func until(_ limit: Double = 3, _ condition: () -> Bool) async -> Double? {
            let start = CACurrentMediaTime()
            while CACurrentMediaTime() - start < limit {
                if condition() { return (CACurrentMediaTime() - start) * 1_000 }
                await wait(0.002)
            }
            return condition() ? (CACurrentMediaTime() - start) * 1_000 : nil
        }
        func delivered(since time: CFTimeInterval) -> [(time: CFTimeInterval, frames: [PersonaVoiceFrame])] {
            libraryMadeSources().flatMap(\.deliveries).filter { $0.time >= time }
        }
        func levels(since time: CFTimeInterval) -> [Float] { delivered(since: time).flatMap { $0.frames.map(\.level) } }
        func decibels(since time: CFTimeInterval) -> [Float] { delivered(since: time).flatMap { $0.frames.map(\.decibels) } }

        /// The live outline's layer, to record what it shows.
        func ringLayer() -> PersonaVoiceRingLayer? {
            NSApp.windows.first { $0.title == "Workbench persona" && $0.isVisible }?
                .contentView?.layer?.sublayers?.compactMap { $0 as? PersonaVoiceRingLayer }.first
        }
        func state(at time: CFTimeInterval) -> PersonaVoiceRingState.Visible { shown.last { $0.time <= time }?.state ?? .quiet }

        /// Onset and return to quiet for synthetic speech heard between `from`
        /// and `to`, measured from the frames' arrival: a speech frame is one at
        /// least `speechThreshold` loud.
        func measure(from: CFTimeInterval, to: CFTimeInterval) -> [String: Any] {
            let frames = delivered(since: from).filter { $0.time <= to }.flatMap { delivery in delivery.frames.map { (delivery.time, $0) } }
            let speech = frames.filter { $0.1.decibels >= speechThreshold }
            guard let first = speech.first?.0, let last = speech.last?.0 else { return ["heard": false] }
            let alreadyLit = state(at: first) != .quiet
            let lit = alreadyLit ? first : shown.first { $0.time >= first && $0.state != .quiet }?.time
            let settled = state(at: last) == .quiet ? last : shown.first { $0.time >= last && $0.state == .quiet }?.time
            // Share of the speech the outline stayed lit for, from onset to the last speech frame.
            var litTime = 0.0
            if let lit, last > lit {
                var cursor = lit, current = state(at: lit)
                for change in shown where change.time > lit && change.time < last {
                    if current != .quiet { litTime += change.time - cursor }
                    cursor = change.time; current = change.state
                }
                if current != .quiet { litTime += last - cursor }
            }
            let lastThird = frames.filter { $0.0 >= last - 3 && $0.0 <= last }
            let lastThirdLit = lastThird.isEmpty ? 0 : Double(lastThird.filter { state(at: $0.0) != .quiet }.count) / Double(lastThird.count)
            return ["heard": true, "speechFrames": speech.count, "firstSpeechFrameAfterStartMs": (first - from) * 1_000,
                    "speechMs": (last - first) * 1_000,
                    "onsetMs": lit.map { ($0 - first) * 1_000 } ?? -1, "litBeforeFirstSpeechFrame": alreadyLit,
                    "releaseMs": settled.map { ($0 - last) * 1_000 } ?? -1,
                    "litShare": last > (lit ?? last) ? litTime / (last - (lit ?? last)) : 0,
                    "litShareLast3s": lastThirdLit,
                    "loudShown": shown.contains { $0.time >= first && $0.time <= last && $0.state == .loud }]
        }

        /// Speaks one synthetic utterance through the speakers and waits for it to end.
        func say(_ text: String, volume: Float, whileSpeaking: (() async -> Void)? = nil) async -> (started: CFTimeInterval, finished: CFTimeInterval) {
            let synthesizer = AVSpeechSynthesizer(), observer = Speaking()
            synthesizer.delegate = observer
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate; utterance.volume = volume
            let asked = CACurrentMediaTime()
            synthesizer.speak(utterance)
            _ = await until(3) { observer.started != nil }
            if let whileSpeaking { await whileSpeaking() }
            _ = await until(30) { observer.finished != nil }
            return (observer.started ?? asked, observer.finished ?? CACurrentMediaTime())
        }
        static func stats(_ values: [Float]) -> [String: Any] {
            let sorted = values.sorted()
            func at(_ share: Double) -> Double { sorted.isEmpty ? 0 : Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]) }
            return ["count": sorted.count, "median": at(0.5), "p90": at(0.9), "max": Double(sorted.last ?? 0),
                    "overQuarter": sorted.isEmpty ? 0 : Double(sorted.filter { $0 > 0.25 }.count) / Double(sorted.count)]
        }
        /// Whether macOS counts this process as using an input: what lights the
        /// menu bar's microphone indicator.
        static func inputRunning() -> Bool? {
            guard #available(macOS 14.2, *) else { return nil }
            var translate = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid = ProcessInfo.processInfo.processIdentifier
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = withUnsafeMutablePointer(to: &pid) { qualifier in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translate, UInt32(MemoryLayout<pid_t>.size), qualifier, &size, &object)
            }
            guard status == noErr, object != kAudioObjectUnknown else { return false }
            var running = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &running, 0, nil, &size, &value) == noErr else { return nil }
            return value != 0
        }
        func microphoneOpen() -> Bool { Self.inputRunning() ?? (library.voiceDevice != nil) }

        func perform(speak: Bool) async throws {
            let badge = root.appendingPathComponent("synthetic-badge.png")
            guard let tiff = PersonaVoiceNativeCheck.badge().tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw PersonaError.unreadableImage }
            try png.write(to: badge)
            _ = try library.addImage(badge, name: "Synthetic presenter")
            receipt["inputMetadata"] = Self.inputRunning() == nil ? "unavailable before macOS 14.2" : "Core Audio process object"

            expect(!microphoneOpen(), "microphone closed before anything is shown")
            guard case .success = library.showOverlay() else { throw PersonaError.unreadableImage }
            await wait(0.6)
            expect(!microphoneOpen() && libraryMadeSources().isEmpty, "showing a persona alone never opens the microphone")

            let on = CACurrentMediaTime()
            library.setVoiceRing(true)
            if let layer = ringLayer() { layer.onVisibleChange = { [weak self] state, time in self?.shown.append((time, state)) } }
            else { expect(false, "the live outline's layer can be observed") }
            let firstFrame = await until { !delivered(since: on).isEmpty }
            let opened = await until { microphoneOpen() }
            receipt["device"] = library.voiceDevice ?? "unknown"
            receipt["firstFramesMs"] = firstFrame ?? -1
            receipt["microphoneOpenMs"] = opened ?? -1
            expect(firstFrame != nil && firstFrame! < 1_500, "the ring hears the microphone within 1.5 s (\(Int(firstFrame ?? -1)) ms)")
            expect(opened != nil, "macOS reports the microphone in use while the ring is on")

            // The room, as it is.
            let quiet = CACurrentMediaTime()
            await wait(4)
            let room = delivered(since: quiet)
            let batches = room.map(\.frames.count)
            let chunk = room.first?.frames.first?.seconds ?? 0
            receipt["frameSeconds"] = chunk
            receipt["deliveriesPerSecond"] = Double(room.count) / 4
            receipt["framesPerDelivery"] = batches.isEmpty ? 0 : Double(batches.reduce(0, +)) / Double(batches.count)
            receipt["room"] = Self.stats(levels(since: quiet))
            let roomLoudness = decibels(since: quiet).filter { $0 > -120 }.sorted()
            let roomP90 = roomLoudness.isEmpty ? -70 : roomLoudness[min(roomLoudness.count - 1, Int(Double(roomLoudness.count) * 0.9))]
            speechThreshold = roomP90 + 10
            receipt["roomDecibels"] = ["median": Double(roomLoudness.isEmpty ? -120 : roomLoudness[roomLoudness.count / 2]), "p90": Double(roomP90),
                                       "speechThreshold": Double(speechThreshold)]
            let roomCues = shown.filter { $0.time >= quiet && $0.state != .quiet }.count
            receipt["roomCues"] = roomCues
            expect(room.count >= 8, "frames keep arriving (\(room.count) deliveries in 4 s)")
            expect(roomCues == 0, "the room alone never lights the outline (\(roomCues) changes)")
            try render("persona-voice-native-room.png")

            if speak {
                // Synthetic speech through the air. Each result is measured from
                // the arrival of its first and last loud frames.
                let sentence = "Okay, this is Workbench checking the voice outline. It should light while I speak and settle when I stop."
                var latency: [String: Any] = [:]
                var rendered = false
                let normal = await say(sentence, volume: 1) {
                    await self.wait(1.5)
                    if (try? self.render("persona-voice-native-speaking.png")) != nil { rendered = true }
                }
                await wait(1.5)
                latency["normal"] = measure(from: normal.started - 0.3, to: normal.finished + 1)
                receipt["speech"] = Self.stats(levels(since: normal.started))
                let afterward = CACurrentMediaTime()
                await wait(1)
                receipt["afterSpeech"] = Self.stats(levels(since: afterward))
                expect(rendered, "the speaking outline could be rendered")

                let soft = await say(sentence, volume: 0.3)
                await wait(1.5)
                latency["soft"] = measure(from: soft.started - 0.3, to: soft.finished + 1)

                let passage = "Here is how the quarterly numbers came together across every region we serve starting with the north where growth held steady through the winter and then picked up again as new customers joined in the spring and the teams in the south matched that pace"
                let continuous = await say(passage, volume: 1)
                await wait(1.5)
                latency["continuous"] = measure(from: continuous.started - 0.3, to: continuous.finished + 1)

                // Already speaking when the outline turns on: its first frames are speech.
                library.setVoiceRing(false)
                _ = await until(1) { !microphoneOpen() }
                var enabledAt = CACurrentMediaTime()
                let immediate = await say(sentence, volume: 1) {
                    await self.wait(0.4)
                    enabledAt = CACurrentMediaTime()
                    self.library.setVoiceRing(true)
                    if let layer = self.ringLayer() { layer.onVisibleChange = { [weak self] state, time in self?.shown.append((time, state)) } }
                }
                await wait(1.5)
                latency["immediate"] = measure(from: enabledAt, to: immediate.finished + 1)

                latency["targets"] = ["onsetMs": 150, "releaseMs": 500]
                latency["speechThresholdDBFS"] = Double(speechThreshold)
                receipt["latency"] = latency
                for name in ["normal", "soft", "continuous", "immediate"] {
                    guard let result = latency[name] as? [String: Any], result["heard"] as? Bool == true else {
                        expect(false, "\(name) speech was heard above the room"); continue
                    }
                    let onset = result["onsetMs"] as? Double ?? -1, release = result["releaseMs"] as? Double ?? -1
                    expect(onset >= 0 && onset <= 150, "\(name) speech lights the outline within 150 ms of its first loud frame (\(Int(onset)) ms)")
                    expect(release >= 0 && release <= 500, "\(name) speech settles within 500 ms of its last loud frame (\(Int(release)) ms)")
                }
                if let result = latency["continuous"] as? [String: Any] {
                    let share = result["litShareLast3s"] as? Double ?? 0
                    expect(share >= 0.9, "long speech keeps the outline lit to the end (\(Int(share * 100))% of its last 3 s)")
                }
            }

            try await coexist(name: "recorder", label: "Dictate and Snap & Talk narration settings (AVAudioRecorder, 16 kHz PCM)") { try self.recorder() }
            try await coexist(name: "engine", label: "meeting capture microphone (second AVAudioEngine, 4,096-frame tap)") { try self.engine() }

            // A recording already running when the ring is turned on.
            library.setVoiceRing(false)
            _ = await until(1) { !microphoneOpen() }
            let running = try recorder()
            await wait(0.5)
            let late = CACurrentMediaTime()
            library.setVoiceRing(true)
            let joined = await until { !delivered(since: late).isEmpty }
            await wait(2)
            let result = running.finish()
            receipt["recorderFirst"] = ["ringFramesMs": joined ?? -1, "recording": result]
            expect(joined != nil, "turning the ring on during a recording still hears the microphone")
            expect((result["seconds"] as? Double ?? 0) > 2, "that recording keeps recording while the ring joins")

            // Everything that must close the microphone, promptly.
            var stops: [String: Double] = [:]
            library.hideOverlay()
            stops["hide"] = await until { !microphoneOpen() } ?? -1
            _ = library.showOverlay()
            _ = await until { microphoneOpen() }
            library.setVoiceRing(false)
            stops["turnOff"] = await until { !microphoneOpen() } ?? -1
            library.setVoiceRing(true)
            _ = await until { microphoneOpen() }
            library.toggleQuickPersona()
            stops["personaKey"] = await until { !microphoneOpen() } ?? -1
            _ = library.showOverlay()
            _ = await until { microphoneOpen() }
            library.shutdown()
            stops["quit"] = await until { !microphoneOpen() } ?? -1
            receipt["closesMs"] = stops
            for (name, milliseconds) in stops.sorted(by: { $0.key < $1.key }) {
                expect(milliseconds >= 0 && milliseconds < 500, "\(name) closes the microphone within 0.5 s (\(Int(milliseconds)) ms)")
            }
            receipt["engineRestarts"] = libraryMadeSources().reduce(0) { $0 + $1.restarts }
            recordTimeline(since: on)
        }

        /// Every frame's arrival and every change the outline showed, relative to
        /// the outline first turning on, and how long macOS took to hand each
        /// buffer over: reported apart from the outline's own response.
        func recordTimeline(since start: CFTimeInterval) {
            receipt["frames"] = libraryMadeSources().flatMap(\.deliveries).flatMap { delivery in
                delivery.frames.map { [((delivery.time - start) * 1_000).rounded(), Double($0.decibels), $0.speaking ? 1 : 0, Double($0.level)] }
            }
            receipt["framesColumns"] = ["receivedMs", "dBFS", "speaking", "level"]
            receipt["shown"] = shown.map { [((($0.time - start) * 1_000)).rounded(), $0.state.rawValue] as [Any] }
            let timings = libraryMadeSources().flatMap(\.timings)
            let handover = timings.compactMap { entry in entry.timing.captured.map { (entry.timing.tapped - ($0 + entry.timing.seconds)) * 1_000 } }.sorted()
            let dispatch = timings.map { ($0.received - $0.timing.tapped) * 1_000 }.sorted()
            func percentile(_ values: [Double], _ share: Double) -> Double { values.isEmpty ? -1 : values[min(values.count - 1, Int(Double(values.count) * share))] }
            receipt["inputLatency"] = [
                "bufferMs": percentile(timings.map { $0.timing.seconds * 1_000 }.sorted(), 0.5),
                "bufferEndToAnalyserMsMedian": percentile(handover, 0.5), "bufferEndToAnalyserMsP90": percentile(handover, 0.9),
                "analyserToMainThreadMsMedian": percentile(dispatch, 0.5), "analyserToMainThreadMsP90": percentile(dispatch, 0.9),
                "note": "macOS delivers the microphone in buffers of this length; a sound is heard up to one buffer plus this hand-over before its frame arrives. Onset and release are measured from arrival."]
        }

        /// Starts a second microphone user beside the ring, then checks both.
        func coexist(name: String, label: String, start: () throws -> Competitor) async throws {
            _ = await until { microphoneOpen() }
            let before = CACurrentMediaTime()
            let competitor = try start()
            var windows: [Int] = []
            for _ in 0..<6 {
                let window = CACurrentMediaTime()
                await wait(0.5)
                windows.append(delivered(since: window).count)
            }
            let result = competitor.finish()
            let after = CACurrentMediaTime()
            await wait(1.5)
            let continued = delivered(since: after).count
            receipt[name] = ["label": label, "competitor": result, "ringDeliveriesPerHalfSecond": windows,
                             "ringDeliveriesAfterStop": continued, "ringLevels": Self.stats(levels(since: before))]
            expect(windows.allSatisfy { $0 > 0 }, "the ring keeps hearing beside \(label)")
            expect((result["seconds"] as? Double ?? 0) > 2.5 && (result["heard"] as? Bool ?? false), "\(label) records beside the ring")
            expect(continued > 0 && microphoneOpen(), "the ring keeps running after \(label) stops")
        }

        struct Competitor { let finish: () -> [String: Any] }

        func recorder() throws -> Competitor {
            let url = root.appendingPathComponent("beside-ring-\(UUID().uuidString).wav")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else { throw PersonaVoiceError.unavailable("A Dictate-style recording could not start beside the ring.") }
            var peak: Float = -160
            let meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in recorder.updateMeters(); peak = max(peak, recorder.peakPower(forChannel: 0)) }
            return Competitor {
                meter.invalidate()
                let seconds = recorder.currentTime
                recorder.stop()
                let frames = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
                try? FileManager.default.removeItem(at: url)
                return ["seconds": seconds, "fileSeconds": frames, "peakPower": Double(peak), "heard": peak > -120 && frames > 0]
            }
        }

        func engine() throws -> Competitor {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            final class Counter { var buffers = 0; var loudest: Float = 0; let lock = NSLock() }
            let counter = Counter()
            input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                var peak: Float = 0
                for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
                counter.lock.lock(); counter.buffers += 1; counter.loudest = max(counter.loudest, peak); counter.lock.unlock()
            }
            engine.prepare()
            try engine.start()
            let started = CFAbsoluteTimeGetCurrent()
            return Competitor {
                let seconds = CFAbsoluteTimeGetCurrent() - started
                input.removeTap(onBus: 0); engine.stop()
                counter.lock.lock(); defer { counter.lock.unlock() }
                return ["seconds": seconds, "buffers": counter.buffers, "sampleRate": format.sampleRate,
                        "peak": Double(counter.loudest), "heard": counter.buffers > 0 && counter.loudest > 0]
            }
        }

        /// The live persona window, as its layers draw it.
        func render(_ name: String) throws {
            guard let window = NSApp.windows.first(where: { $0.title == "Workbench persona" && $0.isVisible }),
                  let layer = window.contentView?.layer else { failures.append("no visible persona window to render"); return }
            let scale = window.backingScaleFactor, size = layer.bounds.size
            guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw PersonaError.unreadableImage }
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); context.fill(CGRect(origin: .zero, size: size))
            layer.render(in: context)
            guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { throw PersonaError.unreadableImage }
            try data.write(to: output.appendingPathComponent(name))
            receipt["window"] = ["width": window.frame.width, "height": window.frame.height]
        }
    }

    /// A round badge with a hat and a name label, drawn here so no personal
    /// artwork is ever used.
    static func badge() -> NSImage {
        NSImage(size: CGSize(width: 560, height: 560), flipped: false) { _ in
            NSColor(srgbRed: 0.93, green: 0.76, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 80, y: 100, width: 400, height: 400)).fill()
            NSColor(srgbRed: 0.1, green: 0.2, blue: 0.2, alpha: 1).setStroke()
            let rim = NSBezierPath(ovalIn: CGRect(x: 80, y: 100, width: 400, height: 400)); rim.lineWidth = 12; rim.stroke()
            NSColor(srgbRed: 0.35, green: 0.4, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 190, y: 110, width: 180, height: 240)).fill()
            NSColor(srgbRed: 0.85, green: 0.7, blue: 0.58, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 215, y: 300, width: 130, height: 150)).fill()
            NSColor(white: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 200, y: 430, width: 160, height: 100), xRadius: 50, yRadius: 50).fill()
            NSColor(srgbRed: 0.93, green: 0.76, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 70, y: 16, width: 420, height: 92), xRadius: 46, yRadius: 46).fill()
            let label = NSAttributedString(string: "Synthetic presenter", attributes: [
                .font: NSFont.systemFont(ofSize: 38, weight: .semibold), .foregroundColor: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.2, alpha: 1)])
            label.draw(at: CGPoint(x: 280 - label.size().width / 2, y: 62 - label.size().height / 2))
            return true
        }
    }
}
