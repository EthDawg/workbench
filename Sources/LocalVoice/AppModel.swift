import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import PhotoHandoffKit

@MainActor
final class AppModel: NSObject, ObservableObject, AVAudioPlayerDelegate, AVAudioRecorderDelegate {
    static weak var intentModel: AppModel?
    let shortcutRequest = DictationRequest()
    func cancelShortcut(_ id: UUID) {
        guard shortcutRequest.id == id else { return }
        cancelCurrentCapture()
    }
    func transcribeForShortcut(_ url: URL, id: UUID = UUID()) async throws -> String {
        guard ready else { throw VoiceError.message("Open Workbench and finish preparing the speech model, then run this shortcut again.") }
        guard phase == .idle, !rendering else { throw VoiceError.message("Workbench is busy. Finish the current recording or reading first.") }
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
    @Published var isMicrophoneQuiet = false
    @Published var captureUsesHoldShortcut = false
    @Published private(set) var captureOutputModeLabel = "Light cleanup"
    @Published private(set) var captureShortcutInstruction = "Use Stop to finish"
    @Published var captureFailure: String?
    var captureDestinationName: String? { destination?.app.localizedName }
    var canCancelCurrentCapture: Bool {
        [.requesting, .recording].contains(phase) || ([.transcribing, .cleaning].contains(phase) && transcriptionTask != nil)
    }
    func dismissCaptureFailure() { captureFailure = nil }
    @Published var preferences = VoicePreferences.load() {
        didSet {
            preferences.save()
            if oldValue.dictationShortcut != preferences.dictationShortcut || oldValue.controlsShortcut != preferences.controlsShortcut || oldValue.libraryShortcut != preferences.libraryShortcut || oldValue.presenterShortcut != preferences.presenterShortcut || oldValue.readbackShortcut != preferences.readbackShortcut { onShortcutsChanged?() }
        }
    }
    @Published var rawTranscript = ""
    @Published var cleanupMethod = ""
    @Published var editingShortcut: UInt32?
    @Published var shortcutRecordingMessage: String?
    @Published var previewingPanel = false
    @Published var shortcutFailures: [UInt32: String] = [:]
    @Published var quickTab = "Dictate"
    @Published var page = "home"
    @Published var libraryFocusToken = UUID()
    @Published var showingPhonePhotos = false
    @Published var phase: Phase = .idle
    @Published var ready = false
    @Published var preparing = false
    @Published var modelMessage = "Preparing local speech…"
    @Published var status = "Ready when you are."
    @Published var error: String?
    @Published var transcript = "" { didSet { draftRevision &+= 1; persist() } }
    @Published var speechText = "" { didSet { persist() } }
    @Published var history: [Transcript] = []
    @Published var replacements: [Replacement] = []
    @Published private(set) var rememberedCorrection: RememberedCorrection?
    @Published var voice = "Karen" { didSet { persist() } }
    @Published var rate = 180.0 { didSet { persist() } }
    @Published var elapsed = 0.0
    @Published var level = 0.0
    @Published var readingProvider = ReadingProvider(rawValue: UserDefaults.standard.string(forKey: "readingProvider.v1") ?? "") ?? .mac {
        didSet { UserDefaults.standard.set(readingProvider.rawValue, forKey: "readingProvider.v1"); stopPlayback() }
    }
    @Published var keyNotice = SpekoKeychain.hasKey ? "Key ready in Keychain." : "Add your own key to use Speko."
    private var readingTask: Task<Void, Never>?
    private var readingGenerationID: UUID?
    var readingLimit: Int { readingProvider == .speko ? SpekoRenderer.maximumCharacters : 50_000 }
    func saveSpekoKey(_ key: String) {
        do { try SpekoKeychain.save(key); invalidateAudio(); keyNotice = "Key saved in Keychain." }
        catch { self.error = error.localizedDescription }
    }
    func removeSpekoKey() {
        do { try SpekoKeychain.remove(); readingProvider = .mac; invalidateAudio(); keyNotice = "Key removed. Using Mac voices." }
        catch { self.error = error.localizedDescription }
    }
    private func invalidateAudio() { stopPlayback(); AudioRenderer.remove(audioURL); audioURL = nil; audioSignature = "" }
    func cancelReading() {
        guard readingGenerationActive else { return }
        let mayBeBilled = readingProvider == .speko
        let task = readingTask
        readingGenerationID = nil
        readingTask = nil
        readingGenerationActive = false
        cloudRequestActive = false
        rendering = false
        task?.cancel()
        status = mayBeBilled ? "Reading generation cancelled. Speko may still bill text already accepted." : "Reading generation cancelled."
    }
    @Published private(set) var readingGenerationActive = false
    @Published var cloudRequestActive = false
    @Published var rendering = false
    @Published var playing = false
    @Published var paused = false
    @Published var audioDuration = 0.0
    @Published var playbackTime = 0.0
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var canRetry = false
    var retryCaptureLabel: String { captureRecovery.pending?.capture == nil ? "Retry transcription" : "Retry saving" }
    var retryCaptureHelp: String { captureRecovery.pending?.capture == nil ? "Retry the captured audio" : "Save the recognized text without transcribing or pasting again" }
    var hasCaptureRecovery: Bool { captureRecovery.hasRecovery }
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
    private var recorder: AVAudioRecorder?
    private var recordURL: URL?
    private var meter: Timer?
    private var player: AVAudioPlayer?
    private var playTimer: Timer?
    private var playbackID: UUID?
    private var audioURL: URL?
    private var audioSignature = ""
    private var peakPower: Float = -160
    private var destination: TextDelivery.Target?
    private var recordingAttempt: UUID?
    private var recordingSettings: CaptureSettings?
    private var permissionRequest: Task<Bool, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionID: UUID?
    private var persistWork: DispatchWorkItem?
    var onPhaseChange: (() -> Void)?
    var onShortcutsChanged: (() -> Void)?
    var onEditShortcut: ((UInt32) -> Void)?
    var onShowEditor: ((String) -> Void)?
    var onUsePhotoAsBackdrop: ((URL, String) -> Void)?
    var onMenuRecording: (() -> Void)?
    var onCloseMenu: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onPasteTranscript: ((String) -> Void)?
    var onCancelShortcut: (() -> Void)?
    var onResetShortcuts: (() -> Void)?
    var onResetPanel: (() -> Void)?
    var microphoneStartFailure: ((TextDelivery.Target?) -> String?)?
    var voices: [String] = []

    override init() {
        super.init()
        Self.intentModel = self
        photoHandoffActivation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPhotoHandoffIfEnabled() }
        refreshPhotoHandoffIfEnabled()
        do {
            let state = try store.load()
            transcript = state.draft; speechText = state.speechText; history = state.history
            rawTranscript = state.rawDraft ?? state.draft
            replacements = state.replacements; voice = state.voice; rate = state.rate
        } catch {
            let backup = store.url.deletingLastPathComponent().appendingPathComponent("state-unreadable-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: store.url, to: backup)
                self.error = "Your saved session could not be opened. A recovery copy was preserved as \(backup.lastPathComponent) in Application Support/LocalVoice."
            } catch {
                self.error = "Your saved session could not be opened or backed up. Automatic saving is disabled to protect the original file."
                return
            }
        }
        voices = NSSpeechSynthesizer.availableVoices.compactMap { id in
            let info = NSSpeechSynthesizer.attributes(forVoice: id)
            guard let locale = info[.localeIdentifier] as? String, locale.hasPrefix("en"), let name = info[.name] as? String else { return nil }
            return name
        }.sorted()
        let preferred = ["Karen", "Samantha", "Daniel", "Moira", "Rishi", "Tessa"]
        voices = preferred.filter { voices.contains($0) } + voices.filter { !preferred.contains($0) }
        if !voices.contains(voice), let first = voices.first { voice = first }
        loaded = true
        restoreCaptureRecovery()
        Task { await prepare() }
    }

