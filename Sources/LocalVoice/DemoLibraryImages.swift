import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An in-memory handoff, never a reference into a capture cache or an asset store.
struct DemoLibraryImageSnapshot {
    let data: Data
    let title: String
}

enum DemoLibraryImageUse {
    case present, persona
    var contentTypes: [UTType] {
        switch self {
        case .present: return [.png, .jpeg, .heic]
        case .persona: return [.png, .jpeg, .heic, .webP, .gif, .tiff]
        }
    }
    func supports(_ item: DemoResource) -> Bool {
        guard item.kind == .file, let type = UTType(filenameExtension: URL(fileURLWithPath: item.content).pathExtension) else { return false }
        return contentTypes.contains(type)
    }
}

enum DemoLibraryImageFile {
    static let maximumPreparationBytes = 40 * 1_024 * 1_024
    static let maximumExportBytes = 100 * 1_024 * 1_024

    /// File-provider short reads and replacement during reading must not produce
    /// a different source from the file the person chose. No reference is refreshed here.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        var checkedURL = url
        checkedURL.removeAllCachedResourceValues()
        let before = try checkedURL.resourceValues(forKeys: keys)
        guard before.isRegularFile == true, let size = before.fileSize, size > 0, size <= maximumBytes,
              !FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VoiceError.message("Choose a readable image under \(maximumBytes / 1_024 / 1_024) MB. Use Locate file if this reference has changed.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        checkedURL.removeAllCachedResourceValues()
        let after = try checkedURL.resourceValues(forKeys: keys)
        guard data.count <= maximumBytes, data.count == size, before.fileSize == after.fileSize,
              before.contentModificationDate == after.contentModificationDate,
              (before.fileResourceIdentifier as? NSObject) == (after.fileResourceIdentifier as? NSObject) else {
            throw VoiceError.message("This image changed while it was being opened. Use Locate file to review it, then try again.")
        }
        return data
    }

    static func validate(_ data: Data, contentTypes: [UTType], maximumBytes: Int, maximumPixels: Double = 50_000_000) throws {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?, contentTypes.contains(where: { $0.identifier == identifier }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0, width * height <= maximumPixels,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil else {
            throw VoiceError.message("This image is not supported here. Choose a valid image under \(maximumBytes / 1_024 / 1_024) MB and \(Int(maximumPixels / 1_000_000)) megapixels.")
        }
    }
}
