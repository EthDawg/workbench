import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import SwiftUI

enum ReadbackSectionStatus: String, Codable, CaseIterable {
    case needsNarration
    case recording
    case queued
    case transcribing
    case ready
    case failed

    var title: String {
        switch self {
        case .needsNarration: "Needs narration"
        case .recording: "Recording"
        case .queued: "Queued"
        case .transcribing: "Transcribing"
        case .ready: "Ready"
        case .failed: "Needs attention"
        }
    }
}

struct ReadbackSection: Codable, Identifiable, Equatable {
    let id: UUID
    var capturedAt: Date
    var displayName: String
    var directory: String
    var screenshot: String
    var audio: String?
    var originalTranscript: String?
    var transcript: String?
    var status: ReadbackSectionStatus
    var failure: String?
    var deletedAt: Date?

    mutating func moveFiles(from oldDirectory: String, to newDirectory: String) {
        func moved(_ path: String?) -> String? {
            guard let path else { return nil }
            let prefix = oldDirectory + "/"
            return path.hasPrefix(prefix) ? newDirectory + "/" + path.dropFirst(prefix.count) : path
        }
        screenshot = moved(screenshot) ?? screenshot
        audio = moved(audio)
        originalTranscript = moved(originalTranscript)
        transcript = moved(transcript)
        directory = newDirectory
    }
}

struct ReadbackManifest: Codable, Equatable {
    static let currentFormat = 1
    var formatVersion = currentFormat
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var sections: [ReadbackSection]
}

enum ReadbackError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

enum ReadbackStore {
    static let manifestName = "session.json"

    static func create(at root: URL, title: String) throws -> ReadbackManifest {
        let fm = FileManager.default
        let root = root.standardizedFileURL
        if fm.fileExists(atPath: root.path) {
            let contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            if contents.contains(where: { $0.lastPathComponent == manifestName }) {
                throw ReadbackError.message("That folder is already a Readback session. Open it instead.")
            }
            guard contents.isEmpty else {
                throw ReadbackError.message("Choose a new or empty folder so existing files are never replaced.")
            }
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try createPrivateDirectory(root.appendingPathComponent("items", isDirectory: true))
        try createPrivateDirectory(root.appendingPathComponent("trash", isDirectory: true))
        let now = Date()
        let manifest = ReadbackManifest(id: UUID(), title: title, createdAt: now, updatedAt: now, sections: [])
        try save(manifest, at: root)
        try writeCompanionFiles(at: root, title: title)
        return manifest
    }

    static func load(from root: URL) throws -> ReadbackManifest {
        let url = root.appendingPathComponent(manifestName)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ReadbackManifest.self, from: data)
        guard manifest.formatVersion == ReadbackManifest.currentFormat else {
            throw ReadbackError.message("This Readback session uses format \(manifest.formatVersion), but this Workbench supports format \(ReadbackManifest.currentFormat). The folder was not changed.")
        }
        for section in manifest.sections {
            _ = try safeURL(root: root, relative: section.directory)
            _ = try safeURL(root: root, relative: section.screenshot)
            for path in [section.audio, section.originalTranscript, section.transcript].compactMap({ $0 }) {
                _ = try safeURL(root: root, relative: path)
            }
        }
        return manifest
    }

    static func save(_ manifest: ReadbackManifest, at root: URL) throws {
        var value = manifest; value.updatedAt = Date()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        try writePrivate(encoder.encode(value), to: root.appendingPathComponent(manifestName))
    }

