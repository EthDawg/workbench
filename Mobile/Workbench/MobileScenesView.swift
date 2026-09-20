import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO

struct MobileScenesView: View {
    var captureOnOpen = false
    @EnvironmentObject private var scenes: SceneLibraryModel
    @EnvironmentObject private var handoff: PhotoHandoffModel
    @State private var selection: PhotosPickerItem?
    @State private var choosingPhotos = false
    @State private var choosingSceneFile = false
    @State private var camera = false
    @State private var choosingArrivals = false
    @State private var choosingStarters = false
    @State private var starterID: UUID?
    @State private var cloudSettings = false
    @State private var opened = false
    @State private var busy = false
    @State private var notice: String?
    @State private var selectedID: UUID?
    @State private var editing = false
    private var saved: [SavedSceneRecord] { scenes.records.filter { !$0.isDeleted }.sorted { $0.modified > $1.modified } }

    var body: some View {
        List {
            Section {
                Text("Prepare here. Present on your Mac.").font(.headline)
                Text("Choose a backdrop, position the device and add your branding. Your scene stays editable.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Camera", systemImage: "camera") { requestCamera() }.buttonStyle(.borderedProminent)
                    Button("Photos", systemImage: "photo") { choosingPhotos = true }.buttonStyle(.bordered)
                }.controlSize(.large).disabled(busy)
                Button { choosingStarters = true } label: {
                    Label("Start with a picture", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.disabled(busy)
                if !handoff.photos.isEmpty {
                    Button("From photo handoff…") { choosingArrivals = true }.disabled(busy)
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-handoff") {
                    Button("Use sample photo") { create(PhotoHandoffPreview.sampleData(), name: "Sample scene") }
                        .accessibilityIdentifier("scene.sample")
                }
                #endif
            }
            if busy { ProgressView("Preparing scene…") }
            if let message = notice ?? scenes.error {
                Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("scene.notice") }
            }
            Section("Saved scenes") {
                if saved.isEmpty {
                    Text("Your first scene starts with a picture.").foregroundStyle(.secondary)
                }
                ForEach(saved) { record in
                    NavigationLink { MobileSceneEditor(sceneID: record.id) } label: {
                        HStack(spacing: 14) {
                            SceneThumbnail(scene: record.scene, store: scenes).frame(width: 100, height: 64).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.scene.name).font(.headline)
                                Text(sceneStatus(record)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5)
                    }.contextMenu {
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            do { _ = try scenes.duplicate(id: record.id) } catch { notice = error.localizedDescription }
                        }
                    }
                }
            }
            Section {
                Button("Import scene copy…", systemImage: "square.and.arrow.down") { choosingSceneFile = true }
                    .disabled(scenes.isStorageBlocked || busy)
                Button { cloudSettings = true } label: {
                    Label(scenes.isEnabled ? "Personal iCloud sync" : "Sync scenes with your Mac", systemImage: "icloud")
                }
                Text(scenes.isEnabled ? scenes.status : "Optional. Local scenes work without an account or connection.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Scenes").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("scene.library")
            .photosPicker(isPresented: $choosingPhotos, selection: $selection, matching: .images, preferredItemEncoding: .current)
            .fileImporter(isPresented: $choosingSceneFile, allowedContentTypes: [SceneFile.contentType], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    selectedID = try scenes.importPackage(SceneFile.read(url)).id
                    editing = true
                } catch { notice = error.localizedDescription }
            }
            .onChange(of: selection) { _, item in
                guard let item else { return }
                busy = true
                Task { @MainActor in
                    defer { busy = false; selection = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoHandoffInputError.unreadable }
                        create(data, name: "Untitled scene")
                    } catch { notice = error.localizedDescription }
                }
            }
            .fullScreenCover(isPresented: $camera) {
                PhotoHandoffCamera { result in
                    camera = false
                    switch result {
                    case .success(let data): if let data { create(data, name: "Untitled scene") }
                    case .failure(let error): notice = error.localizedDescription
                    }
                }.ignoresSafeArea()
            }
            .sheet(isPresented: $cloudSettings) { MobileSceneSyncSettings() }
            .sheet(isPresented: $choosingStarters, onDismiss: {
                if let starterID { selectedID = starterID; self.starterID = nil; editing = true }
            }) {
                AmbientStarterGallery { record in
                    starterID = record.id; notice = nil; choosingStarters = false
                }
            }
            .sheet(isPresented: $choosingArrivals) {
                NavigationStack {
                    List(handoff.photos) { photo in
                        Button {
                            do {
                                guard let url = handoff.fileURL(for: photo) else { throw SceneDocumentError.missingAsset }
                                create(try Data(contentsOf: url), name: photo.title)
                                choosingArrivals = false
                            } catch { notice = error.localizedDescription }
                        } label: { PhotoHandoffRow(photo: photo) }
                    }.navigationTitle("Photo handoff")
                        .toolbar { Button("Done") { choosingArrivals = false } }
                }
            }
            .navigationDestination(isPresented: $editing) {
                if let selectedID { MobileSceneEditor(sceneID: selectedID) }
            }
            .task {
                guard !opened else { return }; opened = true
                if captureOnOpen { requestCamera() }
                if scenes.isEnabled { await scenes.refresh() }
            }
    }

    private func requestCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            notice = "Camera is unavailable here. Choose Photos or a starting picture."; return
        }
        Task { @MainActor in
            let granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                ? true : await AVCaptureDevice.requestAccess(for: .video)
            if granted, UIApplication.shared.applicationState == .active { camera = true }
            else { notice = "Camera access is off. You can allow Workbench in Settings or choose Photos." }
        }
    }
    private func create(_ data: Data, name: String) {
        do {
            let asset = try scenes.importAsset(data)
            var scene = PortableScene(name: name, background: asset); scene.viewport = SceneDevice()
            let record = try scenes.create(scene)
            selectedID = record.id; editing = true; notice = nil
        } catch { notice = error.localizedDescription }
    }
}

