import SwiftUI
import PhotosUI
import PencilKit
import UniformTypeIdentifiers
import ImageIO

struct MobileImageWorkspace: View {
    let kind: MobileImageKind
    var projectID: UUID? = nil
    @EnvironmentObject private var store: MobileStore
    @EnvironmentObject private var scenes: SceneLibraryModel
    @State private var project: MobileImageProject?
    @State private var lastSaved: MobileImageProject?
    @State private var loaded = false
    @State private var background: UIImage?
    @State private var foreground: UIImage?
    @State private var logo: UIImage?
    @State private var persona: UIImage?
    @State private var notice: String?
    @State private var drawingUnavailable = false
    @State private var toolsVisible = true
    @StateObject private var drawingControls = MobileDrawingControls()
    @State private var photo: PhotosPickerItem?
    @State private var choosingPhotos = false
    @State private var choosingFile = false
    @State private var destination = ImageDestination.newImage
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var share: ImageShare?
    @State private var exporting = false
    @StateObject private var wallpaperSaver = WallpaperPhotoSaver()
    @Environment(\.openURL) private var openURL
    @State private var convertedSceneID: UUID?
    @State private var reused: MobileImageProject?
    @State private var showingReused = false
    @State private var dragStart: CGPoint?
    @State private var zoomStart: Double?
    @State private var deviceAspect: Double = 0.4615
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let project, let background {
                        if geometry.size.width >= 800 {
                            HStack(alignment: .top, spacing: 28) {
                                preview(project, image: background, width: max(280, min(geometry.size.width, 1200) - 348),
                                        maximumHeight: max(320, geometry.size.height - 110))
                                editor(project).frame(width: 280).disabled(kind == .wallpaper && (wallpaperSaver.isBusy || exporting))
                            }
                        } else {
                            preview(project, image: background, width: geometry.size.width - 40,
                                    maximumHeight: min(520, max(300, geometry.size.height * 0.56)))
                            editor(project).disabled(kind == .wallpaper && (wallpaperSaver.isBusy || exporting))
                        }
                    } else {
                        emptyState
                    }
                    if importing { ProgressView("Opening image…").frame(maxWidth: .infinity) }
                    if let message = notice ?? store.error {
                        Label(message, systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("imageWorkspaceNotice")
                    }
                    if store.writesDisabled {
                        Label("Saving is paused. You can still preview and export readable images.", systemImage: "lock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }.background(Color(uiColor: .systemGroupedBackground))
        }
        .background(MobileScreenAspectReader { deviceAspect = $0 }.allowsHitTesting(false))
        .navigationTitle(project?.title.isEmpty == false ? project!.title : kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if project != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New image…", systemImage: "photo.badge.plus") { beginPhotos(.newImage) }
                        if kind == .wallpaper, wallpaperSaver.state == .saved || wallpaperSaver.state == .unconfirmed {
                            Button("Save another Photos copy", systemImage: "photo.badge.plus") { saveWallpaperToPhotos(allowAnotherCopy: true) }
                        }
                        if let project {
                            Section("Use the original image in") {
                                Button("Scene for Mac", systemImage: "rectangle.inset.filled") { createScene() }
                                ForEach(MobileImageKind.allCases.filter { $0 != kind && $0 != .backdrop }) { target in
                                    Button(target.title, systemImage: target.symbol) { reuse(project, as: target) }
                                }
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Image actions").disabled(importing || store.writesDisabled || (kind == .wallpaper && (wallpaperSaver.isBusy || exporting)))
                }
            }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photo, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            let target = destination
            importTask?.cancel(); importing = true
            importTask = Task { @MainActor in
                defer { importing = false; photo = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw MobileStoreError.invalid("Photos could not provide this image. Try a downloaded copy from Files.")
                    }
                    try Task.checkCancellation()
                    accept(data, target: target, title: "Untitled \(kind == .markup ? "markup" : kind == .wallpaper ? "wallpaper" : "backdrop")")
                } catch is CancellationError { }
                catch { notice = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 64_000_000 else {
                    throw MobileStoreError.invalid("Choose an image smaller than 64 MB.")
                }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                guard let data = try handle.read(upToCount: 64_000_001), data.count <= 64_000_000 else {
                    throw MobileStoreError.invalid("This image is larger than 64 MB.")
                }
                accept(data, target: destination, title: url.deletingPathExtension().lastPathComponent)
            } catch { notice = error.localizedDescription }
        }
        .sheet(item: $share) { item in MobileImageShareSheet(url: item.url) }
        .navigationDestination(isPresented: Binding(get: { convertedSceneID != nil }, set: { if !$0 { convertedSceneID = nil } })) {
            if let convertedSceneID { MobileSceneEditor(sceneID: convertedSceneID) }
        }
        .navigationDestination(isPresented: $showingReused) {
            if let reused { MobileImageWorkspace(kind: reused.kind, projectID: reused.id) }
        }
        .task { load() }
        .onChange(of: project) { previous, next in
            if kind == .wallpaper, previous?.asset != next?.asset || previous?.zoom != next?.zoom || previous?.centerX != next?.centerX || previous?.centerY != next?.centerY || previous?.wallpaperAspect != next?.wallpaperAspect {
                wallpaperSaver.imageChanged()
            }
            guard next != lastSaved else { return }
            saveTask?.cancel()
            saveTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(450)); try Task.checkCancellation(); _ = saveNow() }
                catch { }
            }
        }
        .onDisappear {
            importTask?.cancel(); saveTask?.cancel(); _ = saveNow()
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveTask?.cancel(); _ = saveNow() } }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: kind.symbol).font(.system(size: 38, weight: .light)).foregroundStyle(.tint)
                Text(kind == .markup ? "Make your point." : kind == .wallpaper ? "A calmer screen." : "Set the scene.")
                    .font(.largeTitle.weight(.semibold))
                Text(kind == .markup ? "Draw on a photo or screenshot, then share a new image. Your original stays intact."
                     : kind == .wallpaper ? "Frame an image for your device, then save a copy to Photos."
                     : "Combine a backdrop with your picture, logo or finished persona card.")
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if project != nil {
                Label("The original image is missing. Choose a replacement to continue.", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            importButtons(project == nil ? .newImage : .background)
            if kind != .markup {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Or choose a starting point").font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(MobileBackdropPalette.allCases) { palette in
                            Button {
                                let image = palette == .coast ? UIImage(named: "Coast") ?? MobileImageRenderer.starter(palette, portrait: kind == .wallpaper)
                                    : MobileImageRenderer.starter(palette, portrait: kind == .wallpaper)
                                guard let data = image.pngData() else {
                                    notice = "This colour backdrop could not be created."; return
                                }
                                accept(data, target: project == nil ? .newImage : .background, title: palette.rawValue)
                            } label: {
                                Group {
                                    if palette == .coast, let image = UIImage(named: "Coast") {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        LinearGradient(colors: palette.colors.map(Color.init(uiColor:)), startPoint: .topLeading, endPoint: .bottomTrailing)
                                    }
                                }.frame(height: 126).clipped().clipShape(RoundedRectangle(cornerRadius: 20))
                                    .overlay(alignment: .bottomLeading) { Text(palette.rawValue).font(.headline).foregroundStyle(.white).padding(16) }
                            }.buttonStyle(.plain).accessibilityLabel("Use \(palette.rawValue) picture").accessibilityIdentifier("\(kind.rawValue).starter.\(palette.rawValue.lowercased())")
                                .disabled(importing || store.writesDisabled)
                        }
                    }
                }
            }
        }.frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
    }

    private func preview(_ project: MobileImageProject, image: UIImage, width: CGFloat, maximumHeight: CGFloat) -> some View {
        let aspect = MobileImageRenderer.aspect(project: project, background: image)
        let canvasWidth = max(1, min(width, maximumHeight * aspect))
        let size = CGSize(width: canvasWidth, height: canvasWidth / aspect)
        return VStack(spacing: 12) {
            if kind == .markup {
                HStack {
                    Button { drawingControls.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!drawingControls.canUndo).accessibilityLabel("Undo drawing")
                    Button { drawingControls.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!drawingControls.canRedo).accessibilityLabel("Redo drawing")
                    Spacer()
                    Toggle("Drawing tools", isOn: $toolsVisible).toggleStyle(.button)
                }.buttonStyle(.bordered).disabled(drawingUnavailable || store.writesDisabled)
                MobileDrawingCanvas(image: image, data: binding(\.drawing, fallback: nil), toolsVisible: toolsVisible,
                                    isEnabled: !drawingUnavailable && !store.writesDisabled, controls: drawingControls,
                                    onError: { notice = $0 })
                    .frame(width: size.width, height: size.height).id(project.asset)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                MobileCompositionPreview(project: project, background: image, foreground: foreground, logo: logo, persona: persona)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: kind == .wallpaper ? 28 : 12))
                    .contentShape(Rectangle())
                    .gesture(cropGesture(size: size, image: image))
                    .accessibilityLabel(kind == .wallpaper ? "Wallpaper preview" : "Backdrop preview")
                    .accessibilityHint("Use Adjust crop below for accessible position and zoom controls.")
                Text("Pinch to zoom · Drag to frame").font(.caption).foregroundStyle(.secondary)
            }
            Text(drawingControls.exceedsLimit ? "Undo to return within the drawing limit"
                 : project == lastSaved ? "Saved on this device"
                 : store.error != nil || store.writesDisabled ? "Changes have not been saved" : "Saving changes…")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func editor(_ project: MobileImageProject) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Name this image", text: limitedBinding(\.title)).textFieldStyle(.roundedBorder)
                    .disabled(store.writesDisabled)
            }
            if kind != .markup {
                layerMenu("Background", target: .background, exists: true)
                DisclosureGroup("Adjust crop") {
                    VStack(spacing: 14) {
                        cropSlider("Horizontal", value: binding(\.centerX, fallback: 0.5), range: 0...1)
                        cropSlider("Vertical", value: binding(\.centerY, fallback: 0.5), range: 0...1)
                        cropSlider("Zoom", value: binding(\.zoom, fallback: 1), range: 1...5)
                        Button("Centre crop") { edit { $0.zoom = 1; $0.centerX = 0.5; $0.centerY = 0.5 } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if kind == .wallpaper {
                            Picker("Shape", selection: binding(\.wallpaperAspect, fallback: 0.4615)) {
                                Text("Saved shape").tag(project.wallpaperAspect)
                                if abs(project.wallpaperAspect - 9.0 / 19.5) > 0.001 { Text("Phone portrait").tag(9.0 / 19.5) }
                                if abs(project.wallpaperAspect - 0.75) > 0.001 { Text("iPad portrait").tag(0.75) }
                            }
                        }
                    }.padding(.top, 12)
                }.disabled(store.writesDisabled)
            }
            if kind == .backdrop {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add to the scene").font(.headline)
                    layerMenu("Picture", target: .foreground, exists: project.foregroundAsset != nil)
                    layerMenu("Logo", target: .logo, exists: project.logoAsset != nil)
                    layerMenu("Persona", target: .persona, exists: project.personaAsset != nil)
                    Text("Transparent logos and finished persona cards keep their own appearance.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Caption (optional)", text: limitedBinding(\.caption), axis: .vertical)
                        .lineLimit(1...3).textFieldStyle(.roundedBorder).disabled(store.writesDisabled)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                if kind == .wallpaper {
                    Button { saveWallpaperToPhotos() } label: {
                        HStack {
                            if wallpaperSaver.isBusy || exporting { ProgressView() }
                            Label(wallpaperSaver.state == .saved ? "Saved to Photos" : wallpaperSaver.isBusy ? "Saving to Photos…" : "Save to Photos", systemImage: wallpaperSaver.state == .saved ? "checkmark.circle" : "square.and.arrow.down")
                        }.frame(maxWidth: .infinity, minHeight: 36)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(exporting || importing || wallpaperSaver.isBusy || wallpaperSaver.state == .saved || wallpaperSaver.state == .unconfirmed)
                        .accessibilityIdentifier("wallpaper.savePhotos")
                    if let message = wallpaperSaver.message {
                        Label(message, systemImage: wallpaperSaver.state == .saved ? "checkmark.circle" : "info.circle")
                            .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("wallpaper.photoSaveStatus")
                    }
                    if wallpaperSaver.state == .denied {
                        Button("Open Photos permission settings", systemImage: "gearshape") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                            .frame(minHeight: 44)
                    }
                    if wallpaperSaver.state == .saved {
                        Text("In Photos, open the saved picture → Share → Use as Wallpaper. Review Apple’s crop, then add it.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Button { export() } label: { Label("Share PNG", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 36) }
                        .buttonStyle(.bordered).controlSize(.large).disabled(exporting || importing || wallpaperSaver.isBusy)
                } else {
                    Button { export() } label: {
                        Label(exporting ? "Preparing image…" : "Share PNG", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(exporting || importing || drawingUnavailable || drawingControls.exceedsLimit)
                }
                Text("A new image, up to 3840 pixels. The original stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                if kind == .backdrop {
                    Button { createScene() } label: { Label("Create scene for Mac", systemImage: "rectangle.inset.filled").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                        .disabled(scenes.isStorageBlocked || importing || exporting)
                    Text("Creates an editable scene with this background, logo and persona. Your original composition stays here; its picture, caption and drawing can also be recovered from the scene.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if kind == .wallpaper {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Workbench saves a still picture. Apple’s wallpaper picker handles the final crop, clock and widgets.")
                    Text("On supported iPhones, an eligible photo can use Apple’s Spatial Scene effect on the Lock Screen. Look for Spatial Scene in the wallpaper picker; it may not be available for this picture.")
                    Link("Apple’s wallpaper guide", destination: URL(string: "https://support.apple.com/102638")!)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func importButtons(_ target: ImageDestination) -> some View {
        HStack(spacing: 12) {
            Button { beginPhotos(target) } label: { Label("Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(kind == .wallpaper ? "wallpaper.choose" : "\(kind.rawValue).choose")
            Button { destination = target; choosingFile = true } label: { Label("Files", systemImage: "folder").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        }.controlSize(.large).disabled(importing || store.writesDisabled)
    }
    private func layerMenu(_ title: String, target: ImageDestination, exists: Bool) -> some View {
        Menu {
            Button("Choose from Photos", systemImage: "photo") { beginPhotos(target) }
            Button("Choose from Files", systemImage: "folder") { destination = target; choosingFile = true }
            if exists && target != .background {
                Button("Remove \(title.lowercased())", systemImage: "minus.circle") {
                    edit { target.setAsset(nil, on: &$0) }; refreshImages()
                }
            }
        } label: {
            HStack {
                Label(title, systemImage: target.symbol)
                Spacer()
                Text(exists ? "Replace" : "Add").foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.caption)
            }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
        }.disabled(importing || store.writesDisabled)
    }
    private func cropSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(title == "Zoom" ? String(format: "%.1f×", value.wrappedValue) : String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).accessibilityLabel(title == "Zoom" ? "Image zoom" : "\(title) crop")
        }
    }
    private func cropGesture(size: CGSize, image: UIImage) -> some Gesture {
        DragGesture(minimumDistance: 3).onChanged { value in
            guard !store.writesDisabled, !(kind == .wallpaper && (wallpaperSaver.isBusy || exporting)), let project else { return }
            if dragStart == nil { dragStart = CGPoint(x: project.centerX, y: project.centerY) }
            guard let start = dragStart else { return }
            let rect = MobileImageRenderer.cropRect(image: image.size, canvas: size, zoom: project.zoom,
                                                    centerX: project.centerX, centerY: project.centerY)
            edit {
                $0.centerX = min(1, max(0, start.x - value.translation.width / max(1, rect.width)))
                $0.centerY = min(1, max(0, start.y - value.translation.height / max(1, rect.height)))
            }
        }.onEnded { _ in dragStart = nil }
            .simultaneously(with: MagnificationGesture().onChanged { value in
                guard !store.writesDisabled, !(kind == .wallpaper && (wallpaperSaver.isBusy || exporting)), let project else { return }
                if zoomStart == nil { zoomStart = project.zoom }
                edit { $0.zoom = min(5, max(1, (zoomStart ?? 1) * value)) }
            }.onEnded { _ in zoomStart = nil })
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        guard let projectID else { return }
        guard let saved = store.document.images.first(where: { $0.id == projectID && $0.kind == kind }) else {
            notice = "This saved image is no longer available in this tool."; return
        }
        project = saved; lastSaved = saved; refreshImages()
    }
    private func refreshImages() {
        guard let project else { return }
        background = store.image(project)
        foreground = project.foregroundAsset.flatMap { store.imageAsset($0) }
        logo = project.logoAsset.flatMap { store.imageAsset($0) }
        persona = project.personaAsset.flatMap { store.imageAsset($0) }
        drawingUnavailable = false
        if let data = project.drawing, (try? PKDrawing(data: data)) == nil {
            drawingUnavailable = true; notice = "The saved drawing could not be read. Use Image actions to open the original in another tool. Your saved drawing is untouched."
        }
        if (project.foregroundAsset != nil && foreground == nil) || (project.logoAsset != nil && logo == nil) || (project.personaAsset != nil && persona == nil) {
            notice = "A saved layer is missing. Replace or remove it before sharing."
        }
    }
    private func beginPhotos(_ target: ImageDestination) { destination = target; photo = nil; choosingPhotos = true }
    private func accept(_ data: Data, target: ImageDestination, title: String) {
        do {
            try validateImage(data)
            guard !store.writesDisabled else { throw MobileStoreError.invalid("Saving is paused. Your original images are unchanged.") }
            notice = nil
            if target == .newImage || project == nil {
                guard saveNow(), var created = store.importImage(data, kind: kind, title: String(title.prefix(200))) else { return }
                if kind == .wallpaper {
                    created.wallpaperAspect = min(1.5, max(0.4, deviceAspect))
                    guard store.updateImage(created) else { return }
                }
                project = created; lastSaved = created
                drawingControls.setLimitExceeded(false)
            } else {
                guard let asset = store.importLayer(data) else { return }
                edit {
                    target.setAsset(asset, on: &$0)
                }
                _ = saveNow()
            }
            refreshImages()
        } catch { notice = error.localizedDescription }
    }
    private func validateImage(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 64_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width.isFinite, height.isFinite, width * height <= 50_000_000,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) != nil else {
            throw MobileStoreError.invalid("Choose a readable still image under 64 MB and 50 megapixels. Animated images and documents are not supported here.")
        }
    }
    @discardableResult private func saveNow() -> Bool {
        saveTask?.cancel()
        guard let project, project != lastSaved else { return true }
        guard store.updateImage(project) else { return false }
        lastSaved = project; return true
    }
    private func edit(_ mutate: (inout MobileImageProject) -> Void) {
        guard var next = project else { return }; mutate(&next); project = next
    }
    private func binding<T>(_ path: WritableKeyPath<MobileImageProject, T>, fallback: T) -> Binding<T> {
        Binding(get: { project?[keyPath: path] ?? fallback }, set: { value in edit { $0[keyPath: path] = value } })
    }
    private func limitedBinding(_ path: WritableKeyPath<MobileImageProject, String>) -> Binding<String> {
        Binding(get: { project?[keyPath: path] ?? "" }, set: { value in edit { $0[keyPath: path] = String(value.prefix(200)) } })
    }
    private func reuse(_ original: MobileImageProject, as target: MobileImageKind) {
        guard saveNow(), let copy = store.reuse(original, as: target) else { return }
        reused = copy; showingReused = true
    }
    private func createScene() {
        guard saveNow(), let project else { return }
        do { convertedSceneID = try MobileSceneImport.convert(project: project, store: store, scenes: scenes).id }
        catch { notice = error.localizedDescription }
    }
    private func export() {
        guard !exporting, !(kind == .wallpaper && wallpaperSaver.isBusy), let project else { return }
        exporting = true; toolsVisible = false
        defer { exporting = false }
        do {
            guard let image = store.image(project, maxPixels: 3840) else { throw MobileStoreError.invalid("The original image could not be opened.") }
            let result = try MobileImageRenderer.render(project: project, background: image,
                foreground: project.foregroundAsset.flatMap { store.imageAsset($0, maxPixels: 3840) },
                logo: project.logoAsset.flatMap { store.imageAsset($0, maxPixels: 1600) },
                persona: project.personaAsset.flatMap { store.imageAsset($0, maxPixels: 2400) })
            guard let data = result.pngData() else { throw MobileStoreError.invalid("The PNG could not be created. Your saved work is unchanged.") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            _ = saveNow(); share = ImageShare(url: url)
        } catch { notice = error.localizedDescription }
    }

    private func saveWallpaperToPhotos(allowAnotherCopy: Bool = false) {
        guard kind == .wallpaper, !exporting, !wallpaperSaver.isBusy, let project else { return }
        exporting = true; notice = nil
        do {
            guard let image = store.image(project, maxPixels: 3840) else { throw MobileStoreError.invalid("The original image could not be opened.") }
            let result = try MobileImageRenderer.render(project: project, background: image)
            guard let data = result.pngData() else { throw MobileStoreError.invalid("The PNG could not be created. Your saved work is unchanged.") }
            _ = saveNow()
            Task { @MainActor in
                defer { exporting = false }
                await wallpaperSaver.save(pngData: data, allowAnotherCopy: allowAnotherCopy)
            }
        } catch { exporting = false; notice = error.localizedDescription }
    }
}

private enum ImageDestination: Equatable {
    case newImage, background, foreground, logo, persona
    var symbol: String {
        switch self { case .newImage, .background: "photo"; case .foreground: "rectangle.on.rectangle"; case .logo: "seal"; case .persona: "person.crop.rectangle" }
    }
    func setAsset(_ asset: String?, on project: inout MobileImageProject) {
        switch self {
        case .newImage, .background: if let asset { project.replaceBackground(with: asset) }
        case .foreground: project.foregroundAsset = asset
        case .logo: project.logoAsset = asset
        case .persona: project.personaAsset = asset
        }
    }
}

private struct ImageShare: Identifiable { let id = UUID(); let url: URL }
struct MobileImageShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.modalPresentationStyle = .pageSheet
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
