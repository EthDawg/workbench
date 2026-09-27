import Foundation
import CryptoKit
import Darwin

enum SnapError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum SnapSource: String, Codable, CaseIterable {
    case region, window, screen, clipboard, imported, narrated
    var title: String {
        switch self {
        case .region: "Region"
        case .window: "Window"
        case .screen: "Screen"
        case .clipboard: "Clipboard"
        case .imported: "Imported image"
        case .narrated: "Snap & Talk"
        }
    }
}

struct SnapPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

/// Normalised coordinates use the original image's bottom-left origin.
struct SnapCrop: Codable, Equatable {
    var x = 0.0
    var y = 0.0
    var width = 1.0
    var height = 1.0
    static let full = Self()
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 &&
            x + width <= 1.000001 && y + height <= 1.000001
    }
}

struct SnapMark: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case pen, arrow, rectangle }
    var id = UUID()
    var kind: Kind
    var points: [SnapPoint]
    var colour = "red"
    var width = 0.004
    var isValid: Bool {
        (2...20_000).contains(points.count) && points.allSatisfy(\.isValid) &&
            ["red", "yellow", "blue", "white", "black"].contains(colour) && width.isFinite && (0.0001...0.1).contains(width)
    }
}

struct SnapEdit: Codable, Equatable {
    var crop = SnapCrop.full
    var marks: [SnapMark] = []
    var isValid: Bool { crop.isValid && marks.count <= 1_000 && marks.allSatisfy(\.isValid) }
}

struct SnapItem: Codable, Equatable, Identifiable {
    var formatVersion = 1
    var revision = UUID()
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var notes = ""
    var tags: [String] = []
    var source: SnapSource
    var pixelWidth: Int
    var pixelHeight: Int
    var originalSHA256: String
    var imageName = "original.png"
    var imageSHA256: String
    var edit = SnapEdit()
    var archivedAt: Date?

    var searchableText: String { ([title, notes, source.title] + tags).joined(separator: " ") }
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { searchableText.localizedStandardContains(String($0)) }
    }
    func validate() throws {
        let validName = imageName == "original.png" || (imageName.hasPrefix("edit-") && imageName.hasSuffix(".png") && UUID(uuidString: String(imageName.dropFirst(5).dropLast(4))) != nil)
        guard formatVersion == 1, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 240,
              notes.count <= 50_000, tags.count <= 50, tags.allSatisfy({ !$0.isEmpty && $0.count <= 80 }),
              pixelWidth > 0, pixelHeight > 0, pixelWidth <= 32_768, pixelHeight <= 32_768,
              Int64(pixelWidth) * Int64(pixelHeight) <= 100_000_000,
              originalSHA256.count == 64, imageSHA256.count == 64, validName, edit.isValid,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite else {
            throw SnapError.message("This Snap record is not supported or is damaged. Its files have been kept.")
        }
    }
}

/// A job receives these value bytes, never a mutable file URL into the library.
struct SnapSnapshot {
    let item: SnapItem
    let originalPNG: Data
    let imagePNG: Data
    var sourceReference: String { "workbench-snap:\(item.id.uuidString.lowercased())" }
}

struct SnapLibraryRead {
    var items: [SnapItem]
    var problems: [String]
}

/// One directory per stable UUID. Original media and older rendered edits are
/// immutable. Metadata is replaced atomically; archive is reversible metadata.
final class SnapStore {
    let root: URL
    private let manager = FileManager.default
    static let maximumImageBytes = 100 * 1_024 * 1_024
    private var loadedRecords: [UUID: Data] = [:]

    init(root: URL) { self.root = root.standardizedFileURL }