func sceneStatus(_ record: SavedSceneRecord) -> String {
    if record.account == nil { return "Saved on this device" }
    if record.isDirty { return "Waiting for iCloud" }
    return "In iCloud"
}

struct MobileSceneSyncSettings: View {
    @EnvironmentObject private var scenes: SceneLibraryModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Your scenes, on your devices", systemImage: "icloud").font(.headline)
                    Text("Use the same Apple Account on iPhone and Mac. Enabling sync sends saved scenes and their pictures to your private iCloud.")
                    Text("Saved changes upload while Workbench is open. Reopen the app or refresh to check for changes from your other device. A scene in iCloud may still be waiting to download there.")
                }
                Section {
                    if scenes.isEnabled {
                        Button("Refresh now", systemImage: "arrow.clockwise") { Task { await scenes.refresh() } }.disabled(scenes.isBusy)
                        Button("Turn off scene sync") { scenes.disable() }
                        Text("Turning off sync keeps scenes on this device and in iCloud.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button("Enable personal sync", systemImage: "icloud") { Task { await scenes.enable() } }
                            .disabled(scenes.isBusy || !scenes.isConfigured)
                    }
                    if scenes.isBusy { ProgressView("Connecting to iCloud…") }
                    Text(scenes.status).foregroundStyle(.secondary)
                    if let error = scenes.error { Text(error).foregroundStyle(.secondary) }
                }
            }.navigationTitle("Scene sync").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Cached by immutable content hash and library directory. Decoding happens off
/// the main actor once, not for every slider movement or sync status update.
@MainActor private final class SceneThumbnailCache {
    static let shared = SceneThumbnailCache()
    private let images = NSCache<NSString, UIImage>()
    init() { images.totalCostLimit = 64_000_000; images.countLimit = 80 }
    func image(at url: URL, key: String) async -> UIImage? {
        if let cached = images.object(forKey: key as NSString) { return cached }
        let image = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return UIImage?.none }
            return UIImage(cgImage: cg)
        }.value
        guard !Task.isCancelled else { return nil }
        if let image { images.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4)) }
        return image
    }
}

