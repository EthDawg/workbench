import Foundation
import CryptoKit
import ImageIO

public enum SceneDocumentError: LocalizedError, Equatable {
    case invalid(String), futureVersion, concurrentChange, missingAsset, storageBlocked
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .futureVersion: return "This scene needs a newer Workbench. Its original files have been kept."
        case .concurrentChange: return "This scene changed elsewhere. Reopen it before saving; your original files are kept."
        case .missingAsset: return "A picture in this scene is missing or damaged. Replace it before syncing or exporting."
        case .storageBlocked: return "The scene library could not be read. Its files are preserved and saving is paused."
        }
    }
}

/// Authored coordinates use normalized travel in an unflipped canvas. Device IDs,
/// desktop recovery, capture sources and presentation state never enter this type.
public struct PortableScene: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var background: String
    public var backgroundX = 0.5
    public var backgroundY = 0.5
    public var zoom = 1.0
    /// Opt-in photograph motion. Absent in older documents means still.
    public var gentleMotion: Bool? = nil
    /// Optional local image rig; background remains its complete still poster.
    public var ambience: SceneAmbience? = nil
    public var showsPhone = true
    public var phoneX = 0.5
    public var phoneY = 0.5
    public var phoneHeight = 0.88
    public var viewport: SceneDevice? = nil
    public var logo: SceneLogoLayer? = nil
    public var hand: SceneHandLayer? = nil
    public var persona: ScenePersonaLayer? = nil
    public var groupID: UUID? = nil
    /// Kept with imported mobile collages so conversion never flattens or loses work.
    public var legacyMobileProject: Data? = nil
    /// Original collage layers that a newer scene editor may not expose yet.
    /// They travel with the document for recovery, never as external file links.
    public var retainedAssets: [String]? = nil

    public init(id: UUID = UUID(), name: String, background: String) {
        self.id = id; self.name = name; self.background = background
    }
    public var assets: Set<String> {
        Set([background, logo?.image, hand?.image, persona?.image, persona?.card?.portrait].compactMap { $0 } + (retainedAssets ?? []))
            .union(ambience?.assets ?? [])
    }
    public func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160,
              assets.allSatisfy(SceneAsset.isName),
              (0...1).contains(backgroundX), (0...1).contains(backgroundY), (1...3).contains(zoom),
              (0...1).contains(phoneX), (0...1).contains(phoneY), (0.3...1).contains(phoneHeight),
              (legacyMobileProject?.count ?? 0) <= 8_000_000, (retainedAssets?.count ?? 0) <= 6 else {
            throw SceneDocumentError.invalid("The scene contains unsupported settings. Its original has been kept.")
        }
        try viewport?.validate(); try logo?.validate(); try hand?.validate(); try persona?.validate(); try ambience?.validate()
        return self
    }
}

public struct SceneDevice: Codable, Equatable, Sendable {
    public var aspect: Double
    public var border: Double
    public var corners: Double
    public init(aspect: Double = 9.0 / 19.5, border: Double = 0.009, corners: Double = 0.10) {
        self.aspect = aspect; self.border = border; self.corners = corners
    }
    func validate() throws {
        guard (0.3...2.4).contains(aspect), (0.003...0.035).contains(border), (0...0.3).contains(corners)
        else { throw SceneDocumentError.invalid("This device frame is not valid.") }
    }
}

public struct SceneLogoLayer: Codable, Equatable, Sendable {
    public var image: String
    public var corner: String
    public var width: Double
    public var backing: String
    public init(image: String, corner: String = "topRight", width: Double = 0.16, backing: String = "light") {
        self.image = image; self.corner = corner; self.width = width; self.backing = backing
    }
    func validate() throws {
        guard SceneAsset.isName(image), ["topLeft", "topRight", "bottomLeft", "bottomRight"].contains(corner),
              ["none", "light", "dark"].contains(backing), (0.08...0.28).contains(width)
        else { throw SceneDocumentError.invalid("This scene logo is not valid.") }
    }
}

