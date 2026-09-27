import AppKit
import Foundation

/// Where macOS saves screenshots. Nil means its default, the Desktop.
protocol ScreenshotLocationStore: AnyObject {
    var location: String? { get set }
}

/// The person's own macOS screenshot setting, read and changed only through
/// explicit Snap choices.
final class SystemScreenshotLocation: ScreenshotLocationStore {
    private let domain = "com.apple.screencapture" as CFString
    var location: String? {
        get { CFPreferencesCopyAppValue("location" as CFString, domain) as? String }
        set {
            CFPreferencesSetAppValue("location" as CFString, newValue as CFString?, domain)
            CFPreferencesAppSynchronize(domain)
        }
    }
}

/// Keeps the Desktop clear by gathering macOS screenshots into Snap History.
/// Only files macOS itself marked as screen captures are touched, in any
/// language. A Snap is stored and read back before its file moves to the
/// Trash, so nothing is deleted and every original stays recoverable.
enum SnapScreenshots {
    static let attribute = "com.apple.metadata:kMDItemIsScreenCapture"
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]

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
    static func screenCaptures(in folder: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
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
    /// original digests already in history: a screenshot already there is only
    /// cleared, so a retry after a failed Trash move never duplicates a Snap.
    /// Returns nil when the image was already in Snap History.
    @discardableResult
    static func adopt(_ file: URL, store: SnapStore, known: inout Set<String>, trash: (URL) throws -> Void) throws -> SnapItem? {
        let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard size <= SnapStore.maximumImageBytes else { throw SnapError.message("\(file.lastPathComponent) is larger than 100 MB, so it was left in place.") }
        let bytes = try Data(contentsOf: file)
        let png = file.pathExtension.lowercased() == "png" ? bytes : try SnapRendering.png(bytes)
        let digest = SnapStore.digest(png)
        if known.contains(digest) { try trash(file); return nil }
        let dimensions = try SnapRendering.dimensions(png)
        let item = try store.insert(originalPNG: png, width: dimensions.width, height: dimensions.height,
                                    title: String(file.deletingPathExtension().lastPathComponent.prefix(240)),
                                    source: .imported, createdAt: created(file) == .distantPast ? Date() : created(file))
        guard (try? store.snapshot(item.id))?.originalPNG == png else {
            throw SnapError.message("\(file.lastPathComponent) could not be confirmed in Snap History, so it was left in place.")
        }
        known.insert(digest)
        try trash(file)
        return item
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
