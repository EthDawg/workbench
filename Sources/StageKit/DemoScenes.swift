import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import SceneSyncKit

struct DemoScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Untitled scene"
    var background: String
    var backgroundX = 0.5
    var backgroundY = 0.5
    var zoom = 1.0
    var gentleMotion: Bool? = nil
    var ambience: SceneAmbience? = nil
    var showsPhone = true
    var phoneX = 0.5
    var phoneY = 0.5
    var phoneHeight = 0.88
    var logo: SceneLogo? = nil
    var viewport: DeviceViewport? = nil
    var hand: SceneHand? = nil
    var persona: PersonaPlacement? = nil
    /// Local edit provenance, deliberately absent from portable/legacy JSON.
    var libraryRevision: UUID? = nil
    private enum CodingKeys: String, CodingKey {
        case id, name, background, backgroundX, backgroundY, zoom, gentleMotion, ambience, showsPhone,
             phoneX, phoneY, phoneHeight, logo, viewport, hand, persona
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.background == rhs.background &&
        lhs.backgroundX == rhs.backgroundX && lhs.backgroundY == rhs.backgroundY && lhs.zoom == rhs.zoom &&
        lhs.gentleMotion == rhs.gentleMotion && lhs.ambience == rhs.ambience &&
        lhs.showsPhone == rhs.showsPhone && lhs.phoneX == rhs.phoneX && lhs.phoneY == rhs.phoneY &&
        lhs.phoneHeight == rhs.phoneHeight && lhs.logo == rhs.logo && lhs.viewport == rhs.viewport &&
        lhs.hand == rhs.hand && lhs.persona == rhs.persona
    }

    func validated() throws -> DemoScene {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 160, background == URL(fileURLWithPath: background).lastPathComponent,
              !background.hasPrefix("."), !background.contains("/"), !background.contains("\\"),
              !background.isEmpty,
              [backgroundX, backgroundY, zoom, phoneX, phoneY, phoneHeight].allSatisfy(\.isFinite)
        else { throw SceneError.invalidScene }
        var value = self
        value.ambience = try ambience?.validated()
        value.logo = try logo?.validated()
        value.viewport = try viewport?.validated()
        value.hand = try hand?.validated()
        value.persona = try persona?.validated()
        value.backgroundX = min(1, max(0, backgroundX)); value.backgroundY = min(1, max(0, backgroundY))
        value.zoom = min(3, max(1, zoom))
        value.phoneHeight = min(ViewportGeometry.heightRange.upperBound, max(ViewportGeometry.heightRange.lowerBound, phoneHeight))
        value.phoneX = min(1, max(0, phoneX)); value.phoneY = min(1, max(0, phoneY))
        return value
    }
}

enum SceneError: LocalizedError {
    case invalidScene, futureVersion, invalidImage, storageBlocked, noScene, desktopUnavailable, missingLogo, invalidHand, missingHand, missingPersona
    var errorDescription: String? {
        switch self {
        case .missingPersona: return "The persona image is missing. Replace or remove it before presenting or exporting."
        case .invalidHand: return "Choose a hand cutout PNG with real transparency. A white background or checkerboard photograph cannot wrap around the device."
        case .missingHand: return "The hand cutout is missing. Replace or remove it before presenting or exporting."
        case .missingLogo: return "The customer logo is missing. Replace or remove it before exporting or applying this scene."
        case .invalidScene: return "This scene contains invalid settings. The original has been kept."
        case .futureVersion: return "These scenes need a newer Workbench. The original has been kept."
        case .invalidImage: return "Choose a PNG, JPEG or HEIC image under 40 MB and 50 megapixels."
        case .storageBlocked: return "The saved scenes could not be read. They are preserved; no changes have been saved."
        case .noScene: return "Choose a scene first."
        case .desktopUnavailable: return "The current desktop picture could not be saved for restoration. Export the scene instead."
        }
    }
}

struct SceneArchive: Codable {
    var version = 1
    var scenes: [DemoScene] = []
}

enum SceneStorage {
    static func load(_ url: URL) throws -> [DemoScene] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let archive = try JSONDecoder().decode(SceneArchive.self, from: Data(contentsOf: url))
        guard (1...2).contains(archive.version), archive.version == 2 || archive.scenes.allSatisfy({ $0.ambience == nil }) else { throw SceneError.futureVersion }
        guard Set(archive.scenes.map(\.id)).count == archive.scenes.count else { throw SceneError.invalidScene }
        return try archive.scenes.map { try $0.validated() }
    }
    static func save(_ scenes: [DemoScene], to url: URL) throws {
        let checked = try scenes.map { try $0.validated() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(SceneArchive(version: checked.contains(where: { $0.ambience != nil }) ? 2 : 1, scenes: checked)).write(to: url, options: .atomic)
    }
}

