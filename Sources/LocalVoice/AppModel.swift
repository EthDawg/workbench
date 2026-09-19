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
            if oldValue.dictationShortcut != preferences.dictationShortcut || oldValue.controlsShortcut != preferences.controlsShortcut || oldValue.libraryShortcut != preferences.libraryShortcut { onShortcutsChanged?() }
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
        didSet {
            UserDefaults.standard.set(readingProvider.rawValue, forKey: "readingProvider.v1")
            stopPlayback()
            if readingProvider == .speko { Task { await refreshSpekoVoices() } }
        }
    }
    @Published var selectedSpekoVoice = SpekoVoicePreference.load() {
        didSet {
            guard oldValue != selectedSpekoVoice else { return }
            SpekoVoicePreference.save(selectedSpekoVoice)
            invalidateAudio()
        }
    }
    @Published private(set) var spekoVoices: [SpekoVoice] = []
    @Published private(set) var loadingSpekoVoices = false
    @Published private(set) var spekoVoiceNotice = ""
    private var spekoVoiceRefreshID: UUID?
    @Published var keyNotice = SpekoKeychain.hasKey ? "Key ready in Keychain." : "Add your own key to use Speko."
    private var readingTask: Task<Void, Never>?
    var readingLimit: Int { readingProvider == .speko ? SpekoRenderer.maximumCharacters : 50_000 }
    var displayedSpekoVoices: [SpekoVoice] {
        guard let selectedSpekoVoice, !spekoVoices.contains(where: { $0.id == selectedSpekoVoice.id }) else { return spekoVoices }
        return [selectedSpekoVoice] + spekoVoices
    }
    func saveSpekoKey(_ key: String) {
        do {
            try SpekoKeychain.save(key)
            invalidateAudio()
            keyNotice = "Key saved in Keychain."
            Task { await refreshSpekoVoices(force: true) }
        }
        catch { self.error = error.localizedDescription }
    }
    func removeSpekoKey() {
        do {
            try SpekoKeychain.remove()
            readingProvider = .mac
            spekoVoiceRefreshID = nil
            loadingSpekoVoices = false
            spekoVoices = []
            selectedSpekoVoice = nil
            spekoVoiceNotice = ""
            invalidateAudio()
            keyNotice = "Key removed. Using Mac voices."
        }
        catch { self.error = error.localizedDescription }
    }
    func selectSpekoVoice(id: String?) {
        selectedSpekoVoice = id.flatMap { id in displayedSpekoVoices.first(where: { $0.id == id }) }
    }
    func refreshSpekoVoices(force: Bool = false) async {
        guard readingProvider == .speko, (!loadingSpekoVoices || force), !rendering else { return }
        guard SpekoKeychain.hasKey else {
            spekoVoiceNotice = "Save your Speko key to browse voices."
            return
        }
        let refreshID = UUID()
        spekoVoiceRefreshID = refreshID
        loadingSpekoVoices = true
        spekoVoiceNotice = "Loading English voices…"
        defer {
            if spekoVoiceRefreshID == refreshID { loadingSpekoVoices = false }
        }
        do {
            let voices = try await SpekoVoiceCatalog.load(key: SpekoKeychain.read())
            try Task.checkCancellation()
            guard spekoVoiceRefreshID == refreshID, readingProvider == .speko, SpekoKeychain.hasKey else { return }
            spekoVoices = voices
            spekoVoiceNotice = voices.isEmpty ? "Speko returned no English voices that support a 5,000-character reading." : "\(voices.count) voices available."
        } catch is CancellationError {
            if spekoVoiceRefreshID == refreshID { spekoVoiceNotice = "" }
        } catch {
            if spekoVoiceRefreshID == refreshID { spekoVoiceNotice = error.localizedDescription }
        }
    }
    private func invalidateAudio() { stopPlayback(); AudioRenderer.remove(audioURL); audioURL = nil; audioSignature = "" }
    func cancelReading() { readingTask?.cancel(); status = "Reading cancelled. Speko may still bill text already accepted." }
    @Published var cloudRequestActive = false
    @Published var rendering = false
    @Published var playing = false
    @Published var paused = false
    @Published var audioDuration = 0.0
    @Published var playbackTime = 0.0
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var canRetry = false
    let engine = RecognitionEngine()
    let cleanupEngine = CleanupEngine()
    let store = StateStore()
    let library = DemoLibraryModel()
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
        do {
            if let old = recordURL { try? FileManager.default.removeItem(at: old) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-recording-\(UUID().uuidString).wav")
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
        } catch { fail(error.localizedDescription) }
    }

    func stopRecording() {
        guard phase == .recording, let url = recordURL else { return }
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil; level = 0
        guard duration >= 0.35, peakPower > -55 else {
            try? FileManager.default.removeItem(at: url); recordURL = nil
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
        if let url = recordURL { try? FileManager.default.removeItem(at: url) }; recordURL = nil
        phase = .idle; level = 0; status = "Recording discarded."; onPhaseChange?()
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
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        panel.message = "Choose an audio file up to 30 minutes. Your selected speech engine will transcribe it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importAudio(url)
    }
    func importAudio(_ url: URL) {
        guard phase == .idle, ready else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration > 0, duration <= 1800 else { throw VoiceError.message("Choose an audio file between 1 second and 30 minutes long.") }
            destination = nil; transcribe(url, duration: duration, temporary: false)
        } catch { fail("Could not read this audio file. \(error.localizedDescription)") }
    }
    func retryTranscription() {
        guard phase == .idle, let url = recordURL else { return }
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
                rawTranscript = raw; transcript = result
                cleanupMethod = cleaned.method
                history = TranscriptHistory.adding(Transcript(text: result, seconds: duration, rawText: raw, cleanupMethod: cleaned.method), to: history)
                // Commit the capture before focus restoration or clipboard delivery can suspend this task.
                saveNow()
                accessibilityGranted = AXIsProcessTrusted()
                if let shortcutID {
                    status = "Transcript returned to Shortcuts."
                    shortcutRequest.finish(id: shortcutID, result: .success(result))
                } else {
                    phase = .delivering; status = "Delivering text…"; onPhaseChange?()
                    let outcome = await TextDelivery.deliver(result, target: destination, mode: settings.preferences.delivery, restoreClipboard: settings.preferences.restoreClipboard)
                    status = outcome.message
                    clipboardReceipt.record(outcome: outcome, wordCount: TextRules.wordCount(result))
                }
                if temporary { try? FileManager.default.removeItem(at: url); recordURL = nil }
                phase = .idle; onPhaseChange?()
            } catch {
                guard transcriptionID == invocation else { return }
                if Task.isCancelled || error is CancellationError {
                    if let shortcutID { shortcutRequest.finish(id: shortcutID, result: .failure(error)) }
                    if temporary { try? FileManager.default.removeItem(at: url); recordURL = nil }
                    phase = .idle; status = "Transcription cancelled. No text was added."; onPhaseChange?(); return
                }
                canRetry = temporary && shortcutID == nil; fail("Transcription failed. \(error.localizedDescription)")
            }
        }
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

    private var signature: String {
        let selectedVoice = readingProvider == .speko ? selectedSpekoVoice?.requestSignature ?? "automatic" : voice
        return "\(readingProvider.rawValue)|\(selectedVoice)|\(Int(rate))|\(speechText)"
    }
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
        rendering = true
        readingTask = Task {
            defer { rendering = false; readingTask = nil }
            do {
                let url = try await generateAudio()
                try Task.checkCancellation()
                let activePlayer = try AVAudioPlayer(contentsOf: url); activePlayer.delegate = self
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
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    private func generateAudio() async throws -> URL {
        if let audioURL, signature == audioSignature { return audioURL }
        rendering = true; error = nil
        let text = speechText, selectedVoice = voice, selectedSpekoVoice = self.selectedSpekoVoice, selectedRate = Int(rate), originalSignature = signature
        guard text.count <= readingLimit else { throw VoiceError.message("This reading is too long for the selected provider.") }
        let url: URL
        if readingProvider == .speko {
            let key = try SpekoKeychain.read()
            cloudRequestActive = true
            defer { cloudRequestActive = false }
            url = try await SpekoRenderer.render(text: text, key: key, voice: selectedSpekoVoice)
        } else {
            url = try await Task.detached(priority: .userInitiated) { try AudioRenderer.render(text: text, voice: selectedVoice, rate: selectedRate) }.value
        }
        do { try Task.checkCancellation() } catch { AudioRenderer.remove(url); throw error }
        AudioRenderer.remove(audioURL); audioURL = url; audioSignature = originalSignature
        return url
    }
    func saveAudio() {
        guard !rendering, !speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Audio]; panel.nameFieldStringValue = "Reading.m4a"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        rendering = true
        readingTask = Task {
            defer { rendering = false; readingTask = nil }
            do {
                let url = try await generateAudio()
                try Task.checkCancellation()
                try await Task.detached { try AudioRenderer.export(url, to: destination) }.value
                rendering = false; status = "Audio saved to \(destination.lastPathComponent)."
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
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
    func shutdown() { photoHandoffRefresh?.cancel(); photoHandoffActivation = nil; readingTask?.cancel(); shortcutRequest.cancel(); transcriptionTask?.cancel(); transcriptionID = nil; clipboardReceipt.clear(); cancelRecording(); stopPlayback(); saveNow(); AudioRenderer.remove(audioURL); if let recordURL { try? FileManager.default.removeItem(at: recordURL) } }
}
