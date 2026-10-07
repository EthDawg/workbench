import AppKit
import AVFoundation
import Combine

// Report a problem (#296): the composer's one owner. AppDelegate creates one, supplies the
// window, capture, microphone admission and context closures, and opens it from Help and from
// Dictate and Snap problems. The draft and outbox belong to BugReportStore; delivery to
// BugReportTransport.

/// A voice note recorder. The app uses AVAudioRecorder; checks and the gallery supply none.
@MainActor
protocol BugReportRecording: AnyObject {
    var isRecording: Bool { get }
    var elapsed: TimeInterval { get }
    /// Called when the 60-second cap or the device ends the recording.
    var onFinish: (() -> Void)? { get set }
    func start(to url: URL) throws
    func stop()
}

/// Mono 16 kHz 16-bit PCM, the settings Snap & Talk narration already records with.
@MainActor
final class BugReportRecorder: NSObject, BugReportRecording, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    var onFinish: (() -> Void)?
    var isRecording: Bool { recorder?.isRecording == true }
    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    func start(to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.prepareToRecord(), recorder.record(forDuration: TimeInterval(BugReportLimits.voiceSeconds)) else {
            throw BugReportError.message("The microphone could not start. Check that an input device is connected.")
        }
        self.recorder = recorder
    }

    func stop() { recorder?.stop(); recorder = nil }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.onFinish?() }
    }
}

/// What a receipt says and offers, derived from the delivery's saved state.
struct BugReportReceipt: Identifiable, Equatable {
    enum Tone { case progress, done, problem }
    enum Action: Equatable { case retry, sendAgain, sendAttachmentsAgain, saveCopy, remove }
    var id: String
    var title: String
    var detail: String
    var tone: Tone
    var actions: [Action]
}

@MainActor
final class BugReportModel: ObservableObject {
    struct Services {
        /// Safe context, read synchronously when the composer opens, before focus moves.
        var context: (BugReportOrigin) -> BugReportContext = { BugReportContext(surface: $0.surface, errorCode: $0.errorCode) }
        var build: () -> BugReportBuild = { .running() }
        var now: () -> Date = Date.init
        /// Why a screenshot cannot start now, such as another capture in progress.
        var screenshotAdmission: () -> String? = { nil }
        /// Screen Recording, read passively: the composer never prompts mid-report, and never
        /// captures without it (macOS would return only the desktop picture).
        var screenCaptureGranted: () -> Bool = { CGPreflightScreenCaptureAccess() }
        var openScreenCaptureSettings: () -> Void = { NSWorkspace.shared.open(ScreenCaptureAccess.settingsURL) }
        /// Region capture with only the report window hidden. Nil when cancelled.
        var captureScreenshot: @MainActor () async throws -> BugReportImage? = { nil }
        var cancelScreenshot: () -> Void = {}
        var chooseImage: () -> URL? = { nil }
        var chooseFolder: () -> URL? = { nil }
        var reveal: (URL) -> Void = { _ in }
        /// Why the microphone cannot start now: the shared admission with Dictate, Meetings and Snap & Talk.
        var microphoneAdmission: () -> String? = { nil }
        var microphoneStatus: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
        var requestMicrophone: @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
        var openMicrophoneSettings: () -> Void = {}
        /// True only when the selected speech engine is already ready and idle; never a download or a switch.
        var transcriptionReady: () -> Bool = { false }
        var transcribe: @MainActor (URL) async throws -> String = { _ in throw BugReportError.message("Speech is not ready.") }
        var announce: @MainActor (String) -> Void = { FeedbackAnnouncement.post($0) }
        /// The report's busy state changed: recording or capturing started or ended.
        var onBusyChange: () -> Void = {}
        /// Reads the edition's destination again when the composer opens; nil keeps the initial one.
        var currentDestination: (() -> BugReportDestination?)?
    }
    enum ProblemAction: Equatable { case chooseImage, screenAccess, microphoneSettings, saveCopy }
    static let screenAccessOff = "Screen Recording is off for Workbench, so it can't take a screenshot. Choose an image you already have, or allow Workbench under Privacy & Security › Screen Recording."