struct SceneThumbnail: View {
    let scene: PortableScene
    @ObservedObject var store: SceneLibraryModel
    var motionPlaying = false // Gallery and exported previews stay still by default.
    @State private var images: [String: UIImage] = [:]
    @State private var loading = true
    private var visibleAssets: Set<String> {
        Set([scene.background, scene.logo?.image, scene.persona?.image].compactMap { $0 })
            .union(motionPlaying ? scene.ambience?.assets ?? [] : [])
    }
    private var assetKey: String { store.directory.path + ":" + visibleAssets.sorted().joined(separator: ",") }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                backdrop(in: geometry.size)
                device(in: geometry.size)
                logo(in: geometry.size)
                persona(in: geometry.size)
            }.clipped()
        // Cropped artwork can extend outside the geometry. Restrict hit tests
        // to the preview so it cannot cover the scene controls below it.
        }.contentShape(Rectangle())
            .accessibilityElement(children: .ignore).accessibilityLabel("Scene layout preview")
            .task(id: assetKey) { await loadImages() }
    }
    private func loadImages() async {
        loading = true
        var loaded: [String: UIImage] = [:]
        for name in visibleAssets {
            guard !Task.isCancelled else { return }
            if let url = try? store.assetURL(name) {
                loaded[name] = await SceneThumbnailCache.shared.image(at: url, key: store.directory.path + ":" + name)
            }
        }
        guard !Task.isCancelled else { return }; images = loaded; loading = false
    }
    @ViewBuilder private func backdrop(in size: CGSize) -> some View {
        if let background = images[scene.background] {
            let rig = motionImages
            SceneMotionPreview(image: background, x: scene.backgroundX, y: scene.backgroundY,
                zoom: scene.zoom, playing: motionPlaying && (scene.ambience == nil || rig != nil), ambience: rig)
                .frame(width: size.width, height: size.height)
        } else if loading { ProgressView().tint(.white) }
        else { Image(systemName: "photo").foregroundStyle(.white.opacity(0.5)) }
    }
    private var motionImages: SceneMotionImages? {
        guard motionPlaying, let rig = scene.ambience,
              let clean = images[rig.cleanPlate], let detail = images[rig.detail] else { return nil }
        return SceneMotionImages(preset: rig.preset, cleanPlate: clean, detail: detail)
    }
    @ViewBuilder private func device(in size: CGSize) -> some View {
        if scene.showsPhone {
            let device = scene.viewport ?? SceneDevice()
            let height = size.height * scene.phoneHeight
            let width = min(size.width * 0.96, height * device.aspect)
            let corner = min(width, height) * device.corners
            RoundedRectangle(cornerRadius: corner).fill(Color(white: 0.1))
                .overlay { Image(systemName: "iphone").font(.system(size: min(32, width * 0.3))).foregroundStyle(.white.opacity(0.5)) }
                .overlay { RoundedRectangle(cornerRadius: corner).stroke(.white.opacity(0.2), lineWidth: 2) }
                .frame(width: width, height: height)
                .position(x: width / 2 + (size.width - width) * scene.phoneX,
                          y: height / 2 + (size.height - height) * (1 - scene.phoneY))
        }
    }
    @ViewBuilder private func logo(in size: CGSize) -> some View {
        if let logo = scene.logo, let artwork = images[logo.image] {
            let width = size.width * logo.width
            let height = min(size.height * 0.16, width * artwork.size.height / artwork.size.width)
            let actualWidth = height * artwork.size.width / artwork.size.height
            let left = logo.corner.hasSuffix("Left"), top = logo.corner.hasPrefix("top")
            let backing: Color = logo.backing == "none" ? .clear : (logo.backing == "light" ? .white : .black)
            Image(uiImage: artwork).resizable().scaledToFit().frame(width: actualWidth, height: height)
                .padding(4).background(backing, in: RoundedRectangle(cornerRadius: 5))
                .position(x: left ? actualWidth / 2 + 16 : size.width - actualWidth / 2 - 16,
                          y: top ? height / 2 + 16 : size.height - height / 2 - 16)
        }
    }
    @ViewBuilder private func persona(in size: CGSize) -> some View {
        if let persona = scene.persona, let artwork = images[persona.image] {
            let width = size.width * persona.width
            let height = min(size.height * 0.6, width * artwork.size.height / artwork.size.width)
            let actualWidth = height * artwork.size.width / artwork.size.height
            Image(uiImage: artwork).resizable().scaledToFit().frame(width: actualWidth, height: height)
                .position(x: actualWidth / 2 + (size.width - actualWidth) * persona.x,
                          y: height / 2 + (size.height - height) * (1 - persona.y))
        }
    }
}