public struct SceneHandLayer: Codable, Equatable, Sendable {
    public var image: String
    public var scale: Double
    public var x: Double
    public var y: Double
    public var mirrored: Bool
    public var tone: String
    public init(image: String, scale: Double = 1, x: Double = 0, y: Double = 0, mirrored: Bool = false, tone: String = "original") {
        self.image = image; self.scale = scale; self.x = x; self.y = y; self.mirrored = mirrored; self.tone = tone
    }
    func validate() throws {
        guard SceneAsset.isName(image), (0.35...2).contains(scale), (-1...1).contains(x), (-1...1).contains(y),
              ["original", "lighter", "deeper"].contains(tone)
        else { throw SceneDocumentError.invalid("This scene hand layer is not valid.") }
    }
}

public struct SceneCardStyle: Codable, Equatable, Sendable {
    public var portrait: String
    public var label: String
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(portrait: String, label: String, red: Double, green: Double, blue: Double) {
        self.portrait = portrait; self.label = label; self.red = red; self.green = green; self.blue = blue
    }
    func validate() throws {
        guard SceneAsset.isName(portrait), label.count <= 80,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              [red, green, blue].allSatisfy({ (0...1).contains($0) })
        else { throw SceneDocumentError.invalid("This persona label or colour is not valid.") }
    }
}

public struct ScenePersonaLayer: Codable, Equatable, Sendable {
    /// Independent rendered fallback. Changing a library card cannot alter it.
    public var image: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var card: SceneCardStyle? = nil
    public init(image: String, x: Double = 0.98, y: Double = 0.02, width: Double = 0.16) {
        self.image = image; self.x = x; self.y = y; self.width = width
    }
    func validate() throws {
        guard SceneAsset.isName(image), (0...1).contains(x), (0...1).contains(y), (0.06...0.4).contains(width)
        else { throw SceneDocumentError.invalid("This scene persona is not valid.") }
        try card?.validate()
    }
}

public enum SceneAsset {
    // Match the existing Mac library's 40 MiB image limit during migration.
    public static let maximumBytes = 40 * 1024 * 1024
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func name(for data: Data) -> String { digest(data) + ".image" }
    public static func isName(_ value: String) -> Bool {
        value.count == 70 && value.hasSuffix(".image") && value.prefix(64).allSatisfy { "0123456789abcdef".contains($0) }
    }
    public static func validate(_ data: Data, named name: String) throws {
        guard isName(name), !data.isEmpty, data.count <= maximumBytes, self.name(for: data) == name,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 50_000_000
        else { throw SceneDocumentError.missingAsset }
    }
}

/// A portable export is also the unit sent to iCloud: authored metadata and every
/// required picture in one bounded binary property list, never local file paths.
public struct ScenePackage: Codable, Equatable, Sendable {
    public var format = "workbench-scene"
    public var version = 1
    public var scene: PortableScene
    public var assets: [String: Data]
    public static let maximumBytes = 100_000_000
    public init(scene: PortableScene, assets: [String: Data]) {
        self.scene = scene; self.assets = assets; version = scene.ambience == nil ? 1 : 2
    }
    public func validated() throws -> Self {
        guard format == "workbench-scene", (1...2).contains(version),
              version >= 2 || scene.ambience == nil else { throw SceneDocumentError.futureVersion }
        _ = try scene.validated()
        guard Set(assets.keys) == scene.assets, assets.count <= 12,
              assets.values.reduce(0, { $0 + $1.count }) <= 90_000_000 else { throw SceneDocumentError.missingAsset }
        for (name, bytes) in assets { try SceneAsset.validate(bytes, named: name) }
        return self
    }
    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(validated())
        guard data.count <= Self.maximumBytes else { throw SceneDocumentError.invalid("This scene is too large to transfer. Choose smaller source pictures.") }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SceneDocumentError.invalid("This scene file is too large to open safely.") }
        return try PropertyListDecoder().decode(Self.self, from: data).validated()
    }
}
