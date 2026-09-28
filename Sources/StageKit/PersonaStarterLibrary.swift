import AppKit
import ImageIO
import UniformTypeIdentifiers

struct PersonaStarter: Identifiable, Equatable {
    let id: String
    let label: String
    /// Circle's curated framing: head and shoulders, with room above the hair.
    var framing = PersonaFraming(x: 0.5, y: 0.57, zoom: 1.28)
    var filename: String { id + ".png" }
}

/// A bundled choice is a source picture, never an automatically saved persona.
/// Imports use the same owned-copy and active-group rules as a chosen local file.
struct PersonaStarterLibrary {
    static let portraits: [PersonaStarter] = [
        .init(id: "care-lead", label: "Care lead"),
        .init(id: "field-lead", label: "Field lead"),
        .init(id: "front-desk", label: "Front desk"),
        .init(id: "operations-lead", label: "Operations lead"),
        .init(id: "logistics-lead", label: "Logistics lead"),
        .init(id: "care-coordinator", label: "Care coordinator"),
        .init(id: "hospitality-lead", label: "Hospitality lead"),
        .init(id: "field-technician", label: "Field technician")
    ]

    let directory: URL?
    init(directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("PersonaPortraits", isDirectory: true)) {
        self.directory = directory
    }

    func source(for portrait: PersonaStarter) -> URL? {
        guard Self.portraits.contains(portrait), let directory, directory.isFileURL,
              let folder = try? FileManager.default.attributesOfItem(atPath: directory.path),
              folder[.type] as? FileAttributeType == .typeDirectory else { return nil }
        let url = directory.appendingPathComponent(portrait.filename)
        guard let file = try? FileManager.default.attributesOfItem(atPath: url.path),
              file[.type] as? FileAttributeType == .typeRegular,
              let bytes = file[.size] as? NSNumber, bytes.intValue > 0,
              bytes.intValue <= LogoImport.maximumBytes else { return nil }
        return url
    }

    func thumbnail(for portrait: PersonaStarter) -> NSImage? {
        guard let url = source(for: portrait), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 50_000_000,
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 360
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: bitmap, size: CGSize(width: bitmap.width, height: bitmap.height))
    }

    /// The starter as a new editable portrait draft. Choosing a starter saves
    /// nothing; `PersonaLibrary.add(_:)` does, at Add persona.
    func draft(_ portrait: PersonaStarter, for library: PersonaLibrary) throws -> PersonaPortraitDraft {
        guard let url = source(for: portrait), thumbnail(for: portrait) != nil else {
            throw PersonaStarterError.unavailable
        }
        return try library.portraitDraft(from: url, card: PersonaCardStyle(label: portrait.label), framing: portrait.framing)
    }
}

enum PersonaStarterError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "This starter portrait is unavailable in this build. Choose another portrait or import your own."
    }
}