    func refreshPhotoHandoffIfEnabled() {
        guard photoHandoff.isEnabled, photoHandoff.isConfigured, !photoHandoff.isBusy, photoHandoffRefresh == nil else { return }
        photoHandoffRefresh = Task { [weak self] in
            guard let self else { return }
            defer { photoHandoffRefresh = nil }
            await photoHandoff.refresh()
        }
    }

    func prepare() async {
        guard !preparing, !ready else { return }
        preparing = true; modelMessage = "Preparing speech · first setup may take a few minutes"
        do { try await engine.prepare(); ready = true; modelMessage = await engine.statusDescription() }
        catch { modelMessage = "Speech model needs attention"; self.error = "Could not prepare the speech model. Check your connection and click Retry model. \(error.localizedDescription)" }
        preparing = false
    }

    func toggleRecording(fromShortcut: Bool = false, target: TextDelivery.Target? = nil) {
        if phase == .requesting { cancelRecording(); return }
        if phase == .recording { stopRecording(); return }
        guard phase == .idle, ready, !rendering else { return }
        guard admitNewCapture() else { return }
        let intendedTarget = target ?? (fromShortcut ? TextDelivery.capture() : nil)
        if let reason = microphoneStartFailure?(intendedTarget) {
            captureFailure = reason; status = reason; return
        }
        clipboardReceipt.clear()
        captureFailure = nil
        previewingPanel = false
        stopPlayback()
        captureUsesHoldShortcut = fromShortcut && preferences.capture == .hold
        recordingSettings = captureSettings()
        isMicrophoneQuiet = false
        let attempt = UUID(); recordingAttempt = attempt
        destination = intendedTarget
        phase = .requesting
        Task { await startRecording(attempt) }
    }
    func shortcutChanged(down: Bool) {
        let usesHold = phase == .idle ? preferences.capture == .hold : captureUsesHoldShortcut
        if !usesHold { if down { toggleRecording(fromShortcut: true) }; return }
        if down { if phase == .idle { toggleRecording(fromShortcut: true) } }
        else if phase == .recording { stopRecording() }
        else if phase == .requesting { cancelRecording() }
    }