    func load() throws -> SnapLibraryRead {
        guard manager.fileExists(atPath: root.path) else { return .init(items: [], problems: []) }
        try requireDirectory(root)
        let children = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var items: [SnapItem] = [], problems: [String] = []
        for child in children {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            do { items.append(try read(id)) }
            catch { problems.append("Snap \(id.uuidString.prefix(8)): \(error.localizedDescription)") }
        }
        return .init(items: items.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }, problems: problems)
    }

    func read(_ id: UUID) throws -> SnapItem {
        let directory = try itemDirectory(id)
        let data = try readPrivateFile(directory.appendingPathComponent("snap.json"), maximum: 4 * 1_024 * 1_024)
        let item = try JSONDecoder().decode(SnapItem.self, from: data)
        try item.validate()
        guard item.id == id else { throw SnapError.message("The Snap identity does not match its folder. Its files were kept.") }
        loadedRecords[id] = data
        return item
    }

    func snapshot(_ id: UUID) throws -> SnapSnapshot {
        let item = try read(id), directory = try itemDirectory(id)
        let original = try readPrivateFile(directory.appendingPathComponent("original.png"), maximum: Self.maximumImageBytes)
        let image = item.imageName == "original.png" ? original : try readPrivateFile(directory.appendingPathComponent(item.imageName), maximum: Self.maximumImageBytes)
        guard Self.digest(original) == item.originalSHA256, Self.digest(image) == item.imageSHA256 else {
            throw SnapError.message("This Snap's image changed outside Workbench. Its original files were kept; import the changed image as a new Snap.")
        }
        return .init(item: item, originalPNG: original, imagePNG: image)
    }

    @discardableResult
    func insert(originalPNG: Data, renderedPNG: Data? = nil, width: Int, height: Int,
                title: String, source: SnapSource, edit: SnapEdit = .init(), notes: String = "", tags: [String] = [], id: UUID = UUID(),
                createdAt: Date = Date()) throws -> SnapItem {
        guard !originalPNG.isEmpty, originalPNG.count <= Self.maximumImageBytes,
              renderedPNG.map({ !$0.isEmpty && $0.count <= Self.maximumImageBytes }) ?? true else {
            throw SnapError.message("Choose an image smaller than 100 MB.")
        }
        try prepareRoot()
        let destination = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        guard !manager.fileExists(atPath: destination.path) else { throw SnapError.message("This Snap already exists. Reload history before trying again.") }
        let staging = root.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        var item = SnapItem(id: id, createdAt: createdAt, updatedAt: Date(), title: title, source: source,
                            pixelWidth: width, pixelHeight: height, originalSHA256: Self.digest(originalPNG), imageSHA256: Self.digest(originalPNG), edit: edit)
        item.notes = notes; item.tags = tags
        try item.validate()
        try write(originalPNG, to: staging.appendingPathComponent("original.png"))
        if let renderedPNG, renderedPNG != originalPNG {
            item.imageName = "edit-\(UUID().uuidString.lowercased()).png"
            item.imageSHA256 = Self.digest(renderedPNG)
            try write(renderedPNG, to: staging.appendingPathComponent(item.imageName))
        }
        try item.validate()
        let bytes = try encode(item)
        try write(bytes, to: staging.appendingPathComponent("snap.json"))
        try manager.moveItem(at: staging, to: destination)
        loadedRecords[id] = bytes
        return item
    }

    @discardableResult
    func save(_ proposed: SnapItem, renderedPNG: Data? = nil) throws -> SnapItem {
        try proposed.validate()
        let directory = try itemDirectory(proposed.id), recordURL = directory.appendingPathComponent("snap.json")
        let disk = try readPrivateFile(recordURL, maximum: 4 * 1_024 * 1_024)
        guard loadedRecords[proposed.id] == disk else { throw SnapError.message("This Snap changed elsewhere. Reload it before saving; your current edit is still open.") }
        let current = try JSONDecoder().decode(SnapItem.self, from: disk)
        guard proposed.revision == current.revision else { throw SnapError.message("This Snap changed while you were editing. Close this edit and reopen the latest version; its original is safe.") }
        guard proposed.originalSHA256 == current.originalSHA256, proposed.createdAt == current.createdAt,
              proposed.source == current.source, proposed.pixelWidth == current.pixelWidth, proposed.pixelHeight == current.pixelHeight else {
            throw SnapError.message("An edit cannot replace the original Snap.")
        }
        var item = proposed
        var newFile: URL?
        if let renderedPNG {
            guard !renderedPNG.isEmpty, renderedPNG.count <= Self.maximumImageBytes else { throw SnapError.message("The edited image is too large to save.") }
            item.imageName = "edit-\(UUID().uuidString.lowercased()).png"
            item.imageSHA256 = Self.digest(renderedPNG)
            newFile = directory.appendingPathComponent(item.imageName)
            try write(renderedPNG, to: newFile!)
        } else {
            guard item.edit == current.edit, item.imageName == current.imageName, item.imageSHA256 == current.imageSHA256 else {
                throw SnapError.message("Save the rendered image together with its edit.")
            }
        }
        do {
            item.updatedAt = Date(); item.revision = UUID()
            let bytes = try encode(item)
            guard try readPrivateFile(recordURL, maximum: 4 * 1_024 * 1_024) == disk else { throw SnapError.message("This Snap changed during saving. Reload it and try again.") }
            try write(bytes, to: recordURL)
            loadedRecords[item.id] = bytes
            return item
        } catch {
            if let newFile { try? manager.removeItem(at: newFile) }
            throw error
        }
    }

    func setArchived(_ archived: Bool, ids: [UUID]) throws {
        // Resolve the entire selection before making any change. No image is
        // deleted. A later disk failure is reported and history can be reloaded.
        let items = try ids.map { try read($0) }
        for var item in items {
            if (item.archivedAt != nil) == archived { continue }
            item.archivedAt = archived ? Date() : nil
            try save(item)
        }
    }

    func imageURL(_ id: UUID) throws -> URL {
        let item = try read(id)
        return try itemDirectory(id).appendingPathComponent(item.imageName)
    }

    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func encode(_ item: SnapItem) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(item)
        guard bytes.count <= 4 * 1_024 * 1_024 else {
            throw SnapError.message("This edit has too many annotation points to save. Undo or clear some marks, then try again. The original is unchanged.")
        }
        return bytes
    }

    func organizationURL(key: String) throws -> URL {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else {
            throw SnapError.message("This review has an invalid identity.")
        }
        return root.appendingPathComponent("Reviews", isDirectory: true).appendingPathComponent(key + ".md")
    }

    func readOrganization(key: String) throws -> (url: URL, text: String, digest: String)? {
        let url = try organizationURL(key: key)
        guard manager.fileExists(atPath: url.path) else { return nil }
        try requireDirectory(root)
        try requireDirectory(url.deletingLastPathComponent())
        let data = try readPrivateFile(url, maximum: 8 * 1_024 * 1_024)
        guard let text = String(data: data, encoding: .utf8) else { throw SnapError.message("The current review is not readable text. Its file was kept.") }
        return (url, text, Self.digest(data))
    }

    func publishOrganization(_ text: String, key: String, expectedDigest: String?) throws -> URL {
        guard try readOrganization(key: key)?.digest == expectedDigest else {
            throw SnapError.message("The current review changed while this task ran. Its newer content was kept. Read the saved task result, then choose Use as current review if you want to replace it.")
        }
        return try writeOrganization(text, key: key)
    }

    func writeOrganization(_ text: String, key: String) throws -> URL {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }), text.utf8.count <= 8 * 1_024 * 1_024 else {
            throw SnapError.message("This review is too large to save. Choose fewer Snaps.")
        }
        try prepareRoot()
        let directory = root.appendingPathComponent("Reviews", isDirectory: true)
        if !manager.fileExists(atPath: directory.path) { try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try requireDirectory(directory)
        let url = try organizationURL(key: key)
        try write(Data(text.utf8), to: url)
        return url
    }
    private func prepareRoot() throws {
        if !manager.fileExists(atPath: root.path) { try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try requireDirectory(root)
    }
    private func itemDirectory(_ id: UUID) throws -> URL {
        try requireDirectory(root)
        let directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try requireDirectory(directory)
        return directory
    }
    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            throw SnapError.message("Snap storage must be an ordinary local directory, without symbolic links.")
        }
    }
    private func readPrivateFile(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= maximum else {
            throw SnapError.message("A Snap file is missing, unsupported or too large. Its files were kept.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw SnapError.message("A Snap file grew beyond the supported size while reading it. Its files were kept.") }
        return data
    }
    private func write(_ data: Data, to url: URL) throws {
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SnapError.message("Snap cannot replace this file safely.") }
        }
        let staged = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        guard manager.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SnapError.message("Snap could not prepare a private file. Check available disk space.")
        }
        defer { try? manager.removeItem(at: staged) }
        let handle = try FileHandle(forWritingTo: staged)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(staged.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // No throwing work after the atomic commit.
    }
}
