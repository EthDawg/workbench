import AVFoundation
import Combine
import Foundation

/// One explicit owner for meeting capture, durable finalisation and sequential
/// recognition. The shell supplies admission and an atomic history upsert.
@MainActor
final class MeetingModel: ObservableObject {
    @Published private(set) var apps: [MeetingAudioApp] = []
    @Published private(set) var offer: MeetingAudioApp?
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isStarting = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var notice = "Choose an app and microphone, then start. Recording is limited to two hours."
    @Published private(set) var error: String?
    @Published private(set) var hasRecovery = false
    /// The history writer reads these during saveTranscript; originals stay unchanged.
    @Published private(set) var pendingTranscriptNotes: [String] = []
    @Published var detectionEnabled: Bool {
        didSet {
            defaults.set(detectionEnabled, forKey: Self.detectionKey)
            configureDetection()
        }
    }
    @Published var includeMicrophone = true
    @Published var selectedAppID: Int32?
    @Published var purpose = "meeting"

    var isBusy: Bool { isRecording || isProcessing || isStarting }
    var mayStart: (() -> String?)?
    var saveTranscript: ((Transcript, String) throws -> Void)?
    var onStateChange: (() -> Void)?

    static let detectionKey = "workbench.meeting.detect.v1"
    static let disabledAppsKey = "workbench.meeting.disabled-apps.v1"
    private let directory: URL
    private let defaults: UserDefaults
    private let detector: MeetingDetector
    private let transcribe: (URL) async throws -> String
    private let microphonePermission: () async -> Bool
    private let captureFactory: () -> MeetingCapture
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var activeCapture: MeetingCapture?
    private var activeSession: URL?
    private var activeManifest: MeetingManifest?
    private var shuttingDown = false

    convenience init(engine: RecognitionEngine, directory: URL, defaults: UserDefaults = .standard) {
        self.init(directory: directory, defaults: defaults, processSource: MeetingSystemProcessSource(),
                  transcribe: { try await engine.transcribe($0) },
                  microphonePermission: Self.requestMicrophone, captureFactory: { MeetingSystemCapture() })
    }

    /// These seams exercise the actual controller with synthetic capture and
    /// recognition. No check needs a device, permission prompt or model download.
    init(directory: URL, defaults: UserDefaults, processSource: MeetingProcessSource,
         transcribe: @escaping (URL) async throws -> String,
         microphonePermission: @escaping () async -> Bool,
         captureFactory: @escaping () -> MeetingCapture) {
        self.directory = directory; self.defaults = defaults
        self.detector = MeetingDetector(source: processSource)
        self.transcribe = transcribe; self.microphonePermission = microphonePermission
        self.captureFactory = captureFactory
        detectionEnabled = defaults.bool(forKey: Self.detectionKey)
        detector.disabledBundleIDs = Set(defaults.stringArray(forKey: Self.disabledAppsKey) ?? [])
        configureDetection()
        recoveryTask = Task { [weak self] in await self?.refreshRecovery() }
    }

    private static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func refreshApps() {
        apps = detector.availableApps()
        if !detector.isAvailable { error = detector.unavailableReason }
        else if let issue = detector.lastError { error = issue }
    }