    private func startRecording(_ attempt: UUID) async {
        guard recordingAttempt == attempt else { return }
        phase = .requesting; error = nil; onPhaseChange?()
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: granted = true
        case .notDetermined:
            status = "Allow Microphone access in the macOS prompt."
            if permissionRequest == nil { permissionRequest = Task { await AVCaptureDevice.requestAccess(for: .audio) } }
            granted = await permissionRequest!.value; permissionRequest = nil
        default: granted = false
        }
        guard recordingAttempt == attempt else { return }
        guard granted else {
            fail("Microphone access is off. Open System Settings → Privacy & Security → Microphone and allow \(Workbench.displayName)."); return
        }
        var startedAudio: URL?
        do {
            let url = try captureRecovery.beginRecording()
            startedAudio = url
            recordURL = url
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let capture = try AVAudioRecorder(url: url, settings: settings)
            capture.delegate = self; capture.isMeteringEnabled = true
            guard capture.prepareToRecord(), capture.record() else { throw VoiceError.message("The microphone could not start. Check that an input device is connected.") }
            recorder = capture; recordURL = url; canRetry = false; elapsed = 0; level = 0; peakPower = -160
            phase = .recording
            status = captureUsesHoldShortcut ? "Listening… release the shortcut to finish" : "Listening… choose Finish when you are done."
            onPhaseChange?()
            meter = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters(); self.elapsed = recorder.currentTime
                    self.peakPower = max(self.peakPower, recorder.peakPower(forChannel: 0))
                    self.level = max(0, min(1, Double(recorder.averagePower(forChannel: 0) + 55) / 55))
                    self.isMicrophoneQuiet = self.elapsed >= 6 && self.peakPower <= -55
                    if self.elapsed >= 300 { self.stopRecording() }
                }
            }
        } catch {
            // A failed start has no usable capture; never clear a prior recovery.
            if let url = startedAudio, let pending = captureRecovery.pending, pending.capture == nil,
               url.lastPathComponent == pending.audioFilename {
                do { try captureRecovery.clear(pending.id); recordURL = nil }
                catch { self.error = error.localizedDescription }
            }
            fail(error.localizedDescription)
        }
    }

    func stopRecording() {
        guard phase == .recording, let url = recordURL else { return }
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil; level = 0
        guard duration >= 0.35, peakPower > -55 else {
            discardRecordingRecovery()
            fail("No clear speech was captured. Check your microphone and try again."); return
        }
        transcribe(url, duration: duration, temporary: true, settings: recordingSettings)
        recordingSettings = nil
    }

    func cancelRecording() {
        if phase == .requesting {
            shortcutRequest.cancel(); recordingAttempt = nil; phase = .idle; status = "Capture cancelled. Use the shortcut again when microphone permission is ready."; onPhaseChange?(); return
        }
        guard phase == .recording else { return }
        shortcutRequest.cancel()
        recordingAttempt = nil
        recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil
        let discarded = discardRecordingRecovery()
        phase = .idle; level = 0
        status = discarded ? "Recording discarded." : "Recording stopped. Recovery files could not be discarded; open Workbench to review them."
        onPhaseChange?()
    }

    func cancelCurrentCapture() {
        if [.requesting, .recording].contains(phase) { cancelRecording(); return }
        guard [.transcribing, .cleaning].contains(phase), transcriptionTask != nil else { return }
        // Keep the recording gate closed until the selected engine unwinds. A
        // slow model must never finish into a newer capture after cancellation.
        shortcutRequest.cancel()
        transcriptionTask?.cancel()
        phase = .cancelling; status = "Cancelling…"; onPhaseChange?()
    }

    func importAudio() {
        guard phase == .idle, ready else { return }
        guard admitNewCapture() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        panel.message = "Choose an audio file up to 30 minutes. Your selected speech engine will transcribe it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importAudio(url)
    }
    func importAudio(_ url: URL) {
        guard phase == .idle, ready else { return }
        guard admitNewCapture() else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration > 0, duration <= 1800 else { throw VoiceError.message("Choose an audio file between 1 second and 30 minutes long.") }
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
        guard ready else { captureFailure = "Wait for the speech model to finish preparing, then retry transcription."; onPhaseChange?(); return }
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

    private func transcribe(_ url: URL, duration: Double, temporary: Bool, settings: CaptureSettings? = nil) {
        let settings = settings ?? captureSettings()
        let shortcutID = shortcutRequest.id
        let invocation = UUID(); transcriptionID = invocation
        clipboardReceipt.clear()
        captureFailure = nil
        previewingPanel = false
        captureProcessingLabel = "Preparing transcription…"
        phase = .transcribing; status = "Turning speech into text…"; error = nil; canRetry = false; onPhaseChange?()
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
                let raw = try await engine.transcribe(url)
                try Task.checkCancellation()
                guard transcriptionID == invocation else { throw CancellationError() }
                if let shortcutID, shortcutRequest.id != shortcutID { throw CancellationError() }
                phase = .cleaning; status = "Tidying your words…"; onPhaseChange?()
                let cleaned = await cleanupEngine.clean(raw, style: settings.preferences.cleanup, configuration: settings.cleanup)
                try Task.checkCancellation()
                guard transcriptionID == invocation else { throw CancellationError() }
                if let shortcutID, shortcutRequest.id != shortcutID { throw CancellationError() }
                let result = TextRules.apply(cleaned.text, replacements: settings.replacements)
                guard !result.isEmpty else { throw VoiceError.message("No speech was recognised. Try speaking closer to the microphone.") }
                guard try commitRecognizedCapture(raw: raw, text: result, seconds: duration,
                    method: cleaned.method, ownedAudio: temporary ? url : nil, invocation: invocation) else { return }
                accessibilityGranted = AXIsProcessTrusted()
                if let shortcutID {
                    status = "Transcript returned to Shortcuts."
                    shortcutRequest.finish(id: shortcutID, result: .success(result))
                } else {
                    phase = .delivering; status = "Delivering text…"; onPhaseChange?()
                    let outcome = await TextDelivery.deliver(result, target: destination, mode: settings.preferences.delivery, restoreClipboard: settings.preferences.restoreClipboard)
                    guard transcriptionID == invocation else { return }
                    status = outcome.message
                    clipboardReceipt.record(outcome: outcome, wordCount: TextRules.wordCount(result))
                }
                phase = .idle; onPhaseChange?()
            } catch {
                guard transcriptionID == invocation else { return }
                if Task.isCancelled || error is CancellationError {
                    if let shortcutID { shortcutRequest.finish(id: shortcutID, result: .failure(error)) }
                    let discarded = !temporary || discardRecordingRecovery()
                    phase = .idle
                    status = discarded ? "Transcription cancelled. No text was added." : "Transcription cancelled. Recovery files are still kept; open Workbench to review them."
                    onPhaseChange?(); return
                }
                canRetry = temporary && shortcutID == nil; fail("Transcription failed. \(error.localizedDescription)")
            }
        }
    }

    private func admitNewCapture() -> Bool {
        guard captureRecovery.hasRecovery else { return true }
        let message = captureRecovery.problem?.localizedDescription ?? "A previous capture is kept. Use \(retryCaptureLabel) before starting another capture."
        captureFailure = message; error = message; status = message; onPhaseChange?(); return false
    }

    /// No asynchronous boundary occurs between the generation check and commit.
    /// The ID survives retries, so writing again cannot create a second capture.
    private func commitRecognizedCapture(raw: String, text: String, seconds: Double, method: String,
                                         ownedAudio: URL?, invocation: UUID) throws -> Bool {
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
        // retain keeps the result in memory even when the independent journal fails.
        do { try captureRecovery.retain(record) }
        catch {
            guard captureRecovery.pending?.capture?.id == capture.id else { throw error }
            // The result is in memory; report any journal failure alongside the state write below.
        }
        return savePendingCapture()
    }

    @discardableResult private func savePendingCapture() -> Bool {
        guard loaded, let record = captureRecovery.pending, let capture = record.capture else { return false }
        var journalError: Error?
        do { try captureRecovery.retain(record) } catch { journalError = error }
        let nextHistory = TranscriptHistory.adding(capture, to: history)
        let state = SavedState(draft: transcript, speechText: speechText, history: nextHistory,
                               replacements: replacements, voice: voice, rate: rate, rawDraft: rawTranscript)
        do {
            if let captureStateWriter { try captureStateWriter(state) } else { try store.save(state) }
        } catch {
            canRetry = true
            let recovery = journalError == nil ? "The recovery copy is kept." : "Recovery text could not be written either. Copy or Save text before quitting. Your existing audio files are kept."
            fail("Could not save this capture. \(recovery) Use Retry saving. No text was sent. \(error.localizedDescription)")
            captureFailure = self.error; onPhaseChange?(); return false
        }
        history = nextHistory
        do { try captureRecovery.clear(record.id) }
        catch {
            canRetry = true
            fail("Text saved, but capture recovery could not be cleared. Use Retry saving; the saved capture will not be duplicated. No text was sent. \(error.localizedDescription)")
            captureFailure = self.error; onPhaseChange?(); return false
        }
        recordURL = nil; canRetry = false; captureFailure = nil; error = nil
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
                : (preservedSavedDraft ? "An unsaved capture was recovered. Your saved draft is unchanged. Retry saving adds the capture to Recent transcripts without pasting."
                   : "An unsaved capture was recovered. Use Retry saving; text will not be pasted automatically.")
            captureFailure = message; status = message
        } catch { self.error = error.localizedDescription; captureFailure = self.error; status = "Capture recovery needs attention." }
    }

    @discardableResult private func discardRecordingRecovery() -> Bool {
        guard let record = captureRecovery.pending, record.capture == nil else { return !captureRecovery.hasRecovery }
        do { try captureRecovery.clear(record.id); recordURL = nil; canRetry = false; return true }
        catch { self.error = error.localizedDescription; captureFailure = self.error; return false }
    }

    /// Called only after the normal Dictate view's explicit confirmation. The
    /// draft stays open; no imported URL can enter the recovery store's deletion.
    func discardCaptureRecovery() {
        guard canDiscardCaptureRecovery, let record = captureRecovery.pending else { return }
        do {
            try captureRecovery.clear(record.id)
            recordURL = nil; canRetry = false; captureFailure = nil; error = nil
            status = "Recovery discarded. Your current draft is kept."; onPhaseChange?()
        } catch { self.error = error.localizedDescription; captureFailure = self.error; onPhaseChange?() }
    }
    func showCaptureRecoveryFiles() {
        if !NSWorkspace.shared.open(captureRecovery.directory) { error = "The CaptureRecovery folder could not be opened." }
    }

    func copyTranscript() {
        copyTextWithReceipt(transcript)
    }
    private func copyTextWithReceipt(_ text: String) {
        guard !text.isEmpty else { return }
        captureFailure = nil
        let count = TextDelivery.copy(text)
        let outcome = TextDelivery.Outcome(message: count == nil ? "Could not copy the transcript." : "Copied to clipboard.", clipboardChangeCount: count, wasPasted: false, destinationName: nil, failure: count == nil ? .copyFailed : nil)
        status = outcome.message
        clipboardReceipt.record(outcome: outcome, wordCount: TextRules.wordCount(text))
    }
    func showLibrary() { page = "library"; onShowEditor?("library"); libraryFocusToken = UUID() }
    func savePrompt(_ text: String) { guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; showLibrary(); library.newPrompt(text) }
    func copyCapture(_ item: Transcript) { copyTextWithReceipt(item.text) }
    func showPanelPreview() {
        guard phase == .idle else { return }
        captureUsesHoldShortcut = false
        _ = captureSettings()
        previewingPanel = true; onPhaseChange?()
    }
    func closePanelPreview() { previewingPanel = false; onPhaseChange?() }
    func cleanCurrentDraft() {
        guard phase == .idle, !transcript.isEmpty else { return }
        let original = transcript
        let revision = draftRevision
        let settings = captureSettings()
        let invocation = UUID(); transcriptionID = invocation
        clipboardReceipt.dismissHUD(); captureFailure = nil
        previewingPanel = false; destination = nil
        captureProcessingLabel = "Text cleanup · on this Mac"
        phase = .cleaning; status = "Tidying your words…"; error = nil
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
                status = "Cleanup cancelled. Your draft was kept."; return
            }
            guard revision == draftRevision else {
                status = "Your draft changed during cleanup. Your latest text was kept."; return
            }
            rawTranscript = original; transcript = TextRules.apply(cleaned.text, replacements: settings.replacements)
            cleanupMethod = cleaned.method; status = cleaned.method + " · original retained"; persist()
        }
        onPhaseChange?()
    }
    func openTranscript(_ item: Transcript) {
        rememberedCorrection = nil
        transcript = item.text; rawTranscript = item.rawText ?? item.text; cleanupMethod = item.cleanupMethod ?? "Original"; page = "dictate"; persist()
    }
    func useOriginal() { rememberedCorrection = nil; transcript = rawTranscript; cleanupMethod = "Original restored"; status = "Original transcript restored."; persist() }
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityGranted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    func refreshPermissions() { accessibilityGranted = AXIsProcessTrusted() }
    func openMicrophoneSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
    func exportTranscript() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try transcript.write(to: url, atomically: true, encoding: .utf8); status = "Transcript saved." }
        catch { fail(error.localizedDescription) }
    }
    func exportCapture(_ item: Transcript, version: TranscriptExportVersion) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = TranscriptExport.defaultFilename
        panel.title = "Export saved transcript"
        panel.message = version == .original
            ? "Save the original recognised wording as a UTF-8 text file."
            : "Save the cleaned transcript as a UTF-8 text file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TranscriptExport.write(item, version: version, to: url)
            self.error = nil
            status = "\(version.rawValue) saved to \(url.lastPathComponent)."
        } catch {
            self.error = "Could not save this transcript. \(error.localizedDescription)"
        }
    }

    private var signature: String { "\(readingProvider.rawValue)|\(voice)|\(Int(rate))|\(speechText)" }
    var canSeekReading: Bool { !rendering && (playing || paused) && player != nil && audioDuration.isFinite && audioDuration > 0 }
    func seekReading(to seconds: TimeInterval) {
        guard canSeekReading, seconds.isFinite, let player else { return }
        // Stay on the final audio frame: seeking to/past EOF can make a player
        // wrap to the beginning. A paused reading stays paused at this position.
        let lastFrame = max(0, player.duration - 1 / max(1, player.format.sampleRate))
        player.currentTime = min(max(0, seconds), lastFrame)
        playbackTime = player.currentTime
    }
    func skipReading(by seconds: TimeInterval) {
        guard seconds.isFinite, let player else { return }
        seekReading(to: player.currentTime + seconds)
    }
    func listen() {
        guard !rendering, phase == .idle else { return }
        if playing {
            player?.pause(); playbackTime = player?.currentTime ?? 0
            playing = false; paused = true; status = "Reading paused."; return
        }
        if paused, signature == audioSignature {
            guard player?.play() == true else {
                stopPlayback(); error = "Audio could not resume. Check your Mac's audio output."; return
            }
            playing = true; paused = false; status = "Reading aloud."; return
        }
        stopPlayback()
        let generationID = UUID()
        readingGenerationID = generationID
        rendering = true
        readingTask = Task {
            defer {
                if readingGenerationID == generationID {
                    rendering = false; readingGenerationActive = false; cloudRequestActive = false
                    readingTask = nil; readingGenerationID = nil
                }
            }
            do {
                let url = try await generateAudio(generationID: generationID)
                try Task.checkCancellation()
                guard readingGenerationID == generationID else { throw CancellationError() }
                let activePlayer = try AVAudioPlayer(contentsOf: url); activePlayer.delegate = self
                try Task.checkCancellation()
                guard readingGenerationID == generationID else { throw CancellationError() }
                guard activePlayer.play() else { throw VoiceError.message("Audio could not play. Check your Mac's audio output.") }
                player = activePlayer
                let invocation = UUID(); playbackID = invocation
                playing = true; audioDuration = activePlayer.duration; status = "Reading aloud."
                playTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.playbackID == invocation, let activePlayer = self.player else { return }
                        self.playbackTime = activePlayer.currentTime
                    }
                }
            } catch {
                if !(error is CancellationError), readingGenerationID == generationID { self.error = error.localizedDescription }
            }
        }
    }
    private func generateAudio(generationID: UUID) async throws -> URL {
        if let audioURL, signature == audioSignature { return audioURL }
        guard readingGenerationID == generationID else { throw CancellationError() }
        rendering = true; readingGenerationActive = true; error = nil
        let text = speechText, selectedVoice = voice, selectedRate = Int(rate), selectedProvider = readingProvider, originalSignature = signature
        let limit = selectedProvider == .speko ? SpekoRenderer.maximumCharacters : 50_000
        guard text.count <= limit else { throw VoiceError.message("This reading is too long for the selected provider.") }
        defer {
            if readingGenerationID == generationID {
                readingGenerationActive = false; cloudRequestActive = false
            }
        }
        let url: URL
        if selectedProvider == .speko {
            let key = try SpekoKeychain.read()
            cloudRequestActive = true
            url = try await SpekoRenderer.render(text: text, key: key)
        } else {
            url = try await AudioRenderer.renderCancellable(text: text, voice: selectedVoice, rate: selectedRate)
        }
        do {
            try Task.checkCancellation()
            guard readingGenerationID == generationID else { throw CancellationError() }
        } catch {
            AudioRenderer.remove(url); throw error
        }
        AudioRenderer.remove(audioURL); audioURL = url; audioSignature = originalSignature
        return url
    }
    func saveAudio() {
        guard !rendering, !speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Audio]; panel.nameFieldStringValue = "Reading.m4a"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let generationID = UUID()
        readingGenerationID = generationID
        rendering = true
        readingTask = Task {
            defer {
                if readingGenerationID == generationID {
                    rendering = false; readingGenerationActive = false; cloudRequestActive = false
                    readingTask = nil; readingGenerationID = nil
                }
            }
            do {
                let url = try await generateAudio(generationID: generationID)
                try Task.checkCancellation()
                guard readingGenerationID == generationID else { throw CancellationError() }
                try await Task.detached { try AudioRenderer.export(url, to: destination) }.value
                try Task.checkCancellation()
                guard readingGenerationID == generationID else { throw CancellationError() }
                status = "Audio saved to \(destination.lastPathComponent)."
            } catch {
                if !(error is CancellationError), readingGenerationID == generationID { self.error = error.localizedDescription }
            }
        }
    }
    func stopPlayback() {
        let wasActive = playing || paused
        player?.stop(); player = nil; playing = false; paused = false; playbackTime = 0; audioDuration = 0
        playTimer?.invalidate(); playTimer = nil; playbackID = nil
        if wasActive { status = "Reading stopped." }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.stopPlayback(); self.status = flag ? "Finished reading." : "Playback interrupted."
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.cancelRecording()
            let message = error?.localizedDescription ?? "Recording was interrupted. Please try again."
            self.captureFailure = message; self.fail(message)
        }
    }
    func addReplacement(heard: String, written: String) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines), written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !written.isEmpty else { return }
        rememberedCorrection = nil
        replacements.append(Replacement(heard: heard, written: written)); persist()
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
        try store.save(SavedState(draft: proposal.previewText, speechText: speechText, history: history,
                                  replacements: proposal.updatedRules, voice: voice, rate: rate, rawDraft: rawTranscript))
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
        try store.save(SavedState(draft: draft, speechText: speechText, history: history,
                                  replacements: receipt.beforeRules, voice: voice, rate: rate, rawDraft: rawTranscript))
        persistWork?.cancel()
        replacements = receipt.beforeRules
        if transcript != draft { transcript = draft }
        rememberedCorrection = nil
        status = restoreDraft ? "Correction undone." : "Dictionary change undone. Your newer draft edits are kept."
    }
    func dismissRememberedCorrection() { rememberedCorrection = nil }
    func removeTranscript(_ item: Transcript) { history.removeAll { $0.id == item.id }; persist() }
    func fail(_ text: String) {
        if phase != .idle { captureFailure = text }
        if let id = shortcutRequest.id { shortcutRequest.finish(id: id, result: .failure(VoiceError.message(text))) }
        error = text; phase = .idle; status = "Needs attention"; onPhaseChange?()
    }
    func persist() {
        guard loaded else { return }
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        persistWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    func saveNow() {
        guard loaded else { return }
        do { try store.save(SavedState(draft: transcript, speechText: speechText, history: history, replacements: replacements, voice: voice, rate: rate, rawDraft: rawTranscript)) }
        catch { self.error = "Could not save this session. \(error.localizedDescription)" }
    }
    func shutdown() {
        photoHandoffRefresh?.cancel(); photoHandoffActivation = nil; readingTask?.cancel()
        shortcutRequest.cancel(); transcriptionTask?.cancel(); transcriptionID = nil; recordingAttempt = nil
        clipboardReceipt.clear(); recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil
        stopPlayback(); saveNow(); AudioRenderer.remove(audioURL)
        // Quit stops work. Only a durable capture commit or explicit Cancel may
        // delete the owned audio/journal; the next launch discovers unfinished work.
    }
}
