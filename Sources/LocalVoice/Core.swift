import Foundation
import AVFoundation
import Darwin

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct SavedState: Codable {
    var draft = ""
    var speechText = ""
    var history: [Transcript] = []
    var replacements: [Replacement] = []
    /// A voice identifier, or a name an earlier build saved. Empty until
    /// someone chooses, so a fresh install uses the best installed voice.
    var voice = ""
    var rate = 180.0
    var rawDraft: String? = nil
}

struct StateStore {
    let url: URL
    init(directory: URL = Workbench.supportDirectory(component: "LocalVoice")) {
        url = directory.appendingPathComponent("state.json")
    }
    func load() throws -> SavedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedState() }
        return try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
    }
    func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(state)
        try AtomicPrivateFile.write(data, to: url)
    }
}

/// Permissions and synchronization precede the atomic replacement. A reported
/// failure never means the new state was already committed and then chmod failed.
enum AtomicPrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".workbench-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

enum TranscriptExportVersion: String {
    case cleaned = "Cleaned text"
    case original = "Original wording"
}

enum TranscriptExport {
    static let defaultFilename = "Workbench Transcript.txt"
    static func text(for capture: Transcript, version: TranscriptExportVersion) -> String {
        version == .original ? capture.rawText ?? capture.text : capture.text
    }
    static func data(for capture: Transcript, version: TranscriptExportVersion) -> Data {
        Data(text(for: capture, version: version).utf8)
    }
    static func write(_ capture: Transcript, version: TranscriptExportVersion, to destination: URL) throws {
        try data(for: capture, version: version).write(to: destination, options: .atomic)
    }
}

private final class CancellableProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var launched = false

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let shouldTerminate = launched && process.isRunning
        lock.unlock()
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    func run() throws {
        let errors = Pipe()
        process.standardError = errors
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do {
            try process.run()
            launched = true
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.lock()
        launched = false
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw VoiceError.message(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "The audio operation failed.")
        }
    }
}

enum AudioRenderer {
    static func render(text: String, voice: String, rate: Int) throws -> URL {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceError.message("Add some text first.") }
        guard text.count <= 50_000 else { throw VoiceError.message("Please keep each reading under 50,000 characters.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let input = folder.appendingPathComponent("input.txt")
        let output = folder.appendingPathComponent("speech.aiff")
        do {
            try text.write(to: input, atomically: true, encoding: .utf8)
            try run("/usr/bin/say", ["-v", voice, "-r", String(rate), "-f", input.path, "-o", output.path])
            try FileManager.default.removeItem(at: input)
            let file = try AVAudioFile(forReading: output)
            guard file.length > 0 else { throw VoiceError.message("This voice produced no audio. Choose another installed voice and try again.") }
            return output
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    static func renderCancellable(text: String, voice: String, rate: Int) async throws -> URL {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceError.message("Add some text first.") }
        guard text.count <= 50_000 else { throw VoiceError.message("Please keep each reading under 50,000 characters.") }
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let input = folder.appendingPathComponent("input.txt")
        let output = folder.appendingPathComponent("speech.aiff")
        do {
            try text.write(to: input, atomically: true, encoding: .utf8)
            try await runCancellable("/usr/bin/say", ["-v", voice, "-r", String(rate), "-f", input.path, "-o", output.path])
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: input)
            let file = try AVAudioFile(forReading: output)
            guard file.length > 0 else { throw VoiceError.message("This voice produced no audio. Choose another installed voice and try again.") }
            return output
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    // Normalize the sample rate: compact macOS voices often emit 22.05 kHz,
    // whose AAC encoder cannot accept common music-oriented bitrates.
    private static func exportArguments(_ source: URL, _ staged: URL) -> [String] {
        ["-f", "m4af", "-d", "aac@44100", "-b", "96000", source.path, staged.path]
    }
    static func export(_ source: URL, to destination: URL) throws {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: staged) }
        try run("/usr/bin/afconvert", exportArguments(source, staged))
        // Atomic write preserves an existing file if conversion fails.
        try Data(contentsOf: staged).write(to: destination, options: .atomic)
    }
    /// Save audio's export. A conversion still running after a minute plus a
    /// tenth of the reading's length is stopped, so a hung afconvert cannot
    /// hold Save audio, and Replace reading behind it, until relaunch.
    static func exportBounded(_ source: URL, to destination: URL) async throws {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: staged) }
        let seconds = (try? AVAudioFile(forReading: source)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        do { try await runBounded("/usr/bin/afconvert", exportArguments(source, staged), timeout: 60 + seconds / 10) }
        catch is ToolTimeout { throw VoiceError.message("Saving the audio took too long, so it was stopped. Nothing was saved. Choose Save audio to try again.") }
        try Data(contentsOf: staged).write(to: destination, options: .atomic)
    }
    struct ToolTimeout: Error {}
    /// Runs a tool that must finish within `timeout` seconds, stopping it if not.
    static func runBounded(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await runCancellable(executable, arguments); return true }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)); return false }
            defer { group.cancelAll() }
            guard try await group.next() == true else { throw ToolTimeout() }
        }
    }
    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VoiceError.message(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "The audio operation failed.")
        }
    }
    static func runCancellable(_ executable: String, _ arguments: [String]) async throws {
        let operation = CancellableProcess(executable: executable, arguments: arguments)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await Task.detached(priority: .userInitiated) { try operation.run() }.value
        } onCancel: {
            operation.cancel()
        }
    }
    static func remove(_ url: URL?) {
        guard let url, url.deletingLastPathComponent().lastPathComponent.hasPrefix("LocalVoice-") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
