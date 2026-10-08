import AVFoundation
import AppKit
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
    @Published private(set) var voiceSession = LiveVoiceSnapshot()
    @Published private(set) var notice = "Choose an app and microphone, then start. Recording is limited to two hours."
    @Published private(set) var problem: MeetingProblem?
    private(set) var error: String? {
        get { problem?.message }
        set { problem = newValue.map(MeetingProblem.unknown) }
    }
    @Published private(set) var admission = MeetingAdmission()
    @Published private(set) var appEnumeration = MeetingAppEnumeration.unchecked
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
    @Published private(set) var completedTranscriptText: String?
    @Published private(set) var autoFinishSeconds: Int?
    @Published var automaticallyFinishCalls: Bool {
        didSet {
            defaults.set(automaticallyFinishCalls, forKey: "workbench.meeting.auto-finish.v1")
            if !automaticallyFinishCalls { autoFinishSeconds = nil }
        }
    }
    private var autoFinish = MeetingAutoFinish()
    private var recordingApp: MeetingAudioApp?
    /// The history writer reads these during saveTranscript; originals stay unchanged.
    @Published private(set) var pendingTranscriptNotes: [String] = []
    @Published var detectionEnabled: Bool {
        didSet {
            defaults.set(detectionEnabled, forKey: Self.detectionKey)
            configureDetection()
        }
    }
    @Published var includeMicrophone = true { didSet { refreshAdmission() } }
    @Published var selectedAppID: Int32? { didSet { refreshAdmission() } }
    @Published var purpose = "meeting"

    var isBusy: Bool { isRecording || isProcessing || isStarting }
    var hostAdmission: (() -> MeetingHostAdmission)? { didSet { refreshAdmission() } }
    // Retained injected capture exclusion; speech readiness has its own typed projection.
    var mayStart: (() -> String?)? { didSet { refreshAdmission() } }
    private var host = MeetingHostAdmission(recognition: .init(admission: .localReady))
    let recordingPlayback = MeetingRecordingPlayback()
    var mayPlayRecording: (() -> Bool)?
    @Published private(set) var canPlayRecording = true

    func updateRecordingPlaybackAdmission() {
        let allowed = mayPlayRecording?() ?? true
        if canPlayRecording != allowed { canPlayRecording = allowed }
        if !allowed { recordingPlayback.pause() }
    }
    var saveTranscript: ((Transcript, String) throws -> Void)?
    var loadSavedTranscript: ((UUID) throws -> (transcript: Transcript, notes: [String])?)?
    /// Checks replace this so they never fill the person's Trash.
    var moveToTrash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var onStateChange: (() -> Void)?

    static let detectionKey = "workbench.meeting.detect.v1"
    static let keptForLater = "Recording was cancelled. Original audio was kept."
    /// The one refusal whose fix is in System Settings, so the page can offer it beside this message only.
    static let microphoneRefused = MeetingProblem.microphoneDenied.message
    static let disabledAppsKey = "workbench.meeting.disabled-apps.v1"
    private let directory: URL
    private let defaults: UserDefaults
    private let detector: MeetingDetector
    private let transcribe: (URL) async throws -> String
    private let microphonePermission: () async -> Bool
    private let microphoneStatus: () -> AVAuthorizationStatus
    private let readSpeechSnapshot: (() async -> RecognitionSnapshot)?
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
    private var liveEngine: RecognitionEngine?
    private var liveVoice: LiveVoiceService?

    convenience init(engine: RecognitionEngine, directory: URL, defaults: UserDefaults = .standard) {
        self.init(directory: directory, defaults: defaults, processSource: MeetingSystemProcessSource(),
                  transcribe: { try await engine.transcribe($0) },
                  microphonePermission: Self.requestMicrophone, captureFactory: { MeetingSystemCapture() },
                  microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
                  readSpeechSnapshot: { await engine.snapshot() })
        liveEngine = engine
        host = MeetingHostAdmission()
        refreshAdmission()
    }

    /// These seams exercise the actual controller with synthetic capture and
    /// recognition. No check needs a device, permission prompt or model download.
    init(directory: URL, defaults: UserDefaults, processSource: MeetingProcessSource,
         transcribe: @escaping (URL) async throws -> String,
         microphonePermission: @escaping () async -> Bool,
         captureFactory: @escaping () -> MeetingCapture,
         startupNoticeDelayNanoseconds: UInt64 = 10_000_000_000,
         microphoneStatus: @escaping () -> AVAuthorizationStatus = { .authorized },
         readSpeechSnapshot: (() async -> RecognitionSnapshot)? = nil) {
        self.directory = directory; self.defaults = defaults
        self.detector = MeetingDetector(source: processSource)
        self.transcribe = transcribe; self.microphonePermission = microphonePermission
        self.microphoneStatus = microphoneStatus
        self.readSpeechSnapshot = readSpeechSnapshot
        self.captureFactory = captureFactory
        self.startupNoticeDelayNanoseconds = startupNoticeDelayNanoseconds
        detectionEnabled = defaults.bool(forKey: Self.detectionKey)
        automaticallyFinishCalls = defaults.object(forKey: "workbench.meeting.auto-finish.v1") as? Bool ?? true
        detector.disabledBundleIDs = Set(defaults.stringArray(forKey: Self.disabledAppsKey) ?? [])
        configureDetection()
        recoveryTask = Task { [weak self] in await self?.refreshRecovery() }
        refreshAdmission()
    }

    /// Hosts call this after their state has changed, not from a synchronous
    /// objectWillChange read. It requests neither permission nor capture.
    func refreshAdmission() {
        if let hostAdmission { host = hostAdmission() }
        let microphone = microphoneStatus()
        let speech = host.recognition.canTranscribe ? nil : MeetingProblem.speech(host.recognition.line)
        var refusal: MeetingProblem? = shuttingDown || host.closing ? .closing : speech
        if refusal == nil { refusal = host.captureProblem ?? mayStart?().map(MeetingProblem.busy) }
        if refusal == nil, selectedAppID != nil {
            switch appEnumeration {
            case .failed(let detail): refusal = .sourceProbe(detail)
            case .unavailable(let detail): refusal = .appAudioUnavailable(detail)
            case .unchecked: refusal = .sourceProbe("Refresh audio apps to check the selected source.")
            case .available:
                if !apps.contains(where: { $0.id == selectedAppID }) { refusal = .sourceDisappeared }
            }
        }
        if refusal == nil, includeMicrophone {
            if microphone == .denied { refusal = .microphoneDenied }
            if microphone == .restricted { refusal = .microphoneRestricted }
        }
        if refusal == nil, selectedAppID == nil, !includeMicrophone { refusal = .noSource }
        let next = MeetingAdmission(microphone: microphone, captureProblem: refusal, recognitionProblem: speech)
        if admission != next { admission = next }
        if let problem, [.microphoneDenied, .microphoneRestricted, .microphoneUnconfirmed].contains(problem), microphone == .authorized { setProblem(nil) }
    }

    func updateHostAdmission(_ value: MeetingHostAdmission) { host = value; refreshAdmission() }
    private func setProblem(_ value: MeetingProblem?) { problem = value }
    var openPrivacyPane: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    func openMicrophoneSettings() { openPrivacy("Microphone") }
    func openAudioRecordingSettings() { openPrivacy("AudioCapture") }
    private func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane), openPrivacyPane(url) else {
            setProblem(.unknown("System Settings could not be opened. Open Privacy & Security from System Settings to review access. No recording started.")); return
        }
    }
    var canUseAppAudioOnly: Bool { selectedAppID != nil && appEnumeration == .available && apps.contains { $0.id == selectedAppID } }
    func useAppAudioOnly() { guard !isBusy, canUseAppAudioOnly else { return }; includeMicrophone = false; setProblem(nil) }
    func useMicrophoneOnly() { guard !isBusy else { return }; selectAudioSource(nil); setProblem(nil) }

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
        if completedTranscriptID == id { completedTranscriptID = nil; completedTranscriptText = nil }
    }

    /// Choosing microphone-only is the explicit source choice; it cannot leave
    /// the preparation form with both sources switched off. Never starts capture.
    func selectAudioSource(_ id: Int32?) {
        guard !isBusy else { return }
        selectedAppID = id
        if id == nil { includeMicrophone = true }
    }

    func refreshApps() {
        switch detector.enumerateApps() {
        case .success(let current): apps = current; appEnumeration = .available
        case .failure(let issue):
            if case .appAudioUnavailable(let detail) = issue { appEnumeration = .unavailable(detail) }
            else { appEnumeration = .failed(issue.message) }
        }
        refreshAdmission()
    }

    func start(expectedApp: MeetingAudioApp? = nil) async {
        guard !isBusy, !shuttingDown else { return }
        if selectedAppID != nil { refreshApps() }
        refreshAdmission()
        if let issue = admission.captureProblem { setProblem(issue); return }
        let app: MeetingAudioApp?
        if let selectedAppID {
            guard let chosen = apps.first(where: { $0.id == selectedAppID }) else {
                setProblem(.sourceDisappeared)
                return
            }
            if let expectedApp, chosen.id != expectedApp.id || chosen.bundleID != expectedApp.bundleID {
                error = "That call offer has changed. Choose the current audio source to start."; return
            }
            app = chosen
        } else { app = nil }
        guard app != nil || includeMicrophone else { error = "Choose an app, the microphone, or both."; return }
        let token = UUID(); generation = token
        let microphone = includeMicrophone, kind = purpose == "call" ? "call" : "meeting"
        setProblem(nil); offer = nil; elapsed = 0; pendingTranscriptNotes = []; completedTranscriptID = nil; completedTranscriptText = nil; keptWithoutSpeech = nil; receipt = nil
        autoFinish = MeetingAutoFinish(); autoFinishSeconds = nil; recordingApp = app
        notice = microphone ? "Waiting for microphone access…" : "Starting app audio… macOS may ask for Audio Recording access."
        phase(starting: true)
        voiceSession = LiveVoiceSnapshot(phase: .preparing)
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
        var createdLive: LiveVoiceService?
        do {
            if microphone {
                let before = microphoneStatus()
                let allowed: Bool
                if before == .authorized { allowed = true }
                else if before == .notDetermined { allowed = await microphonePermission() }
                else { allowed = false }
                try check(token)
                let after = microphoneStatus()
                guard allowed, after == .authorized else {
                    throw after == .restricted ? MeetingProblem.microphoneRestricted : after == .denied ? MeetingProblem.microphoneDenied : MeetingProblem.microphoneUnconfirmed
                }
            }
            try check(token)
            if let readSpeechSnapshot {
                let current = await readSpeechSnapshot()
                try check(token)
                guard current.canTranscribe else { throw MeetingProblem.speech(current.line) }
                host.recognition = current
            }
            if app != nil { refreshApps() }
            refreshAdmission()
            try check(token)
            if let issue = admission.captureProblem { throw issue }
            guard selectedAppID == app?.id, includeMicrophone == microphone else { throw MeetingProblem.checkpoint("The prepared sources changed. Review them and start again.") }
            if let app, !apps.contains(where: { $0.id == app.id && $0.bundleID == app.bundleID }) { throw MeetingProblem.sourceDisappeared }
            notice = app != nil ? "Starting app audio… macOS may ask for Audio Recording access." : "Starting microphone…"
            let manifest = MeetingManifest(id: UUID(), createdAt: Date(), updatedAt: Date(), purpose: purpose,
                                           appName: app?.name, appBundleID: app?.bundleID,
                                           includesMicrophone: microphone, includesRemote: app != nil,
                                           state: .recording, seconds: 0)
            let root = directory
            let session = try await MeetingFileWork.run { try MeetingStore.create(root: root, manifest: manifest) }
            createdSession = session; initial = manifest
            try check(token)
            refreshAdmission()
            if let issue = admission.captureProblem { throw issue }
            activeSession = session; activeManifest = manifest
            // Hold admission through the model reservation too. Cancel waits for this exact
            // startup owner instead of allowing its late completion into a newer capture.
            let recorder = captureFactory(); capture = recorder; activeCapture = recorder
            var sources: [LiveVoiceSourceStatus] = []
            if microphone { sources.append(.init(source: .microphone, name: "Microphone")) }
            if let app { sources.append(.init(source: .app, name: app.name)) }
            voiceSession = LiveVoiceSnapshot(sessionID: manifest.id, phase: .preparing, sources: sources)
            if let engine = liveEngine, try await engine.beginLiveSession(manifest.id) {
                try check(token)
                liveVoice = LiveVoiceService(id: manifest.id, sources: sources,
                    journal: session.appendingPathComponent("live-transcript.json"),
                    recognize: { try await engine.transcribeLive($0, sessionID: manifest.id) },
                    update: { [weak self] snapshot in
                        Task { @MainActor in self?.receiveLiveSnapshot(snapshot) }
                    })
                createdLive = liveVoice
            } else if liveEngine != nil {
                voiceSession.message = "This model transcribes saved audio when you finish. Live words are available with Parakeet."
            }
            // A server reservation returns false; that awaited path needs the
            // same cancellation/admission check as a live local reservation.
            try check(token)
            refreshAdmission()
            if let issue = admission.captureProblem { throw issue }
            let input = liveVoice?.input
            // macOS has no passive check for call audio, and a refused tap delivers silence, so
            // Home's Permissions learns it is allowed only from the app's first real sound.
            let evidence = app != nil ? CallAudioEvidence(defaults) : nil
            try await recorder.start(MeetingCaptureRequest(tracksDirectory: session.appendingPathComponent(MeetingStore.tracksDirectory),
                app: app, includeMicrophone: microphone, onAudio: { audio in
                    if audio.source != .local { evidence?.hear(audio.samples) }
                    input?.append(LiveVoiceAudio(source: audio.source == .local ? .microphone : .app,
                        samples: audio.samples, sampleRate: audio.sampleRate, start: audio.startSeconds))
                }))
            try check(token)
            notice = "Recording. Your original audio is being saved."
            voiceSession.phase = .listening
            phase(recording: true)
            operation = nil
            watch(recorder, token: token)
        } catch {
            if let initial {
                _ = await createdLive?.cancel()
                if liveVoice === createdLive { liveVoice = nil }
                await liveEngine?.endLiveSession(initial.id)
            }
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
            if app != nil, let problem = error as? MeetingProblem, case .appAudioPermission = problem {
                defaults.set(CallAudioRecord.refused.rawValue, forKey: CallAudioRecord.key)
            }
            guard generation == token || activeSession == createdSession && createdSession != nil else { return }
            if !(error is CancellationError), self.error == nil { setProblem((error as? MeetingProblem) ?? .unknown(error.localizedDescription)) }
            activeCapture = nil; activeSession = nil; activeManifest = nil; operation = nil
            notice = error is CancellationError ? "Cancelled. Any recorded audio was kept for explicit retry." : "Recording stopped. Any saved audio is available for retry."
            phase()
            voiceSession.phase = .recoverableFailure
            await refreshRecovery()
        }
    }

    func stop(expected: UUID? = nil) async {
        guard isRecording, expected == nil || recordingIdentity == expected else { return }
        await finishCapture(process: true)
    }

    func keepRecording() {
        autoFinish.keepRecording(); autoFinishSeconds = nil
    }

    func pause() async {
        guard isRecording, let capture = activeCapture, !capture.isPaused else { return }
        let id = generation
        do {
            try await capture.pause()
            guard generation == id, isRecording else { return }
            voiceSession.phase = .paused
            voiceSession.sources = voiceSession.sources.map { var value = $0; value.health = .paused; value.level = 0; return value }
        } catch { self.error = error.localizedDescription }
    }

    func resume() async {
        guard isRecording, let capture = activeCapture, capture.isPaused else { return }
        let id = generation
        voiceSession.phase = .reconnecting
        do {
            try await capture.resume()
            guard generation == id, isRecording else { return }
            voiceSession.phase = .listening
        } catch { self.error = error.localizedDescription; voiceSession.phase = .paused }
    }

    private func receiveLiveSnapshot(_ snapshot: LiveVoiceSnapshot) {
        guard voiceSession.sessionID == snapshot.sessionID, activeSession != nil else { return }
        voiceSession = snapshot
        voiceSession.elapsed = max(elapsed, snapshot.elapsed)
        if isProcessing { voiceSession.phase = .finishing }
        else if isRecording && voiceSession.phase == .recoverableFailure { voiceSession.phase = .listening }
        else if activeCapture?.isPaused == true {
            voiceSession.phase = .paused
            voiceSession.sources = voiceSession.sources.map { var source = $0; source.health = .paused; source.level = 0; return source }
        }
        else if let message = activeCapture?.recoveryMessage {
            voiceSession.phase = .reconnecting; voiceSession.message = message
        }
    }

    private func finishCapture(process: Bool, reason: String? = nil) async {
        guard let capture = activeCapture, let session = activeSession, let manifest = activeManifest else { return }
        watcher?.cancel(); watcher = nil
        autoFinishSeconds = nil
        capture.requestStop()
        let token = UUID(); generation = token
        notice = "Saving the original audio…"
        phase(processing: true)
        voiceSession.phase = .finishing
        let task = Task { [weak self] in
            guard let self else { return }
            let report = await capture.finish()
            var checkpoint = process ? await self.liveVoice?.finish() : await self.liveVoice?.cancel()
            if let checkpoint { self.voiceSession.segments = LiveVoiceTurns.group(checkpoint.orderedSegments) }
            self.liveVoice = nil
            await self.liveEngine?.endLiveSession(manifest.id)
            do {
                if !report.liveAudioComplete, checkpoint != nil {
                    checkpoint!.complete = false
                    try LiveVoiceJournal.save(checkpoint!, to: session.appendingPathComponent("live-transcript.json"))
                }
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
                if !(error is CancellationError) { self.setProblem((error as? MeetingProblem) ?? .unknown(error.localizedDescription)) }
                self.notice = "Original audio was kept. Retry when you are ready."
            }
            self.activeCapture = nil; self.activeSession = nil; self.activeManifest = nil
            await self.refreshRecovery()
            self.operation = nil; self.phase()
            self.voiceSession.phase = self.completedTranscriptID == manifest.id ? .completed : .recoverableFailure
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
        next.gaps += report.gaps
        // Cancellation never cancels the small atomic finalisation write.
        do { try await Task.detached(priority: .utility) { try MeetingStore.save(next, at: session, replacing: previous) }.value }
        catch { throw MeetingProblem.save(error.localizedDescription) }
    }

    func cancel() async {
        watcher?.cancel(); watcher = nil
        if isRecording { await finishCapture(process: false, reason: Self.keptForLater); return }
        guard isStarting || isProcessing else { return }
        generation = UUID()
        startupNoticeTask?.cancel(); startupNoticeTask = nil
        activeCapture?.requestStop()
        let current = operation
        liveVoice?.requestCancel()
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
        let token = UUID(); generation = token
        setProblem(nil); pendingTranscriptNotes = []; completedTranscriptID = nil; completedTranscriptText = nil; keptWithoutSpeech = nil; receipt = nil
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
                if let expected = chosen?.checkpoint, let current = entry.checkpoint, !expected.matches(current) {
                    throw MeetingProblem.checkpoint("The selected recording checkpoint changed. Review it again; no recognition or save was started.")
                }
                try await self.process(session: entry.session, token: token, reviewed: entry.checkpoint)
            } catch {
                if !(error is CancellationError) { self.setProblem((error as? MeetingProblem) ?? .unknown(error.localizedDescription)) }
                self.notice = "The saved checkpoint was kept for review."
            }
            // The kept list is current before the page sees the work end.
            await self.refreshRecovery()
            self.operation = nil; self.phase()
        }
        operation = task; await task.value
    }

    private func process(session: URL, token: UUID, reviewed: MeetingRecoveryCheckpoint? = nil) async throws {
        try check(token)
        let inspected = try await MeetingFileWork.run { try MeetingRecovery.inspect(session: session) }
        try check(token)
        guard let checkpoint = inspected.checkpoint else { throw MeetingProblem.checkpoint("The recording checkpoint could not be read.") }
        if let reviewed, !reviewed.matches(checkpoint) { throw MeetingProblem.checkpoint("The selected checkpoint changed. Review it again before saving or transcribing.") }
        let intent: MeetingProcessor.Intent
        if checkpoint.text != nil { intent = .commitOnly(checkpoint) }
        else {
            guard checkpoint.originalsAvailable else {
                if checkpoint.manifest.tracks.isEmpty { throw MeetingProblem.noSamples }
                throw MeetingProblem.checkpoint("Original audio is missing and this transcript is incomplete. Its remaining checkpoint was kept; the past recording cannot be recaptured.")
            }
            if let readSpeechSnapshot {
                let current = await readSpeechSnapshot(); try check(token)
                guard current.canTranscribe else { throw MeetingProblem.speech(current.line) }
                host.recognition = current
            }
            refreshAdmission()
            if let issue = admission.recognitionProblem { throw issue }
            intent = .recognize(checkpoint)
        }
        processingSessionID = UUID(uuidString: session.lastPathComponent)
        defer { processingSessionID = nil }
        notice = checkpoint.text != nil ? "Saving complete transcript…" : "Transcribing saved audio…"
        let processor = MeetingProcessor(session: session, transcribe: transcribe, commit: { [weak self] transcript, purpose, notes in
            guard let self else { throw CancellationError() }
            try self.check(token)
            if let existing = try self.loadSavedTranscript?(transcript.id) {
                self.pendingTranscriptNotes = existing.notes; self.completedTranscriptText = existing.transcript.text
                return
            }
            guard let save = self.saveTranscript else { throw MeetingError.message("History is not ready to save this recording. Its original audio was kept.") }
            self.pendingTranscriptNotes = notes
            try save(transcript, purpose)
            if let resolve = self.loadSavedTranscript {
                guard let saved = try resolve(transcript.id) else { throw MeetingProblem.save("History did not confirm the saved UUID.") }
                self.completedTranscriptText = saved.transcript.text; self.pendingTranscriptNotes = saved.notes
            } else { self.completedTranscriptText = transcript.text }
        }, isCurrent: { [weak self] in self?.generation == token })
        let result: MeetingProcessor.Outcome
        do { result = try await processor.run(intent: intent) }
        catch is CancellationError { throw CancellationError() }
        catch let issue as MeetingProblem { throw issue }
        catch { throw checkpoint.text != nil ? MeetingProblem.save(error.localizedDescription) : MeetingProblem.recognition(error.localizedDescription) }
        if let saved = try loadSavedTranscript?(result.manifest.id), result.committed {
            pendingTranscriptNotes = saved.notes; completedTranscriptText = saved.transcript.text
        } else { pendingTranscriptNotes = result.notes }
        if result.committed { completedTranscriptID = result.manifest.id }
        else { keptWithoutSpeech = KeptMeeting(session: session, message: result.manifest.failure ?? "No speech was recognised.") }
        notice = ([result.committed ? "Saved to History." : result.manifest.failure ?? "The recording checkpoint was kept."] + pendingTranscriptNotes).joined(separator: " ")
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
                self.voiceSession.elapsed = self.elapsed
                if capture.isPaused { self.voiceSession.phase = .paused }
                else if let message = capture.recoveryMessage {
                    self.voiceSession.phase = .reconnecting; self.voiceSession.message = message
                } else if self.voiceSession.phase == .reconnecting { self.voiceSession.phase = .listening; self.voiceSession.message = nil }
                var reason = capture.stopReason
                if self.elapsed >= MeetingSegmentPlan.maximumMeetingSeconds { reason = "The two-hour recording limit was reached." }
                ticks += 1
                if ticks % 4 == 0, let app = self.recordingApp {
                    self.autoFinishSeconds = self.autoFinish.observe(self.detector.activity(for: app),
                        now: ProcessInfo.processInfo.systemUptime,
                        suspended: !self.automaticallyFinishCalls || capture.isPaused || capture.recoveryMessage != nil)
                }
                if ticks % 10 == 0 {
                    let root = self.directory
                    let bytes = try? await MeetingFileWork.run { MeetingDiskBudget.availableBytes(at: root) }
                    guard self.generation == token, self.isRecording else { return }
                    if let bytes, bytes < MeetingDiskBudget.stopFloorBytes { reason = "Recording stopped because disk space is running low." }
                }
                if let reason { await self.finishCapture(process: false, reason: reason); return }
                if self.autoFinishSeconds == 0 {
                    await self.finishCapture(process: true); return
                }
            }
        }
    }

    private func phase(starting: Bool = false, recording: Bool = false, processing: Bool = false) {
        isStarting = starting; isRecording = recording; isProcessing = processing
        if !starting { startupNoticeTask?.cancel(); startupNoticeTask = nil }
        detector.isSuppressed = isBusy
        refreshAdmission()
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
        refreshAdmission()
        detector.isSuppressed = isBusy || host.closing || !host.recognition.canTranscribe
            || host.captureProblem != nil || mayStart?() != nil
        offer = detector.evaluate()
        if let issue = detector.lastError, !isBusy { error = issue }
    }

    /// Chooses the offered source for review. A call on this Mac is saved as a Call.
    func useOffer(_ app: MeetingAudioApp) {
        guard !isBusy else { return }
        selectedAppID = app.id
        if MeetingDetector.isCallService(app) { purpose = "call" }
    }

    /// The button acts on the offer it displayed. Never substitutes a new process/app.
    func startOffered(_ app: MeetingAudioApp) async {
        guard !isBusy, !shuttingDown else { return }
        guard offer == app else { error = "That call offer has changed. Choose the current audio source to start."; return }
        refreshApps()
        if case .failed(let detail) = appEnumeration { setProblem(.sourceProbe(detail)); return }
        if case .unavailable(let detail) = appEnumeration { setProblem(.appAudioUnavailable(detail)); return }
        guard apps.contains(where: { $0.id == app.id && $0.bundleID == app.bundleID }) else {
            offer = nil; error = "That audio source is no longer available. Choose its current source to start."; return
        }
        useOffer(app)
        await start(expectedApp: app)
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
    func dismissError() { setProblem(nil) }

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
        refreshAdmission()
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

/// Writes call audio's record once, from the first app samples that carry sound. A refused tap
/// delivers silence rather than an error, so silence proves nothing either way and writes nothing.
final class CallAudioEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var heard = false
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func hear(_ samples: [Float]) {
        lock.lock(); let done = heard; lock.unlock()
        guard !done, samples.contains(where: { $0 != 0 }) else { return }
        lock.lock(); defer { lock.unlock() }
        guard !heard else { return }
        heard = true
        defaults.set(CallAudioRecord.allowed.rawValue, forKey: CallAudioRecord.key)
    }
}