/// One rendering path for the editor and the exported desktop picture.
enum SceneRenderer {
    static func phoneRect(_ scene: DemoScene, in size: CGSize) -> CGRect {
        ViewportGeometry(scene: scene, size: size).outer
    }
    static func logoRect(_ logo: SceneLogo, imageSize: CGSize, in size: CGSize) -> CGRect {
        let margin = min(size.width, size.height) * 0.035
        let maxWidth = size.width * logo.width
        let maxHeight = size.height * 0.16
        let scale = min(maxWidth / max(1, imageSize.width), maxHeight / max(1, imageSize.height))
        let width = imageSize.width * scale, height = imageSize.height * scale
        let left = logo.corner == .topLeft || logo.corner == .bottomLeft
        let top = logo.corner == .topLeft || logo.corner == .topRight
        return CGRect(x: left ? margin : size.width - margin - width,
                      y: top ? size.height - margin - height : margin, width: width, height: height)
    }
    static func draw(_ scene: DemoScene, image: NSImage, size: CGSize, logoImage: NSImage? = nil, handImage: NSImage? = nil, personaImage: NSImage? = nil, drawsBackground: Bool = true) {
        let bounds = CGRect(origin: .zero, size: size)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        if drawsBackground {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let scale = max(size.width / image.size.width, size.height / image.size.height) * scene.zoom
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: (size.width - fitted.width) * scene.backgroundX,
                              y: (size.height - fitted.height) * scene.backgroundY,
                              width: fitted.width, height: fitted.height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        }
        if scene.showsPhone, let hand = scene.hand, let handImage {
            HandRenderer.draw(hand, image: handImage, device: phoneRect(scene, in: size))
        }
        if scene.showsPhone {
            let geometry = ViewportGeometry(scene: scene, size: size)
            let frame = geometry.outer
            let outer = NSBezierPath(roundedRect: frame, xRadius: geometry.outerRadius, yRadius: geometry.outerRadius)
            let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.32)
            shadow.shadowBlurRadius = frame.width * 0.06; shadow.shadowOffset = CGSize(width: 0, height: -frame.width * 0.025)
            NSGraphicsContext.saveGraphicsState(); shadow.set()
            NSColor(srgbRed: 0.06, green: 0.065, blue: 0.075, alpha: 1).setFill(); outer.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: geometry.screen, xRadius: geometry.innerRadius, yRadius: geometry.innerRadius).fill()
        }
        drawLogo(scene, size: size, image: logoImage)
        drawPersona(scene, size: size, image: personaImage)
        NSGraphicsContext.restoreGraphicsState()
    }
    static func drawLogo(_ scene: DemoScene, size: CGSize, image: NSImage?) {
        if let logo = scene.logo, let logoImage = image {
            let rect = logoRect(logo, imageSize: logoImage.size, in: size)
            if logo.backing != .none {
                let pad = min(size.width, size.height) * 0.012
                (logo.backing == .light ? NSColor.white : NSColor.black).withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -pad, dy: -pad), xRadius: pad * 0.6, yRadius: pad * 0.6).fill()
            }
            logoImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    static func drawPersona(_ scene: DemoScene, size: CGSize, image: NSImage?) {
        guard let persona = scene.persona, let image else { return }
        image.draw(in: PersonaGeometry.rect(persona, imageSize: image.size, in: size),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
    static func png(_ scene: DemoScene, image: NSImage, size: CGSize, logoImage: NSImage? = nil, handImage: NSImage? = nil, personaImage: NSImage? = nil) throws -> Data {
        guard size.width >= 1, size.height >= 1, size.width <= 8192, size.height <= 8192,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw SceneError.invalidImage }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        draw(scene, image: image, size: size, logoImage: logoImage, handImage: handImage, personaImage: personaImage)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SceneError.invalidImage }
        return data
    }
}

enum DesktopImageVerification {
    static func matches(_ current: URL?, _ expected: URL) -> Bool {
        guard let current else { return false }
        if current == expected { return true }
        guard current.isFileURL, expected.isFileURL else { return false }
        return current.standardizedFileURL.resolvingSymlinksInPath() == expected.standardizedFileURL.resolvingSymlinksInPath()
    }

    // macOS may finish the change after setDesktopImageURL returns. Yield to the
    // main run loop between reads; a timeout keeps recovery available.
    static func confirm(_ expected: URL, read: @escaping () -> URL?, attempts: Int = 12,
                        schedule: @escaping (@escaping () -> Void) -> Void = { next in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: next)
                        }, completion: @escaping (Bool) -> Void) {
        if matches(read(), expected) { completion(true); return }
        guard attempts > 0 else { completion(false); return }
        schedule { confirm(expected, read: read, attempts: attempts - 1, schedule: schedule, completion: completion) }
    }
}

struct DesktopSnapshot: Codable {
    var screenID: String
    var originalURL: URL
    var appliedURL: URL
    var pendingURL: URL?
    var scaling: Int?
    var clipping: Bool?
    var fill: [Double]?
    func owns(_ url: URL?) -> Bool {
        DesktopImageVerification.matches(url, appliedURL) || pendingURL.map { DesktopImageVerification.matches(url, $0) } == true
    }
    func preparingSwitch(to next: URL, current: URL?) -> DesktopSnapshot? {
        guard let current, owns(current) else { return nil }
        var snapshot = self
        // A previous pending picture may already be on screen after an interrupted
        // finalization. Preserve that observed picture before replacing pendingURL.
        snapshot.appliedURL = current
        snapshot.pendingURL = next
        return snapshot
    }
}