    let store: BugReportStore
    let transport: BugReportTransport
    /// Where Send goes now. Read again each time the composer opens, so a developer override set
    /// with `defaults write` applies without a rebuild or relaunch.
    @Published private(set) var destination: BugReportDestination?
    var services: Services
    private let recorder: BugReportRecording?

    @Published var explanation = "" { didSet { if explanation != oldValue { textChanged() } } }
    @Published var replyEmail = "" { didSet { if replyEmail != oldValue { textChanged() } } }
    @Published private(set) var screenshot: BugReportImageInfo?
    @Published private(set) var screenshotPreview: NSImage?
    @Published private(set) var voiceSeconds: Double?
    @Published private(set) var recording = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var playing = false
    @Published private(set) var capturing = false
    @Published private(set) var transcribing = false
    @Published private(set) var transcript: String?
    @Published private(set) var problem: String?
    @Published private(set) var problemAction: ProblemAction?
    /// A screenshot or voice note problem shows beside those controls, where the person acted.
    @Published private(set) var problemNearEvidence = false
    /// A quiet line after an action that worked, such as Save a copy.
    @Published private(set) var note: String?
    @Published private(set) var sending = false
    /// The draft's origin and context, recorded when the composer opened.
    @Published private(set) var draft: BugReportDraft?
    private var saveTask: Task<Void, Never>?
    private var meter: Timer?
    private var player: AVAudioPlayer?
    private var playerDelegate: BugReportPlayerDelegate?
    private var transportObservation: AnyCancellable?
    private var screenshotDescriptor: BugReportAttachment?
    private var voiceDescriptor: BugReportAttachment?

    init(store: BugReportStore, transport: BugReportTransport, destination: BugReportDestination?,
         recorder: BugReportRecording? = nil, services: Services = Services()) {
        self.store = store; self.transport = transport; self.destination = destination
        self.recorder = recorder; self.services = services
        if let saved = store.loadDraft() {
            draft = saved
            explanation = saved.explanation; replyEmail = saved.replyEmail
            screenshot = saved.screenshot; voiceSeconds = saved.voiceSeconds
            let shot = saved.screenshot != nil ? store.draftScreenshot() : nil
            screenshotPreview = shot.flatMap(NSImage.init(data:))
            screenshotDescriptor = shot.map { BugReportAttachment(name: BugReportAttachment.screenshot, data: $0) }
            voiceDescriptor = saved.voiceSeconds != nil ? store.draftVoice().map { BugReportAttachment(name: BugReportAttachment.voice, data: $0) } : nil
        }
        recorder?.onFinish = { [weak self] in self?.stopRecording() }
        transportObservation = transport.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: State

    /// Sending is part of this build. Without a configured inbox the composer offers Save a copy.
    var available: Bool { destination != nil }
    var isBusy: Bool { recording || capturing }
    var hasAttachments: Bool { screenshot != nil || voiceSeconds != nil }
    var explanationProblem: String? { BugReportText.explanationProblem(explanation) }
    var emailProblem: String? {
        let email = replyEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : BugReportText.emailProblem(email)
    }
    /// The live counter, from 90% of the limit, in the code points the limit counts.
    var counter: String? {
        let count = explanation.unicodeScalars.count
        return count >= BugReportLimits.explanationCounterFrom || explanation.utf8.count > BugReportLimits.explanationBytes
            ? "\(count.formatted()) / \(BugReportLimits.explanationScalars.formatted())" : nil
    }
    var hasContent: Bool { BugReportText.hasVisibleText(explanation) || hasAttachments }
    var canSubmit: Bool { hasContent && explanationProblem == nil && emailProblem == nil && !sending && !isBusy }
    var canSend: Bool { available && canSubmit }

    /// One sentence naming what goes, as the inclusion summary.
    var inclusionSummary: String {
        var parts: [String] = []
        if BugReportText.hasVisibleText(explanation) { parts.append("your description") }
        if screenshot != nil { parts.append("the screenshot") }
        if voiceSeconds != nil { parts.append("the voice recording") }
        if !replyEmail.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("your email address") }
        guard !parts.isEmpty else { return "Add words, a screenshot or a voice note. Safe details about this build go with it." }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "It includes \(list), with the safe details below."
    }

