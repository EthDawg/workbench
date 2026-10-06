import Foundation
import CryptoKit

/// One explicit export awaiting a verified Library reference. Retrying never
/// exports again and never silently adopts bytes changed by another application.
struct PackSavedResource: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let byteCount: Int
    let digest: String

    func verify() throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize == byteCount else {
            throw VoiceError.message("The saved file is missing or changed. Its original contents could not be verified; keep or inspect that file before saving a new copy.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), count = 0
        while let chunk = try handle.read(upToCount: min(65_536, byteCount + 1 - count)), !chunk.isEmpty {
            count += chunk.count
            guard count <= byteCount else { throw VoiceError.message("The saved file changed while it was checked. Its original contents could not be verified.") }
            hash.update(data: chunk)
        }
        guard count == byteCount, hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
            throw VoiceError.message("The saved file's contents changed. Retry will not replace or adopt the changed file.")
        }
    }
}
