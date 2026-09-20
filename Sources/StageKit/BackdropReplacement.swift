import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import SceneSyncKit

enum BackdropReplacementError: LocalizedError {
    case noChange, sceneMissing, staleScene, imageChanged, closed
    var errorDescription: String? {
        switch self {
        case .noChange: return "Choose a different backdrop or adjust its crop first."
        case .sceneMissing: return "This scene is no longer available. Cancel and choose a saved scene."
        case .staleScene: return "This scene’s backdrop changed while the preview was open. Cancel and reopen Change backdrop to use its latest version."
        case .imageChanged: return "That saved backdrop changed or is missing. Choose the image again before applying it."
        case .closed: return "This preview has closed. Open Change backdrop again."
        }
    }
}

struct SceneBackdrop: Equatable {
    var image: String
    var x: Double
    var y: Double
    var zoom: Double
    var ambience: SceneAmbience?
    var gentleMotion: Bool?
    init(_ scene: DemoScene) {
        image = scene.background; x = scene.backgroundX; y = scene.backgroundY; zoom = scene.zoom
        ambience = scene.ambience; gentleMotion = scene.gentleMotion
    }
    func applying(to scene: DemoScene) throws -> DemoScene {
        var next = scene
        if scene.background != image { next.ambience = nil; next.gentleMotion = nil }
        next.background = image; next.backgroundX = x; next.backgroundY = y; next.zoom = zoom
        return try next.validated()
    }
}

/// One bounded, immutable still-image snapshot. Preview never copies files to
/// the scene folder and never depends on a security-scoped URL staying open.
struct BackdropImage {
    static let contentTypes: [UTType] = [.png, .jpeg, .heic]
    static let maximumBytes = 40 * 1024 * 1024
    let data: Data
    let image: NSImage
    let fileExtension: String
    let digest: Data

