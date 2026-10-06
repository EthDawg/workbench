import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import PhotoHandoffKit
import ToolbarCore

@MainActor
final class AppModel: NSObject, ObservableObject {
    static weak var intentModel: AppModel?
    let shortcutRequest = DictationRequest()
    func cancelShortcut(_ id: UUID) {
        guard shortcutRequest.id == id else { return }
        cancelCurrentCapture()
    }
    func transcribeForShortcut(_ url: URL, id: UUID = UUID()) async throws -> String {
        guard ready else { throw VoiceError.message("Open Workbench and finish preparing the speech model, then run this shortcut again.") }
        guard phase == .idle else { throw VoiceError.message("Workbench is busy. Finish the current recording first.") }
        guard !meetings.isBusy else { throw VoiceError.message("Finish the meeting recording or transcription first.") }
        guard !captureRecovery.hasRecovery else { throw CaptureRecoveryError.pending }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > 0, duration <= 1800 else { throw VoiceError.message("Choose an audio recording up to 30 minutes long.") }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try shortcutRequest.begin(id: id) { continuation.resume(with: $0) }
                    onCloseMenu?(); destination = nil
                    transcribe(url, duration: duration, temporary: false)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelShortcut(id)
            }
        }
    }

    enum Phase: String { case idle, requesting, recording, transcribing, cleaning, delivering, cancelling }
    let clipboardReceipt = ClipboardReceiptModel()
    @Published var captureProcessingLabel = "Preparing speech…"
    @Published private(set) var waitingForDrawing = false
    var shouldDeferDelivery: (() -> Bool)?
    private let drawingDelivery = DrawingDeliveryGate()
    func resumeWaitingDelivery() {
        guard waitingForDrawing, shouldDeferDelivery?() != true else { return }
        drawingDelivery.resolve(.resume)
    }
    func copyWaitingDelivery() { drawingDelivery.resolve(.copy) }
    @Published var isMicrophoneQuiet = false
    @Published var captureUsesHoldShortcut = false
    /// This attempt's press of the global Dictate shortcut in Hold, timed by
    /// the native key events (#134 T5).
    private var holdGesture: HoldGesture?
    /// The one-time coaching card; the floating control's host shows it.
    let coach = FeedbackCoachModel()
    /// A delivery that did not finish, kept by this owner rather than by the
    /// receipt and saved with the session, so hiding or clearing the receipt,
    /// or quitting, cannot resolve it (T5).
    @Published private(set) var undelivered = UnresolvedDeliverySlot() { didSet { if undelivered != oldValue { persist() } } }
    @Published private(set) var captureOutputModeLabel = "Light cleanup"
    @Published private(set) var captureShortcutInstruction = "Use Stop to finish"
    @Published var captureFailure: String?
    var captureDestinationName: String? { destination?.app.localizedName }
    var canCancelCurrentCapture: Bool {
        [.requesting, .recording].contains(phase) || ([.transcribing, .cleaning].contains(phase) && transcriptionTask != nil)
    }
    func dismissCaptureFailure() { captureFailure = nil }
    @Published var preferences: VoicePreferences {
        didSet {
            preferences.save()
            if VoicePreferences.shortcutIDs.contains(where: { oldValue.shortcut($0) != preferences.shortcut($0) }) { onShortcutsChanged?() }
        }
    }
    @Published var rawTranscript = ""
    @Published var cleanupMethod = ""
    @Published var editingShortcut: UInt32?
    @Published var shortcutRecordingMessage: String?
    @Published var previewingPanel = false
    let promptInsertion = PromptInsertion()
    /// The floating toolbar's mode follows the journey: starting anything from
    /// any door makes it the mode, ending leaves it. Dictate seeds it because it
    /// works in every app with only the microphone.
    @Published var toolbarMode: ToolbarMode = ToolbarMode(rawValue: UserDefaults.standard.string(forKey: "workbench.toolbarMode.v1") ?? "") ?? .dictate {
        didSet { UserDefaults.standard.set(toolbarMode.rawValue, forKey: "workbench.toolbarMode.v1") }
    }
    @Published var floatingToolbarVisible = UserDefaults.standard.object(forKey: "workbench.floatingToolbar.v1") as? Bool ?? true {
        didSet { UserDefaults.standard.set(floatingToolbarVisible, forKey: "workbench.floatingToolbar.v1") }
    }
    @Published var shortcutFailures: [UInt32: String] = [:]
    @Published var page = "home"
    /// A section a named door asks its page to show and focus once it appears, such as Dictate's
    /// options (#134). The page clears it when it has.
    @Published var focusRequest: PageFocusRequest?
    /// How the next visit to History begins. The page applies it once and
    /// clears it; without one, History opens on All.
    @Published var historyDoor: HistoryDoor?
    @Published var libraryFocusToken = UUID()
    @Published var phase: Phase = .idle {
        didSet {
            if phase == .idle {
                destination?.opaqueEditor?.end()
                liveDictation?.end(); liveDictation = nil
            }
        }
    }
    @Published var ready = false
    @Published var preparing = false
    @Published var modelMessage = "Download Parakeet to turn speech into text on this Mac."
    @Published private(set) var recognition = RecognitionSnapshot()
    @Published private(set) var microphoneAuthorization = AVAuthorizationStatus.notDetermined
    @Published private(set) var microphoneFailure: AVAuthorizationStatus?
    var readMicrophoneAuthorization: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var requestMicrophoneAuthorization: @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    /// The engine remains authoritative; the isolated gallery can hold this reply
    /// to exercise cancellation without constructing any audio capture.
    var readSpeechAdmission: @MainActor (RecognitionEngine) async -> Bool = { await $0.isReady }
    var openMicrophonePrivacy: () -> Bool = { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
    /// The writing model's one download, Ollama's, owned here as Parakeet's setup is: leaving
    /// Settings › Models changes nothing, and its line reaches wherever readiness shows (#134).
    private(set) lazy var cleanupModels: CleanupModelManager = {
        let manager = CleanupModelManager()
        cleanupModelsObserver = manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return manager
    }()
    private var cleanupModelsObserver: AnyCancellable?
    /// The writing model's progress or failure beside the speech model's line, or nothing.
    var writingModelLine: String? { cleanupModels.downloadLine ?? cleanupModels.failure }
    /// Why the speech model could not be prepared, for Settings › Models beside its Try again.
    @Published var modelFailure: String?
    @Published var status = "Ready when you are."
    /// What needs attention, with the page that shows it in full. It is raised only with
    /// `report(_:on:)`, so its page is chosen where the problem happens (#134).
    @Published private(set) var attention: Attention?
    /// The problem's words, for the banner, the menu-bar panel and VoiceOver.
    var error: String? { attention?.message }
    @Published var transcript = "" { didSet { draftRevision &+= 1; persist() } }
    @Published var speechText = "" { didSet { persist() } }
    @Published var history: [Transcript] = [] { didSet { recordFirstDictation() } }
    let historyLibrary = WorkbenchHistoryModel(directory: Workbench.supportDirectory(component: "LocalVoice"))
    let handoffJobs = HandoffJobsModel(directory: Workbench.supportDirectory(component: "Handoffs"))
    lazy var meetings = MeetingModel(engine: engine, directory: Workbench.supportDirectory(component: "Meetings"))
    var onHandOffSelection: ((String?) -> Void)?
    var onSuggestTranscriptDetails: ((UUID) -> Void)?
    var resolveAdditionalHandoffItems: ((Set<WorkbenchItemReference>) throws -> [HandoffSourceSnapshot])?
    @Published var replacements: [Replacement] = []
    @Published private(set) var rememberedCorrection: RememberedCorrection?
    /// Dormant Read values retained exactly for SavedState compatibility.
    @Published var voice = "" { didSet { persist() } }
    @Published var rate = 180.0 { didSet { persist() } }
    @Published var elapsed = 0.0
    @Published var level = 0.0
    @Published private(set) var pendingTranscript: Transcript?

    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var canRetry = false
    var retryCaptureLabel: String { captureRecovery.pending?.capture == nil ? "Retry transcription" : "Retry saving" }
    var retryCaptureHelp: String { captureRecovery.pending?.capture == nil ? "Retry the captured audio" : "Save the recognized text without transcribing or pasting again" }
    var hasCaptureRecovery: Bool { captureRecovery.hasRecovery }
    var canRecordAgain: Bool { phase == .idle && captureRecovery.canKeepAudioForLater }
    var hasSavedRecordings: Bool { FileManager.default.fileExists(atPath: captureRecovery.savedRecordingsDirectory.path) }
    var canDiscardCaptureRecovery: Bool { phase == .idle && captureRecovery.pending != nil && captureRecovery.problem == nil }
    private let captureRecovery = CaptureRecoveryStore(directory: Workbench.supportDirectory(component: "LocalVoice").appendingPathComponent("CaptureRecovery", isDirectory: true))
    // The focused acceptance harness injects only the state write, never live input or delivery.
    var captureStateWriter: ((SavedState) throws -> Void)?
    let engine = RecognitionEngine()
    let cleanupEngine = CleanupEngine()
    let store = StateStore()
    let library = DemoLibraryModel()
    lazy var presenter = PresenterModel(library: library)
    var onShowPresenter: (() -> Void)?
    let photoHandoff = PhotoHandoffModel(directory: Workbench.supportDirectory(component: "PhotoHandoff"), platform: "Mac")
    private var photoHandoffRefresh: Task<Void, Never>?
    private var photoHandoffActivation: AnyCancellable?
    private var loaded = false
    private var draftRevision: UInt64 = 0
    private var liveCapture: DictationVoiceCapture?
    var hasActiveVoiceCapture: Bool { liveCapture != nil }
    @Published private(set) var voiceSession = LiveVoiceSnapshot()
    /// Only the verified, isolated surface-gallery child can project recording
    /// state without creating a real audio capture.
    func applyGalleryVoiceSnapshot(_ snapshot: LiveVoiceSnapshot) {
        guard ProcessInfo.processInfo.arguments.contains(SurfaceGallery.passFlag) else { return }
        voiceSession = snapshot
    }
    private var recordURL: URL?
    private var meter: Timer?

    private var peakPower: Float = -160
    private var destination: TextDelivery.Target? {
        didSet { oldValue?.opaqueEditor?.end(); liveDictation?.end(); liveDictation = nil }
    }
    private var liveDictation: LiveDictationDelivery?
    /// Dictated words fit the field (#14); the dictionary's spellings keep their capitals.
    private var insertionContext: InsertionBoundary.Context { .init(dictionaryTerms: replacements.map(\.written)) }
    private var recordingAttempt: UUID?
    private var recordingSettings: CaptureSettings?
    private var permissionRequest: Task<Bool, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionID: UUID?
    var toolbarCaptureIdentity: String {
        [recordingAttempt, transcriptionID, captureRecovery.pending?.id].compactMap { $0?.uuidString }.joined(separator: ":")
    }

    private var persistWork: DispatchWorkItem?
    var onPhaseChange: (() -> Void)?
    var onShortcutsChanged: (() -> Void)?
    var onEditShortcut: ((UInt32) -> Void)?
    @Published var toolbarControls: CaptureHUDControls?
    var onShowEditor: ((String) -> Void)?
    var onShowAnnotationMenu: (() -> Void)?
    var onUsePhotoAsBackdrop: ((URL, String) -> Void)?
    var onMenuRecording: (() -> Void)?
    var onCloseMenu: (() -> Void)?
    var onCancelShortcut: (() -> Void)?
    var onResetShortcuts: (() -> Void)?
    var onResetPanel: (() -> Void)?
    var microphoneStartFailure: ((TextDelivery.Target?) -> String?)?

    init(preferences: VoicePreferences, startSpeechLifecycle: Bool = true) {
        self.preferences = preferences
        super.init()
        Self.intentModel = self
        // Any door that prepares the speech model shows its progress in the one readiness
        // line Home, the panel and Dictate read.
        let engine = self.engine, sink = ModelProgressSink(self)
        if startSpeechLifecycle {
            Task { await engine.observe { state in Task { @MainActor in sink.model?.acceptRecognition(state) } } }
        }
        photoHandoffActivation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPhotoHandoffIfEnabled(); self?.refreshMicrophoneAuthorization(); self?.meetings.refreshAdmission() }
        refreshPhotoHandoffIfEnabled()
        var savedUndelivered: UnresolvedDelivery?
        var loadedDraftRevision = draftRevision
        do {
            let state = try store.load()
            transcript = state.draft; speechText = state.speechText; history = state.history
            savedUndelivered = state.undelivered; loadedDraftRevision = draftRevision
            // Observers do not run inside init, so a loaded History records it here.
            recordFirstDictation()
            rawTranscript = state.rawDraft ?? state.draft
            replacements = state.replacements; voice = state.voice; rate = state.rate
            let removalIssues = MeetingTranscriptRemoval.reconcile(
                root: Workbench.supportDirectory(component: "Meetings"), history: store)
            if !removalIssues.isEmpty {
                report("A recording couldn’t be removed completely. " + removalIssues.joined(separator: " "), on: .history)
            }
        } catch {
            let backup = store.url.deletingLastPathComponent().appendingPathComponent("state-unreadable-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: store.url, to: backup)
                report("Your saved session could not be opened. A recovery copy was preserved as \(backup.lastPathComponent) in \(backup.deletingLastPathComponent().path).", on: .dictate)
            } catch {
                report("Your saved session could not be opened or backed up. Automatic saving is disabled to protect the original file.", on: .dictate)
                return
            }
        }
        loaded = true
        library.preserveRetiredReading(speechText)
        restoreCaptureRecovery()
        // With the draft settled: a delivery that did not finish comes back
        // only while its record still holds its words (#134 T5).
        undelivered.restore(savedUndelivered, loadedDraftRevision: loadedDraftRevision, in: deliveryRecords)
        if startSpeechLifecycle { Task { await prepare() } }
    }

    func refreshPhotoHandoffIfEnabled() {
        guard photoHandoff.isEnabled, photoHandoff.isConfigured, !photoHandoff.isBusy, photoHandoffRefresh == nil else { return }
        photoHandoffRefresh = Task { [weak self] in
            guard let self else { return }
            defer { photoHandoffRefresh = nil }
            await photoHandoff.refresh()
        }
    }

    /// Reject observer deliveries that crossed on their way back to the main actor.
    func acceptRecognition(_ state: RecognitionSnapshot) {
        guard state.sequence >= recognition.sequence else { return }
        recognition = state; ready = state.canTranscribe; preparing = state.isPreparing
        modelMessage = state.line; modelFailure = state.failure?.errorDescription
    }
    func prepare() async {
        do { try await engine.prepareCached() } catch { /* The engine owns the typed failure. */ }
        acceptRecognition(await engine.snapshot())
    }
    func downloadSpeechModel() async {
        do { try await engine.acquireSelectedModel() } catch { /* The engine owns the typed failure. */ }
        acceptRecognition(await engine.snapshot())
    }
    func cancelSpeechPreparation() { Task { await engine.cancelPreparation(); acceptRecognition(await engine.snapshot()) } }
    var canToggleRecording: Bool {
        phase == .requesting || phase == .recording || (phase == .idle && ready)
    }

    func toggleRecording(fromShortcut: Bool = false, target: TextDelivery.Target? = nil) {
        if phase == .requesting { cancelRecording(); return }
        if phase == .recording { stopRecording(); return }
        guard phase == .idle else { return }
        guard ready else { page = "models"; onShowEditor?("models"); return }
        microphoneFailure = nil
        let intendedTarget = target ?? (fromShortcut ? TextDelivery.capture() : nil)
        if let reason = microphoneStartFailure?(intendedTarget) {
            // Dictate's banner shows it beside the page's mic, as admitNewCapture's refusals are.
            captureFailure = reason; report(reason, on: .dictate); status = reason; return
        }
        guard admitNewCapture() else { return }
        clipboardReceipt.clear()
        captureFailure = nil; dismissCaptureCue()
        coach.remove(); holdGesture = nil
        previewingPanel = false
        captureUsesHoldShortcut = fromShortcut && preferences.capture == .hold
        recordingSettings = captureSettings()
        isMicrophoneQuiet = false
        let attempt = UUID(); recordingAttempt = attempt
        destination = intendedTarget
        destination?.opaqueEditor?.begin(shortcut: preferences.dictationShortcut)
        if recordingSettings?.preferences.delivery == .paste, shouldDeferDelivery?() != true {
            liveDictation = LiveDictationDelivery.begin(target: intendedTarget, shortcut: preferences.dictationShortcut, context: insertionContext)
        }
        phase = .requesting
        Task { await startRecording(attempt) }
    }
    /// Record again, from a failure's own controls or More: only ever a start. They were drawn, or
    /// More was built, while nothing ran, so a recording begun since, by the shortcut say, is left
    /// alone rather than cancelled or stopped by the toggle, as Home's Quick start does (#211).
    func recordAgain() {
        guard phase == .idle else { return }
        toggleRecording()
    }
    /// `time` is the key event's own timestamp (NSEvent or Carbon), in
    /// seconds since the Mac started. A hold is timed from the press that
    /// began the attempt to its release, never from later callbacks.
    func shortcutChanged(down: Bool, at time: TimeInterval? = nil) {
        let usesHold = phase == .idle ? preferences.capture == .hold : captureUsesHoldShortcut
        if !usesHold { if down { toggleRecording(fromShortcut: true) }; return }
        if down {
            guard phase == .idle else { return }
            toggleRecording(fromShortcut: true)
            if phase == .requesting, captureUsesHoldShortcut, let attempt = recordingAttempt, let time {
                holdGesture = HoldGesture(attempt: attempt, pressedAt: time)
            }
        } else {
            if let time, let attempt = recordingAttempt, holdGesture?.attempt == attempt { holdGesture?.release(at: time) }
            if phase == .recording { stopRecording() }
            else if phase == .requesting { cancelRecording() }
        }
    }

    private func startRecording(_ attempt: UUID) async {
        guard recordingAttempt == attempt else { return }
        phase = .requesting; attention = nil; onPhaseChange?()
        let granted: Bool
        microphoneAuthorization = readMicrophoneAuthorization()
        switch microphoneAuthorization {
        case .authorized: granted = true
        case .notDetermined:
            status = "Allow Microphone access in the macOS prompt."
            if permissionRequest == nil { permissionRequest = Task { await requestMicrophoneAuthorization() } }
            granted = await permissionRequest!.value; permissionRequest = nil
        default: granted = false
        }
        guard recordingAttempt == attempt else { return }
        microphoneAuthorization = readMicrophoneAuthorization()
        guard granted, microphoneAuthorization == .authorized else {
            fail(Self.microphoneMessage(microphoneAuthorization)); microphoneFailure = microphoneAuthorization; return
        }
        let admitted = await readSpeechAdmission(engine)
        // Cancel or a new Start can run while the actor replies. Neither a true
        // nor a false old reply may create recovery files or fail the new attempt.
        guard recordingAttempt == attempt else { return }
        guard ready, admitted else { fail("Speech is no longer ready. Open Models, then start a new recording when setup is complete."); return }
        var startedAudio: URL?
        do {
            let url = try captureRecovery.beginRecording()
            startedAudio = url
            recordURL = url
            let capture = DictationVoiceCapture(id: captureRecovery.pending!.id, engine: engine)
            liveCapture = capture
            voiceSession = LiveVoiceSnapshot(sessionID: capture.id, phase: .preparing,
                sources: [.init(source: .microphone, name: "Microphone")])
            try await capture.start(url: url) { [weak self] snapshot in
                Task { @MainActor in self?.receiveDictationSnapshot(snapshot, attempt: attempt) }
            }
            guard recordingAttempt == attempt else {
                _ = await capture.finish(recognize: false)
                if liveCapture === capture { liveCapture = nil }
                let deliveryProblem = cancelLiveDictation()
                if deliveryProblem == nil { _ = discardRecordingRecovery() }
                else { canRetry = true; status = deliveryProblem! }
                if phase == .cancelling { phase = .idle; onPhaseChange?() }
                return
            }
            recordURL = url; canRetry = false; elapsed = 0; level = 0; peakPower = -160
            phase = .recording
            voiceSession.phase = .listening
            status = captureUsesHoldShortcut ? "Listening… release the shortcut to finish" : "Listening… choose Finish when you are done."
            onPhaseChange?()
            meter = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let capture = self.liveCapture, self.phase == .recording else { return }
                    self.elapsed = capture.elapsed
                    self.peakPower = capture.peak; self.level = capture.isPaused ? 0 : capture.level
                    self.voiceSession.elapsed = self.elapsed
                    if let message = capture.recoveryMessage {
                        self.voiceSession.phase = .reconnecting; self.voiceSession.message = message
                    } else if capture.isPaused { self.voiceSession.phase = .paused }
                    else if self.voiceSession.phase == .reconnecting { self.voiceSession.phase = .listening; self.voiceSession.message = nil }
                    self.isMicrophoneQuiet = self.elapsed >= 6 && self.peakPower <= -55
                    if let problem = capture.problem { self.voiceSession.message = problem; self.stopRecording() }
                    else if self.elapsed >= 300 { self.stopRecording() }
                }
            }
        } catch {
            liveCapture = nil
            if recordingAttempt != attempt {
                let deliveryProblem = cancelLiveDictation()
                if deliveryProblem == nil { _ = discardRecordingRecovery() } else { canRetry = true }
                phase = .idle; voiceSession = LiveVoiceSnapshot(); status = deliveryProblem ?? "Recording cancelled."; onPhaseChange?(); return
            }
            voiceSession.phase = .recoverableFailure
            // Preserve even a partial start when macOS supplied audio before failing.
            if let url = startedAudio, let pending = captureRecovery.pending, pending.capture == nil,
               url.lastPathComponent == pending.audioFilename,
               ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == 0 {
                do { try captureRecovery.clear(pending.id); recordURL = nil }
                catch { report(error.localizedDescription, on: .dictate) }
            }
            fail(error.localizedDescription)
        }
    }

    func stopRecording() {
        guard phase == .recording, let url = recordURL else { return }
        meter?.invalidate(); meter = nil; level = 0
        if let capture = liveCapture {
            phase = .transcribing; voiceSession.phase = .finishing
            status = "Finishing your words…"; onPhaseChange?()
            let attempt = recordingAttempt
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                let (report, checkpoint) = await capture.finish()
                guard self.recordingAttempt == attempt else { return }
                self.liveCapture = nil; self.transcriptionTask = nil
                if let checkpoint { self.voiceSession.segments = LiveVoiceTurns.group(checkpoint.orderedSegments) }
                if Task.isCancelled || self.phase == .cancelling {
                    let deliveryProblem = self.cancelLiveDictation()
                    if deliveryProblem == nil { _ = self.discardRecordingRecovery() } else { self.canRetry = true }
                    self.phase = .idle
                    self.voiceSession.phase = .idle; self.status = deliveryProblem ?? "Recording cancelled."; self.onPhaseChange?(); return
                }
                let recordedPeak = report.tracks.first?.peak ?? 0
                self.peakPower = max(capture.peak, recordedPeak > 0 ? Float(20 * log10(recordedPeak)) : -160)
                self.voiceSession.message = report.failure ?? report.gaps.first
                if let failure = report.failure {
                    self.elapsed = report.seconds; self.canRetry = true
                    self.voiceSession.phase = .recoverableFailure
                    self.fail("Recording stopped. Original audio was kept for retry. \(failure)")
                    return
                }
                self.completeStoppedRecording(url, duration: report.seconds,
                    liveText: checkpoint?.complete == true ? checkpoint?.text : nil)
            }
            return
        }
        completeStoppedRecording(url, duration: elapsed)
    }

    private func completeStoppedRecording(_ url: URL, duration: Double, liveText: String? = nil) {
        // The recorder ran, so a shortcut press that began this attempt can be judged.
        let gesture = recordingAttempt.flatMap { attempt in holdGesture?.attempt == attempt ? holdGesture : nil }
        holdGesture = nil
        guard duration >= CaptureCue.shortestSpeech, peakPower > -55 else {
            if let message = cancelLiveDictation() { canRetry = true; fail(message); return }
            discardRecordingRecovery()
            let reason: CaptureCue.Reason = duration < CaptureCue.shortestSpeech ? .tooShort : .tooQuiet
            endWithoutSpeech(reason, teachesHold: HoldLesson.teaches(gesture, outcome: reason)); return
        }
        transcribe(url, duration: duration, temporary: true, settings: recordingSettings, heldShortcut: gesture != nil, recognizedText: liveText)
        recordingSettings = nil
    }

    private func receiveDictationSnapshot(_ snapshot: LiveVoiceSnapshot, attempt: UUID) {
        guard recordingAttempt == attempt, voiceSession.sessionID == snapshot.sessionID,
              [.requesting, .recording, .transcribing].contains(phase), liveCapture != nil else { return }
        voiceSession = snapshot
        liveDictation?.preview(snapshot.text)
        voiceSession.elapsed = max(elapsed, snapshot.elapsed)
        if phase == .transcribing { voiceSession.phase = .finishing }
        else if phase == .recording && voiceSession.phase == .recoverableFailure { voiceSession.phase = .listening }
        else if liveCapture?.isPaused == true {
            voiceSession.phase = .paused
            voiceSession.sources = voiceSession.sources.map { var source = $0; source.health = .paused; source.level = 0; return source }
        }
        else if let message = liveCapture?.recoveryMessage {
            voiceSession.phase = .reconnecting; voiceSession.message = message
        }
    }

    func pause() async {
        guard phase == .recording, let capture = liveCapture, !capture.isPaused else { return }
        do {
            try await capture.pause()
            guard liveCapture === capture, phase == .recording else { return }
            voiceSession.phase = .paused; level = 0
        }
        catch { report(error.localizedDescription, on: .dictate) }
    }

    func resume() async {
        guard phase == .recording, let capture = liveCapture, capture.isPaused else { return }
        do {
            try await capture.resume()
            guard liveCapture === capture, phase == .recording else { return }
            voiceSession.phase = .listening
        }
        catch { report(error.localizedDescription, on: .dictate) }
    }

    func cancelRecording() {
        if phase == .requesting {
            if liveCapture != nil {
                shortcutRequest.cancel(); recordingAttempt = nil; phase = .cancelling
                liveCapture?.requestStop(); status = "Cancelling…"; onPhaseChange?(); return
            }
            let deliveryProblem = cancelLiveDictation()
            shortcutRequest.cancel(); recordingAttempt = nil; phase = .idle; status = deliveryProblem ?? "Capture cancelled. Use the shortcut again when microphone permission is ready."; onPhaseChange?(); return
        }
        guard phase == .recording else { return }
        if let capture = liveCapture {
            shortcutRequest.cancel(); recordingAttempt = nil; holdGesture = nil
            meter?.invalidate(); meter = nil; capture.requestStop()
            phase = .cancelling; voiceSession.phase = .finishing; onPhaseChange?()
            Task { [weak self] in
                _ = await capture.finish(recognize: false)
                guard let self, self.liveCapture === capture else { return }
                self.liveCapture = nil
                let deliveryProblem = self.cancelLiveDictation()
                let discarded = deliveryProblem == nil && self.discardRecordingRecovery()
                if deliveryProblem != nil { self.canRetry = true }
                self.phase = .idle; self.level = 0; self.voiceSession = LiveVoiceSnapshot()
                self.status = deliveryProblem ?? (discarded ? "Recording discarded." : "Recording stopped. Recovery files are kept for review.")
                self.onPhaseChange?()
            }
            return
        }
        shortcutRequest.cancel()
        recordingAttempt = nil; holdGesture = nil
        meter?.invalidate(); meter = nil
        let deliveryProblem = cancelLiveDictation()
        let discarded = deliveryProblem == nil && discardRecordingRecovery()
        if deliveryProblem != nil { canRetry = true }
        phase = .idle; level = 0
        status = deliveryProblem ?? (discarded ? "Recording discarded." : "Recording stopped. Recovery files could not be discarded; open Workbench to review them.")
        onPhaseChange?()
    }

    func cancelCurrentCapture() {
        if [.requesting, .recording].contains(phase) { cancelRecording(); return }
        guard [.transcribing, .cleaning].contains(phase), transcriptionTask != nil else { return }
        // Keep the recording gate closed until the selected engine unwinds. A
        // slow model must never finish into a newer capture after cancellation.
        shortcutRequest.cancel()
        liveCapture?.cancelRecognition()
        transcriptionTask?.cancel()
        phase = .cancelling; status = "Cancelling…"; onPhaseChange?()
    }

    private func cancelLiveDictation() -> String? {
        let owned = liveDictation; liveDictation = nil
        return owned?.cancel()
    }

    func importAudio() {
        guard !meetings.isBusy else { report("Finish the meeting recording or transcription first.", on: .dictate); return }
        guard phase == .idle, ready else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        panel.message = "Choose an audio file up to 30 minutes. Your selected speech engine will transcribe it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importAudio(url)
    }
    func importAudio(_ url: URL) {
        guard !meetings.isBusy else { report("Finish the meeting recording or transcription first.", on: .dictate); return }
        guard phase == .idle, ready else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration > 0, duration <= 1800 else { throw VoiceError.message("Choose an audio file between 1 second and 30 minutes long.") }
            // Importing the current recovery is a retry, not a new capture whose
            // archive operation would move the selected URL out from under us.
            if recordURL?.standardizedFileURL == url.standardizedFileURL {
                retryTranscription(); return
            }
            guard admitNewCapture() else { return }
            destination = nil; transcribe(url, duration: duration, temporary: false)
        } catch { fail("Could not read this audio file. \(error.localizedDescription)") }
    }
    func retryTranscription() {
        guard phase == .idle else { return }
        if captureRecovery.pending?.capture != nil {
            // A failed request is over. Never replay a previous app target or
            // Shortcuts continuation when the user only asked to retry saving.
            if savePendingCapture() { status = "Capture saved. Copy or paste the text when you’re ready." }
            return
        }
        guard let url = recordURL else { return }
        guard ready else { captureFailure = "Open Models to prepare speech, then retry transcription. The original audio is kept."; onPhaseChange?(); return }
        destination = nil
        transcribe(url, duration: elapsed, temporary: true)
    }

    private func captureSettings() -> CaptureSettings {
        rememberedCorrection = nil
        let settings = CaptureSettings(preferences: preferences, cleanup: CleanupConfigurationStore().snapshot(), replacements: replacements)
        captureOutputModeLabel = settings.outputLabel
        captureShortcutInstruction = captureUsesHoldShortcut
            ? "Release \(settings.preferences.dictationShortcut.label) to finish"
            : (settings.preferences.dictationShortcut.enabled ? "Stop or \(settings.preferences.dictationShortcut.label) to finish" : "Use Stop to finish")
        return settings
    }

    private func transcribe(_ url: URL, duration: Double, temporary: Bool, settings: CaptureSettings? = nil, heldShortcut: Bool = false, recognizedText: String? = nil) {
        let settings = settings ?? captureSettings()
        let shortcutID = shortcutRequest.id
        let invocation = UUID(); transcriptionID = invocation
        clipboardReceipt.clear()
        captureFailure = nil; dismissCaptureCue()
        previewingPanel = false
        captureProcessingLabel = "Preparing transcription…"
        phase = .transcribing; status = "Turning speech into text…"; attention = nil; canRetry = false; onPhaseChange?()
        transcriptionTask = Task {
            defer {
                if transcriptionID == invocation { transcriptionTask = nil; transcriptionID = nil }
            }
            do {
                let configuration = await engine.configuration()
                try Task.checkCancellation()
                guard transcriptionID == invocation else { throw CancellationError() }
                captureProcessingLabel = configuration.provider == .parakeet
                    ? "Parakeet · on this Mac" : "\(configuration.model) · local server"
                let raw: String
                if let recognizedText { raw = recognizedText }
                else { raw = try await engine.transcribe(url) }
                try Task.checkCancellation()
                guard transcriptionID == invocation else { throw CancellationError() }
                if let shortcutID, shortcutRequest.id != shortcutID { throw CancellationError() }
                phase = .cleaning; status = "Tidying your words…"; onPhaseChange?()
                let cleaned = await cleanupEngine.clean(raw, style: settings.preferences.cleanup, configuration: settings.cleanup)
                try Task.checkCancellation()
                guard transcriptionID == invocation else { throw CancellationError() }
                if let shortcutID, shortcutRequest.id != shortcutID { throw CancellationError() }
                let result = TextRules.apply(cleaned.text, replacements: settings.replacements)
                guard !result.isEmpty else {
                    // Silence, noise or a sound that is not speech came back as
                    // no words. Our own recording stays for Retry on Dictate.
                    if let message = cancelLiveDictation() { canRetry = temporary && shortcutID == nil; fail(message); return }
                    canRetry = temporary && shortcutID == nil
                    endWithoutSpeech(.nothingRecognised(keptAudio: temporary)); return
                }
                guard let captureID = try commitRecognizedCapture(raw: raw, text: result, seconds: duration,
                    method: cleaned.method, ownedAudio: temporary ? url : nil, invocation: invocation) else { return }
                // A hold that produced words shows the gesture is known: never teach it.
                if heldShortcut { coach.tips.retire(HoldLesson.tip) }
                accessibilityGranted = AXIsProcessTrusted()
                if let shortcutID {
                    status = "Transcript returned to Shortcuts."
                    shortcutRequest.finish(id: shortcutID, result: .success(result))
                } else {
                    phase = .delivering; status = "Delivering text…"; onPhaseChange?()
                    var delivery = settings.preferences.delivery
                    // Without Accessibility approval the text is copied, so there is no paste to wait for.
                    if liveDictation == nil, delivery == .paste, destination != nil, accessibilityGranted, shouldDeferDelivery?() == true {
                        waitingForDrawing = true
                        captureProcessingLabel = "Finish drawing to paste, or copy now."
                        status = "Text ready. Finish drawing to return to your Mac text field."
                        onPhaseChange?()
                        defer { waitingForDrawing = false }
                        if try await drawingDelivery.wait() == .copy { delivery = .clipboard }
                    }
                    try Task.checkCancellation()
                    guard transcriptionID == invocation else { return }
                    let outcome: TextDelivery.Outcome
                    if let owned = liveDictation {
                        outcome = owned.finish(result, restoreClipboard: settings.preferences.restoreClipboard)
                        liveDictation = nil
                        // History already owns the result. Only confirmed field delivery
                        // releases its original; uncertainty keeps it in Saved recordings.
                        if let pending = captureRecovery.pending, pending.id == captureID {
                            do {
                                if outcome.wasPasted { try captureRecovery.clear(captureID) }
                                else { _ = try captureRecovery.keepAudioForLater(committedCapture: captureID) }
                                recordURL = nil; canRetry = false
                            } catch {
                                canRetry = true
                                report("The transcript is saved, but its recording could not be finalized. Recovery files are kept. \(error.localizedDescription)", on: .dictate)
                            }
                        }
                    } else {
                        outcome = await TextDelivery.deliver(result, target: destination, mode: delivery, restoreClipboard: settings.preferences.restoreClipboard, fit: insertionContext)
                    }
                    guard transcriptionID == invocation else { return }
                    status = outcome.message
                    clipboardReceipt.record(outcome: outcome, wordCount: TextRules.wordCount(result))
                    undelivered.note(outcome, text: result, from: .transcript(captureID), in: deliveryRecords)
                }
                phase = .idle; voiceSession.phase = .completed; onPhaseChange?()
            } catch {
                guard transcriptionID == invocation else { return }
                if Task.isCancelled || error is CancellationError {
                    if let shortcutID { shortcutRequest.finish(id: shortcutID, result: .failure(error)) }
                    let deliveryProblem = cancelLiveDictation()
                    let discarded = deliveryProblem == nil && (!temporary || discardRecordingRecovery())
                    if deliveryProblem != nil { canRetry = temporary }
                    phase = .idle
                    status = deliveryProblem ?? (discarded ? "Transcription cancelled. No text was added." : "Transcription cancelled. Recovery files are still kept; open Workbench to review them.")
                    onPhaseChange?(); return
                }
                canRetry = temporary && shortcutID == nil; fail("Transcription failed. \(error.localizedDescription)")
            }
        }
    }

    private func admitNewCapture() -> Bool {
        guard captureRecovery.hasRecovery else { return true }
        if captureRecovery.canKeepAudioForLater {
            do {
                try captureRecovery.keepAudioForLater()
                recordURL = nil; canRetry = false; captureFailure = nil; attention = nil
                status = "Previous audio kept in Saved recordings."
                onPhaseChange?(); return true
            } catch {
                let message = "Could not keep the previous recording safely. Its recovery files are unchanged. \(error.localizedDescription)"
                captureFailure = message; report(message, on: .dictate); status = message; onPhaseChange?(); return false
            }
        }
        let message = captureRecovery.problem?.localizedDescription ?? "A previous capture is kept. Use \(retryCaptureLabel) before starting another capture."
        captureFailure = message; report(message, on: .dictate); status = message; onPhaseChange?(); return false
    }

    /// No asynchronous boundary occurs between the generation check and commit.
    /// The ID survives retries, so writing again cannot create a second capture.
    /// Returns the saved capture's ID, the record its delivery names, or nil.
    private func commitRecognizedCapture(raw: String, text: String, seconds: Double, method: String,
                                         ownedAudio: URL?, invocation: UUID) throws -> UUID? {
        try Task.checkCancellation()
        guard transcriptionID == invocation else { throw CancellationError() }
        let id = ownedAudio != nil ? (captureRecovery.pending?.id ?? UUID()) : UUID()
        let capture = Transcript(id: id, text: text, seconds: seconds, rawText: raw, cleanupMethod: method)
        let record = CaptureRecoveryRecord(id: id, audioFilename: ownedAudio?.lastPathComponent, capture: capture)
        _ = try record.validated()
        guard captureRecovery.pending == nil || captureRecovery.pending?.id == id else { throw CaptureRecoveryError.pending }
        if let ownedAudio {
            guard try captureRecovery.audioURL(for: record)?.standardizedFileURL == ownedAudio.standardizedFileURL else { throw CaptureRecoveryError.invalid }
        }
        rawTranscript = raw; transcript = text; cleanupMethod = method
        quietCapturesInARow = 0
        // retain keeps the result in memory even when the independent journal fails.
        do { try captureRecovery.retain(record) }
        catch {
            guard captureRecovery.pending?.capture?.id == capture.id else { throw error }
            // The result is in memory; report any journal failure alongside the state write below.
        }
        return savePendingCapture() ? capture.id : nil
    }

    @discardableResult private func savePendingCapture() -> Bool {
        guard loaded, let record = captureRecovery.pending, let capture = record.capture else { return false }
        var journalError: Error?
        do { try captureRecovery.retain(record) } catch { journalError = error }
        let nextHistory = TranscriptHistory.adding(capture, to: history)
        let state = session(draft: transcript, history: nextHistory, replacements: replacements)
        do {
            if let captureStateWriter { try captureStateWriter(state) } else { try store.save(state) }
        } catch {
            canRetry = true
            let recovery = journalError == nil ? "The recovery copy is kept." : "Recovery text could not be written either. Copy or Save text before quitting. Your existing audio files are kept."
            let delivery = liveDictation?.attempted == true ? "Live text may already be in your app; no final insertion was attempted." : "No text was sent."
            fail("Could not save this capture. \(recovery) Use Retry saving. \(delivery) \(error.localizedDescription)")
            captureFailure = self.error; onPhaseChange?(); return false
        }
        history = nextHistory
        if liveDictation != nil {
            // Live preview can already exist in the field. Keep its original until
            // final replacement is verified; an uncertain insertion retains audio.
            canRetry = false; captureFailure = nil; attention = nil; onPhaseChange?(); return true
        }
        do { try captureRecovery.clear(record.id) }
        catch {
            canRetry = true
            let delivery = liveDictation?.attempted == true ? "Live text may already be in your app; no final insertion was attempted." : "No text was sent."
            fail("Text saved, but capture recovery could not be cleared. Use Retry saving; the saved capture will not be duplicated. \(delivery) \(error.localizedDescription)")
            captureFailure = self.error; onPhaseChange?(); return false
        }
        recordURL = nil; canRetry = false; captureFailure = nil; attention = nil
        onPhaseChange?(); return true
    }

    private func restoreCaptureRecovery() {
        do {
            guard let record = try captureRecovery.load() else { return }
            var preservedSavedDraft = false
            if let capture = record.capture {
                // A crash after commit but before journal cleanup must not send
                // text again or replace a newer draft on the next launch.
                if history.contains(where: { $0.id == capture.id && $0.text == capture.text && $0.rawText == capture.rawText }) {
                    try captureRecovery.clear(record.id); return
                }
                let recoveredOriginal = capture.rawText ?? capture.text
                // Ordinary draft saves can succeed after the capture commit
                // failed, without adding its history ID. Keep that saved draft;
                // the immutable recovered capture can still be saved separately.
                preservedSavedDraft = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (transcript != capture.text || rawTranscript != recoveredOriginal)
                if !preservedSavedDraft {
                    rawTranscript = recoveredOriginal; transcript = capture.text
                    cleanupMethod = capture.cleanupMethod ?? "Original"
                }
            }
            recordURL = try captureRecovery.audioURL(for: record, requireExists: record.capture == nil)
            if let recordURL, let file = try? AVAudioFile(forReading: recordURL) {
                elapsed = Double(file.length) / file.processingFormat.sampleRate
            }
            canRetry = true
            let message = record.capture == nil ? "A recording was recovered. Use Retry transcription."
                : (preservedSavedDraft ? "An unsaved capture was recovered. Your saved draft is unchanged. Retry saving adds the capture to History without pasting."
                   : "An unsaved capture was recovered. Use Retry saving; text will not be pasted automatically.")
            captureFailure = message; status = message
        } catch { report(error.localizedDescription, on: .dictate); captureFailure = self.error; status = "Capture recovery needs attention." }
    }

    @discardableResult private func discardRecordingRecovery() -> Bool {
        guard let record = captureRecovery.pending, record.capture == nil else { return !captureRecovery.hasRecovery }
        do { try captureRecovery.clear(record.id); recordURL = nil; canRetry = false; return true }
        catch { report(error.localizedDescription, on: .dictate); captureFailure = self.error; return false }
    }

    /// Called only after the normal Dictate view's explicit confirmation. The
    /// draft stays open; no imported URL can enter the recovery store's deletion.
    func discardCaptureRecovery() {
        guard canDiscardCaptureRecovery, let record = captureRecovery.pending else { return }
        do {
            try captureRecovery.clear(record.id)
            recordURL = nil; canRetry = false; captureFailure = nil; attention = nil
            status = "Recovery discarded. Your current draft is kept."; onPhaseChange?()
        } catch { report(error.localizedDescription, on: .dictate); captureFailure = self.error; onPhaseChange?() }
    }
    func showCaptureRecoveryFiles() {
        if !NSWorkspace.shared.open(captureRecovery.directory) { report("The CaptureRecovery folder could not be opened.", on: .dictate) }
    }
    func showSavedRecordings() {
        if !NSWorkspace.shared.open(captureRecovery.savedRecordingsDirectory) { report("Saved recordings could not be opened.", on: .dictate) }
    }

    func copyTranscript() {
        copyTextWithReceipt(transcript, of: .draft(revision: draftRevision))
    }
    /// History and the draft as they are now: the records an undelivered result names.
    private var deliveryRecords: DeliveryRecords {
        DeliveryRecords(history: history, draft: (text: transcript, revision: draftRevision))
    }
    /// What the shelf shows of the undelivered result, judged against those records now.
    var unresolvedDelivery: UnresolvedDelivery? { undelivered.shown(in: deliveryRecords) }
    private func copyTextWithReceipt(_ text: String, of reference: UnresolvedDelivery.Reference) {
        guard !text.isEmpty else { return }
        captureFailure = nil; dismissCaptureCue()
        let count = TextDelivery.copy(text)
        let outcome = TextDelivery.Outcome(message: count == nil ? "Could not copy the transcript." : TextDelivery.copiedMessage, clipboardChangeCount: count, wasPasted: false, destinationName: nil, failure: count == nil ? .copyFailed : nil)
        status = outcome.message
        clipboardReceipt.record(outcome: outcome, wordCount: TextRules.wordCount(text))
        // Copying the same words from anywhere resolves an undelivered result.
        undelivered.note(outcome, text: text, from: reference, in: deliveryRecords)
    }
    /// Copy again, for a result whose copy failed or was never pasted: the
    /// words its record holds now, never whatever the draft became.
    func copyUnresolvedDelivery() {
        guard let entry = undelivered.entry, let words = undelivered.wordsToCopy(in: deliveryRecords) else { return }
        copyTextWithReceipt(words, of: entry.reference)
    }
    /// The person's own choice to set it aside. Hiding a notice never does this.
    func dismissUnresolvedDelivery() { undelivered.dismiss() }
    func reviewUnresolvedDelivery() {
        guard let entry = unresolvedDelivery else { return }
        switch entry.reference {
        case .transcript(let id): openHistory(HistoryDoor(transcript: id))
        case .draft: page = "dictate"
        }
    }
    func showLibrary() { page = "library"; onShowEditor?("library"); libraryFocusToken = UUID() }
    /// Every door opens History on All, even when History is already showing.
    /// Dictate's own option asks for Transcripts, and Hand off for its task.
    func openHistory(_ door: HistoryDoor = HistoryDoor()) { historyDoor = door; page = "history" }
    /// Records the first dictation the moment History holds a transcript,
    /// whichever door made it (the toolbar, a shortcut, the Dictate page or a
    /// meeting), so removing transcripts later never brings Home's guide back (#15).
    private func recordFirstDictation() {
        if let next = HomeJourney(transcripts: history.count, guide: preferences.firstDictationGuide).guideToSave {
            preferences.firstDictationGuide = next
        }
    }
    func savePrompt(_ text: String) { guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; showLibrary(); library.newPrompt(text) }
    func copyCapture(_ item: Transcript) { copyTextWithReceipt(item.text, of: .transcript(item.id)) }
    func showPanelPreview() {
        guard phase == .idle else { return }
        captureUsesHoldShortcut = false
        _ = captureSettings()
        previewingPanel = true; onPhaseChange?()
    }
    func closePanelPreview() { previewingPanel = false; onPhaseChange?() }
    func cleanCurrentDraft(completion: ((String) -> Void)? = nil) {
        guard phase == .idle, !transcript.isEmpty else { return }
        let original = transcript
        let revision = draftRevision
        let settings = captureSettings()
        let invocation = UUID(); transcriptionID = invocation
        clipboardReceipt.dismissHUD(); captureFailure = nil; dismissCaptureCue()
        previewingPanel = false; destination = nil
        captureProcessingLabel = "Text cleanup · on this Mac"
        phase = .cleaning; status = "Tidying your words…"; attention = nil
        transcriptionTask = Task {
            defer {
                if transcriptionID == invocation {
                    transcriptionTask = nil; transcriptionID = nil
                    phase = .idle; onPhaseChange?()
                }
            }
            let cleaned = await cleanupEngine.clean(original, style: settings.preferences.cleanup, configuration: settings.cleanup)
            guard transcriptionID == invocation else { return }
            guard !Task.isCancelled else {
                status = "Cleanup cancelled. Your draft was kept."; completion?(status); return
            }
            guard revision == draftRevision else {
                status = "Your draft changed during cleanup. Your latest text was kept."; completion?(status); return
            }
            rawTranscript = original; transcript = TextRules.apply(cleaned.text, replacements: settings.replacements)
            cleanupMethod = cleaned.method; status = cleaned.method + " · original retained"; persist()
            completion?(status)
        }
        onPhaseChange?()
    }
    func openTranscript(_ item: Transcript) {
        // The wait is said on History, where Open was clicked.
        let wait = "Finish the current dictation or processing before replacing its draft."
        guard phase == .idle else { report(wait, on: .history); return }
        // History's notice has no Dismiss, so an Open that goes ahead takes its earlier wait away.
        if attention == Attention(message: wait, page: .history) { attention = nil }
        page = "dictate"
        if (!transcript.isEmpty || !rawTranscript.isEmpty) && (transcript != item.text || rawTranscript != (item.rawText ?? item.text)) {
            pendingTranscript = item
            return
        }
        applyHistoryTranscript(item)
    }
    func keepCurrentTranscript() { pendingTranscript = nil }
    func replaceDraftWithTranscript() {
        guard phase == .idle, let item = pendingTranscript else { return }
        applyHistoryTranscript(item)
    }
    private func applyHistoryTranscript(_ item: Transcript) {
        pendingTranscript = nil
        rememberedCorrection = nil
        rawTranscript = item.rawText ?? item.text; cleanupMethod = item.cleanupMethod ?? "Original"
        transcript = item.text; page = "dictate"; persist()
    }
    @discardableResult func useOriginal() -> String {
        rememberedCorrection = nil; transcript = rawTranscript; cleanupMethod = "Original restored"
        status = "Original transcript restored."; persist()
        return status
    }
    /// Set up automatic paste: the first click may show macOS's request; later
    /// clicks open Privacy & Security › Accessibility, so none is a dead end.
    func requestAccessibility() {
        var asked = preferences.accessibilityRequested
        let step = AccessibilitySetup.live.run(asked: &asked) { [weak self] in
            self?.report("System Settings could not be opened. Open Privacy & Security › Accessibility and allow Workbench there.", on: .dictate)
        }
        if asked != preferences.accessibilityRequested { preferences.accessibilityRequested = asked }
        accessibilityGranted = step == .approved || AXIsProcessTrusted()
    }
    func refreshPermissions() { accessibilityGranted = AXIsProcessTrusted() }
    static func microphoneMessage(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Microphone access is available."
        case .notDetermined: return "Microphone access has not been granted. Start recording when you want to request access; saved text remains available."
        case .denied: return "Microphone access is off. Open System Settings › Privacy & Security › Microphone to review access. Saved text remains available."
        case .restricted: return "macOS reports that microphone access is restricted. Your saved text remains available."
        @unknown default: return "Microphone access could not be determined. Your saved text remains available."
        }
    }
    var canOpenMicrophoneSettings: Bool { microphoneFailure == .denied }
    var idleMicrophoneTitle: String? {
        switch microphoneFailure {
        case .denied: return "Microphone access is off"
        case .restricted: return "Microphone access is restricted"
        default: return nil
        }
    }
    func refreshMicrophoneAuthorization() {
        microphoneAuthorization = readMicrophoneAuthorization()
        guard microphoneFailure != nil else { return }
        if microphoneAuthorization == .authorized {
            microphoneFailure = nil; dismissCaptureFailure()
            if attention?.page == .dictate { dismissError() }
        }
    }
    func openMicrophoneSettings() {
        guard openMicrophonePrivacy() else {
            let message = "System Settings could not be opened. Open it manually and choose Privacy & Security › Microphone."
            captureFailure = message; report(message, on: .dictate); return
        }
        dismissCaptureFailure()
    }
    func exportTranscript() -> String? {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { try transcript.write(to: url, atomically: true, encoding: .utf8); status = "Transcript saved."; return status }
        catch { fail(error.localizedDescription) }
        return nil
    }
    /// Nil is a cancelled Save panel; the review can acknowledge only an actual result.
    @discardableResult func exportCapture(_ item: Transcript, version: TranscriptExportVersion) -> Bool? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = TranscriptExport.defaultFilename
        panel.title = "Export saved transcript"
        panel.message = version == .original
            ? "Save the original recognised wording as a UTF-8 text file."
            : "Save the cleaned transcript as a UTF-8 text file."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try TranscriptExport.write(item, version: version, to: url)
            attention = nil
            status = "\(version.rawValue) saved to \(url.lastPathComponent)."
            return true
        } catch {
            report("Could not save this transcript. \(error.localizedDescription)", on: .history)
            return false
        }
    }

    // MARK: Mac voices

    /// Raises a problem with the page that shows it in full (#134): the menu-bar panel's door
    /// opens that page, so it is chosen here, where the problem is known, never from the words.
    func report(_ message: String, on page: Attention.Page) {
        attention = Attention(message: message, page: page)
    }
    /// Dismiss the error banner without changing saved work.
    func dismissError() {
        attention = nil
    }

    // Dictionary saves through the same validation and phrase identity as Remember
    // correction. Add never saves a phrase twice, and a new output for a saved
    // phrase needs the explicit Update. Neither rewrites the current draft.
    func addReplacement(heard: String, written: String) throws {
        let change = try CorrectionRule.change(heard: heard, written: written, replacements: replacements)
        guard !change.isAlreadySaved else { return }
        guard change.isNew else {
            throw VoiceError.message("“\(change.rule.heard)” is already in your dictionary as “\(change.previousRule?.written ?? "")”. Choose Update to change it.")
        }
        rememberedCorrection = nil
        replacements = change.updatedRules; persist()
        status = "Added “\(change.rule.heard)” to your dictionary."
    }
    /// Keeps the saved rule's identity and place, so unrelated rules keep their order.
    func updateReplacement(heard: String, written: String) throws {
        let change = try CorrectionRule.change(heard: heard, written: written, replacements: replacements)
        guard !change.isAlreadySaved else { return }
        guard change.updatesExisting else {
            throw VoiceError.message("“\(change.rule.heard)” is not in your dictionary yet. Choose Add to save it.")
        }
        rememberedCorrection = nil
        replacements = change.updatedRules; persist()
        status = "Updated “\(change.rule.heard)”. Future dictations write “\(change.rule.written)”."
    }
    /// Resolves one phrase's conflicting rules with the chosen output. Only that
    /// phrase's other rules are removed.
    func resolveReplacementConflict(keeping chosen: Replacement) throws {
        let resolved = try CorrectionRule.resolvingConflict(keeping: chosen, in: replacements)
        rememberedCorrection = nil
        replacements = resolved; persist()
        status = "Kept “\(chosen.written)”. The other rules for that phrase were removed."
    }
    func removeReplacement(_ item: Replacement) { rememberedCorrection = nil; replacements.removeAll { $0.id == item.id }; persist() }

    // Save the complete prospective session before publishing success. A failed
    // write leaves the draft, dictionary and receipt unchanged for a safe retry.
    func rememberCorrection(heard: String, written: String, expectedDraft: String) throws {
        guard loaded else { throw VoiceError.message("Session saving is unavailable. Reopen Workbench before remembering a correction.") }
        guard phase == .idle else { throw VoiceError.message("Finish the current dictation before remembering a correction.") }
        guard transcript == expectedDraft else { throw VoiceError.message("The draft changed. Close this sheet and review the new draft first.") }
        let proposal = try CorrectionRule.propose(heard: heard, written: written, draft: transcript, replacements: replacements)
        guard !proposal.isAlreadyRemembered || proposal.changesDraft else { return }
        let beforeRules = replacements
        try store.save(session(draft: proposal.previewText, history: history, replacements: proposal.updatedRules))
        persistWork?.cancel()
        replacements = proposal.updatedRules
        if proposal.changesDraft { transcript = proposal.previewText }
        rememberedCorrection = RememberedCorrection(written: proposal.rule.written, beforeRules: beforeRules,
            afterRules: replacements, beforeDraft: expectedDraft, afterDraft: transcript, appliedRevision: draftRevision)
        status = proposal.changesDraft ? "Correction saved. This draft is updated; copy it when you’re ready." : "Correction saved for future dictations."
    }

    func undoRememberedCorrection() throws {
        guard let receipt = rememberedCorrection else { return }
        guard loaded, phase == .idle else { throw VoiceError.message("Finish the current dictation before undoing the correction.") }
        guard replacements == receipt.afterRules else { throw VoiceError.message("Your dictionary has changed. Review the correction in Dictionary instead.") }
        // A revision check also protects edits that return to the same string.
        let restoreDraft = draftRevision == receipt.appliedRevision && transcript == receipt.afterDraft
        let draft = restoreDraft ? receipt.beforeDraft : transcript
        try store.save(session(draft: draft, history: history, replacements: receipt.beforeRules))
        persistWork?.cancel()
        replacements = receipt.beforeRules
        if transcript != draft { transcript = draft }
        rememberedCorrection = nil
        status = restoreDraft ? "Correction undone." : "Dictionary change undone. Your newer draft edits are kept."
    }
    func dismissRememberedCorrection() { rememberedCorrection = nil }
    func removeTranscript(_ item: Transcript, includingRecording: Bool = false) {
        guard loaded, history.contains(where: { $0.id == item.id }) else { return }
        guard includingRecording || !meetings.hasRecording(for: item.id) else {
            report("This transcript has a saved recording. Choose Remove again to review removing both.", on: .history)
            return
        }
        let next = history.filter { $0.id != item.id }
        let commit = {
            try self.store.save(self.session(draft: self.transcript, history: next, replacements: self.replacements))
            self.persistWork?.cancel()
            self.history = next
            self.meetings.transcriptRemoved(item.id)
            // Removing the transcript is the person's choice: nothing is left to deliver.
            self.undelivered.transcriptRemoved(item.id)
        }
        do {
            if includingRecording {
                if let issue = try meetings.removeCompletedRecording(for: item.id, commit: commit) { report(issue, on: .history) }
                else { attention = nil; status = "Transcript and recording removed." }
            } else {
                try commit()
                status = "Transcript removed."
            }
            // Named selections retain the missing reference until the person
            // deliberately removes it, so an old selection cannot silently shrink.
        } catch { report("Could not finish removing the transcript. " + error.localizedDescription, on: .history) }
    }
    func retainMeetingTranscript(_ capture: Transcript, purpose: String) throws {
        guard loaded else { throw VoiceError.message("The transcript library is not ready.") }
        // A failed final meeting-journal write can follow a successful History
        // commit. That retry may not replace later edits or their saved metadata.
        if try savedMeetingTranscript(capture.id) != nil { return }
        let next = TranscriptHistory.adding(capture, to: history)
        // Save metadata first: if history saving fails the meeting's durable
        // journal retains this same UUID for a safe retry.
        var metadata = historyLibrary.metadata(for: capture.id)
        metadata.purpose = purpose == "call" ? .call : .meeting
        metadata.captureNotes = meetings.pendingTranscriptNotes
        historyLibrary.setMetadata(metadata, for: capture.id)
        if let error = historyLibrary.error { throw VoiceError.message(error) }
        try store.save(session(draft: transcript, history: next, replacements: replacements))
        history = next
        status = "Meeting saved in History."
        onPhaseChange?()
    }
    func savedMeetingTranscript(_ id: UUID) throws -> (transcript: Transcript, notes: [String])? {
        guard let saved = try store.load().history.first(where: { $0.id == id }) else { return nil }
        let metadata = try historyLibrary.store.load().transcripts.first { $0.id == id }?.metadata
        return (saved, metadata?.captureNotes ?? [])
    }
    func selectedHandoffSources(references: Set<WorkbenchItemReference>? = nil) throws -> [HandoffSourceSnapshot] {
        try Self.handoffSources(selected: references ?? historyLibrary.selected, history: history,
                                library: historyLibrary, additional: resolveAdditionalHandoffItems)
    }
    /// Frozen sources for a selection: transcripts from `history` with their
    /// details, and other kinds (Snaps in the app) through `additional`.
    static func handoffSources(selected: Set<WorkbenchItemReference>, history: [Transcript], library historyLibrary: WorkbenchHistoryModel,
                               additional resolveAdditionalHandoffItems: ((Set<WorkbenchItemReference>) throws -> [HandoffSourceSnapshot])?) throws -> [HandoffSourceSnapshot] {
        let ids = Set(selected.filter { $0.kind == .transcript }.map(\.id))
        let items = history.filter { ids.contains($0.id) }
        guard items.count == ids.count else {
            throw VoiceError.message("This selection includes a removed transcript. Remove its missing reference before starting a task.")
        }
        var result = items.map { item in
            let metadata = historyLibrary.metadata(for: item.id)
            let names = [metadata.person, metadata.company].filter { !$0.isEmpty }
            let title = metadata.purpose.title + (names.isEmpty ? "" : " · " + names.joined(separator: " · "))
                + " · " + item.date.formatted(date: .abbreviated, time: .shortened)
            return HandoffSourceSnapshot(reference: WorkbenchItemReference(kind: .transcript, id: item.id),
                title: title, capturedAt: item.date, text: item.text, originalText: item.rawText ?? item.text,
                role: metadata.purpose == .prompt ? .instructions : .reference, captureNotes: metadata.captureNotes,
                seconds: item.seconds)
        }
        let additional = Set(selected.filter { $0.kind != .transcript })
        if !additional.isEmpty {
            guard let resolveAdditionalHandoffItems else { throw VoiceError.message("The selected Snap library is unavailable.") }
            result += try resolveAdditionalHandoffItems(additional)
        }
        guard Set(result.map(\.reference)) == selected else { throw VoiceError.message("Some selected items are missing. Review the selection before starting.") }
        return result
    }
    func fail(_ text: String) {
        dismissCaptureCue()
        if phase != .idle { captureFailure = text }
        if let id = shortcutRequest.id { shortcutRequest.finish(id: id, result: .failure(VoiceError.message(text))) }
        let message = liveDictation?.attempted == true ? text + " Live text may remain in your app. Review it before copying the kept result." : text
        report(message, on: .dictate); phase = .idle; status = "Needs attention"; onPhaseChange?()
    }
    /// A dictation that ended without words (#156). Routine outcomes are not
    /// failures: no recovery panel and no error, just a cue in place of the
    /// recording controls that goes by itself, the same words for VoiceOver,
    /// and any recording of our own kept for Retry on the Dictate page.
    /// Failures (permission, microphone, engine or provider, saving and
    /// recovered recordings) keep going through fail() and the explicit panel.
    @Published private(set) var captureCue: CaptureCue?
    private var captureCueClock: CaptureCueClock?
    private var captureCueExpiry: Task<Void, Never>?
    var announceForAccessibility: (String) -> Void = { CaptureCueAnnouncement.post($0) }
    /// Silent captures in a row. A second is more likely a muted or wrong
    /// microphone, or a closed lid, than a pause, so it gets the explicit panel
    /// that says where to look instead of another brief cue.
    private var quietCapturesInARow = 0
    func endWithoutSpeech(_ reason: CaptureCue.Reason, teachesHold: Bool = false) {
        if case .tooQuiet = reason { quietCapturesInARow += 1 } else { quietCapturesInARow = 0 }
        if quietCapturesInARow >= 2 {
            quietCapturesInARow = 0
            fail("No speech heard twice in a row. Check the input in System Settings › Sound, and open the lid of a MacBook.")
            return
        }
        if let id = shortcutRequest.id {
            // A Shortcuts run gets its reply; a floating cue would only flash for automation.
            shortcutRequest.finish(id: id, result: .failure(VoiceError.message(CaptureCue.message + ".")))
            captureFailure = nil; phase = .idle; status = CaptureCue(reason: reason).status; onPhaseChange?()
            return
        }
        captureFailure = nil
        phase = .idle
        // A press of the Dictate shortcut in Hold let go too soon learns the
        // gesture once, in place of this attempt's cue (#134 T5). A lesson
        // already taught, or one no host can show, leaves the cue; so does a
        // card the host drops, so the attempt never ends with neither.
        if teachesHold, coach.request(HoldLesson.card(shortcut: preferences.dictationShortcut.label),
                                      otherwise: { [weak self] in self?.showDroppedLessonCue(reason) }) {
            status = "No speech heard. " + HoldLesson.title(shortcut: preferences.dictationShortcut.label)
            onPhaseChange?()
            return
        }
        showCaptureCue(reason)
    }
    /// A Snap & Talk narration that heard nothing gets the same brief cue at the toolbar's
    /// place, so a quiet take never looks saved. Dictation's own work and failures come first.
    func showNarrationCue() {
        guard phase == .idle, captureFailure == nil else { return }
        showCaptureCue(.narrationNotHeard)
    }
    /// The host could not show the lesson it was offered: the attempt gets
    /// #156's cue after all, unless something newer has begun.
    private func showDroppedLessonCue(_ reason: CaptureCue.Reason) {
        guard phase == .idle, captureFailure == nil, captureCue == nil else { return }
        showCaptureCue(reason)
    }
    private func showCaptureCue(_ reason: CaptureCue.Reason) {
        let cue = CaptureCue(reason: reason)
        captureCue = cue
        captureCueClock = CaptureCueClock(routine: true, shownAt: Date())
        status = cue.status
        announceForAccessibility(cue.message)
        scheduleCaptureCueExpiry()
        onPhaseChange?()
    }
    /// Hovering the cue, or VoiceOver on it, pauses its time; letting go resumes it.
    func holdCaptureCue(_ held: Bool) {
        guard captureCue != nil, captureCueClock?.isHeld != held else { return }
        captureCueClock?.hold(held, at: Date())
        scheduleCaptureCueExpiry()
    }
    /// The cue goes; any kept recording stays exactly as it was.
    func dismissCaptureCue() {
        captureCueExpiry?.cancel(); captureCueExpiry = nil
        captureCueClock = nil
        if captureCue != nil { captureCue = nil; onPhaseChange?() }
    }
    private func scheduleCaptureCueExpiry() {
        captureCueExpiry?.cancel(); captureCueExpiry = nil
        guard let cue = captureCue, let deadline = captureCueClock?.deadline else { return }
        captureCueExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.captureCue?.id == cue.id else { return }
            self.dismissCaptureCue()
        }
    }
    func persist() {
        guard loaded else { return }
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        persistWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    func saveBeforeUpdate() -> Bool {
        guard loaded else { return false }
        do {
            try store.save(session(draft: transcript, history: history, replacements: replacements))
            return true
        } catch { report("Could not save before updating. \(error.localizedDescription)", on: .dictate); return false }
    }
    func saveNow() {
        guard loaded else { return }
        do { try store.save(session(draft: transcript, history: history, replacements: replacements)) }
        catch { report("Could not save this session. \(error.localizedDescription)", on: .dictate) }
    }
    /// The session a write commits: the draft, History and rules it writes,
    /// and the rest as they are. The one undelivered result goes with it only
    /// while what is written still holds its words (#134 T5).
    private func session(draft: String, history: [Transcript], replacements: [Replacement]) -> SavedState {
        let records = DeliveryRecords(history: history, draft: draft == transcript ? (text: draft, revision: draftRevision) : nil)
        return SavedState(draft: draft, speechText: speechText, history: history, replacements: replacements,
                          voice: voice, rate: rate, rawDraft: rawTranscript, undelivered: undelivered.saved(in: records))
    }
    func shutdown() {
        Task { await engine.cancelPreparation() }
        // Quit never attempts another external write. Preserve provisional field text
        // and the existing recovery audio; next launch cannot replay this target.
        liveDictation?.end(); liveDictation = nil
        meetings.shutdown(); handoffJobs.shutdown()
        photoHandoffRefresh?.cancel(); photoHandoffActivation = nil
        shortcutRequest.cancel(); transcriptionTask?.cancel(); transcriptionID = nil; recordingAttempt = nil
        clipboardReceipt.clear(); coach.remove(); liveCapture?.requestStop(); meter?.invalidate(); meter = nil
        if let capture = liveCapture { Task { _ = await capture.finish(recognize: false) } }
        saveNow()
        // Quit stops work. Only a durable capture commit or explicit Cancel may
        // delete the owned audio/journal; the next launch discovers unfinished work.
    }

    /// Quit waits for the original microphone file and model reservation before exiting.
    func prepareVoiceForShutdown() async {
        liveDictation?.end(); liveDictation = nil
        recordingAttempt = nil
        if let capture = liveCapture {
            _ = await capture.finish(recognize: false)
            liveCapture = nil
        }
    }
}
