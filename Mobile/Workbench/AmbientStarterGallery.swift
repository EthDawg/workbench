import SwiftUI
import ImageIO

enum AmbientStarter: String, CaseIterable, Identifiable {
    case windowLight = "window-light", campusBreeze = "campus-breeze", coastalSky = "coastal-sky"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .windowLight: return "Window light"
        case .campusBreeze: return "Campus breeze"
        case .coastalSky: return "Coastal sky"
        }
    }
    var detailName: String { self == .campusBreeze ? "eucalyptus" : "clouds" }
    var description: String {
        switch self {
        case .windowLight: return "A quiet room with drifting clouds."
        case .campusBreeze: return "Eucalyptus leaves move in a light breeze."
        case .coastalSky: return "A still coastline under a moving sky."
        }
    }
    static var bundledDirectory: URL? { Bundle.main.url(forResource: "AmbientScenes", withExtension: nil) }

    /// All sources are read and checked before a scene is committed. Its poster
    /// and motion pictures become ordinary immutable assets in the local library.
    @MainActor func create(in library: SceneLibraryModel, directory: URL? = bundledDirectory) throws -> SavedSceneRecord {
        guard let directory else { throw SceneDocumentError.invalid("These starting pictures are unavailable. Choose a photo instead.") }
        let names = [rawValue + "-poster", rawValue, detailName]
        let bytes = try names.map { name in
            let data = try Data(contentsOf: directory.appendingPathComponent(name + ".png"))
            try SceneAsset.validate(data, named: SceneAsset.name(for: data))
            return data
        }
        let assets = try bytes.map { try library.importAsset($0) }
        var scene = PortableScene(name: title, background: assets[0])
        scene.viewport = SceneDevice()
        scene.showsPhone = false
        scene.ambience = SceneAmbience(preset: rawValue, cleanPlate: assets[1], detail: assets[2])
        scene.gentleMotion = true // Choosing this treatment is an explicit motion request.
        return try library.create(scene)
    }

    func poster(directory: URL? = Self.bundledDirectory) -> UIImage? {
        guard let url = directory?.appendingPathComponent(rawValue + "-poster.png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct AmbientStarterGallery: View {
    @EnvironmentObject private var scenes: SceneLibraryModel
    @Environment(\.dismiss) private var dismiss
    let onCreate: (SavedSceneRecord) -> Void
    @State private var notice: String?
    @State private var preparing = false
    @State private var posters: [AmbientStarter: UIImage] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("A little life in the background. Your device, logo and persona stay still.")
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(AmbientStarter.allCases) { starter in
                            Button { choose(starter) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Group {
                                        if let image = posters[starter] { Image(uiImage: image).resizable().scaledToFill() }
                                        else { Rectangle().fill(.quaternary).overlay { Image(systemName: "photo") } }
                                    }.aspectRatio(16.0 / 9, contentMode: .fit).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(starter.title).font(.headline)
                                    Text(starter.description).font(.subheadline).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("scene.starter." + starter.rawValue)
                                .accessibilityHint("Creates an editable scene with gentle motion. You can turn it off.")
                        }
                    }
                    Text("Motion starts in the editor when your device settings allow it. These previews are still pictures.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let notice { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("scene.starterNotice") }
                    Divider()
                    Text("Still starting pictures").font(.headline)
                    ForEach(MobileBackdropPalette.allCases) { palette in
                        Button(palette.rawValue) { chooseStill(palette) }.buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }.padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }.disabled(preparing || scenes.isStorageBlocked)
                .navigationTitle("Start with a picture").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .task { for starter in AmbientStarter.allCases { posters[starter] = starter.poster() } }
        }
    }
    private func choose(_ starter: AmbientStarter) {
        complete { try starter.create(in: scenes) }
    }
    private func chooseStill(_ palette: MobileBackdropPalette) {
        complete {
            let image = palette == .coast ? UIImage(named: "Coast") ?? MobileImageRenderer.starter(palette, portrait: false)
                : MobileImageRenderer.starter(palette, portrait: false)
            guard let data = image.pngData() else { throw SceneDocumentError.missingAsset }
            var scene = PortableScene(name: palette.rawValue, background: try scenes.importAsset(data))
            scene.viewport = SceneDevice()
            return try scenes.create(scene)
        }
    }
    private func complete(_ create: () throws -> SavedSceneRecord) {
        guard !preparing else { return }; preparing = true
        do { onCreate(try create()) }
        catch { preparing = false; notice = error.localizedDescription }
    }
}
