import Foundation
import AVFoundation

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct SavedState: Codable {
    var draft = ""
    var speechText = ""
    var history: [Transcript] = []
    var replacements: [Replacement] = []
    var voice = "Karen"
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
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
    static func export(_ source: URL, to destination: URL) throws {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: staged) }
        // Normalize the sample rate: compact macOS voices often emit 22.05 kHz,
        // whose AAC encoder cannot accept common music-oriented bitrates.
        try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac@44100", "-b", "96000", source.path, staged.path])
        // Atomic write preserves an existing file if conversion fails.
        try Data(contentsOf: staged).write(to: destination, options: .atomic)
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