final class DemoScenes: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var scenes: [DemoScene] = [] { didSet { reconcileSelection() } }
    @Published var query = "" { didSet { reconcileSelection() } }
    @Published var selectedID: UUID?
    @Published var notice: String?
    @Published var choosingPersonas = false
    var personaSceneID: UUID?
    @Published private(set) var storageBlocked = false
    @Published private(set) var hasDesktopSnapshot = false
    @Published private(set) var desktopBusy = false
    @Published private(set) var screenAspect: CGFloat = 16.0 / 9.0
    let root: URL
    let systemIntegrationEnabled: Bool
    let personas: PersonaLibrary
    @Published private(set) var sceneSync: MacSceneSync?
    private var window: NSWindow?
    private var presentation: DemoPresentation?
    let desktopMotion = MainActor.assumeIsolated { DesktopMotionController() }
    var onOpen: (() -> Void)?
    var onBeginPresentation: (() -> Void)?
    var mayBeginInteraction: (() -> Bool)?
    var isPresenting: Bool { presentation != nil }
    @Published private(set) var myDevice: DeviceViewport?
    @Published private(set) var savedLogos: [SavedSceneLogo] = []
    @Published private(set) var starterPreferences = StarterPreferences()
    private var logoLibraryBlocked = false
    private var starterLibraryBlocked = false
    private var lastMigrationNotice: String?
    var starters: [SceneStarter] { starterPreferences.visible }
    private let imageCache = NSCache<NSString, NSImage>()
    var matches: [DemoScene] { scenes.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var selected: DemoScene? { matches.first { $0.id == selectedID } }
    private func reconcileSelection() {
        if !matches.contains(where: { $0.id == selectedID }) { selectedID = matches.first?.id }
    }
    private var archiveURL: URL { root.appendingPathComponent("scenes.json") }
    private var snapshotURL: URL { root.appendingPathComponent("desktop-restore.json") }
    init(root: URL? = nil, readOnlyReason: String? = nil, systemIntegrationEnabled: Bool = true) {
        self.root = root ?? Workbench.supportDirectory(component: "StageMark").appendingPathComponent("Scenes")
        self.systemIntegrationEnabled = systemIntegrationEnabled
        self.personas = PersonaLibrary(root: self.root, readOnlyReason: readOnlyReason)
        super.init()
        if let readOnlyReason {
            storageBlocked = true; logoLibraryBlocked = true; starterLibraryBlocked = true
            notice = readOnlyReason
            return
        }
        imageCache.countLimit = 8; imageCache.totalCostLimit = 150 * 1024 * 1024
        MainActor.assumeIsolated {
            let adapter = MacSceneSync(root: self.root, systemIntegrationEnabled: systemIntegrationEnabled)
            sceneSync = adapter
            adapter.onChange = { [weak self] in self?.adoptCanonicalScenes() }
            adoptCanonicalScenes(); selectedID = scenes.first?.id
        }
        do {
            let libraryURL = self.root.appendingPathComponent("saved-logos.json")
            savedLogos = try SceneLibraryStorage.read([SavedSceneLogo].self, from: libraryURL, fallback: []).map { try $0.validated() }
            guard Set(savedLogos.map(\.id)).count == savedLogos.count else { throw SceneError.invalidScene }
            // One-time adoption: a deliberately emptied library stays empty.
            // Existing scene images remain the source of truth and are never moved.
            if !storageBlocked, !FileManager.default.fileExists(atPath: libraryURL.path) {
                var adopted: [SavedSceneLogo] = []
                var artwork = Set<Data>()
                for scene in scenes {
                    if let logo = scene.logo, let data = try? Data(contentsOf: self.root.appendingPathComponent(logo.image)),
                       NSImage(data: data) != nil, artwork.insert(data).inserted {
                        adopted.append(try SavedSceneLogo(name: scene.name, image: logo.image).validated())
                    }
                }
                try SceneLibraryStorage.write(adopted, to: libraryURL); savedLogos = adopted
            }
        } catch { savedLogos = []; logoLibraryBlocked = true; notice = "The saved-logo library could not be read. Its original file is preserved." }
        do {
            starterPreferences = try SceneLibraryStorage.read(StarterPreferences.self, from: self.root.appendingPathComponent("starter-preferences.json"), fallback: StarterPreferences())
        } catch { starterLibraryBlocked = true; notice = "Starter customizations could not be read. Their original file is preserved." }
        hasDesktopSnapshot = FileManager.default.fileExists(atPath: snapshotURL.path)
        if let data = try? Data(contentsOf: self.root.appendingPathComponent("my-device.json")) {
            myDevice = try? JSONDecoder().decode(DeviceViewport.self, from: data).validated()
        }
    }
    private func adoptCanonicalScenes() {
        MainActor.assumeIsolated {
            guard let sceneSync else { return }
            scenes = sceneSync.scenes; storageBlocked = sceneSync.isBlocked
            if let message = sceneSync.migrationNotice { notice = message }
            else if notice == lastMigrationNotice { notice = nil }
            lastMigrationNotice = sceneSync.migrationNotice
        }
    }
    func isSceneReadOnly(_ scene: DemoScene) -> Bool {
        MainActor.assumeIsolated { storageBlocked || sceneSync?.isReadOnly(scene.id) != false }
    }
    func show() {
        if let onOpen { refreshScreen(); onOpen(); return }
        if window == nil {
            let created = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1060, height: 780),
                                   styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            created.title = "\(Workbench.displayName) · Demo scenes"
            created.delegate = self
            created.minSize = CGSize(width: 850, height: 680); created.isReleasedWhenClosed = false
            created.contentView = NSHostingView(rootView: DemoScenesView(model: self))
            created.center(); window = created; refreshScreen()
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func image(for scene: DemoScene) -> NSImage? {
        guard MainActor.assumeIsolated({ sceneSync?.unavailableAssetIDs.contains(scene.id) != true }) else { return nil }
        if let cached = imageCache.object(forKey: scene.background as NSString) { return cached }
        guard (try? scene.validated()) != nil,
              let image = NSImage(contentsOf: root.appendingPathComponent(scene.background)) else { return nil }
        let cost = Int(min(200_000_000, image.size.width * image.size.height * 4))
        imageCache.setObject(image, forKey: scene.background as NSString, cost: cost); return image
    }
    func showPersonas(for sceneID: UUID? = nil) {
        personaSceneID = sceneID
        choosingPersonas = true
        show()
    }
    func saveMyDevice() {
        guard let scene = selected else { return }
        do {
            let profile = try (scene.viewport ?? .legacy).validated()
            try JSONEncoder().encode(profile).write(to: root.appendingPathComponent("my-device.json"), options: .atomic)
            myDevice = profile; notice = "My device saved. Use it in any scene."
        } catch { notice = error.localizedDescription }
    }
    func startDemo(mode: PresentationMode = .fullScreen) {
        guard systemIntegrationEnabled else { return }
        guard mayBeginInteraction?() != false else { notice = "Finish your current recording or keyboard practice before presenting."; return }
        guard let scene = selected, let image = image(for: scene) else { return }
        if scene.logo != nil && logoImage(for: scene) == nil { notice = SceneError.missingLogo.localizedDescription; return }
        if scene.hand != nil && handImage(for: scene) == nil { notice = SceneError.missingHand.localizedDescription; return }
        if scene.persona != nil && personaImage(for: scene) == nil { notice = SceneError.missingPersona.localizedDescription; return }
        if presentation != nil { presentation?.bringForward(); return }
        personas.pauseOverlaySession()
        onBeginPresentation?()
        let presenter = DemoPresentation(scene: scene, image: image, logo: logoImage(for: scene), hand: handImage(for: scene), persona: personaImage(for: scene), ambience: ambienceImages(for: scene), screen: targetScreen, root: root, mode: mode)
        presenter.onEnd = { [weak self] in self?.presentation = nil; self?.objectWillChange.send(); self?.show() }
        presentation = presenter
        objectWillChange.send()
        window?.orderOut(nil)
        presenter.start()
    }
    func endPresentation() { presentation?.end() }
    func shutdown() {
        personas.shutdown()
        MainActor.assumeIsolated { desktopMotion.stop(); sceneSync?.shutdown() }
        presentation?.onEnd = nil; presentation?.end(); presentation = nil
        window?.orderOut(nil); window?.contentView = nil; window?.delegate = nil; window = nil
        imageCache.removeAllObjects()
    }
    private func persist(_ next: [DemoScene]) throws {
        guard !storageBlocked else { throw SceneError.storageBlocked }
        try MainActor.assumeIsolated {
            guard let adapter = sceneSync else { throw SceneError.storageBlocked }
            guard Set(next.map(\.id)).count == next.count else { throw SceneError.invalidScene }
            let removed = scenes.filter { old in !next.contains(where: { $0.id == old.id }) }
            let added = next.filter { value in !scenes.contains(where: { $0.id == value.id }) }
            let changed = next.filter { value in scenes.contains(where: { $0.id == value.id && $0 != value }) }
            guard removed.count + added.count + changed.count <= 1 else { throw SceneDocumentError.concurrentChange }
            if let value = removed.first { try adapter.remove(value) }
            else if let value = added.first { try adapter.create(value) }
            else if let value = changed.first { try adapter.save(value) }
            else {
                let ids = next.filter { !adapter.recoveryIDs.contains($0.id) }.map(\.id)
                if ids != adapter.library.records.filter({ !$0.isDeleted }).map(\.id) { try adapter.reorder(ids) }
            }
            adoptCanonicalScenes()
        }
    }
    @discardableResult func update(_ scene: DemoScene) -> Bool {
        do {
            let checked = try scene.validated()
            guard scenes.contains(where: { $0.id == scene.id }) else { throw SceneError.noScene }
            try persist(scenes.map { $0.id == scene.id ? checked : $0 }); return true
        } catch { notice = error.localizedDescription; return false }
    }
    /// A handoff photo enters the same in-memory replacement transaction as a
    /// chosen file. The scene ID is captured; selection and live output stay put.
    func makeBackdropReplacement(sceneID: UUID, imageURL: URL, title: String) throws -> BackdropReplacement {
        guard !storageBlocked else { throw SceneError.storageBlocked }
        guard let scene = scenes.first(where: { $0.id == sceneID }) else { throw BackdropReplacementError.sceneMissing }
        let draft = BackdropReplacement(scene: scene, root: root)
        try draft.chooseImage(imageURL, name: title, source: "From iPhone · Independent copy")
        return draft
    }
    func applyBackdrop(_ draft: BackdropReplacement) throws {
        guard !storageBlocked else { throw SceneError.storageBlocked }
        guard draft.root.standardizedFileURL == root.standardizedFileURL else { throw BackdropReplacementError.closed }
        guard draft.active else { throw BackdropReplacementError.closed }
        guard draft.canApply, let candidate = draft.candidate else { throw BackdropReplacementError.noChange }
        // Use the latest canonical snapshot, preserving newer foreground edits.
        // The record revision and store compare-and-swap guard the final commit.
        var latest = scenes
        guard let index = latest.firstIndex(where: { $0.id == draft.sceneID }) else { throw BackdropReplacementError.sceneMissing }
        guard SceneBackdrop(latest[index]) == draft.original else { throw BackdropReplacementError.staleScene }
        var copied: URL?
        do {
            let filename: String
            if let existing = candidate.existingFilename {
                _ = try DemoScene(background: existing).validated()
                guard let fresh = try? BackdropImage.read(root.appendingPathComponent(existing)),
                      fresh.digest == candidate.image.digest else { throw BackdropReplacementError.imageChanged }
                filename = existing
            } else {
                filename = "backdrop-" + UUID().uuidString + "." + candidate.image.fileExtension
                let destination = root.appendingPathComponent(filename)
                try candidate.image.data.write(to: destination, options: .atomic)
                copied = destination
            }
            var fields = draft.original
            fields.image = filename; fields.x = draft.x; fields.y = draft.y; fields.zoom = draft.zoom
            latest[index] = try fields.applying(to: latest[index])
            try persist(latest)
            imageCache.removeObject(forKey: filename as NSString)
            draft.cancel()
            notice = "Backdrop saved. It will be used next time you present, export or apply this scene."
        } catch {
            if let copied { try? FileManager.default.removeItem(at: copied) }
            throw error
        }
    }
    func importImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic]; panel.canChooseDirectories = false
        panel.message = "Choose a customer backdrop. A copy stays with this scene for next time."
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do { try self?.addImage(url) } catch { self?.notice = error.localizedDescription }
        }
    }
    func addImage(_ url: URL, name: String? = nil) throws {
        let filename = try copyImage(url)
        let destination = root.appendingPathComponent(filename)
        var scene = DemoScene(name: String((name ?? url.deletingPathExtension().lastPathComponent).prefix(160)), background: filename)
        scene.viewport = myDevice ?? .phone
        do { try persist(scenes + [scene]); query = ""; selectedID = scene.id; notice = nil }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    private func copyImage(_ url: URL) throws -> String {
        guard !storageBlocked else { throw SceneError.storageBlocked }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard count > 0, count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 50_000_000,
              NSImage(contentsOf: url) != nil else { throw SceneError.invalidImage }
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic"].contains(ext) else { throw SceneError.invalidImage }
        let filename = UUID().uuidString + "." + ext
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: url, to: destination)
        return filename
    }
    func useStarter(_ starter: SceneStarter, directory: URL = SceneStarters.directory) throws {
        guard let preset = starter.ambientPreset else {
            try addImage(starter.url(in: directory), name: starter.name); return
        }
        guard !storageBlocked else { throw SceneError.storageBlocked }
        let assets = directory.deletingLastPathComponent().appendingPathComponent("AmbientScenes")
        let filename = try copyImage(starter.url(in: directory))
        do {
            try MainActor.assumeIsolated {
                guard let adapter = sceneSync else { throw SceneError.storageBlocked }
                let plate = try adapter.library.importAsset(Data(contentsOf: assets.appendingPathComponent(preset + ".png")))
                let detail = try adapter.library.importAsset(Data(contentsOf: assets.appendingPathComponent(starter.detailFilename)))
                var scene = DemoScene(name: starter.name, background: filename)
                scene.ambience = SceneAmbience(preset: preset, cleanPlate: plate, detail: detail)
                scene.gentleMotion = true; scene.showsPhone = false; scene.viewport = myDevice ?? .phone
                try persist(scenes + [scene]); query = ""; selectedID = scene.id; notice = nil
            }
        } catch { try? FileManager.default.removeItem(at: root.appendingPathComponent(filename)); throw error }
    }
    func ambienceImages(for scene: DemoScene) -> AmbientSceneImages? {
        guard let recipe = scene.ambience, (try? recipe.validated()) != nil else { return nil }
        func read(_ asset: String) -> CGImage? {
            let url = root.appendingPathComponent("scene-asset-" + asset.dropLast(".image".count) + ".png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let cleanPlate = read(recipe.cleanPlate), let detail = read(recipe.detail) else { return nil }
        return AmbientSceneImages(preset: recipe.preset, cleanPlate: cleanPlate, detail: detail)
    }
    func logoImage(for scene: DemoScene) -> NSImage? {
        guard let logo = scene.logo, (try? logo.validated()) != nil else { return nil }
        if let cached = imageCache.object(forKey: logo.image as NSString) { return cached }
        guard let image = NSImage(contentsOf: root.appendingPathComponent(logo.image)) else { return nil }
        imageCache.setObject(image, forKey: logo.image as NSString,
                             cost: Int(min(200_000_000, image.size.width * image.size.height * 4)))
        return image
    }
    func personaImage(for scene: DemoScene) -> NSImage? {
        guard let persona = scene.persona, (try? persona.validated()) != nil else { return nil }
        // Canonical assets retain their encoded bytes; AppKit detects the image
        // format even when the compatibility cache uses a .png filename.
        return NSImage(contentsOf: root.appendingPathComponent(persona.image))
    }
    func usePersona(_ persona: SavedPersona, in sceneID: UUID) {
        guard var scene = scenes.first(where: { $0.id == sceneID }) else { return }
        var created: URL?
        do {
            _ = try persona.validated()
            guard !isSceneReadOnly(scene) else { throw SceneError.storageBlocked }
            let png = try personas.renderedPNG(for: persona)
            let filename = "persona-scene-" + UUID().uuidString + ".png"
            let destination = root.appendingPathComponent(filename)
            try png.write(to: destination, options: .atomic); created = destination
            var placement = scene.persona ?? PersonaPlacement(image: filename)
            placement.image = filename; scene.persona = placement
            try MainActor.assumeIsolated {
                guard let adapter = sceneSync else { throw SceneError.storageBlocked }
                var authored: SceneCardStyle?
                if let style = persona.card {
                    guard let source = try PersonaStorage.read(root.appendingPathComponent(persona.image), maximumBytes: SceneAsset.maximumBytes)
                    else { throw SceneDocumentError.missingAsset }
                    let portrait = try adapter.library.importAsset(source)
                    authored = SceneCardStyle(portrait: portrait, label: style.label,
                        red: style.background.r, green: style.background.g, blue: style.background.b)
                }
                try adapter.save(scene, card: authored, replacingCard: true)
            }
            notice = "Persona saved as an independent scene copy."
        } catch {
            if let created { try? FileManager.default.removeItem(at: created) }
            notice = error.localizedDescription
        }
    }
    func handImage(for scene: DemoScene) -> NSImage? {
        guard let hand = scene.hand, (try? hand.validated()) != nil else { return nil }
        let key = (hand.image + hand.tone.rawValue) as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let original = NSImage(contentsOf: root.appendingPathComponent(hand.image)) else { return nil }
        let image = HandRenderer.toned(original, tone: hand.tone)
        imageCache.setObject(image, forKey: key, cost: Int(min(200_000_000, image.size.width * image.size.height * 4)))
        return image
    }
    func importHand() {
        guard let id = selected?.id else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png]; panel.canChooseDirectories = false
        panel.message = "Choose a transparent hand-only PNG. The device stays above it; the original proportions are preserved."
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do { try self?.addHand(url, to: id) } catch { self?.notice = error.localizedDescription }
        }
    }
    func addHand(_ url: URL, to id: UUID) throws {
        guard var scene = scenes.first(where: { $0.id == id }) else { throw SceneError.noScene }
        let filename = try copyImage(url)
        let destination = root.appendingPathComponent(filename)
        do {
            guard url.pathExtension.lowercased() == "png", let image = NSImage(contentsOf: destination),
                  HandRenderer.hasTransparency(image) else { throw SceneError.invalidHand }
            var hand = scene.hand ?? SceneHand(image: filename); hand.image = filename; scene.hand = hand
            try persist(scenes.map { $0.id == id ? scene : $0 }); notice = nil
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    func importLogo() {
        guard let sceneID = selected?.id else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = LogoImport.contentTypes; panel.canChooseDirectories = false
        panel.message = "Choose a logo, including WebP images saved from your browser. A copy stays on this Mac."
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do { try self?.addLogo(url, to: sceneID) } catch { self?.notice = error.localizedDescription }
        }
    }
    func addLogo(_ url: URL, to sceneID: UUID) throws {
        guard !storageBlocked else { throw SceneError.storageBlocked }
        try addLogo(LogoImport.read(url), to: sceneID)
    }
    func pasteLogo(from pasteboard: NSPasteboard = .general) {
        guard let sceneID = selected?.id else { return }
        do {
            guard !storageBlocked else { throw SceneError.storageBlocked }
            try addLogo(LogoImport.read(pasteboard), to: sceneID)
        } catch { notice = error.localizedDescription }
    }
    private func addLogo(_ imported: LogoImport.Image, to sceneID: UUID) throws {
        guard !storageBlocked else { throw SceneError.storageBlocked }
        guard var scene = scenes.first(where: { $0.id == sceneID }) else { throw SceneError.noScene }
        let filename = UUID().uuidString + ".png"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try imported.png.write(to: root.appendingPathComponent(filename), options: .atomic)
        var logo = scene.logo ?? SceneLogo(image: filename)
        logo.image = filename; scene.logo = logo
        do { try persist(scenes.map { $0.id == sceneID ? scene : $0 }); notice = nil }
        catch { try? FileManager.default.removeItem(at: root.appendingPathComponent(filename)); throw error }
        do { try rememberLogo(filename, name: imported.name) }
        catch { notice = "Logo saved in this scene. The reusable logo library could not be updated; its original file is preserved." }
    }
    /// Missing branding must never silently disappear from a customer export.
    func renderPNG(_ scene: DemoScene, image: NSImage, size: CGSize) throws -> Data {
        let logoImage = logoImage(for: scene)
        if scene.logo != nil && logoImage == nil { throw SceneError.missingLogo }
        let handImage = handImage(for: scene)
        if scene.hand != nil && handImage == nil { throw SceneError.missingHand }
        let personaImage = personaImage(for: scene)
        if scene.persona != nil && personaImage == nil { throw SceneError.missingPersona }
        return try SceneRenderer.png(scene, image: image, size: size, logoImage: logoImage, handImage: handImage, personaImage: personaImage)
    }
    private func rememberLogo(_ filename: String, name: String) throws {
        guard !logoLibraryBlocked else { throw SceneError.storageBlocked }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = try SavedSceneLogo(name: label.isEmpty ? "Customer logo" : String(label.prefix(160)), image: filename).validated()
        // Reimporting the same customer logo should not fill the library with duplicates.
        let data = try Data(contentsOf: root.appendingPathComponent(filename))
        if savedLogos.contains(where: {
            guard let existing = try? Data(contentsOf: root.appendingPathComponent($0.image)) else { return false }
            return existing == data || (try? LogoImport.normalizedPNG(existing)) == data
        }) { return }
        let next = [value] + savedLogos
        try SceneLibraryStorage.write(next, to: root.appendingPathComponent("saved-logos.json")); savedLogos = next
    }
    func useSavedLogo(_ logo: SavedSceneLogo) {
        guard var scene = selected else { return }
        guard (try? logo.validated()) != nil, NSImage(contentsOf: root.appendingPathComponent(logo.image)) != nil else {
            notice = "That logo image is missing. Import it again."; return
        }
        var layer = scene.logo ?? SceneLogo(image: logo.image); layer.image = logo.image; scene.logo = layer; update(scene)
    }
    func removeSavedLogo(_ id: UUID) {
        guard !logoLibraryBlocked else { notice = SceneError.storageBlocked.localizedDescription; return }
        let next = savedLogos.filter { $0.id != id }
        do { try SceneLibraryStorage.write(next, to: root.appendingPathComponent("saved-logos.json")); savedLogos = next }
        catch { notice = error.localizedDescription }
    }
    func renameSavedLogo(_ id: UUID, name: String) {
        guard !logoLibraryBlocked, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let next = savedLogos.map { logo -> SavedSceneLogo in
            var value = logo; if value.id == id { value.name = String(name.prefix(160)) }; return value
        }
        do { try SceneLibraryStorage.write(next, to: root.appendingPathComponent("saved-logos.json")); savedLogos = next }
        catch { notice = error.localizedDescription }
    }
    func makeTextLogo(_ text: String) {
        guard let id = selected?.id else { return }
        do {
            let image = LogoImport.Image(png: try SceneLibraryStorage.textLogo(text), name: text)
            try addLogo(image, to: id)
        } catch { notice = error.localizedDescription }
    }
    func moveScene(_ id: UUID, by offset: Int) {
        var next = scenes
        guard let index = next.firstIndex(where: { $0.id == id }), next.indices.contains(index + offset) else { return }
        next.swapAt(index, index + offset)
        do { try persist(next); selectedID = id } catch { notice = error.localizedDescription }
    }
    func customizeStarter(_ change: (inout StarterPreferences) -> Void) {
        guard !starterLibraryBlocked else { notice = "Starter customizations are preserved until the unreadable file is recovered."; return }
        var next = starterPreferences; change(&next)
        do { try SceneLibraryStorage.write(next, to: root.appendingPathComponent("starter-preferences.json")); starterPreferences = next }
        catch { notice = error.localizedDescription }
    }
    func duplicate() {
        guard let scene = selected else { return }
        do {
            let id = try MainActor.assumeIsolated {
                guard let sceneSync else { throw SceneError.storageBlocked }
                return try sceneSync.duplicate(scene)
            }
            query = ""; selectedID = id
        } catch { notice = error.localizedDescription }
    }
    func remove(_ captured: DemoScene? = nil) {
        guard let scene = captured ?? selected else { return }
        do {
            try MainActor.assumeIsolated {
                guard let sceneSync else { throw SceneError.storageBlocked }
                try sceneSync.remove(scene)
            }
            // Originals and immutable assets remain available to active output.
        } catch { notice = error.localizedDescription }
    }
    var targetScreen: NSScreen? { window?.screen ?? NSScreen.main }
    var outputSize: CGSize {
        guard let screen = targetScreen else { return CGSize(width: 1920, height: 1080) }
        let size = screen.convertRectToBacking(screen.frame).size
        let factor = min(1, 8192 / max(size.width, size.height))
        return CGSize(width: size.width * factor, height: size.height * factor)
    }
    func windowDidChangeScreen(_ notification: Notification) { refreshScreen() }
    func windowDidChangeBackingProperties(_ notification: Notification) { refreshScreen() }
    private func refreshScreen() {
        let size = targetScreen?.frame.size ?? CGSize(width: 1920, height: 1080)
        screenAspect = size.width / max(1, size.height)
    }
    func exportPNG() {
        guard let scene = selected, let image = image(for: scene) else { notice = "The backdrop is missing. Add the image again."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = scene.name + ".png"
        let size = outputSize
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                guard let self else { return }
                try self.renderPNG(scene, image: image, size: size).write(to: url, options: .atomic)
                self.notice = "Saved \(url.lastPathComponent)."
            } catch { self?.notice = error.localizedDescription }
        }
    }
    #if !APP_STORE
    func applyDesktop(animate: Bool = false) {
        guard systemIntegrationEnabled else { return }
        guard !desktopBusy else { return }
        desktopBusy = true
        do {
            guard let scene = selected, let image = image(for: scene), let screen = targetScreen else { throw SceneError.noScene }
            let logo = logoImage(for: scene), hand = handImage(for: scene), persona = personaImage(for: scene)
            let ambientImages = ambienceImages(for: scene)
            let workspace = NSWorkspace.shared
            let screenID = AppCoordinator.displayID(screen)
            let output = root.appendingPathComponent("desktop-\(UUID().uuidString).png")
            try renderPNG(scene, image: image, size: outputSize).write(to: output, options: .atomic)
            var snapshots: [DesktopSnapshot] = FileManager.default.fileExists(atPath: snapshotURL.path)
                ? try JSONDecoder().decode([DesktopSnapshot].self, from: Data(contentsOf: snapshotURL)) : []
            let current = workspace.desktopImageURL(for: screen)
            guard let current else { throw SceneError.desktopUnavailable }
            let options = workspace.desktopImageOptions(for: screen) ?? [:]
            let color = (options[.fillColor] as? NSColor)?.usingColorSpace(.deviceRGB)
            let original = DesktopSnapshot(screenID: screenID, originalURL: current, appliedURL: output,
                scaling: (options[.imageScaling] as? NSNumber)?.intValue,
                clipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                fill: color.map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent), Double($0.alphaComponent)] })
            snapshots = DesktopRecovery.preparing(snapshots, screenID: screenID, current: current, output: output, original: original)
            // Save recovery before changing anything outside the app.
            try JSONEncoder().encode(snapshots).write(to: snapshotURL, options: .atomic)
            hasDesktopSnapshot = true
            notice = "Applying the scene to this display…"
            MainActor.assumeIsolated { desktopMotion.stop() }
            try workspace.setDesktopImageURL(output, for: screen, options: [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue])
            DesktopImageVerification.confirm(output, read: { workspace.desktopImageURL(for: screen) }) { [weak self] confirmed in
                guard let self else { return }
                defer { self.desktopBusy = false }
                guard confirmed else {
                    self.notice = "macOS hasn’t confirmed the desktop change yet. Recovery details are saved; try Restore desktop or export the scene."
                    return
                }
                do {
                    if let index = snapshots.lastIndex(where: { $0.screenID == screenID && $0.owns(output) }) {
                        snapshots[index].appliedURL = output; snapshots[index].pendingURL = nil
                        try JSONEncoder().encode(snapshots).write(to: self.snapshotURL, options: .atomic)
                    }
                    if animate {
                        let started = MainActor.assumeIsolated {
                            self.desktopMotion.start(scene: scene, backdrop: image, logo: logo, hand: hand, persona: persona,
                                                     screen: screen, expectedStill: output, ambience: ambientImages)
                        }
                        self.notice = started ? "Gentle desktop motion is on. Stop motion or quit Workbench to keep the still picture."
                            : "The still picture is applied. Motion could not start on this display."
                    } else {
                        self.notice = "\(scene.name) is on this display. Restore desktop brings your previous picture back."
                    }
                } catch { self.notice = error.localizedDescription }
            }
        } catch { desktopBusy = false; notice = error.localizedDescription }
    }
    func restoreDesktop() {
        guard systemIntegrationEnabled else { return }
        guard !desktopBusy else { return }
        MainActor.assumeIsolated { desktopMotion.stop() }
        desktopBusy = true
        do {
            let snapshots = try JSONDecoder().decode([DesktopSnapshot].self, from: Data(contentsOf: snapshotURL))
            notice = "Restoring the previous desktop…"
            let pictures = Dictionary(NSScreen.screens.compactMap { screen -> (String, URL)? in
                guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
                return (AppCoordinator.displayID(screen), url)
            }, uniquingKeysWith: { first, _ in first })
            let plan = DesktopRecovery.plan(snapshots, current: pictures)
            restoreNext(plan.ready, remaining: plan.retained)
        } catch { desktopBusy = false; notice = error.localizedDescription }
    }
    private func restoreNext(_ pending: [DesktopSnapshot], remaining: [DesktopSnapshot]) {
        guard let snapshot = pending.first else { finishRestore(remaining); return }
        let next = Array(pending.dropFirst())
        guard let screen = NSScreen.screens.first(where: { AppCoordinator.displayID($0) == snapshot.screenID }),
              let current = NSWorkspace.shared.desktopImageURL(for: screen) else {
            restoreNext(next, remaining: remaining + [snapshot]); return
        }
        // A later manual wallpaper change belongs to the user; never overwrite it.
        guard snapshot.owns(current) else { restoreNext(next, remaining: remaining + [snapshot]); return }
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let value = snapshot.scaling { options[.imageScaling] = value }
        if let value = snapshot.clipping { options[.allowClipping] = value }
        if let color = snapshot.fill, color.count == 4 {
            options[.fillColor] = NSColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: color[3])
        }
        do {
            try NSWorkspace.shared.setDesktopImageURL(snapshot.originalURL, for: screen, options: options)
            DesktopImageVerification.confirm(snapshot.originalURL, read: { NSWorkspace.shared.desktopImageURL(for: screen) }) { [weak self] confirmed in
                self?.restoreNext(next, remaining: confirmed ? remaining : remaining + [snapshot])
            }
        } catch { restoreNext(next, remaining: remaining + [snapshot]) }
    }
    private func finishRestore(_ remaining: [DesktopSnapshot]) {
        defer { desktopBusy = false }
        do {
            if remaining.isEmpty { try FileManager.default.removeItem(at: snapshotURL) }
            else { try JSONEncoder().encode(remaining).write(to: snapshotURL, options: .atomic) }
            hasDesktopSnapshot = !remaining.isEmpty
            notice = remaining.isEmpty ? "Desktop restored. Any later manual changes were kept." : "Other Spaces or displays still have saved recovery. Switch to each demo desktop and choose Restore desktop there. Later manual pictures are left alone."
        } catch { notice = error.localizedDescription }
    }
    #endif
}
