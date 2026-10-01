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
    /// Recordings that still hold audio without text, newest first. Each is retried, shown or
    /// moved to the Trash by its own row, never by whichever happens to sort first.
    @Published private(set) var recoveries: [MeetingRecoveryEntry] = []
    var hasRecovery: Bool { !recoveries.isEmpty }
    /// The last recording that finished without a word: kept, never offered for retry, and shown
    /// once so the person can find or remove its audio.
    @Published private(set) var keptWithoutSpeech: KeptMeeting?
    /// A quiet line after an action that leaves nothing else on the page, such as Move to Trash.
    @Published private(set) var receipt: String?
    struct KeptMeeting: Equatable {
        var session: URL
        var message: String
    }
    /// Published only after the transcript and its completion journal both commit.
    @Published private(set) var completedTranscriptID: UUID?
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
    let recordingPlayback = MeetingRecordingPlayback()
    var mayPlayRecording: (() -> Bool)?
    @Published private(set) var canPlayRecording = true

    func updateRecordingPlaybackAdmission() {
        let allowed = mayPlayRecording?() ?? true
        if canPlayRecording != allowed { canPlayRecording = allowed }
        if !allowed { recordingPlayback.pause() }
    }
    var saveTranscript: ((Transcript, String) throws -> Void)?
    /// Checks replace this so they never fill the person's Trash.
    var moveToTrash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var onStateChange: (() -> Void)?

    static let detectionKey = "workbench.meeting.detect.v1"
    static let keptForLater = "Recording was cancelled. Original audio was kept."
    /// The one refusal whose fix is in System Settings, so the page can offer it beside this message only.
    static let microphoneRefused = "Allow Microphone access in Privacy & Security to include your voice, or choose app audio only."
    static let disabledAppsKey = "workbench.meeting.disabled-apps.v1"
    private let directory: URL
    private let defaults: UserDefaults
    private let detector: MeetingDetector
    private let transcribe: (URL) async throws -> String
    private let microphonePermission: () async -> Bool
    private let captureFactory: () -> MeetingCapture
    private let startupNoticeDelayNanoseconds: UInt64
    private var generation = UUID()
    var recordingIdentity: UUID? { isRecording ? generation : nil }
    private var operation: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var startupNoticeTask: Task<Void, Never>?
    private var activeCapture: MeetingCapture?
    private var activeSession: URL?
    private var activeManifest: MeetingManifest?
    private var processingSessionID: UUID?
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
         captureFactory: @escaping () -> MeetingCapture,
         startupNoticeDelayNanoseconds: UInt64 = 10_000_000_000) {
        self.directory = directory; self.defaults = defaults
        self.detector = MeetingDetector(source: processSource)
        self.transcribe = transcribe; self.microphonePermission = microphonePermission
        self.captureFactory = captureFactory
        self.startupNoticeDelayNanoseconds = startupNoticeDelayNanoseconds
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

    func hasRecording(for transcriptID: UUID) -> Bool {
        MeetingTranscriptRemoval.hasRecording(root: directory, id: transcriptID)
    }

    func recordingURL(for transcriptID: UUID) throws -> URL {
        guard !(isBusy && (activeManifest?.id == transcriptID || processingSessionID == transcriptID)) else {
            throw MeetingError.message("This recording is still in use. Finish its capture or recovery before playing it.")
        }
        return MeetingStore.sessionURL(root: directory, id: transcriptID)
    }

    /// No suspension between admission and staging: capture/recovery cannot
    /// start using this same UUID during a confirmed removal.
    func removeCompletedRecording(for transcriptID: UUID, commit: () throws -> Void) throws -> String? {
        guard recordingPlayback.session?.lastPathComponent != transcriptID.uuidString else {
            throw MeetingError.message("Close the recording review before removing this transcript and its audio.")
        }
        guard !shuttingDown,
              !(isBusy && (activeManifest?.id == transcriptID || processingSessionID == transcriptID)) else {
            throw MeetingError.message("This recording is still in use. Finish or cancel it before removing its transcript and audio.")
        }
        let notice = try MeetingTranscriptRemoval.remove(root: directory, id: transcriptID, commit: commit)
        transcriptRemoved(transcriptID)
        return notice
    }

    /// History calls this after its durable removal, including when the audio
    /// directory has already gone. Failed or cancelled removals never arrive here.
    func transcriptRemoved(_ id: UUID) {
        if completedTranscriptID == id { completedTranscriptID = nil }
    }

    /// Choosing microphone-only is the explicit source choice; it cannot leave
    /// the preparation form with both sources switched off. Never starts capture.
    func selectAudioSource(_ id: Int32?) {
        guard !isBusy else { return }
        selectedAppID = id
        if id == nil { includeMicrophone = true }
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
        error = nil; offer = nil; elapsed = 0; pendingTranscriptNotes = []; completedTranscriptID = nil; keptWithoutSpeech = nil; receipt = nil
        notice = microphone ? "Waiting for microphone access…" : "Starting app audio… macOS may ask for Audio Recording access."
        phase(starting: true)
        let delay = startupNoticeDelayNanoseconds
        startupNoticeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.generation == token, self.isStarting else { return }
            let permission = microphone ? (app != nil ? "Microphone or Audio Recording" : "Microphone") : "Audio Recording"
            self.notice = "macOS has not finished starting audio. Check for a \(permission) permission prompt. You can cancel this start while macOS responds."
        }
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
                guard allowed else { throw MeetingError.message(Self.microphoneRefused) }
            }
            try check(token)
            notice = app != nil ? "Starting app audio… macOS may ask for Audio Recording access." : "Starting microphone…"
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

    func stop(expected: UUID? = nil) async {
        guard isRecording, expected == nil || recordingIdentity == expected else { return }
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
                else if reason == Self.keptForLater {
                    // Stop & keep for later is the person's choice, not a failure.
                    self.notice = "Kept for later. Transcribe it below when you are ready."
                    self.error = report.failure
                } else {
                    self.notice = "Recording stopped. Its audio is kept below; transcribe it when you are ready."
                    self.error = reason ?? report.failure
                }
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                self.notice = "Original audio was kept. Retry when you are ready."
            }
            self.activeCapture = nil; self.activeSession = nil; self.activeManifest = nil
            await self.refreshRecovery()
            self.operation = nil; self.phase()
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
        if isRecording { await finishCapture(process: false, reason: Self.keptForLater); return }
        guard isStarting || isProcessing else { return }
        generation = UUID()
        startupNoticeTask?.cancel(); startupNoticeTask = nil
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
        if isStarting {
            notice = "Cancelling start. Waiting for macOS to finish its audio request; a late permission response cannot begin recording."
        }
        await current?.value
        if isBusy { phase() }
    }

    /// Transcribes the chosen kept recording, or the newest readable one when none is named.
    func retry(_ chosen: MeetingRecoveryEntry? = nil) async {
        guard !isBusy, !shuttingDown else { return }
        if let issue = mayStart?() { error = issue; return }
        let token = UUID(); generation = token
        error = nil; pendingTranscriptNotes = []; completedTranscriptID = nil; keptWithoutSpeech = nil; receipt = nil
        notice = "Opening the saved recording…"; phase(processing: true)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let root = self.directory
                let entries = try await MeetingFileWork.run { MeetingRecovery.scan(root: root) }
                try self.check(token)
                let target = chosen.map { chosen in entries.first { $0.id == chosen.id } } ?? entries.first { $0.isReadable }
                guard let entry = target, entry.isReadable else {
                    throw MeetingError.message(target?.problem ?? (chosen == nil ? entries.first?.problem : nil)
                        ?? "That recording is no longer waiting to be transcribed.")
                }
                try await self.process(session: entry.session, token: token)
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                self.notice = "Saved audio remains available for explicit retry."
            }
            // The kept list is current before the page sees the work end.
            await self.refreshRecovery()
            self.operation = nil; self.phase()
        }
        operation = task; await task.value
    }

    private func process(session: URL, token: UUID) async throws {
        try check(token)
        processingSessionID = UUID(uuidString: session.lastPathComponent)
        defer { processingSessionID = nil }
        notice = "Transcribing saved audio…"
        let processor = MeetingProcessor(session: session, transcribe: transcribe, commit: { [weak self] transcript, purpose, notes in
            guard let self else { throw CancellationError() }
            try self.check(token)
            guard let save = self.saveTranscript else { throw MeetingError.message("History is not ready to save this recording. Its original audio was kept.") }
            self.pendingTranscriptNotes = notes
            try save(transcript, purpose)
        }, isCurrent: { [weak self] in self?.generation == token })
        let result = try await processor.run()
        pendingTranscriptNotes = result.notes
        if result.committed { completedTranscriptID = result.manifest.id }
        else { keptWithoutSpeech = KeptMeeting(session: session, message: result.manifest.failure ?? "No speech was recognised.") }
        notice = ([result.committed ? "Saved to History." : "Original audio was kept."] + result.notes).joined(separator: " ")
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
        if !starting { startupNoticeTask?.cancel(); startupNoticeTask = nil }
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
        // An unreadable recording names its own problem in its row on the page.
        recoveries = entries
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
                self.refreshDetection()
            }
        }
    }

    /// One metadata poll, shared by the timer and deterministic lifecycle checks.
    /// It cannot request permission or open a capture.
    func refreshDetection() {
        guard detectionEnabled, !shuttingDown else { offer = nil; return }
        detector.isSuppressed = isBusy || mayStart?() != nil
        offer = detector.evaluate()
        if let issue = detector.lastError, !isBusy { error = issue }
    }

    /// Chooses the offered source for review. A call on this Mac is saved as a Call.
    func useOffer(_ app: MeetingAudioApp) {
        selectedAppID = app.id
        if MeetingDetector.isCallService(app) { purpose = "call" }
    }
    /// Moves one kept recording's folder to the Trash, where Finder can put it back. Only a
    /// session this store lists, and never one being recorded or transcribed.
    func moveRecordingToTrash(_ session: URL) async {
        guard !shuttingDown else { return }
        let id = session.lastPathComponent
        guard !(isBusy && (activeSession?.lastPathComponent == id || processingSessionID?.uuidString == id)),
              recordingPlayback.session?.lastPathComponent != id else {
            error = "This recording is still in use. Finish or close it before moving it to the Trash."; return
        }
        let root = directory, trash = moveToTrash
        do {
            try await MeetingFileWork.run {
                guard let listed = MeetingStore.sessions(in: root).first(where: { $0.lastPathComponent == id }) else {
                    throw MeetingError.message("That recording is no longer in the Meetings folder.")
                }
                try trash(listed)
            }
            if keptWithoutSpeech?.session.lastPathComponent == id { keptWithoutSpeech = nil }
            receipt = "Moved to the Trash. Finder can put it back."
        } catch { self.error = error.localizedDescription }
        await refreshRecovery()
    }

    func dismissKeptWithoutSpeech() { keptWithoutSpeech = nil }
    func dismissError() { error = nil }

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
        recordingPlayback.close()
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
