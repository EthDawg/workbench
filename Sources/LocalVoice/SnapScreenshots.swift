import AppKit
import Foundation

/// Gathers macOS screenshots into Snap History. Only files macOS itself marked
/// as screen captures are touched, in any language. A Snap is stored and read
/// back before its file moves to the Trash, so nothing is deleted and every
/// original stays recoverable.
enum SnapScreenshots {
    static let attribute = "com.apple.metadata:kMDItemIsScreenCapture"
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]

    /// Settling and retry checks read only file metadata. A replacement or a
    /// same-size rewrite must not inherit an older screenshot's retry delay.
    struct FileStamp: Equatable {
        var size: Int
        var modified: Date
        var identity: UInt64

        init?(_ file: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let identity = attributes[.systemFileNumber] as? NSNumber else { return nil }
            self.size = size.intValue; self.modified = modified; self.identity = identity.uint64Value
        }
    }

    static func isScreenCapture(_ url: URL) -> Bool {
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0, size < 1_024 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, 0) }
        guard read == size, let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        return (value as? NSNumber)?.boolValue == true
    }

    /// Screen captures directly inside a folder, oldest first. Hidden, empty,
    /// linked and non-image files are never included.
    static func screenCaptures(in folder: URL) -> [URL] { (try? listScreenCaptures(in: folder)) ?? [] }

    /// Throws when the folder cannot be read, for example before macOS grants
    /// access to the Desktop, so that is never reported as an empty Desktop.
    static func listScreenCaptures(in folder: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        return files.filter { url in
            guard imageExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else { return false }
            return isScreenCapture(url)
        }.sorted { created($0) < created($1) }
    }

    static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// Adds one screenshot to Snap History with its original capture time, then
    /// moves the file to the Trash. A PNG keeps its exact bytes. `known` holds the
    /// original digests and identities already in history: a screenshot already
    /// there is cleared only after its saved original is verified again, so a
    /// retry after a failed Trash move never duplicates or trusts damaged media.
    /// Returns nil when the image was already in Snap History.
    @discardableResult
    static func adopt(_ file: URL, store: SnapStore, known: inout [String: UUID], trash: (URL) throws -> Void) throws -> SnapItem? {
        let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard size <= SnapStore.maximumImageBytes else { throw SnapError.message("\(file.lastPathComponent) is larger than 100 MB, so it was left in place.") }
        let bytes = try Data(contentsOf: file)
        let png = file.pathExtension.lowercased() == "png" ? bytes : try SnapRendering.png(bytes)
        let digest = SnapStore.digest(png)
        let savedID: UUID, added: SnapItem?
        if let id = known[digest] { savedID = id; added = nil }
        else {
            let dimensions = try SnapRendering.dimensions(png)
            let item = try store.insert(originalPNG: png, width: dimensions.width, height: dimensions.height,
                                        title: String(file.deletingPathExtension().lastPathComponent.prefix(240)),
                                        source: .imported, createdAt: created(file) == .distantPast ? Date() : created(file))
            savedID = item.id; added = item
            // The identity exists even if readback or the later Trash move
            // fails. Another file in this batch must reuse that same record.
            known[digest] = item.id
        }
        guard (try? store.snapshot(savedID))?.originalPNG == png else {
            throw SnapError.message("\(file.lastPathComponent) could not be confirmed in History, so it was left in place.")
        }
        try trash(file)
        return added
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