    static func read(_ url: URL, thumbnailSize: Int = 2560) throws -> BackdropImage {
        guard url.isFileURL else { throw SceneError.invalidImage }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size > 0, size <= maximumBytes else { throw SceneError.invalidImage }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try handle.read(upToCount: min(1024 * 1024, maximumBytes + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return try decode(data, thumbnailSize: thumbnailSize)
    }
    /// Gallery thumbnails decode directly from the file, without retaining or
    /// hashing its full encoded bytes. A selected candidate is snapshotted later.
    static func thumbnail(_ url: URL, size: Int = 360) throws -> NSImage {
        guard url.isFileURL else { throw SceneError.invalidImage }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0, bytes <= maximumBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw SceneError.invalidImage }
        _ = try validatedContentType(source)
        return try thumbnail(source, size: size)
    }
    static func decode(_ data: Data, thumbnailSize: Int = 2560) throws -> BackdropImage {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw SceneError.invalidImage }
        let contentType = try validatedContentType(source)
        return BackdropImage(data: data, image: try thumbnail(source, size: thumbnailSize),
                             fileExtension: contentType == .jpeg ? "jpg" : contentType == .heic ? "heic" : "png",
                             digest: Data(SHA256.hash(data: data)))
    }
    private static func validatedContentType(_ source: CGImageSource) throws -> UTType {
        guard let type = CGImageSourceGetType(source) as String?,
              let contentType = contentTypes.first(where: { $0.identifier == type }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0, width * height <= 50_000_000
        else { throw SceneError.invalidImage }
        return contentType
    }
    private static func thumbnail(_ source: CGImageSource, size: Int) throws -> NSImage {
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(2560, max(1, size)),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw SceneError.invalidImage }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

struct BackdropChoice: Identifiable {
    let id: String
    let name: String
    let caption: String
    let url: URL
    let existingFilename: String?
    let thumbnail: NSImage
}

enum BackdropChoices {
    /// One choice per referenced filename; duplicates share their existing
    /// asset. Cancellation is checked between bounded thumbnail decodes.
    static func saved(scenes: [DemoScene], root: URL, preferred: DemoScene,
                      isCancelled: () -> Bool = { false }) -> [BackdropChoice] {
        var filenames = Set<String>(), result: [BackdropChoice] = []
        for scene in [preferred] + scenes {
            if isCancelled() { break }
            guard (try? scene.validated()) != nil, filenames.insert(scene.background).inserted else { continue }
            let choice: BackdropChoice? = autoreleasepool {
                let url = root.appendingPathComponent(scene.background)
                guard let image = try? BackdropImage.thumbnail(url) else { return nil }
                return BackdropChoice(id: "saved:" + scene.background, name: scene.name, caption: "Saved scene",
                                      url: url, existingFilename: scene.background, thumbnail: image)
            }
            if isCancelled() { break }
            if let choice { result.append(choice) }
        }
        return result
    }
    static func starters(_ starters: [SceneStarter], directory: URL = SceneStarters.directory,
                         isCancelled: () -> Bool = { false }) -> [BackdropChoice] {
        var result: [BackdropChoice] = []
        for starter in starters {
            if isCancelled() { break }
            let choice: BackdropChoice? = autoreleasepool {
                let url = starter.url(in: directory)
                guard let image = try? BackdropImage.thumbnail(url) else { return nil }
                return BackdropChoice(id: "starter:" + starter.id, name: starter.name, caption: "Bundled starter",
                                      url: url, existingFilename: nil, thumbnail: image)
            }
            if isCancelled() { break }
            if let choice { result.append(choice) }
        }
        return result
    }
}

final class BackdropReplacement: ObservableObject, Identifiable {
    struct Candidate {
        let selectionID: String
        let name: String
        let source: String
        let image: BackdropImage
        let existingFilename: String?
    }
    let id = UUID()
    let sceneID: UUID
    let original: SceneBackdrop
    let root: URL
    @Published var x: Double
    @Published var y: Double
    @Published var zoom: Double
    @Published private(set) var candidate: Candidate?
    @Published var notice: String?
    @Published private(set) var choosingFile = false
    private(set) var active = true
    private var originalDigest: Data?
    private var panel: NSOpenPanel?

    init(scene: DemoScene, root: URL) {
        sceneID = scene.id; original = SceneBackdrop(scene); self.root = root
        x = scene.backgroundX; y = scene.backgroundY; zoom = scene.zoom
        if (try? scene.validated()) != nil,
           let image = try? BackdropImage.read(root.appendingPathComponent(scene.background)) {
            originalDigest = image.digest
            candidate = Candidate(selectionID: "saved:" + scene.background, name: scene.name,
                                  source: "Current backdrop", image: image, existingFilename: scene.background)
        }
    }
    var canApply: Bool {
        guard active, !choosingFile, let candidate, [x, y, zoom].allSatisfy(\.isFinite),
              (0...1).contains(x), (0...1).contains(y), (1...3).contains(zoom) else { return false }
        return candidate.existingFilename != original.image || x != original.x || y != original.y || zoom != original.zoom
    }
    func previewScene(current: DemoScene) -> DemoScene {
        var scene = current
        scene.backgroundX = x; scene.backgroundY = y; scene.zoom = zoom
        return scene
    }
    func centreCrop() { x = 0.5; y = 0.5; zoom = 1 }
    func choose(_ choice: BackdropChoice) throws {
        try chooseImage(choice.url, name: choice.name, source: choice.caption, selectionID: choice.id, existingFilename: choice.existingFilename)
    }
    func chooseImage(_ url: URL, name: String? = nil, source: String = "Chosen image",
                     selectionID: String? = nil, existingFilename: String? = nil) throws {
        guard active else { throw BackdropReplacementError.closed }
        let image = try BackdropImage.read(url)
        var filename = existingFilename
        // Choosing the current image again should neither reset its crop nor
        // write a duplicate. Keep explicit saved-image choices otherwise.
        if filename == nil {
            let reusable = image.digest == originalDigest ? original.image
                : image.digest == candidate?.image.digest ? candidate?.existingFilename : nil
            if let reusable, let saved = try? BackdropImage.read(root.appendingPathComponent(reusable)), saved.digest == image.digest {
                filename = reusable
            }
        }
        if image.digest != candidate?.image.digest { centreCrop() }
        candidate = Candidate(selectionID: filename.map { "saved:" + $0 } ?? selectionID ?? UUID().uuidString,
                              name: String((name ?? url.lastPathComponent).prefix(160)), source: source,
                              image: image, existingFilename: filename)
        notice = nil
    }
    func chooseFile() {
        guard active, !choosingFile else { return }
        choosingFile = true
        let picker = NSOpenPanel(); picker.allowedContentTypes = BackdropImage.contentTypes
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.message = "Preview a replacement backdrop. Your saved scene changes only when you choose Use backdrop."
        panel = picker
        picker.begin { [weak self, weak picker] response in
            guard let self else { return }
            let chosenURL = picker?.url
            self.panel = nil; self.choosingFile = false
            guard self.active, response == .OK, let url = chosenURL else { return }
            do { try self.chooseImage(url) }
            catch { self.notice = error.localizedDescription + " The previous preview is unchanged." }
        }
    }
    func cancel() {
        active = false; panel?.cancel(nil); panel = nil; choosingFile = false; candidate = nil
    }
}