    static func safeURL(root: URL, relative: String) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw ReadbackError.message("The session contains an unsafe file path and was not changed.")
        }
        let originalBase = root.standardizedFileURL
        let base = originalBase.resolvingSymlinksInPath()
        let candidate = originalBase.appendingPathComponent(relative).standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard resolvedParent.path == base.path || resolvedParent.path.hasPrefix(prefix) else {
            throw ReadbackError.message("The session contains a symbolic link outside its folder.")
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let resolved = candidate.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(prefix) else { throw ReadbackError.message("The session contains a symbolic link outside its folder.") }
        }
        return candidate
    }

    static func readText(root: URL, relative: String?) -> String {
        guard let relative, let url = try? safeURL(root: root, relative: relative) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func writeCompanionFiles(at root: URL, title: String) throws {
        let skillSource = Bundle.module.url(forResource: "SKILL", withExtension: "md", subdirectory: "build-readback-deck")
        guard let skillSource else { throw ReadbackError.message("The slide-building skill is missing from this Workbench build.") }
        try FileManager.default.copyItem(at: skillSource, to: root.appendingPathComponent("SKILL.md"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("SKILL.md").path)
        let readme = """
        # \(title)

        This is a portable Workbench Readback session. `session.json` owns section order and links each screenshot to its original audio, original transcript and editable narration. Deleted sections stay recoverable under `trash/` until Recently Deleted is emptied in Workbench.

        Give this folder to an agent together with `SKILL.md` to create a 16:9 PowerPoint with one uncropped screenshot per slide and the edited narration in speaker notes. The skill deliberately does not invent titles, summaries or other content.

        Keep this folder private when its screenshots or narration contain sensitive information.
        """
        try writePrivate(Data(readme.utf8), to: root.appendingPathComponent("README.md"))
    }
}

struct ReadbackScreenshot {
    let data: Data
    let displayName: String
    let screenFrame: CGRect
}

enum ReadbackScreenCapture {
    @MainActor
    static func currentDisplay() async throws -> ReadbackScreenshot {
        guard CGPreflightScreenCaptureAccess() else {
            throw ReadbackError.message("Screen Recording access is off. Allow Workbench in System Settings → Privacy & Security → Screen Recording, then try again.")
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ReadbackError.message("Workbench could not identify the display under the pointer.")
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ReadbackError.message("The display under the pointer is not currently available for capture.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ReadbackError.message("The captured display could not be encoded as a PNG.")
        }
        return ReadbackScreenshot(data: data, displayName: screen.localizedName, screenFrame: screen.frame)
    }
}

@MainActor
final class ReadbackModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    private struct Job: Hashable { let root: URL; let sectionID: UUID }
    private struct RecordingContext { let root: URL; let sectionID: UUID; let pendingURL: URL }

    @Published private(set) var sessionURL: URL?
    @Published private(set) var manifest: ReadbackManifest?
    @Published private(set) var recentSessionURLs: [URL] = []
    @Published private(set) var isCapturing = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSectionID: UUID?
    @Published private(set) var recordingElapsed = 0.0
    @Published private(set) var recordingThumbnail: NSImage?
    @Published private(set) var recordingScreenFrame: CGRect?
    @Published private(set) var pendingTranscriptionCount = 0
    @Published private(set) var screenPermissionGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var shortcutFailure: String?
    @Published var notice: String?
    @Published var showHUD = UserDefaults.standard.object(forKey: "readback.showHUD.v1") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showHUD, forKey: "readback.showHUD.v1"); stateChanged() }
    }
    @Published private(set) var transcriptDrafts: [UUID: String] = [:]

    var onStateChange: (() -> Void)?
    var onHideForEditorCapture: (() -> Void)?
    var onRestoreAfterEditorCapture: (() -> Void)?
    var onEditShortcut: (() -> Void)?
    var mayBeginCapture: (() -> String?)?
    var activeSections: [ReadbackSection] { manifest?.sections.filter { $0.deletedAt == nil } ?? [] }
    var deletedSections: [ReadbackSection] { manifest?.sections.filter { $0.deletedAt != nil } ?? [] }
    var hasPendingTranscriptions: Bool { pendingTranscriptionCount > 0 }
    var permissionsReady: Bool { screenPermissionGranted && microphonePermission == .authorized }
    var shortcutLabel: String { VoicePreferences.load().shortcut(4).label }

    private let engine: RecognitionEngine
    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var peakPower: Float = -160
    private var recordingContext: RecordingContext?
    private var queue: [Job] = []
    private var processor: Task<Void, Never>?
    private var activeJob: Job?
    private static let recentsKey = "readback.recentSessionPaths.v1"

    init(engine: RecognitionEngine) {
        self.engine = engine
        super.init()
        recentSessionURLs = (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let recent = recentSessionURLs.first, let loaded = try? ReadbackStore.load(from: recent) {
            let restored = recovered(loaded, at: recent)
            setCurrent(url: recent, manifest: restored)
            enqueuePending(in: recent)
        }
        Task { [weak self] in self?.resumeRecentJobs() }
    }

    func refreshPermissionState() {
        screenPermissionGranted = CGPreflightScreenCaptureAccess()
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        stateChanged()
    }

    func setShortcutFailure(_ message: String?) {
        shortcutFailure = message
        stateChanged()
    }

    func createSession() {
        guard !isRecording else { notice = "Finish the current narration before creating another session."; return }
        let panel = NSSavePanel()
        panel.title = "Create Readback Session"
        panel.prompt = "Create Session"
        panel.nameFieldLabel = "Session name:"
        panel.nameFieldStringValue = "New Readback"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let title = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            let created = try ReadbackStore.create(at: url, title: title.isEmpty ? "Readback" : title)
            setCurrent(url: url, manifest: created)
            Task { await preflightPermissions() }
        } catch { notice = error.localizedDescription }
    }

    func openSession() {
        guard !isRecording else { notice = "Finish the current narration before switching sessions."; return }
        let panel = NSOpenPanel()
        panel.title = "Open Readback Session"
        panel.prompt = "Open Session"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func openRecent(_ url: URL) { guard !isRecording else { notice = "Finish the current narration before switching sessions."; return }; open(url) }

    private func open(_ url: URL) {
        do {
            let loaded = try ReadbackStore.load(from: url)
            setCurrent(url: url, manifest: recovered(loaded, at: url))
            enqueuePending(in: url)
            Task { await preflightPermissions() }
        } catch { notice = "This session could not be opened. \(error.localizedDescription)" }
    }

    func closeSession() {
        guard !isRecording else { notice = "Finish the current narration before closing this session."; return }
        sessionURL = nil; manifest = nil; transcriptDrafts = [:]; notice = nil
    }

    func revealSession() { if let sessionURL { NSWorkspace.shared.activateFileViewerSelecting([sessionURL]) } }

    func preflightPermissions() async {
        screenPermissionGranted = CGPreflightScreenCaptureAccess()
        if !screenPermissionGranted { screenPermissionGranted = CGRequestScreenCaptureAccess() }
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphonePermission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        if permissionsReady { notice = "Readback is ready. Move the pointer to the display you want and use \(shortcutLabel)." }
        else { notice = "Allow Screen Recording and Microphone access before using the Readback shortcut." }
        stateChanged()
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    func toggleCapture() async {
        if isRecording { stopNarration(); return }
        await captureNewSection(fromEditor: false)
    }

    func captureNewSection(fromEditor: Bool) async {
        guard !isCapturing, !isRecording else { return }
        if let reason = mayBeginCapture?() { notice = reason; stateChanged(); return }
        guard let root = sessionURL, var current = manifest else { notice = "Create or open a Readback session first."; stateChanged(); return }
        guard permissionsReady else { notice = "Readback needs Screen Recording and Microphone access first."; stateChanged(); return }
        isCapturing = true; notice = "Capturing the display under the pointer…"; stateChanged()
        do {
            let capture = try await captureScreen(fromEditor: fromEditor)
            let id = UUID(), directory = "items/\(id.uuidString.lowercased())"
            let folder = try ReadbackStore.safeURL(root: root, relative: directory)
            try ReadbackStore.createPrivateDirectory(folder)
            let screenshot = directory + "/screen.png"
            try ReadbackStore.writePrivate(capture.data, to: ReadbackStore.safeURL(root: root, relative: screenshot))
            let section = ReadbackSection(id: id, capturedAt: Date(), displayName: capture.displayName, directory: directory,
                screenshot: screenshot, audio: nil, originalTranscript: nil, transcript: nil, status: .needsNarration, failure: nil, deletedAt: nil)
            current.sections.append(section); current.updatedAt = Date(); try ReadbackStore.save(current, at: root)
            manifest = current; recordingThumbnail = NSImage(data: capture.data); recordingScreenFrame = capture.screenFrame
            isCapturing = false
            do { try startNarration(root: root, sectionID: id) }
            catch { markNeedsNarration(root: root, sectionID: id, message: error.localizedDescription) }
        } catch {
            isCapturing = false; notice = "The screen was not captured. \(error.localizedDescription)"; stateChanged()
        }
    }

    func startNarration(for sectionID: UUID) {
        guard !isRecording, !isCapturing, let root = sessionURL, activeSections.contains(where: { $0.id == sectionID }) else { return }
        if let reason = mayBeginCapture?() { notice = reason; stateChanged(); return }
        guard microphonePermission == .authorized else { notice = "Microphone access is required to record narration."; return }
        do {
            if let section = manifest?.sections.first(where: { $0.id == sectionID }), let imageURL = try? ReadbackStore.safeURL(root: root, relative: section.screenshot) {
                recordingThumbnail = NSImage(contentsOf: imageURL)
            }
            recordingScreenFrame = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.frame
            try startNarration(root: root, sectionID: sectionID)
        } catch { notice = error.localizedDescription; stateChanged() }
    }

    private func startNarration(root: URL, sectionID: UUID) throws {
        guard microphonePermission == .authorized else { throw ReadbackError.message("Microphone access is off.") }
        guard var current = try? ReadbackStore.load(from: root), let index = current.sections.firstIndex(where: { $0.id == sectionID && $0.deletedAt == nil }) else {
            throw ReadbackError.message("The Readback section is no longer available.")
        }
        let folder = try ReadbackStore.safeURL(root: root, relative: current.sections[index].directory)
        let pending = folder.appendingPathComponent("narration-pending-\(UUID().uuidString).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let capture = try AVAudioRecorder(url: pending, settings: settings)
        capture.delegate = self; capture.isMeteringEnabled = true
        guard capture.prepareToRecord(), capture.record() else { throw ReadbackError.message("The microphone could not start. Check that an input device is connected.") }
        recorder = capture; recordingContext = RecordingContext(root: root, sectionID: sectionID, pendingURL: pending)
        recordingElapsed = 0; peakPower = -160; isRecording = true; recordingSectionID = sectionID
        current.sections[index].status = .recording; current.sections[index].failure = nil
        try ReadbackStore.save(current, at: root); publish(current, for: root)
        notice = "Narrating section \(current.sections.filter { $0.deletedAt == nil }.firstIndex(where: { $0.id == sectionID }).map { $0 + 1 } ?? 1). Use \(shortcutLabel) again to stop."
        meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters(); self.recordingElapsed = recorder.currentTime
                self.peakPower = max(self.peakPower, recorder.peakPower(forChannel: 0))
                if self.recordingElapsed >= 300 { self.stopNarration() }
                self.stateChanged()
            }
        }
        stateChanged()
    }

    func stopNarration() {
        guard isRecording, let context = recordingContext else { return }
        let duration = recorder?.currentTime ?? recordingElapsed
        recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil
        isRecording = false; recordingSectionID = nil; recordingContext = nil
        do {
            guard duration >= 0.35, peakPower > -55 else {
                try? FileManager.default.removeItem(at: context.pendingURL)
                markNeedsNarration(root: context.root, sectionID: context.sectionID, message: "No clear speech was captured. The screenshot was kept; record its narration again.")
                return
            }
            var current = try ReadbackStore.load(from: context.root)
            guard let index = current.sections.firstIndex(where: { $0.id == context.sectionID }) else { throw ReadbackError.message("The section was removed before its narration could be saved.") }
            try archiveNarrationFiles(section: current.sections[index], root: context.root)
            let relative = current.sections[index].directory + "/narration.wav"
            let destination = try ReadbackStore.safeURL(root: context.root, relative: relative)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: context.pendingURL, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            current.sections[index].audio = relative
            current.sections[index].originalTranscript = nil; current.sections[index].transcript = nil
            current.sections[index].status = .queued; current.sections[index].failure = nil
            try ReadbackStore.save(current, at: context.root); publish(current, for: context.root)
            transcriptDrafts.removeValue(forKey: context.sectionID)
            enqueue(Job(root: context.root, sectionID: context.sectionID))
            notice = "Narration saved. You can capture the next section while this one transcribes."
        } catch {
            markNeedsNarration(root: context.root, sectionID: context.sectionID, message: "The narration could not be saved. \(error.localizedDescription)")
        }
        stateChanged()
    }

    func cancelNarration() {
        guard let context = recordingContext else { return }
        recorder?.stop(); recorder = nil; meter?.invalidate(); meter = nil
        try? FileManager.default.removeItem(at: context.pendingURL)
        isRecording = false; recordingSectionID = nil; recordingContext = nil
        markNeedsNarration(root: context.root, sectionID: context.sectionID, message: "Narration was cancelled. The screenshot and any earlier narration were kept.")
    }

    func replaceScreenshot(_ sectionID: UUID) async {
        guard !isCapturing, !isRecording, let root = sessionURL else { return }
        isCapturing = true; stateChanged()
        do {
            let capture = try await captureScreen(fromEditor: true)
            var current = try ReadbackStore.load(from: root)
            guard let index = current.sections.firstIndex(where: { $0.id == sectionID && $0.deletedAt == nil }) else { throw ReadbackError.message("The section is no longer available.") }
            try archiveFile(relative: current.sections[index].screenshot, label: "screen", root: root, section: current.sections[index])
            try ReadbackStore.writePrivate(capture.data, to: ReadbackStore.safeURL(root: root, relative: current.sections[index].screenshot))
            current.sections[index].capturedAt = Date(); current.sections[index].displayName = capture.displayName
            try ReadbackStore.save(current, at: root); publish(current, for: root)
            notice = "Screenshot replaced. Its narration was kept."
        } catch { notice = "The screenshot was not replaced. \(error.localizedDescription)" }
        isCapturing = false; stateChanged()
    }

    func redoBoth(_ sectionID: UUID) async {
        guard !isCapturing, !isRecording, let root = sessionURL else { return }
        isCapturing = true; stateChanged()
        do {
            let capture = try await captureScreen(fromEditor: true)
            var current = try ReadbackStore.load(from: root)
            guard let index = current.sections.firstIndex(where: { $0.id == sectionID && $0.deletedAt == nil }) else { throw ReadbackError.message("The section is no longer available.") }
            try archiveFile(relative: current.sections[index].screenshot, label: "screen", root: root, section: current.sections[index])
            try ReadbackStore.writePrivate(capture.data, to: ReadbackStore.safeURL(root: root, relative: current.sections[index].screenshot))
            current.sections[index].capturedAt = Date(); current.sections[index].displayName = capture.displayName
            try ReadbackStore.save(current, at: root); publish(current, for: root)
            recordingThumbnail = NSImage(data: capture.data); recordingScreenFrame = capture.screenFrame
            isCapturing = false; try startNarration(root: root, sectionID: sectionID)
        } catch { isCapturing = false; notice = "The section was not replaced. \(error.localizedDescription)"; stateChanged() }
    }

    func retryTranscription(_ sectionID: UUID) {
        guard let root = sessionURL, var current = try? ReadbackStore.load(from: root),
              let index = current.sections.firstIndex(where: { $0.id == sectionID && $0.audio != nil && $0.deletedAt == nil }) else { return }
        current.sections[index].status = .queued; current.sections[index].failure = nil
        try? ReadbackStore.save(current, at: root); publish(current, for: root); enqueue(Job(root: root, sectionID: sectionID))
    }

    func updateTranscript(_ text: String, for sectionID: UUID) {
        guard let root = sessionURL, var current = try? ReadbackStore.load(from: root),
              let index = current.sections.firstIndex(where: { $0.id == sectionID && $0.deletedAt == nil }) else { return }
        let relative = current.sections[index].transcript ?? current.sections[index].directory + "/narration.txt"
        do {
            try ReadbackStore.writePrivate(Data(text.utf8), to: ReadbackStore.safeURL(root: root, relative: relative))
            current.sections[index].transcript = relative; transcriptDrafts[sectionID] = text
            try ReadbackStore.save(current, at: root); publish(current, for: root)
        } catch { notice = "The edited narration could not be saved. \(error.localizedDescription)" }
    }

    func moveSections(from offsets: IndexSet, to destination: Int) {
        guard let root = sessionURL, var current = manifest else { return }
        var active = current.sections.filter { $0.deletedAt == nil }
        active.move(fromOffsets: offsets, toOffset: destination)
        current.sections = active + current.sections.filter { $0.deletedAt != nil }
        do { try ReadbackStore.save(current, at: root); manifest = current }
        catch { notice = "The new section order could not be saved. \(error.localizedDescription)" }
    }

    func moveSection(_ sourceID: UUID, before targetID: UUID) {
        guard sourceID != targetID, let root = sessionURL, var current = manifest else { return }
        var active = current.sections.filter { $0.deletedAt == nil }
        guard let source = active.firstIndex(where: { $0.id == sourceID }), let target = active.firstIndex(where: { $0.id == targetID }) else { return }
        let section = active.remove(at: source)
        active.insert(section, at: source < target ? max(0, target - 1) : target)
        current.sections = active + current.sections.filter { $0.deletedAt != nil }
        do { try ReadbackStore.save(current, at: root); manifest = current }
        catch { notice = "The new section order could not be saved. \(error.localizedDescription)" }
    }

    func deleteSection(_ sectionID: UUID) {
        guard !isRecording, let root = sessionURL, var current = manifest,
              let index = current.sections.firstIndex(where: { $0.id == sectionID && $0.deletedAt == nil }),
              ![.queued, .transcribing].contains(current.sections[index].status) else {
            notice = "Wait for transcription to finish before deleting this section."; return
        }
        do {
            let oldDirectory = current.sections[index].directory
            let newDirectory = "trash/\(sectionID.uuidString.lowercased())"
            let source = try ReadbackStore.safeURL(root: root, relative: oldDirectory)
            let destination = try ReadbackStore.safeURL(root: root, relative: newDirectory)
            if FileManager.default.fileExists(atPath: destination.path) { throw ReadbackError.message("A recovery copy already exists in Recently Deleted.") }
            try FileManager.default.moveItem(at: source, to: destination)
            current.sections[index].moveFiles(from: oldDirectory, to: newDirectory)
            current.sections[index].deletedAt = Date()
            try ReadbackStore.save(current, at: root); manifest = current
            notice = "Section moved to Recently Deleted."
        } catch { notice = "The section was not deleted. \(error.localizedDescription)" }
    }

    func restoreSection(_ sectionID: UUID) {
        guard let root = sessionURL, var current = manifest,
              let index = current.sections.firstIndex(where: { $0.id == sectionID && $0.deletedAt != nil }) else { return }
        do {
            let oldDirectory = current.sections[index].directory
            let newDirectory = "items/\(sectionID.uuidString.lowercased())"
            let source = try ReadbackStore.safeURL(root: root, relative: oldDirectory)
            let destination = try ReadbackStore.safeURL(root: root, relative: newDirectory)
            try FileManager.default.moveItem(at: source, to: destination)
            current.sections[index].moveFiles(from: oldDirectory, to: newDirectory)
            current.sections[index].deletedAt = nil
            try ReadbackStore.save(current, at: root); manifest = current
            notice = "Section restored."
        } catch { notice = "The section could not be restored. \(error.localizedDescription)" }
    }

    func emptyRecentlyDeleted() {
        guard let root = sessionURL, var current = manifest else { return }
        do {
            for section in current.sections where section.deletedAt != nil {
                let url = try ReadbackStore.safeURL(root: root, relative: section.directory)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                transcriptDrafts.removeValue(forKey: section.id)
            }
            current.sections.removeAll { $0.deletedAt != nil }
            try ReadbackStore.save(current, at: root); manifest = current
            notice = "Recently Deleted was emptied. Those files cannot be recovered by Workbench."
        } catch { notice = "Recently Deleted could not be emptied. \(error.localizedDescription)" }
    }

    func shutdown() {
        if isRecording { cancelNarration() }
        if let activeJob { markQueued(activeJob) }
        processor?.cancel(); processor = nil
    }

    private func captureScreen(fromEditor: Bool) async throws -> ReadbackScreenshot {
        if fromEditor {
            onHideForEditorCapture?()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        defer { if fromEditor { onRestoreAfterEditorCapture?() } }
        return try await ReadbackScreenCapture.currentDisplay()
    }

    private func archiveNarrationFiles(section: ReadbackSection, root: URL) throws {
        for (path, label) in [(section.audio, "audio"), (section.originalTranscript, "original-transcript"), (section.transcript, "edited-transcript")] {
            if let path { try archiveFile(relative: path, label: label, root: root, section: section) }
        }
    }

    private func archiveFile(relative: String, label: String, root: URL, section: ReadbackSection) throws {
        let source = try ReadbackStore.safeURL(root: root, relative: relative)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let historyRelative = section.directory + "/history"
        let history = try ReadbackStore.safeURL(root: root, relative: historyRelative)
        try ReadbackStore.createPrivateDirectory(history)
        let ext = source.pathExtension
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(label)" + (ext.isEmpty ? "" : ".\(ext)")
        try FileManager.default.moveItem(at: source, to: history.appendingPathComponent(name))
    }

    private func markNeedsNarration(root: URL, sectionID: UUID, message: String) {
        guard var current = try? ReadbackStore.load(from: root), let index = current.sections.firstIndex(where: { $0.id == sectionID }) else {
            notice = message; stateChanged(); return
        }
        current.sections[index].status = .needsNarration; current.sections[index].failure = message
        try? ReadbackStore.save(current, at: root); publish(current, for: root)
        notice = message; stateChanged()
    }

    private func enqueue(_ job: Job) {
        guard activeJob != job, !queue.contains(job) else { return }
        queue.append(job); updateQueueCount()
        if processor == nil {
            processor = Task { [weak self] in await self?.drainQueue() }
        }
    }

    private func drainQueue() async {
        while !Task.isCancelled, !queue.isEmpty {
            let job = queue.removeFirst(); activeJob = job; updateQueueCount()
            await process(job)
            activeJob = nil; updateQueueCount()
        }
        processor = nil
        if !queue.isEmpty, !Task.isCancelled { enqueue(queue.removeFirst()) }
    }

    private func process(_ job: Job) async {
        do {
            var current = try ReadbackStore.load(from: job.root)
            guard let index = current.sections.firstIndex(where: { $0.id == job.sectionID && $0.deletedAt == nil }),
                  let audio = current.sections[index].audio else { return }
            current.sections[index].status = .transcribing; current.sections[index].failure = nil
            try ReadbackStore.save(current, at: job.root); publish(current, for: job.root)
            let audioURL = try ReadbackStore.safeURL(root: job.root, relative: audio)
            let result = try await engine.transcribe(audioURL)
            guard !result.isEmpty else { throw ReadbackError.message("No speech was recognised. Record the narration again.") }
            current = try ReadbackStore.load(from: job.root)
            guard let freshIndex = current.sections.firstIndex(where: { $0.id == job.sectionID && $0.deletedAt == nil }) else { return }
            let original = current.sections[freshIndex].directory + "/narration-original.txt"
            let edited = current.sections[freshIndex].directory + "/narration.txt"
            try ReadbackStore.writePrivate(Data(result.utf8), to: ReadbackStore.safeURL(root: job.root, relative: original))
            try ReadbackStore.writePrivate(Data(result.utf8), to: ReadbackStore.safeURL(root: job.root, relative: edited))
            current.sections[freshIndex].originalTranscript = original; current.sections[freshIndex].transcript = edited
            current.sections[freshIndex].status = .ready; current.sections[freshIndex].failure = nil
            try ReadbackStore.save(current, at: job.root); publish(current, for: job.root)
            if sessionURL?.standardizedFileURL == job.root.standardizedFileURL { transcriptDrafts[job.sectionID] = result; notice = "Narration transcribed. The section is ready for slides." }
        } catch {
            if Task.isCancelled { markQueued(job); return }
            if error.localizedDescription.localizedCaseInsensitiveContains("already running") {
                markQueued(job); queue.append(job); updateQueueCount()
                try? await Task.sleep(nanoseconds: 800_000_000)
                return
            }
            guard var current = try? ReadbackStore.load(from: job.root), let index = current.sections.firstIndex(where: { $0.id == job.sectionID }) else { return }
            current.sections[index].status = .failed; current.sections[index].failure = error.localizedDescription
            try? ReadbackStore.save(current, at: job.root); publish(current, for: job.root)
            if sessionURL?.standardizedFileURL == job.root.standardizedFileURL { notice = "Transcription failed. The screenshot and audio were kept for retry." }
        }
    }

    private func markQueued(_ job: Job) {
        guard var current = try? ReadbackStore.load(from: job.root), let index = current.sections.firstIndex(where: { $0.id == job.sectionID }) else { return }
        current.sections[index].status = .queued
        try? ReadbackStore.save(current, at: job.root); publish(current, for: job.root)
    }

    private func enqueuePending(in root: URL) {
        guard let current = try? ReadbackStore.load(from: root) else { return }
        for section in current.sections where section.deletedAt == nil && [.queued, .transcribing].contains(section.status) && section.audio != nil {
            enqueue(Job(root: root, sectionID: section.id))
        }
    }

    private func resumeRecentJobs() {
        for root in recentSessionURLs {
            guard let current = try? ReadbackStore.load(from: root) else { continue }
            let repaired = recovered(current, at: root)
            for section in repaired.sections where section.deletedAt == nil && section.status == .queued && section.audio != nil {
                enqueue(Job(root: root, sectionID: section.id))
            }
        }
    }

    private func recovered(_ value: ReadbackManifest, at root: URL) -> ReadbackManifest {
        var current = value; var changed = false
        for index in current.sections.indices where current.sections[index].deletedAt == nil {
            if current.sections[index].status == .transcribing {
                current.sections[index].status = .queued; changed = true
            } else if current.sections[index].status == .recording {
                current.sections[index].status = .needsNarration
                current.sections[index].failure = "Recording was interrupted. The screenshot was kept; record its narration again."
                changed = true
            }
        }
        if changed { try? ReadbackStore.save(current, at: root) }
        return current
    }

    private func setCurrent(url: URL, manifest: ReadbackManifest) {
        sessionURL = url.standardizedFileURL; self.manifest = manifest; notice = nil
        transcriptDrafts = Dictionary(uniqueKeysWithValues: manifest.sections.compactMap { section in
            let text = ReadbackStore.readText(root: url, relative: section.transcript)
            return text.isEmpty ? nil : (section.id, text)
        })
        var paths = recentSessionURLs.map(\.standardizedFileURL).filter { $0 != url.standardizedFileURL }
        paths.insert(url.standardizedFileURL, at: 0); recentSessionURLs = Array(paths.prefix(12))
        UserDefaults.standard.set(recentSessionURLs.map(\.path), forKey: Self.recentsKey)
    }

    private func publish(_ value: ReadbackManifest, for root: URL) {
        guard sessionURL?.standardizedFileURL == root.standardizedFileURL else { return }
        manifest = value
        for section in value.sections where section.transcript != nil {
            transcriptDrafts[section.id] = ReadbackStore.readText(root: root, relative: section.transcript)
        }
        stateChanged()
    }

    private func updateQueueCount() {
        pendingTranscriptionCount = queue.count + (activeJob == nil ? 0 : 1)
        stateChanged()
    }

    private func stateChanged() { onStateChange?() }
}
