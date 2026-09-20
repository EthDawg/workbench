import Foundation

/// One unfinished capture. Audio names are owned leaves, never imported URLs.
struct CaptureRecoveryRecord: Codable {
    var version = 1
    let id: UUID
    var audioFilename: String?
    var capture: Transcript?

    func validated() throws -> Self {
        guard version == 1, audioFilename != nil || capture != nil,
              audioFilename == nil || audioFilename == "capture-\(id.uuidString).wav"
        else { throw CaptureRecoveryError.invalid }
        if let capture {
            guard capture.id == id, !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  capture.seconds.isFinite, capture.seconds >= 0, capture.seconds <= 1800 else { throw CaptureRecoveryError.invalid }
        }
        return self
    }
}

enum CaptureRecoveryError: LocalizedError {
    case invalid, changed, pending
    var errorDescription: String? {
        switch self {
        case .invalid: return "Capture recovery could not be read safely. Its files were kept. Open the CaptureRecovery folder in Workbench’s Application Support before recording again."
        case .changed: return "Capture recovery changed outside this operation. Its files were kept; reopen Workbench before trying again."
        case .pending: return "A capture still needs saving or transcription. Use Retry before starting another capture."
        }
    }
}

/// A small write-ahead record, independent of state.json. A full disk may stop
/// both writes; even then the already-created recording is never deleted here.
final class CaptureRecoveryStore {
    static let maximumMetadataBytes = 4 * 1024 * 1024
    let directory: URL
    private(set) var pending: CaptureRecoveryRecord?
    private(set) var problem: Error?
    private var expectedData: Data?
    var hasRecovery: Bool { pending != nil || problem != nil }
    private var metadataURL: URL { directory.appendingPathComponent("pending.json") }

    init(directory: URL) { self.directory = directory }

    @discardableResult func load() throws -> CaptureRecoveryRecord? {
        do {
            guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
            try checkDirectory()
            let data = try readMetadata()
            expectedData = data
            pending = try data.map { try JSONDecoder().decode(CaptureRecoveryRecord.self, from: $0).validated() }
            // A failed metadata cleanup must not strand an owned recording.
            if pending == nil {
                let audio = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "wav" }
                guard audio.count <= 1 else { throw CaptureRecoveryError.invalid }
                if let url = audio.first {
                    let name = url.deletingPathExtension().lastPathComponent
                    guard let id = UUID(uuidString: String(name.dropFirst("capture-".count))) else { throw CaptureRecoveryError.invalid }
                    pending = try CaptureRecoveryRecord(id: id, audioFilename: url.lastPathComponent).validated()
                }
            }
            if let pending, pending.audioFilename != nil { _ = try audioURL(for: pending, requireExists: false) }
            problem = nil
            return pending
        } catch { problem = error; throw error }
    }

    func beginRecording() throws -> URL {
        guard !hasRecovery else { throw CaptureRecoveryError.pending }
        try makeDirectory()
        // Also catch files created by another instance since startup.
        _ = try load()
        guard !hasRecovery else { throw CaptureRecoveryError.pending }
        let id = UUID()
        let record = CaptureRecoveryRecord(id: id, audioFilename: "capture-\(id.uuidString).wav")
        try retain(record)
        return try audioURL(for: record, requireExists: false)!
    }

    /// Keep the in-memory result even when its durable journal cannot be written.
    func retain(_ record: CaptureRecoveryRecord) throws {
        if let problem { throw problem }
        let record = try record.validated()
        if let pending, pending.id != record.id { throw CaptureRecoveryError.pending }
        pending = record
        try makeDirectory()
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumMetadataBytes else { throw CaptureRecoveryError.invalid }
        guard try readMetadata() == expectedData else { throw CaptureRecoveryError.changed }
        try data.write(to: metadataURL, options: .atomic)
        expectedData = data
    }

    func audioURL(for record: CaptureRecoveryRecord, requireExists: Bool = true) throws -> URL? {
        _ = try record.validated()
        guard let name = record.audioFilename else { return nil }
        try checkDirectory()
        let url = directory.appendingPathComponent(name)
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  let size = values.fileSize, size >= 0, size <= 64_000_000 else { throw CaptureRecoveryError.invalid }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile && !requireExists { }
        return url
    }

    /// Only explicit discard or a successful state commit can release recovery.
    func clear(_ id: UUID) throws {
        guard let pending, pending.id == id else { throw CaptureRecoveryError.changed }
        try checkDirectory()
        guard try readMetadata() == expectedData else { throw CaptureRecoveryError.changed }
        let audio = try audioURL(for: pending, requireExists: false)
        // Remove the marker last: an interrupted cleanup remains discoverable.
        if let audio, FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
        if expectedData != nil { try FileManager.default.removeItem(at: metadataURL) }
        self.pending = nil; expectedData = nil; problem = nil
    }

    private func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try checkDirectory()
    }
    private func checkDirectory() throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CaptureRecoveryError.invalid }
    }
    private func readMetadata() throws -> Data? {
        do {
            let values = try metadataURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  (values.fileSize ?? Int.max) <= Self.maximumMetadataBytes else { throw CaptureRecoveryError.invalid }
            let data = try Data(contentsOf: metadataURL)
            guard data.count <= Self.maximumMetadataBytes else { throw CaptureRecoveryError.invalid }
            return data
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
}