    func start() async {
        guard !isBusy, !shuttingDown else { return }
        if let issue = mayStart?() { error = issue; return }
        let app: MeetingAudioApp?
        if let selectedAppID {
            refreshApps()
            guard let chosen = apps.first(where: { $0.id == selectedAppID }) else {
                error = "The selected audio app is no longer available. Choose its current audio source before starting."
                return
            }
            app = chosen
        } else { app = nil }
        guard app != nil || includeMicrophone else { error = "Choose an app, the microphone, or both."; return }
        let token = UUID(); generation = token
        let microphone = includeMicrophone, kind = purpose == "call" ? "call" : "meeting"
        error = nil; offer = nil; elapsed = 0; pendingTranscriptNotes = []
        notice = "Waiting for recording access…"
        phase(starting: true)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.begin(token: token, app: app, microphone: microphone, purpose: kind)
        }
        operation = task
        await task.value
    }

    private func begin(token: UUID, app: MeetingAudioApp?, microphone: Bool, purpose: String) async {
        var createdSession: URL?
        var initial: MeetingManifest?
        var capture: MeetingCapture?
        do {
            if microphone {
                let allowed = await microphonePermission()
                try check(token)
                guard allowed else { throw MeetingError.message("Allow Microphone access in Privacy & Security to include your voice, or choose app audio only.") }
            }
            try check(token)
            let manifest = MeetingManifest(id: UUID(), createdAt: Date(), updatedAt: Date(), purpose: purpose,
                                           appName: app?.name, appBundleID: app?.bundleID,
                                           includesMicrophone: microphone, includesRemote: app != nil,
                                           state: .recording, seconds: 0)
            let root = directory
            let session = try await MeetingFileWork.run { try MeetingStore.create(root: root, manifest: manifest) }
            createdSession = session; initial = manifest
            try check(token)
            activeSession = session; activeManifest = manifest
            let recorder = captureFactory(); capture = recorder; activeCapture = recorder
            try await recorder.start(MeetingCaptureRequest(tracksDirectory: session.appendingPathComponent(MeetingStore.tracksDirectory),
                                                           app: app, includeMicrophone: microphone))
            try check(token)
            notice = "Recording. Stop to transcribe; the maximum is two hours."
            phase(recording: true)
            operation = nil
            watch(recorder, token: token)
        } catch {
            if let session = createdSession, let manifest = initial {
                let report = await capture?.finish() ?? MeetingCaptureReport()
                do {
                    try await persistStopped(report, session: session, previous: manifest,
                                             reason: error is CancellationError ? "Recording was cancelled. Original audio was kept." : error.localizedDescription)
                } catch let persistenceError {
                    if activeSession == session || generation == token {
                        self.error = "Original audio was kept, but its completion record could not be saved. \(persistenceError.localizedDescription)"
                    }
                }
            }
            // A permission request can return after Cancel and a newer start.
            // It owns no capture then and must not change that newer operation.
            guard generation == token || activeSession == createdSession && createdSession != nil else { return }
            if !(error is CancellationError), self.error == nil { self.error = error.localizedDescription }
            activeCapture = nil; activeSession = nil; activeManifest = nil; operation = nil
            notice = error is CancellationError ? "Cancelled. Any recorded audio was kept for explicit retry." : "Recording stopped. Any saved audio is available for retry."
            phase()
            await refreshRecovery()
        }
    }

    func stop() async {
        guard isRecording else { return }
        await finishCapture(process: true)
    }

    private func finishCapture(process: Bool, reason: String? = nil) async {
        guard let capture = activeCapture, let session = activeSession, let manifest = activeManifest else { return }
        watcher?.cancel(); watcher = nil
        capture.requestStop()
        let token = UUID(); generation = token
        notice = "Saving the original audio…"
        phase(processing: true)
        let task = Task { [weak self] in
            guard let self else { return }
            let report = await capture.finish()
            do {
                try await self.persistStopped(report, session: session, previous: manifest, reason: reason ?? report.failure)
                self.activeCapture = nil; self.activeSession = nil; self.activeManifest = nil
                self.elapsed = report.seconds
                try self.check(token)
                if process { try await self.process(session: session, token: token) }
                else {
                    self.notice = "Recording stopped. Original audio was kept; Retry transcribes it when you choose."
                    self.error = reason ?? report.failure
                }
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                self.notice = "Original audio was kept. Retry when you are ready."
            }
            self.activeCapture = nil; self.activeSession = nil; self.activeManifest = nil
            self.operation = nil; self.phase()
            await self.refreshRecovery()
        }
        operation = task
        await task.value
    }

    private func persistStopped(_ report: MeetingCaptureReport, session: URL,
                                previous: MeetingManifest, reason: String?) async throws {
        var next = previous
        next.state = .stopped; next.tracks = report.tracks; next.seconds = report.seconds
        next.failure = reason
        if let reason, !reason.isEmpty { next.gaps.append(reason) }
        // Cancellation never cancels the small atomic finalisation write.
        try await Task.detached(priority: .utility) { try MeetingStore.save(next, at: session, replacing: previous) }.value
    }

    func cancel() async {
        watcher?.cancel(); watcher = nil
        if isRecording { await finishCapture(process: false, reason: "Recording was cancelled. Original audio was kept."); return }
        guard isStarting || isProcessing else { return }
        generation = UUID()
        activeCapture?.requestStop()
        let current = operation
        current?.cancel()
        if isStarting, activeCapture == nil {
            // The pending microphone prompt owns no audio or session resources.
            // Its generation is invalid now, so a later grant cannot record.
            operation = nil; phase()
            notice = "Recording cancelled."
            return
        }
        // Keep the shared engine/microphone gate closed until it unwinds.
        await current?.value
        if isBusy { phase() }
    }

    func retry() async {
        guard !isBusy, !shuttingDown else { return }
        if let issue = mayStart?() { error = issue; return }
        let token = UUID(); generation = token
        error = nil; pendingTranscriptNotes = []; notice = "Opening the saved recording…"; phase(processing: true)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let root = self.directory
                let entries = try await MeetingFileWork.run { MeetingRecovery.scan(root: root) }
                try self.check(token)
                guard let entry = entries.first(where: { $0.isReadable }) else {
                    throw MeetingError.message(entries.first?.problem ?? "There is no unfinished recording to retry.")
                }
                try await self.process(session: entry.session, token: token)
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                self.notice = "Saved audio remains available for explicit retry."
            }
            self.operation = nil; self.phase()
            await self.refreshRecovery()
        }
        operation = task; await task.value
    }

    private func process(session: URL, token: UUID) async throws {
        try check(token)
        notice = "Transcribing saved audio…"
        let processor = MeetingProcessor(session: session, transcribe: transcribe, commit: { [weak self] transcript, purpose, notes in
            guard let self else { throw CancellationError() }
            try self.check(token)
            guard let save = self.saveTranscript else { throw MeetingError.message("Recent transcripts is not ready to save this recording. Its original audio was kept.") }
            self.pendingTranscriptNotes = notes
            try save(transcript, purpose)
        }, isCurrent: { [weak self] in self?.generation == token })
        let result = try await processor.run()
        pendingTranscriptNotes = result.notes
        notice = ([result.committed ? "Saved to Recent transcripts." : "Original audio was kept."] + result.notes).joined(separator: " ")
        elapsed = result.manifest.seconds
    }

    private func watch(_ capture: MeetingCapture, token: UUID) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, self.generation == token, self.isRecording else { return }
                self.elapsed = capture.elapsedSeconds
                var reason = capture.stopReason
                if self.elapsed >= MeetingSegmentPlan.maximumMeetingSeconds { reason = "The two-hour recording limit was reached." }
                ticks += 1
                if ticks % 10 == 0 {
                    let root = self.directory
                    let bytes = try? await MeetingFileWork.run { MeetingDiskBudget.availableBytes(at: root) }
                    guard self.generation == token, self.isRecording else { return }
                    if let bytes, bytes < MeetingDiskBudget.stopFloorBytes { reason = "Recording stopped because disk space is running low." }
                }
                if let reason { await self.finishCapture(process: false, reason: reason); return }
            }
        }
    }

    private func phase(starting: Bool = false, recording: Bool = false, processing: Bool = false) {
        isStarting = starting; isRecording = recording; isProcessing = processing
        detector.isSuppressed = isBusy
        if isBusy { offer = nil }
        onStateChange?()
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, !shuttingDown else { throw CancellationError() }
    }

    private func refreshRecovery() async {
        let root = directory
        let entries = try? await MeetingFileWork.run { MeetingRecovery.scan(root: root) }
        guard let entries else { return }
        hasRecovery = !entries.isEmpty
        if !isBusy, error == nil, let issue = entries.first(where: { !$0.isReadable })?.problem { error = issue }
    }

    private func configureDetection() {
        detectionTask?.cancel(); detectionTask = nil
        detector.isEnabled = detectionEnabled
        if !detectionEnabled { offer = nil; return }
        guard !shuttingDown else { return }
        if !detector.isAvailable { error = detector.unavailableReason; return }
        detectionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self, self.detectionEnabled, !self.shuttingDown else { return }
                self.detector.isSuppressed = self.isBusy || self.mayStart?() != nil
                self.offer = self.detector.evaluate()
                if let issue = self.detector.lastError, !self.isBusy { self.error = issue }
            }
        }
    }

    func dismissOffer() { if let offer { detector.dismiss(offer) }; offer = nil }
    func snoozeOffers() { detector.snooze(); offer = nil }
    func disableOffers(for app: MeetingAudioApp) {
        detector.disable(app)
        defaults.set(Array(detector.disabledBundleIDs).sorted(), forKey: Self.disabledAppsKey)
        offer = nil
    }

    /// The app's terminateLater hook awaits this before replying to macOS.
    func prepareForShutdown() async {
        shuttingDown = true
        detectionTask?.cancel(); detectionTask = nil; offer = nil
        recoveryTask?.cancel(); recoveryTask = nil
        await cancel()
    }

    /// Last-resort lifecycle hook. The host awaits prepareForShutdown during
    /// normal Quit; this method never blocks the main actor on a writer queue.
    func shutdown() {
        shuttingDown = true; activeCapture?.requestStop()
        detectionTask?.cancel(); watcher?.cancel()
        Task { await prepareForShutdown() }
    }
}
