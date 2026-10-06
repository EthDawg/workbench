import Foundation
import CryptoKit
import Darwin

/// A single ordinary Library file, with a separate completion receipt. The legacy
/// SavedState fields remain the source of recovery until every write is verified.
enum ReadRetirement {
    static let resourceID = UUID(uuidString: "B8B640F1-8E21-4A35-97B2-72BB99CCDB21")!
    static let fileName = "Saved Read text.txt"
    static let receiptName = "read-retirement-v1.json"
    struct Receipt: Codable, Equatable {
        var version = 1
        var resourceID = ReadRetirement.resourceID
        var digest: String
    }
    struct IO {
        var read: (URL, Int) throws -> Data = ReadRetirement.read
        var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        var writeNew: (Data, URL) throws -> Void = ReadRetirement.writeNew
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Never follow a conflicting link or wait on a device/FIFO. A receipt is
    /// small; draft reads are bounded by the exact bytes being preserved.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw VoiceError.message("The saved Read preservation file is not a regular private file of the expected size. It was left unchanged.")
        }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes else { throw VoiceError.message("The saved Read preservation file changed while being checked.") }
        return bytes
    }

    /// Private staged bytes are atomically linked into place without replacing an
    /// existing file. A conflicting file, including a racing writer, stays intact.
    static func writeNew(_ data: Data, _ destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".read-preservation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try AtomicPrivateFile.write(data, to: temporary)
        guard link(temporary.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    @MainActor static func preserve(_ text: String, in library: DemoLibraryModel, io: IO = IO()) throws {
        guard !text.isEmpty else { return }
        let directory = library.store.url.deletingLastPathComponent()
        let file = directory.appendingPathComponent(fileName)
        let receiptURL = directory.appendingPathComponent(receiptName)
        let bytes = Data(text.utf8)
        let expected = Receipt(digest: digest(bytes))
        // A completed migration stays complete if the person later removes or edits
        // their ordinary Library item. Never resurrect it from the dormant field.
        if io.exists(receiptURL) {
            guard try JSONDecoder().decode(Receipt.self, from: io.read(receiptURL, 1024)) == expected else {
                throw VoiceError.message("The saved Read preservation receipt is different or unreadable. Its files were left unchanged.")
            }
            return
        }
        guard library.draft == nil, library.importReview == nil else {
            throw VoiceError.message("Finish the current Library edit or import, then retry saving the old Read text.")
        }
        if io.exists(file) {
            guard try io.read(file, bytes.count) == bytes else { throw VoiceError.message("A different file already uses the saved Read text name. It was left unchanged.") }
        } else { try io.writeNew(bytes, file) }
        guard try io.read(file, bytes.count) == bytes else { throw VoiceError.message("The saved Read file could not be verified. The original draft remains saved.") }
        let item = DemoResource(id: resourceID, kind: .file, title: "Saved Read text", content: file.path,
                                notes: "Preserved from the retired Read tool. Open or preview this UTF-8 file to use its complete text.")
        if let existing = library.resources.first(where: { $0.id == resourceID }) {
            guard existing.kind == .file, existing.content == file.path, existing.bookmark == nil else {
                throw VoiceError.message("The saved Read Library reference has changed. It was left unchanged.")
            }
        } else {
            guard library.save(item) else { throw VoiceError.message(library.error ?? "Library could not save the preserved Read file.") }
        }
        let persisted = try library.store.load()
        guard let reference = persisted.first(where: { $0.id == resourceID }),
              reference.kind == .file, reference.content == file.path, reference.bookmark == nil,
              try io.read(file, bytes.count) == bytes else {
            throw VoiceError.message("The Read file or Library reference could not be verified. The original draft remains saved.")
        }
        try io.writeNew(JSONEncoder().encode(expected), receiptURL)
        guard try JSONDecoder().decode(Receipt.self, from: io.read(receiptURL, 1024)) == expected else {
            throw VoiceError.message("Read text was preserved, but completion could not be verified. Retry before relying on this migration.")
        }
    }
}
