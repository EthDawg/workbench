import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import PhotoHandoffKit
import ToolbarCore

@MainActor
final class AppModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioRecorderDelegate {
    static weak var intentModel: AppModel?
    let shortcutRequest = DictationRequest()
    func cancelShortcut(_ id: UUID) {
        guard shortcutRequest.id == id else { return }
        cancelCurrentCapture()
    }
    func transcribeForShortcut(_ url: URL, id: UUID = UUID()) async throws -> String {
        guard ready else { throw VoiceError.message("Open Workbench and finish preparing the speech model, then run this shortcut again.") }
        guard phase == .idle, !rendering else { throw VoiceError.message("Workbench is busy. Finish the current recording or reading first.") }
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
    @Published var phase: Phase = .idle
    @Published var ready = false
    @Published var preparing = false
    @Published var modelMessage = "Preparing local speech…"
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
    /// The saved Mac voice: an identifier, or a name an earlier build saved.
    /// Empty means nothing was chosen, so the best installed voice is used.
    @Published var voice = "" { didSet { persist() } }
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
    private var readingGenerationID: UUID?
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
        catch { report(error.localizedDescription, on: .read) }
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
        catch { report(error.localizedDescription, on: .read) }
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
    private func invalidateAudio() { stopPlayback(); audio?.discard(); audio = nil }
    func cancelReading() {
        guard readingGenerationActive else { return }
        let mayBeBilled = readingProvider == .speko
        let task = readingTask
        if savingAudioID == readingGenerationID { savingAudioID = nil }
        readingGenerationID = nil
        readingTask = nil
        readingGenerationActive = false
        cloudRequestActive = false
        rendering = false
        task?.cancel()
        pendingRender?.cancel(); pendingRender = nil
        status = mayBeBilled ? "Reading generation cancelled. Speko may still bill text already accepted." : "Reading generation cancelled."
    }
    @Published private(set) var readingGenerationActive = false
    /// Save audio's whole run, from making the audio to writing the file.
    @Published private(set) var savingAudioID: UUID?
    var savingAudio: Bool { savingAudioID != nil }
    @Published var cloudRequestActive = false
    @Published var rendering = false
    @Published var playing = false
    @Published var paused = false
    @Published var audioDuration = 0.0
    @Published var playbackTime = 0.0
    @Published private(set) var pendingReadingSelection: ReadingSelectionImport?
    @Published private(set) var readingFailure: ReadingFailure?
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
    private var recorder: AVAudioRecorder?
    private var recordURL: URL?
    private var meter: Timer?
    private var player: ReadingPlayer?
    private var playTimer: Timer?
    private var playbackID: UUID?
    /// The latest reading's audio, reused while its signature matches.
    private var audio: ReadingTrack?
    /// What the current player plays; it can differ after Save audio.
    private var playingTrack: ReadingTrack?
    /// A Mac voice render that has not produced playable audio yet.
    private var pendingRender: MacSpeechRenderer?
    private var audioURL: URL? { audio?.url }
    private var audioSignature: String { audio?.signature ?? "" }
    private var voicePreview: AVSpeechSynthesizer?
    private var voiceObservers: [AnyCancellable] = []
    private var voiceRefresh: Task<Void, Never>?
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
    var onShowAnnotationMenu: (() -> Void)?
    var onUsePhotoAsBackdrop: ((URL, String) -> Void)?
    var onMenuRecording: (() -> Void)?
    var onCloseMenu: (() -> Void)?
    var onCancelShortcut: (() -> Void)?
    var onResetShortcuts: (() -> Void)?
    var onResetPanel: (() -> Void)?
    var microphoneStartFailure: ((TextDelivery.Target?) -> String?)?
    @Published private(set) var macVoices: [MacVoice] = []
    @Published private(set) var voiceLanguage = "en-US"
    @Published private(set) var previewingVoice = false
    @Published private(set) var readingHighlight: NSRange?
    /// Playback started while a Mac voice keeps rendering the rest.
    @Published private(set) var renderingAhead = false

    init(preferences: VoicePreferences) {
        self.preferences = preferences
        super.init()
        Self.intentModel = self
        photoHandoffActivation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPhotoHandoffIfEnabled() }
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
                report("A recording removal needs attention. " + removalIssues.joined(separator: " "), on: .history)
            }
        } catch {
            let backup = store.url.deletingLastPathComponent().appendingPathComponent("state-unreadable-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: store.url, to: backup)
                report("Your saved session could not be opened. A recovery copy was preserved as \(backup.lastPathComponent) in Application Support/LocalVoice.", on: .dictate)
            } catch {
                report("Your saved session could not be opened or backed up. Automatic saving is disabled to protect the original file.", on: .dictate)
                return
            }
        }
        // A saved voice that is missing stays chosen and is reported; it is
        // never silently replaced. Voices added in Settings appear without a relaunch.
        refreshVoices()
        voiceObservers = [
            NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
                .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshVoices(inBackground: true) },
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in self?.refreshVoices(inBackground: true) }
        ]
        loaded = true
        restoreCaptureRecovery()
        // With the draft settled: a delivery that did not finish comes back
        // only while its record still holds its words (#134 T5).
        undelivered.restore(savedUndelivered, loadedDraftRevision: loadedDraftRevision, in: deliveryRecords)
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
        // Retry model is on Home's engine banner, so Home owns the failure (#134 review).
        catch { modelMessage = "Speech model needs attention"; report("Could not prepare the speech model. Check your connection and click Retry model. \(error.localizedDescription)", on: .home) }
        preparing = false
    }

    /// The one owner of text arriving in Read: the macOS Service, History and
    /// Library items all come here. An empty draft or the same text needs no
    /// choice; a different draft waits behind Replace reading / Keep current,
    /// with the current reading untouched. Nothing here starts audio or sends
    /// text online.
    func receiveReadingSelection(_ selection: ReadingSelectionImport) {
        attention = nil
        clipboardReceipt.dismissHUD()
        if ReadingSelectionImport.needsReview(current: speechText, incoming: selection.text) {
            pendingReadingSelection = selection
            status = "\(selection.origin.name) is ready. Choose Replace reading or Keep current."
        } else {
            pendingReadingSelection = nil
            if speechText != selection.text { applyReadingSelection(selection) }
            else { status = "\(selection.origin.name) already matches this reading draft." }
        }
        page = "speak"
        onShowEditor?("speak")
    }

    /// Read aloud in History and Library.
    func importReading(_ text: String, from origin: ReadingSelectionImport.Origin) {
        do { receiveReadingSelection(try ReadingSelectionImport(text: text, origin: origin)) }
        catch {
            page = "speak"; onShowEditor?("speak")
            report(error.localizedDescription, on: .read)
        }
    }

    /// Home's Read tile: the click is the choice. Different text replaces the
    /// reading through the same step as Replace reading, then Listen starts.
    /// The same text is not restarted: paused resumes, playing carries on.
    func listen(to text: String) {
        // Only replace the draft when the reading can start, so it never waits unheard.
        guard !meetings.isBusy else {
            report("Finish the meeting recording or transcription before playing a reading.", on: .read, from: .homeReadTileMeeting); return
        }
        guard phase == .idle else { return }
        guard canReplaceReading else { status = Self.replaceWaitsForSave; return }
        // Text the selected provider cannot read is turned away before anything changes: the
        // draft, its audio, player and playhead, and any review stay exactly as they were, and
        // nothing starts. The reason is Read's, heard at once wherever the tile was (#173).
        if let rejection = readingRejection(for: text) {
            let reason = copiedTextRefusal(rejection, text: text)
            report(reason, on: .read, from: .homeReadTileRefused)
            announceForAccessibility(reason)
            return
        }
        let setAside = pendingReadingSelection != nil
        pendingReadingSelection = nil
        if text != speechText {
            let note = endReadingForNewText()
            speechText = text
            let notes = [setAside ? "Reading the copied text instead of the text waiting for review." : nil, note].compactMap { $0 }
            if !notes.isEmpty { status = notes.joined(separator: " ") }
        }
        guard !playing else { return }
        listen()
    }

    /// Replace ends a reading that is generating, playing or paused, but waits
    /// for Save audio, which the person chose, to finish.
    var canReplaceReading: Bool { !savingAudio }
    static let replaceWaitsForSave = "Save audio is still making its file. Replace reading when it finishes."

    func replaceReadingWithSelection() {
        guard pendingReadingSelection != nil else { return }
        guard canReplaceReading, let selection = pendingReadingSelection else { status = Self.replaceWaitsForSave; return }
        applyReadingSelection(selection)
    }

    func keepCurrentReading() {
        guard let selection = pendingReadingSelection else { return }
        pendingReadingSelection = nil
        status = "Current reading kept. " + selection.origin.keptNote
    }

    func readingLimitMessage(for text: String) -> String? {
        guard text.count > readingLimit else { return nil }
        return "This text has \(text.count.formatted()) characters. \(readingProviderName) accepts up to \(readingLimit.formatted()); shorten the draft before choosing Listen or Save audio."
    }
    private var readingProviderName: String { readingProvider == .speko ? "Speko" : "Mac reading" }

    /// Why the selected provider cannot read a text (#173).
    enum ReadingRejection: Equatable {
        /// More characters than the provider accepts.
        case tooLong
        /// Within the limit as shown, but over it once prepared: Speko receives the prepared text,
        /// which can be a little longer than what is shown.
        case preparedTooLong
        /// Nothing left to say once the text is prepared for listening.
        case nothingToRead
        /// What Listen and Save audio report when the draft itself cannot be read.
        var message: String {
            switch self {
            case .tooLong, .preparedTooLong: return "This reading is too long for the selected provider."
            case .nothingToRead: return "This text has nothing to read aloud."
            }
        }
    }
    /// The one admission check every reading passes before any audio is made, any text is sent
    /// or an earlier reading ends: the provider's limit on the text as shown and, for Speko, on
    /// the prepared text, then something to read. The prepared text is made only when the text
    /// is within the limit, unless the caller already has it. Nil when the text can be read.
    func readingRejection(for text: String, prepared: ListeningText? = nil) -> ReadingRejection? {
        guard text.count <= readingLimit else { return .tooLong }
        let spoken = (prepared ?? ListeningText(text)).spoken
        guard readingProvider != .speko || spoken.count <= readingLimit else { return .preparedTooLong }
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingToRead }
        return nil
    }
    /// Home's tile read nothing: why, and that the draft it would have replaced is kept.
    private func copiedTextRefusal(_ rejection: ReadingRejection, text: String) -> String {
        let kept = "Your reading draft is unchanged."
        switch rejection {
        case .tooLong:
            return "The copied text has \(text.count.formatted()) characters, more than \(readingProviderName) accepts (\(readingLimit.formatted())). \(kept)"
        case .preparedTooLong:
            return "Prepared for listening, the copied text is longer than \(readingProviderName) accepts (\(readingLimit.formatted()) characters). \(kept)"
        case .nothingToRead:
            return "The copied text has nothing to read aloud. \(kept)"
        }
    }

    private func applyReadingSelection(_ selection: ReadingSelectionImport) {
        let note = endReadingForNewText()
        pendingReadingSelection = nil
        speechText = selection.text
        status = [readingLimitMessage(for: selection.text) ?? "\(selection.origin.name) is ready. Choose Listen to hear it.", note]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// New text ends everything the old text started, so nothing from it can
    /// land later over the new text: its generation, through the same
    /// cancellation as Cancel generation (which also stops a `say` process),
    /// then playback, progress and reusable audio. A late result from the old
    /// generation fails its generation check and is dropped. Returns Speko's
    /// billing note when an online generation stopped.
    private func endReadingForNewText() -> String? {
        clearReadingFailure()
        var note: String?
        if readingGenerationActive {
            if readingProvider == .speko { note = "Speko may still bill text already accepted." }
            cancelReading()
        } else if let task = readingTask {
            // A Listen whose generation has not begun yet.
            readingGenerationID = nil; readingTask = nil; rendering = false
            task.cancel()
        }
        invalidateAudio()
        return note
    }


    func toggleRecording(fromShortcut: Bool = false, target: TextDelivery.Target? = nil) {
        if phase == .requesting { cancelRecording(); return }
        if phase == .recording { stopRecording(); return }
        guard phase == .idle, ready, !rendering else { return }
        let intendedTarget = target ?? (fromShortcut ? TextDelivery.capture() : nil)
        if let reason = microphoneStartFailure?(intendedTarget) {
            captureFailure = reason; status = reason; return
        }
        guard admitNewCapture() else { return }
        clipboardReceipt.clear()
        captureFailure = nil; dismissCaptureCue()
        coach.remove(); holdGesture = nil
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
                catch { report(error.localizedDescription, on: .dictate) }
            }
            fail(error.localizedDescription)
        }
    }

    func stopRecording() {
        guard phase == .recording, let url = recordURL else { return }
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil; level = 0
        // The recorder ran, so a shortcut press that began this attempt can be judged.
        let gesture = recordingAttempt.flatMap { attempt in holdGesture?.attempt == attempt ? holdGesture : nil }
        holdGesture = nil
        guard duration >= CaptureCue.shortestSpeech, peakPower > -55 else {
            discardRecordingRecovery()
            let reason: CaptureCue.Reason = duration < CaptureCue.shortestSpeech ? .tooShort : .tooQuiet
            endWithoutSpeech(reason, teachesHold: HoldLesson.teaches(gesture, outcome: reason)); return
        }
        transcribe(url, duration: duration, temporary: true, settings: recordingSettings, heldShortcut: gesture != nil)
        recordingSettings = nil
    }

    func cancelRecording() {
        if phase == .requesting {
            shortcutRequest.cancel(); recordingAttempt = nil; phase = .idle; status = "Capture cancelled. Use the shortcut again when microphone permission is ready."; onPhaseChange?(); return
        }
        guard phase == .recording else { return }
        shortcutRequest.cancel()
        recordingAttempt = nil; holdGesture = nil
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

    private func transcribe(_ url: URL, duration: Double, temporary: Bool, settings: CaptureSettings? = nil, heldShortcut: Bool = false) {
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
                guard !result.isEmpty else {
                    // Silence, noise or a sound that is not speech came back as
                    // no words. Our own recording stays for Retry on Dictate.
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
                    if delivery == .paste, destination != nil, accessibilityGranted, shouldDeferDelivery?() == true {
                        waitingForDrawing = true
                        captureProcessingLabel = "Finish drawing to paste, or copy now."
                        status = "Text ready. Finish drawing to return to your Mac text field."
                        onPhaseChange?()
                        defer { waitingForDrawing = false }
                        if try await drawingDelivery.wait() == .copy { delivery = .clipboard }
                    }
                    try Task.checkCancellation()
                    guard transcriptionID == invocation else { return }
                    let outcome = await TextDelivery.deliver(result, target: destination, mode: delivery, restoreClipboard: settings.preferences.restoreClipboard)
                    guard transcriptionID == invocation else { return }
                    status = outcome.message
                    clipboardReceipt.record(outcome: outcome, wordCount: TextRules.wordCount(result))
                    undelivered.note(outcome, text: result, from: .transcript(captureID), in: deliveryRecords)
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
    func cleanCurrentDraft() {
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
            attention = nil
            status = "\(version.rawValue) saved to \(url.lastPathComponent)."
        } catch {
            report("Could not save this transcript. \(error.localizedDescription)", on: .history)
        }
    }

    private var signature: String {
        let selectedVoice = readingProvider == .speko ? selectedSpekoVoice?.requestSignature ?? "automatic" : voiceChoice?.voice?.id ?? "missing:" + voice
        return "\(readingProvider.rawValue)|\(selectedVoice)|\(Int(rate))|listening-\(ListeningText.version)|\(speechText)"
    }

    // MARK: Mac voices

    /// The chosen voice, the best default when none was chosen, or a missing choice.
    var voiceChoice: MacVoiceChoice? {
        MacVoiceCatalog.resolve(voice, in: macVoices, preferredLanguage: voiceLanguage)
            ?? MacVoiceCatalog.preferredDefault(in: macVoices, preferredLanguage: voiceLanguage).map(MacVoiceChoice.installed)
    }
    var selectedVoiceID: String { voiceChoice?.voice?.id ?? "" }
    var voiceHint: MacVoiceHint? { MacVoiceCatalog.upgradeHint(for: macVoices, preferredLanguage: voiceLanguage) }
    var missingVoiceMessage: String {
        if case .missing(let name) = voiceChoice {
            return "\(name) is not installed on this Mac. Choose another voice, or add it again in \(MacVoiceCatalog.settingsTitle) settings."
        }
        return "No Mac voice is installed. Add one in \(MacVoiceCatalog.settingsTitle) settings."
    }
    /// Loads installed voices. Launch waits for them; later refreshes (a voice
    /// added in Settings, or returning to the app) run off the main thread.
    func refreshVoices(inBackground: Bool = false) {
        let language = MacVoiceCatalog.preferredLanguage
        guard inBackground else { applyVoices(MacVoiceCatalog.installed(preferredLanguage: language), language: language); return }
        guard voiceRefresh == nil else { return }
        voiceRefresh = Task.detached(priority: .utility) { [weak self] in
            let voices = MacVoiceCatalog.installed(preferredLanguage: language)
            await self?.applyVoices(voices, language: language)
        }
    }
    private func applyVoices(_ voices: [MacVoice], language: String) {
        voiceRefresh = nil
        if voices != macVoices { macVoices = voices }
        if language != voiceLanguage { voiceLanguage = language }
    }
    func chooseVoice(_ id: String) {
        guard macVoices.contains(where: { $0.id == id }), id != voice else { return }
        stopVoicePreview()
        voice = id
    }
    func openVoiceSettings() { NSWorkspace.shared.open(MacVoiceCatalog.settingsURL) }
    /// A short sample in the chosen voice and pace, so voices can be compared.
    func toggleVoicePreview() {
        if previewingVoice { stopVoicePreview(); return }
        guard !rendering, !playing, phase == .idle, !meetings.isBusy, let voice = voiceChoice?.voice, !voice.sayOnly,
              let systemVoice = AVSpeechSynthesisVoice(identifier: voice.id) else { return }
        let utterance = AVSpeechUtterance(string: "This is \(voice.name). Here is how your readings will sound.")
        utterance.voice = systemVoice
        utterance.rate = MacVoicePace.utteranceRate(forWordsPerMinute: rate)
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        voicePreview = synthesizer
        previewingVoice = true
        synthesizer.speak(utterance)
    }
    func stopVoicePreview() {
        guard let preview = voicePreview else { return }
        voicePreview = nil
        previewingVoice = false
        preview.delegate = nil
        preview.stopSpeaking(at: .immediate)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.voicePreview === synthesizer else { return }
            self.voicePreview = nil; self.previewingVoice = false
        }
    }

    // MARK: Reading playback

    /// The text being read, with the spoken word marked, while a Mac voice plays.
    var followAlongText: String? {
        guard playing || paused, let playingTrack, playingTrack.marks != nil else { return nil }
        return playingTrack.text
    }
    func makeReadingPlayer(_ source: ReadingAudioSource) throws -> ReadingPlayer { try ReadingPlayer(source: source) }
    var canSeekReading: Bool { !rendering && (playing || paused) && player != nil && audioDuration.isFinite && audioDuration > 0 }
    func seekReading(to seconds: TimeInterval) {
        guard canSeekReading, seconds.isFinite, let player else { return }
        // Stay on the final frame that exists: a reading that is still rendering
        // can only move within what is ready, and a paused reading stays paused.
        let lastFrame = max(0, player.duration - 1 / max(1, player.sampleRate))
        player.currentTime = min(max(0, seconds), lastFrame)
        playbackTime = player.currentTime
        showReadingPosition(player)
    }
    func skipReading(by seconds: TimeInterval) {
        guard seconds.isFinite, let player else { return }
        seekReading(to: player.currentTime + seconds)
    }
    func listen() {
        guard !meetings.isBusy else { report("Finish the meeting recording or transcription before playing a reading.", on: .read); return }
        guard !rendering, phase == .idle else { return }
        stopVoicePreview()
        clearReadingFailure()
        if playing {
            player?.pause(); playbackTime = player?.currentTime ?? 0
            playing = false; paused = true; status = "Reading paused."; return
        }
        if paused, signature == audioSignature, let player, player.source === audio?.source {
            guard player.play() else {
                stopPlayback(); report("Audio could not resume. Check your Mac's audio output.", on: .read); return
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
                let track = try await generateAudio(generationID: generationID)
                try Task.checkCancellation()
                guard readingGenerationID == generationID else { throw CancellationError() }
                let activePlayer = try makeReadingPlayer(track.source)
                activePlayer.onFinish = { [weak self] finished, success in self?.readingPlayerDidFinish(finished, successfully: success) }
                try Task.checkCancellation()
                guard readingGenerationID == generationID else { throw CancellationError() }
                guard activePlayer.play() else { throw VoiceError.message("Audio could not play. Check your Mac's audio output.") }
                player = activePlayer; playingTrack = track
                renderingAhead = track.isRendering
                let invocation = UUID(); playbackID = invocation
                playing = true; audioDuration = activePlayer.duration; status = "Reading aloud."
                // The playback clock, not rendering, drives the elapsed time and
                // the highlighted word. Common modes keep it running while the
                // scrubber is dragged.
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.playbackID == invocation, let activePlayer = self.player else { return }
                        self.followPlayback(activePlayer)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                playTimer = timer
            } catch {
                if !(error is CancellationError), readingGenerationID == generationID { report(error.localizedDescription, on: .read) }
            }
        }
    }
    private func followPlayback(_ activePlayer: ReadingPlayer) {
        activePlayer.tick()
        guard player === activePlayer else { return }
        let time = activePlayer.currentTime
        if abs(time - playbackTime) >= 0.1 || (!playing && time != playbackTime) { playbackTime = time }
        if activePlayer.duration != audioDuration { audioDuration = activePlayer.duration }
        showReadingPosition(activePlayer)
    }
    private func showReadingPosition(_ activePlayer: ReadingPlayer) {
        let range = playingTrack?.marks?.range(at: activePlayer.positionFrame)
        if range != readingHighlight { readingHighlight = range }
    }
    /// Returns audio for the current signature: reused, or newly made. A Mac
    /// voice returns as soon as the first audio exists and keeps rendering the
    /// rest into the same file; `complete` waits for all of it.
    private func generateAudio(generationID: UUID, complete: Bool = false) async throws -> ReadingTrack {
        if let audio, signature == audioSignature, audio.isComplete || (!complete && audio.isRendering) { return audio }
        guard readingGenerationID == generationID else { throw CancellationError() }
        rendering = true; readingGenerationActive = true; attention = nil
        let text = speechText, prepared = ListeningText(text), selectedChoice = voiceChoice, selectedSpekoVoice = self.selectedSpekoVoice, selectedRate = rate, selectedProvider = readingProvider, originalSignature = signature
        // The same admission Home's tile runs before it replaces the draft (#173).
        if let rejection = readingRejection(for: text, prepared: prepared) { throw VoiceError.message(rejection.message) }
        defer {
            if readingGenerationID == generationID {
                readingGenerationActive = false; cloudRequestActive = false
            }
        }
        let url: URL
        if selectedProvider == .speko {
            let key = try SpekoKeychain.read()
            cloudRequestActive = true
            url = try await SpekoRenderer.render(text: prepared.spoken, key: key, voice: selectedSpekoVoice)
        } else {
            guard let voice = selectedChoice?.voice else { throw VoiceError.message(missingVoiceMessage) }
            if !voice.sayOnly {
                return try await streamMacVoice(voice, text: text, prepared: prepared, rate: selectedRate, signature: originalSignature,
                                                generationID: generationID, complete: complete)
            }
            url = try await AudioRenderer.renderCancellable(text: prepared.spoken, voice: voice.sayName, rate: Int(selectedRate))
        }
        do {
            try Task.checkCancellation()
            guard readingGenerationID == generationID else { throw CancellationError() }
            let track = ReadingTrack(url: url, source: try ReadingFileSource(url: url), text: text, signature: originalSignature)
            keepAudio(track)
            return track
        } catch {
            AudioRenderer.remove(url); throw error
        }
    }
    private func streamMacVoice(_ voice: MacVoice, text: String, prepared: ListeningText, rate: Double, signature: String,
                                generationID: UUID, complete: Bool) async throws -> ReadingTrack {
        let render = try MacSpeechRenderer(text: prepared)
        pendingRender?.cancel()
        pendingRender = render
        defer { if pendingRender === render { pendingRender = nil } }
        // Late callbacks from a replaced or stopped render never reach newer audio.
        render.onAudio = { [weak self, weak render] in
            guard let self, let render, let player = self.player, self.playingTrack?.renderer === render, player.isWaitingForAudio else { return }
            player.tick()
        }
        render.onFinish = { [weak self, weak render] failure in
            guard let self, let render, let track = self.audio, track.renderer === render else { return }
            if let failure {
                // Audio that stopped partway cannot be replayed or saved.
                if self.playingTrack === track { self.stopPlayback() }
                track.discard(); if self.audio === track { self.audio = nil }
                self.report(failure.localizedDescription, on: .read)
            } else {
                track.finishedRendering()
                if self.playingTrack === track { self.renderingAhead = false; self.player?.tick() }
            }
        }
        do {
            try render.start(voiceIdentifier: voice.id, rate: MacVoicePace.utteranceRate(forWordsPerMinute: rate))
            try await render.ready(complete: complete)
            try Task.checkCancellation()
            guard readingGenerationID == generationID, pendingRender === render, let file = render.audio else { throw CancellationError() }
            let track = ReadingTrack(url: file.url, source: file, text: text, signature: signature, renderer: render)
            keepAudio(track)
            return track
        } catch {
            render.cancel()
            throw error
        }
    }
    /// The newest audio replaces the reusable copy; audio still playing stays
    /// readable until its player stops.
    private func keepAudio(_ track: ReadingTrack) {
        if let previous = audio, previous !== playingTrack { previous.discard() }
        audio = track
    }
    var canSaveAudio: Bool { !rendering && !renderingAhead && !speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func saveAudio() {
        guard canSaveAudio else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Audio]; panel.nameFieldStringValue = "Reading.m4a"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        saveAudio(to: destination)
    }
    /// The save the person chose. Replace and Home's Read tile wait for it
    /// rather than cancel it; only Cancel generation ends it early.
    func saveAudio(to destination: URL) {
        guard canSaveAudio else { return }
        let generationID = UUID()
        readingGenerationID = generationID
        savingAudioID = generationID
        rendering = true
        readingTask = Task {
            defer {
                if savingAudioID == generationID { savingAudioID = nil }
                if readingGenerationID == generationID {
                    rendering = false; readingGenerationActive = false; cloudRequestActive = false
                    readingTask = nil; readingGenerationID = nil
                }
            }
            do {
                let url = try await generateAudio(generationID: generationID, complete: true).url
                try Task.checkCancellation()
                guard readingGenerationID == generationID else { throw CancellationError() }
                try await AudioRenderer.exportBounded(url, to: destination)
                try Task.checkCancellation()
                guard readingGenerationID == generationID else { throw CancellationError() }
                status = "Audio saved to \(destination.lastPathComponent)."
            } catch {
                if !(error is CancellationError), readingGenerationID == generationID { report(error.localizedDescription, on: .read) }
            }
        }
    }
    func stopPlayback() {
        let wasActive = playing || paused
        player?.stop(); player = nil; playing = false; paused = false; playbackTime = 0; audioDuration = 0
        playTimer?.invalidate(); playTimer = nil; playbackID = nil
        readingHighlight = nil
        stopVoicePreview()
        if let render = pendingRender { pendingRender = nil; render.cancel() }
        // Audio a Mac voice has not finished cannot be reused: discard it.
        if let track = playingTrack, track.isRendering {
            track.discard()
            if audio === track { audio = nil }
        } else if let track = playingTrack, track !== audio {
            track.discard()
        }
        playingTrack = nil; renderingAhead = false
        if wasActive { status = "Reading stopped." }
    }
    /// Why a reading stopped early. Read shows it beside Listen with Retry, and
    /// the panel and other pages show its message, until Listen, Retry, a
    /// replaced draft or Dismiss clears it. A later, unrelated error does not.
    enum ReadingFailure: Equatable {
        case audioUnreadable
        var message: String { "The reading stopped because its audio could not be read. Try again to make new audio." }
    }
    var canRetryReading: Bool { readingFailure != nil && phase == .idle && !rendering && !playing && !paused }
    func retryReading() {
        guard canRetryReading else { return }
        listen()
    }
    func reportReadingFailure(_ failure: ReadingFailure) {
        readingFailure = failure
        report(failure.message, on: .read)
        announceForAccessibility(failure.message)
    }
    /// Dismiss beside Retry: the reading stays stopped, with its text and voice.
    func dismissReadingFailure() { clearReadingFailure() }
    /// Raises a problem with the page that shows it in full (#134): the menu-bar panel's door
    /// opens that page, so it is chosen here, where the problem is known, never from the words.
    /// `origin` names a control that also shows it beside itself; only Home's Read tile does (#173).
    func report(_ message: String, on page: Attention.Page, from origin: Attention.Origin? = nil) {
        attention = Attention(message: message, page: page, origin: origin)
    }
    /// The error banner's dismiss, which also dismisses a reading failure it shows.
    func dismissError() {
        if let failure = readingFailure, error == failure.message { readingFailure = nil }
        attention = nil
    }
    private func clearReadingFailure() {
        guard let failure = readingFailure else { return }
        if error == failure.message { attention = nil }
        readingFailure = nil
    }
    func readingPlayerDidFinish(_ finished: ReadingPlayer, successfully flag: Bool) {
        guard self.player === finished else { return }
        let track = playingTrack
        stopPlayback()
        guard finished.readFailure == nil else {
            // Audio that could not be read is not reused: Retry or Listen makes
            // it again. The text, voice and pace stay as they were.
            if let track, audio === track { track.discard(); audio = nil }
            reportReadingFailure(.audioUnreadable)
            return
        }
        status = flag ? "Finished reading." : "Playback interrupted."
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.cancelRecording()
            let message = error?.localizedDescription ?? "Recording was interrupted. Please try again."
            self.captureFailure = message; self.fail(message)
        }
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
        report(text, on: .dictate); phase = .idle; status = "Needs attention"; onPhaseChange?()
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
            fail("No speech heard twice in a row. Check the input in System Settings → Sound, and open the lid of a MacBook.")
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
        meetings.shutdown(); handoffJobs.shutdown()
        photoHandoffRefresh?.cancel(); photoHandoffActivation = nil; readingTask?.cancel()
        shortcutRequest.cancel(); transcriptionTask?.cancel(); transcriptionID = nil; recordingAttempt = nil
        clipboardReceipt.clear(); coach.remove(); recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil
        stopPlayback(); saveNow(); AudioRenderer.remove(audioURL)
        // Quit stops work. Only a durable capture commit or explicit Cancel may
        // delete the owned audio/journal; the next launch discovers unfinished work.
    }
}