    /// The exact context.json this draft would freeze now, pretty-printed for Details.
    var detailsJSON: String {
        guard let draft = currentDraft().map(refreshed) else { return "" }
        var manifest = manifest(for: draft, reportID: "00000000-0000-4000-8000-000000000000", screenshot: nil, voice: nil)
        // Descriptors are computed once per file, not on every keystroke.
        manifest.attachments = [screenshot != nil ? screenshotDescriptor : nil, voiceSeconds != nil ? voiceDescriptor : nil].compactMap { $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: manifest.object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Unsent and words-only reports, then the newest other delivered one.
    var receipts: [BugReportReceipt] {
        let all = transport.deliveries
        let unsent = all.filter { $0.isUnsent || $0.wordsOnly }
        let delivered = all.first { !$0.isUnsent && !$0.wordsOnly }
        return (unsent + (delivered.map { [$0] } ?? [])).map(receipt)
    }

    func receipt(_ delivery: BugReportDelivery) -> BugReportReceipt {
        let short = delivery.shortID
        let keeps = "The team keeps reports for up to 90 days. To have it deleted sooner, send a report that asks and quotes \(short)."
        if transport.active.contains(delivery.id), [.waiting, .sending].contains(delivery.state) {
            return .init(id: delivery.id, title: "Sending…", detail: "Saved on this Mac until it's delivered.", tone: .progress, actions: [.saveCopy, .remove])
        }
        switch delivery.state {
        case .waiting where delivery.problem != .offline:
            // Frozen and about to go: it has not met a missing connection.
            return .init(id: delivery.id, title: "Sending…", detail: "Saved on this Mac until it's delivered.", tone: .progress, actions: [.saveCopy, .remove])
        case .waiting:
            return .init(id: delivery.id, title: "Waiting for connection",
                         detail: "Saved on this Mac. It sends by itself when you're back online, even after a restart.", tone: .progress, actions: [.saveCopy, .remove])
        case .sending:
            let when = delivery.nextAttemptAt.map { " It tries again at \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
            let why = delivery.problem == .rateLimited ? "The team's inbox asked Workbench to wait." : "The team's inbox didn't answer."
            return .init(id: delivery.id, title: "Sending…", detail: why + when, tone: .progress, actions: [.saveCopy, .remove])
        case .sent where delivery.wordsOnly:
            let files = [delivery.contents.contains("screenshot") ? "screenshot" : nil, delivery.contents.contains("voice") ? "voice note" : nil].compactMap { $0 }
            let missing = files.isEmpty ? "The report's details couldn't go with it." : "The \(files.joined(separator: " and ")) couldn't go with it."
            return .init(id: delivery.id, title: "Sent · words only · \(short)",
                         detail: "Your words reached the Workbench team. \(missing) Send attachments again sends them as a new copy of report \(short).",
                         tone: .problem, actions: [.sendAttachmentsAgain, .saveCopy, .remove])
        case .sent:
            let confirming = delivery.nextAttemptAt != nil && delivery.destination.verifier != nil
            return .init(id: delivery.id, title: "Sent · \(short)",
                         detail: (confirming ? "Checking that it arrived. " : "Sent to the Workbench team's private inbox. ") + keeps,
                         tone: .done, actions: delivery.evidenceRemoved ? [.remove] : [.saveCopy, .remove])
        case .received:
            return .init(id: delivery.id, title: "Received · \(short)", detail: "The Workbench team has your report. " + keeps, tone: .done, actions: [.remove])
        case .unconfirmed:
            let detail = delivery.problem == .uncertain
                ? "Workbench lost touch with the team's inbox while sending report \(short), so it may already have arrived. Send again sends it once more."
                : "The team's inbox didn't confirm report \(short) arrived. Send again sends the same report once more."
            return .init(id: delivery.id, title: "Couldn't confirm delivery", detail: detail, tone: .problem, actions: [.sendAgain, .saveCopy, .remove])
        case .failed:
            let detail: String
            var actions: [BugReportReceipt.Action] = [.retry, .saveCopy, .remove]
            switch delivery.problem {
            case .tooLarge:
                detail = "The report is larger than the team's inbox accepts. Save a copy, then send a shorter one, for example without the voice note."
                actions = [.saveCopy, .remove]
            case .secureConnection:
                detail = "Workbench couldn't make a secure connection, so nothing was sent. Check the network, then retry."
            case .unauthorized:
                detail = "The team's inbox turned this build away. Retry later, or save a copy."
            case .unreadable:
                detail = "The saved report couldn't be read, so it wasn't sent."
                actions = [.remove]
            default:
                detail = "The team's inbox didn't accept this report. Retry, or save a copy."
            }
            return .init(id: delivery.id, title: "Couldn't deliver", detail: detail, tone: .problem, actions: actions)
        }
    }

    // MARK: Opening

    /// Opens the composer's owner from a door. Context is recorded now, before focus changes.
    /// No capture, recording or permission request starts. The unfinished draft resumes; an empty
    /// one takes the newest origin, and a non-empty one keeps its own unless it had no problem code.
    func open(origin: BugReportOrigin) {
        let context = services.context(origin)
        let fresh = BugReportDraft(origin: origin, context: context, build: services.build(), createdAt: services.now())
        if var current = draft {
            if current.isEmpty && explanation.isEmpty && replyEmail.isEmpty && !hasAttachments {
                current = fresh
            } else if current.origin.errorCode == nil, origin.errorCode != nil {
                current.origin = origin; current.context.surface = context.surface; current.context.errorCode = context.errorCode
            }
            draft = current
        } else {
            draft = fresh
        }
        problem = nil; problemAction = nil; note = nil
        if let currentDestination = services.currentDestination { destination = currentDestination() }
        transport.reload()
    }

    /// The draft as it would be sent now: the running build and the current permission,
    /// recognition and active-tool facts, keeping the origin's surface and problem code.
    private func refreshed(_ draft: BugReportDraft) -> BugReportDraft {
        // The report describes the moment the person chose to report: the build, active tools,
        // surface and problem code stay as recorded when the composer opened, even in a later
        // launch. Only access and speech readiness, which the person may have just fixed, are read again.
        var draft = draft
        let now = services.context(draft.origin)
        draft.context.microphone = now.microphone
        draft.context.screenCapture = now.screenCapture
        draft.context.accessibility = now.accessibility
        draft.context.recognitionProvider = now.recognitionProvider
        draft.context.recognitionReady = now.recognitionReady
        return draft
    }

    private func currentDraft() -> BugReportDraft? {
        guard var draft else { return nil }
        draft.explanation = explanation
        draft.replyEmail = replyEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.screenshot = screenshot; draft.voiceSeconds = voiceSeconds
        return draft
    }

    private func textChanged() {
        note = nil
        if problemAction == nil { problem = nil }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Saves the draft, or removes it when empty, so closing an empty composer leaves nothing.
    func persist() {
        saveTask?.cancel(); saveTask = nil
        guard let draft = currentDraft() else { return }
        do {
            // A voice note being recorded lives in the draft folder before it counts as content.
            if draft.isEmpty { if !recording { try store.clearDraft() } } else { try store.saveDraft(draft) }
        } catch { problem = "Your draft couldn't be saved on this Mac. Keep this window open, or save a copy." }
    }

    // MARK: Screenshot

    func addScreenshot() async {
        guard !capturing, !recording else { return }
        if let reason = services.screenshotAdmission() { show(reason, nearEvidence: true); return }
        guard services.screenCaptureGranted() else { show(Self.screenAccessOff, action: .screenAccess, nearEvidence: true); return }
        capturing = true; services.onBusyChange()
        problem = nil; problemAction = nil; note = nil
        defer { capturing = false; services.onBusyChange() }
        do {
            guard let image = try await services.captureScreenshot() else { return }
            try setScreenshot(image)
        } catch {
            show(error.localizedDescription + " You can choose an image instead.", action: .chooseImage, nearEvidence: true)
        }
    }

    func chooseImage() {
        guard !capturing, let url = services.chooseImage() else { return }
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
            guard size <= BugReportLimits.importBytes else { throw BugReportError.message("Choose a PNG or JPEG image under 25 MB and 40 megapixels.") }
            try setScreenshot(try BugReportMedia.image(try Data(contentsOf: url), scale: 1, sourceLimit: BugReportLimits.importBytes))
            problem = nil; problemAction = nil
        } catch { show(error.localizedDescription, nearEvidence: true) }
    }

    func setScreenshot(_ image: BugReportImage) throws {
        try store.setDraftScreenshot(image.png)
        screenshotDescriptor = BugReportAttachment(name: BugReportAttachment.screenshot, data: image.png)
        screenshot = image.info
        screenshotPreview = NSImage(data: image.png)
        persist()
    }

    func removeScreenshot() {
        try? store.setDraftScreenshot(nil)
        screenshot = nil; screenshotPreview = nil
        persist()
    }

    // MARK: Voice note

    func toggleRecording() async {
        if recording { stopRecording(); return }
        guard !capturing, let recorder else { return }
        stopPlayback()
        if let reason = services.microphoneAdmission() { show(reason, nearEvidence: true); return }
        switch services.microphoneStatus() {
        case .authorized: break
        case .notDetermined:
            guard await services.requestMicrophone(), services.microphoneStatus() == .authorized else {
                show("Microphone access is off for Workbench. You can still send words and a screenshot.", action: .microphoneSettings, nearEvidence: true); return
            }
            if let reason = services.microphoneAdmission() { show(reason, nearEvidence: true); return }
        default:
            show("Microphone access is off for Workbench. You can still send words and a screenshot.", action: .microphoneSettings, nearEvidence: true); return
        }
        do {
            try recorder.start(to: try store.prepareRecording())
        } catch {
            show("The microphone could not start. Check that an input device is connected; your words and screenshot are kept.", nearEvidence: true); return
        }
        recording = true; recordingElapsed = 0; transcript = nil
        problem = nil; problemAction = nil; note = nil
        services.onBusyChange()
        meter = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.recordingElapsed = min(TimeInterval(BugReportLimits.voiceSeconds), self.recorder?.elapsed ?? 0)
            }
        }
    }

    /// Stops and keeps the recording as the draft's voice.wav. Safe to call twice.
    func stopRecording() {
        guard recording else { return }
        recorder?.stop()
        recording = false; meter?.invalidate(); meter = nil
        defer { try? FileManager.default.removeItem(at: store.recordingURL); services.onBusyChange() }
        do {
            try setVoice(try BugReportFiles.read(store.recordingURL, maximum: 64 * 1_024 * 1_024))
        } catch {
            show((error as? BugReportError)?.errorDescription ?? "The voice note couldn't be kept. Record it again.", nearEvidence: true)
        }
    }

    /// Keeps a recording as the draft's canonical voice.wav, cut at 60 seconds.
    func setVoice(_ recording: Data) throws {
        let (wav, seconds) = try BugReportMedia.canonicalWAV(recording)
        try store.setDraftVoice(wav)
        voiceDescriptor = BugReportAttachment(name: BugReportAttachment.voice, data: wav)
        voiceSeconds = seconds; transcript = nil
        persist()
    }

    func removeVoice() {
        stopPlayback()
        try? store.setDraftVoice(nil)
        voiceSeconds = nil; transcript = nil
        persist()
    }

    func togglePlayback() {
        if playing { stopPlayback(); return }
        guard let data = store.draftVoice(), let player = try? AVAudioPlayer(data: data) else { show("The voice note couldn't be played.", nearEvidence: true); return }
        let delegate = BugReportPlayerDelegate { [weak self] in self?.stopPlayback() }
        player.delegate = delegate
        self.player = player; playerDelegate = delegate
        playing = player.play()
    }

    func stopPlayback() {
        player?.stop(); player = nil; playerDelegate = nil; playing = false
    }

    var canTranscribe: Bool { voiceSeconds != nil && !recording && !transcribing && transcript == nil && services.transcriptionReady() }

    /// Uses the selected speech engine only when it is already ready. The result is offered for
    /// review; typing continues meanwhile and nothing is replaced.
    func transcribeVoice() async {
        guard canTranscribe else { return }
        transcribing = true
        defer { transcribing = false }
        do {
            let text = try await services.transcribe(store.draftFolder.appendingPathComponent(BugReportAttachment.voice))
            transcript = text.isEmpty ? nil : text
            if text.isEmpty { show("No words were recognised in the voice note. The recording is still attached.", nearEvidence: true) }
        } catch { show("The voice note couldn't be transcribed. The recording is still attached.", nearEvidence: true) }
    }

    func addTranscript() {
        guard let transcript else { return }
        explanation += (BugReportText.hasVisibleText(explanation) ? "\n\n" : "") + transcript
        self.transcript = nil
    }

    // MARK: Send

    func manifest(for draft: BugReportDraft, reportID: String, screenshot: Data?, voice: Data?) -> BugReportManifest {
        let attachments = [screenshot.map { BugReportAttachment(name: BugReportAttachment.screenshot, data: $0) },
                           voice.map { BugReportAttachment(name: BugReportAttachment.voice, data: $0) }].compactMap { $0 }
        return BugReportManifest(reportID: reportID, createdAt: draft.createdAt, explanation: draft.explanation,
                                 replyEmail: draft.replyEmail.isEmpty ? nil : draft.replyEmail, build: draft.build,
                                 context: draft.context, screenshot: draft.screenshot, attachments: attachments)
    }

    /// The frozen files this draft holds, checked again before they are used.
    private func evidence() throws -> (screenshot: Data?, voice: Data?) {
        var shot: Data?, voice: Data?
        if let info = screenshot {
            guard let data = store.draftScreenshot(), let size = try? BugReportMedia.pngSize(data), size.width == info.width, size.height == info.height else {
                throw BugReportError.message("The screenshot couldn't be read. Remove it and add it again.")
            }
            shot = data
        }
        if voiceSeconds != nil {
            guard let data = store.draftVoice(), (try? BugReportMedia.wavSeconds(data)) != nil else {
                throw BugReportError.message("The voice note couldn't be read. Remove it and record it again.")
            }
            voice = data
        }
        return (shot, voice)
    }

    /// Freezes this draft into one envelope in the outbox, then starts delivery. The click
    /// authorises this report's upload and retries, nothing more.
    func send() {
        guard canSend, let destination, let draft = currentDraft().map(refreshed) else { return }
        sending = true
        defer { sending = false }
        problem = nil; problemAction = nil; note = nil
        do {
            let files = try evidence()
            let reportID = BugReportManifest.newReportID()
            let manifestData = try manifest(for: draft, reportID: reportID, screenshot: files.screenshot, voice: files.voice).encoded()
            let eventID = BugReportEnvelope.newEventID()
            let now = services.now()
            let envelope = try BugReportEnvelope.frozen(manifest: manifestData, screenshot: files.screenshot, voice: files.voice,
                                                        eventID: eventID, destination: destination, timestamp: now)
            try store.freeze(envelope: envelope, delivery: BugReportDelivery(id: reportID, eventID: eventID, destination: destination,
                envelopeSHA256: BugReportText.sha256(envelope), envelopeBytes: envelope.count,
                files: BugReportEnvelope.verifierFiles(try BugReportEnvelope.parse(envelope).items), contents: draft.contents,
                state: .waiting, nextAttemptAt: now, createdAt: now))
            // The report is in the outbox; the draft is done. The composer stays open on its
            // receipt, so what the person writes next is a new report from the same place,
            // without the first one's problem code.
            try? store.clearDraft()
            let next = BugReportOrigin(surface: draft.origin.surface, errorCode: nil)
            self.draft = BugReportDraft(origin: next, context: services.context(next), build: services.build(), createdAt: services.now())
            explanation = ""; replyEmail = ""; screenshot = nil; screenshotPreview = nil; voiceSeconds = nil; transcript = nil
            saveTask?.cancel(); saveTask = nil
            transport.added()
            services.announce("Report saved. Sending.")
        } catch BugReportError.full(let message) {
            show(message, action: .saveCopy)
        } catch {
            show((error as? BugReportError)?.errorDescription ?? "The report couldn't be saved, so nothing was sent. Your draft is kept.")
        }
    }

    // MARK: Save a copy

    /// Save a copy of the draft: a new folder with context.json, screenshot.png and voice.wav.
    func saveDraftCopy() {
        guard canSubmit, let draft = currentDraft().map(refreshed) else { return }
        do {
            let files = try evidence()
            let reportID = BugReportManifest.newReportID()
            let data = try manifest(for: draft, reportID: reportID, screenshot: files.screenshot, voice: files.voice).encoded()
            guard let parent = services.chooseFolder() else { return }
            let folder = try store.export(manifest: data, screenshot: files.screenshot, voice: files.voice, shortID: BugReportText.shortID(reportID), to: parent)
            saved(folder)
        } catch { show((error as? BugReportError)?.errorDescription ?? "A copy couldn't be saved.") }
    }

    func perform(_ action: BugReportReceipt.Action, on id: String) {
        switch action {
        case .retry: transport.retry(id)
        case .sendAgain, .sendAttachmentsAgain:
            do { try transport.sendAgain(id) } catch { show((error as? BugReportError)?.errorDescription ?? "The report couldn't be sent again.") }
        case .saveCopy:
            guard let parent = services.chooseFolder() else { return }
            do { saved(try store.export(id, to: parent)) } catch { show((error as? BugReportError)?.errorDescription ?? "A copy couldn't be saved.") }
        case .remove:
            do { try transport.remove(id) } catch { show("The report couldn't be removed from this Mac.") }
        }
    }

    private func saved(_ folder: URL) {
        problem = nil; problemAction = nil
        note = "Saved a copy in “\(folder.lastPathComponent)”."
        services.announce(note ?? "")
        services.reveal(folder)
    }

    private func show(_ message: String, action: ProblemAction? = nil, nearEvidence: Bool = false) {
        problem = message; problemAction = action; problemNearEvidence = nearEvidence; note = nil
    }

    /// Quit or update: keep a recording in progress and the typed words. Delivery needs nothing;
    /// it resumes at the next launch.
    func shutdown() {
        if recording { stopRecording() }
        if capturing { services.cancelScreenshot() }
        stopPlayback()
        persist()
        transport.stop()
    }
}

private final class BugReportPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let finished: @MainActor () -> Void
    init(_ finished: @escaping @MainActor () -> Void) { self.finished = finished }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }
}
