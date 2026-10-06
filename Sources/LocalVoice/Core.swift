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
    /// Dormant Read compatibility fields. Preserve them exactly; no runtime
    /// voice lookup, synthesis or provider selection consumes them.
    var voice = ""
    var rate = 180.0
    var rawDraft: String? = nil
    /// The one delivery that did not finish (#134 T5), so a quit cannot make
    /// it look delivered. It names its words' record, never the words.
    var undelivered: UnresolvedDelivery? = nil
}

extension SavedState {
    /// As synthesized, with one difference: an undelivered result that this
    /// build cannot read, such as a kind a later build added, is left out
    /// rather than making the whole session unreadable. Older state has none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(draft: try container.decode(String.self, forKey: .draft),
                  speechText: try container.decode(String.self, forKey: .speechText),
                  history: try container.decode([Transcript].self, forKey: .history),
                  replacements: try container.decode([Replacement].self, forKey: .replacements),
                  voice: try container.decode(String.self, forKey: .voice),
                  rate: try container.decode(Double.self, forKey: .rate),
                  rawDraft: try container.decodeIfPresent(String.self, forKey: .rawDraft),
                  undelivered: (try? container.decodeIfPresent(UnresolvedDelivery.self, forKey: .undelivered)) ?? nil)
    }
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
