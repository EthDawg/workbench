import AppKit
import ImageIO

/// Bundled originals are templates, never user documents. Choosing one imports
/// a durable copy through the same path as a customer's own backdrop.
struct SceneStarter: Identifiable {
    let id: String
    var name: String
    let group: String
    var ambientPreset: String? { ["window-light", "campus-breeze", "coastal-sky"].contains(id) ? id : nil }
    var detailFilename: String { id == "campus-breeze" ? "eucalyptus.png" : "clouds.png" }
    var filename: String { ambientPreset == nil ? "stagemark-\(id).png" : id + "-poster.png" }
    func url(in directory: URL = SceneStarters.directory) -> URL {
        (ambientPreset == nil ? directory : directory.deletingLastPathComponent().appendingPathComponent("AmbientScenes"))
            .appendingPathComponent(filename)
    }
    func thumbnail() -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url() as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 560,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

enum SceneStarters {
    static var directory: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("SceneBackdrops")
    }
    static let all: [SceneStarter] = [
        .init(id: "window-light", name: "Window light", group: "Quiet motion"),
        .init(id: "campus-breeze", name: "Campus breeze", group: "Quiet motion"),
        .init(id: "coastal-sky", name: "Coastal sky", group: "Quiet motion"),
        .init(id: "office-professional", name: "Office & professional", group: "Everyday settings"),
        .init(id: "care-service", name: "Care & service", group: "Everyday settings"),
        .init(id: "higher-education-campus", name: "Higher education campus", group: "Australian sectors"),
        .init(id: "acute-healthcare", name: "Acute healthcare", group: "Australian sectors"),
        .init(id: "aged-care", name: "Aged care", group: "Australian sectors"),
        .init(id: "allied-health-ndis", name: "Allied health / NDIS", group: "Australian sectors"),
        .init(id: "financial-services", name: "Financial services", group: "Australian sectors"),
        .init(id: "mining-resources", name: "Mining & resources", group: "Australian sectors")
    ]
}

enum LogoCorner: String, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

enum LogoBacking: String, Codable, CaseIterable {
    case none, light, dark
    var label: String { rawValue.capitalized }
}

struct SceneLogo: Codable, Equatable {
    var image: String
    var corner: LogoCorner = .topRight
    var width = 0.16
    var backing: LogoBacking = .light
    func validated() throws -> SceneLogo {
        guard image == URL(fileURLWithPath: image).lastPathComponent,
              !image.isEmpty, !image.hasPrefix("."), !image.contains("/"), !image.contains("\\"),
              width.isFinite else { throw SceneError.invalidScene }
        var result = self; result.width = min(0.28, max(0.08, width)); return result
    }
}
