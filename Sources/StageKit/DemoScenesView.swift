import AppKit
import SwiftUI

struct DemoScenesView: View {
    @ObservedObject var model: DemoScenes
    @State private var rename = ""
    @State private var confirmingRemoval = false
    @State private var removalCandidate: DemoScene?
    @State private var renameSnapshot: DemoScene?
    @State private var choosingStarter = false
    @State private var choosingLogo = false
    @State private var creatingTextLogo = false
    @State private var textLogoName = "Your company"
    @State private var backdropReplacement: BackdropReplacement?
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Scenes", systemImage: "iphone.and.landscape").font(.title2.weight(.semibold))
                    Text("Your pictures, wallpapers and presentations.").font(.callout).foregroundStyle(.secondary)
                }
                TextField("Find a customer or scene", text: $model.query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Find a scene")
                List(selection: $model.selectedID) {
                    ForEach(model.matches) { scene in
                        HStack(spacing: 9) {
                            Image(systemName: scene.showsPhone ? "iphone" : "photo").foregroundStyle(Workbench.accent)
                            Text(scene.name).lineLimit(2)
                        }.padding(.vertical, 5).tag(scene.id)
                    }
                }.listStyle(.sidebar)
                Button { choosingStarter = true } label: { Label("Choose a starter…", systemImage: "square.grid.2x2") }
                    .disabled(model.storageBlocked)
                Button { model.importImage() } label: { Label("Add backdrop…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(model.storageBlocked)
                Button { model.importSceneCopy() } label: { Label("Import scene copy…", systemImage: "square.and.arrow.down") }
                    .disabled(model.storageBlocked)
                Button { model.showPersonas() } label: { Label("Personas…", systemImage: "person.crop.rectangle") }
                    .help("Show a persona over your browser without a backdrop")
                if let adapter = model.sceneSync { MacSceneSyncControls(adapter: adapter) }
            }.padding(18).frame(width: 245)
            Divider()
            GeometryReader { editor in
            VStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let scene = model.selected {
                    HStack {
                        TextField("Scene name", text: $rename, onCommit: commitName)
                            .font(.title2.weight(.semibold)).textFieldStyle(.plain)
                            .onChange(of: model.selectedID) { _, _ in renameSnapshot = model.selected; rename = model.selected?.name ?? "" }
                            .onAppear { renameSnapshot = scene; rename = scene.name }
                            .onChange(of: scene.libraryRevision) { _, _ in
                                if rename == renameSnapshot?.name { rename = scene.name; renameSnapshot = scene }
                            }
                        Button("Rename") { commitName() }.disabled(rename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rename == scene.name)
                        Menu {
                            Button("Save editable copy…") { commitName(); model.exportSceneCopy() }
                                .disabled(model.isSceneReadOnly(scene))
                            Button("Duplicate scene") { model.duplicate() }
                            Button("Move up") { model.moveScene(scene.id, by: -1) }.disabled(model.scenes.first?.id == scene.id)
                            Button("Move down") { model.moveScene(scene.id, by: 1) }.disabled(model.scenes.last?.id == scene.id)
                            Button("Remove scene…", role: .destructive) { removalCandidate = scene; confirmingRemoval = true }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("Scene options")
                    }
                    if let image = model.image(for: scene) {
                        SceneCanvas(scene: scene, image: image, logoImage: model.logoImage(for: scene), handImage: model.handImage(for: scene), personaImage: model.personaImage(for: scene), editable: !model.isSceneReadOnly(scene)) { value in
                            model.update(value) ? model.scenes.first(where: { $0.id == value.id }) : nil
                        }
                            .frame(width: previewSize(in: editor.size).width, height: previewSize(in: editor.size).height)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)))
                            .accessibilityLabel("Scene preview. Drag the phone or persona to position it; drag the background to crop it.")
                            .frame(maxWidth: .infinity)
                        HStack {
                            Text("Drag to position · saved on release")
                            Spacer()
                            Button("Change backdrop…") { backdropReplacement = BackdropReplacement(scene: model.selected ?? scene, root: model.root) }
                                .disabled(model.storageBlocked)
                            Text("Layout saved automatically").foregroundStyle(Workbench.accent)
                        }.font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 22) {
                            Toggle("Device frame", isOn: binding(\.showsPhone)).toggleStyle(.switch)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Device size").font(.caption).foregroundStyle(.secondary)
                                Slider(value: binding(\.phoneHeight), in: ViewportGeometry.heightRange).disabled(!scene.showsPhone)
                                    .accessibilityLabel("Device size")
                            }
                            Button("Maximise") {
                                var value = scene; value.phoneHeight = ViewportGeometry.heightRange.upperBound; model.update(value)
                            }.disabled(!scene.showsPhone).help("Fill the available height while keeping the whole frame visible")
                        }
                        #if !APP_STORE
                        HStack {
                            Toggle("Gentle motion", isOn: Binding(get: { scene.gentleMotion == true }, set: { enabled in
                                var value = model.selected ?? scene; value.gentleMotion = enabled ? true : nil; model.update(value)
                            }))
                            Text(scene.ambience == nil ? "Moves the photo when presenting. Exports stay still." : "Moves only the natural details. Exports stay still.").font(.caption).foregroundStyle(.secondary)
                        }
                        #endif
                        logoControls(scene)
                        personaControls(scene)
                        DisclosureGroup("Adjust layout") {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Backdrop zoom").font(.caption).foregroundStyle(.secondary)
                                Slider(value: binding(\.zoom), in: 1...3).accessibilityLabel("Backdrop zoom")
                            }
                        viewportControls(scene)
                        HStack(spacing: 12) {
                            Text("Device position").foregroundStyle(.secondary)
                            Button("Left") { position(0.12) }.disabled(!scene.showsPhone)
                            Button("Centre") { position(0.5) }.disabled(!scene.showsPhone)
                            Button("Right") { position(0.88) }.disabled(!scene.showsPhone)
                            Spacer()
                            Button("Reset layout") {
                                var reset = scene; reset.backgroundX = 0.5; reset.backgroundY = 0.5; reset.zoom = 1
                                reset.phoneX = 0.5; reset.phoneY = 0.5; reset.phoneHeight = 0.88; reset.viewport = .phone
                                model.update(reset)
                            }.buttonStyle(.link)
                        }.font(.caption)
                        handControls(scene)
                        }.padding(.top, 10)
                        }.font(.caption)
                    } else {
                        ContentUnavailableView {
                            Label("Backdrop missing", systemImage: "photo.badge.exclamationmark")
                        } description: {
                            Text("Choose a replacement to keep this scene’s saved layout.")
                        } actions: {
                            Button("Change backdrop…") { backdropReplacement = BackdropReplacement(scene: model.selected ?? scene, root: model.root) }
                                .disabled(model.storageBlocked)
                        }
                    }
                } else if !model.scenes.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "magnifyingglass").font(.system(size: 38)).foregroundStyle(.secondary)
                        Text("No matching scenes").font(.title2.weight(.semibold))
                        Button("Clear search") { model.query = "" }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "iphone.and.landscape").font(.system(size: 48)).foregroundStyle(Workbench.accent)
                        Text("Set the scene for your next demo").font(.title2.weight(.semibold))
                        Text("Choose a backdrop, add your logo, and start presenting.\nYour setup is saved for next time.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Choose a starter…") { choosingStarter = true }.buttonStyle(.borderedProminent).disabled(model.storageBlocked)
                        Button("Add your own backdrop…") { model.importImage() }.disabled(model.storageBlocked)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer(minLength: 0)
                if let notice = model.notice {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                        Text(notice).textSelection(.enabled)
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss notice")
                    }.font(.caption).padding(10).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                #if !APP_STORE
                if model.hasDesktopSnapshot {
                    HStack {
                        Text(model.desktopBusy ? "Waiting for macOS…" : "Desktop recovery details are saved.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore desktop") { model.restoreDesktop() }.disabled(model.desktopBusy)
                    }
                }
                #endif
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.disabled(model.selected.map { model.isSceneReadOnly($0) } ?? false)
            #if !APP_STORE
            DesktopMotionControls(controller: model.desktopMotion).padding(.horizontal, 24)
            #endif
            if let scene = model.selected, model.image(for: scene) != nil {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        #if !APP_STORE
                        Button("Present full screen") { commitName(); model.startDemo() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.desktopBusy || !model.systemIntegrationEnabled)
                        Button("Present in window") { commitName(); model.startDemo(mode: .windowed) }.controlSize(.large).disabled(model.desktopBusy || !model.systemIntegrationEnabled)
                        #else
                        Button("Export image…") { commitName(); model.exportPNG() }.buttonStyle(.borderedProminent).controlSize(.large)
                        #endif
                        Spacer()
                        Menu("More") {
                        #if !APP_STORE
                        Button("Export image…") { commitName(); model.exportPNG() }
                        Button("Use as desktop") { commitName(); model.applyDesktop() }.disabled(model.desktopBusy || !model.systemIntegrationEnabled)
                        Button("Use as animated desktop") { commitName(); model.applyDesktop(animate: true) }.disabled(model.desktopBusy || !model.systemIntegrationEnabled)
                        #endif
                        }.fixedSize().accessibilityLabel("More scene actions")
                    }
                    #if !APP_STORE
                    Text("Click the edge tile for controls. Esc closes controls, then ends.")
                        .font(.caption).foregroundStyle(.secondary)
                    #else
                    Text("Export your scene, then position a QuickTime movie preview over its device frame.")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                    NativePresentationApps { model.notice = $0 }
                }.padding(.horizontal, 24).padding(.vertical, 16).background(Workbench.surface)
            }
            }
            }
        }
        .background(Workbench.background).tint(Workbench.accent).workbenchTheme()
        .sheet(item: $backdropReplacement) { draft in BackdropReplacementView(model: model, draft: draft) }
        .sheet(isPresented: $choosingStarter) {
            SceneStarterGallery(model: model) { starter in
                do { try model.useStarter(starter); choosingStarter = false }
                catch { model.notice = error.localizedDescription; choosingStarter = false }
            }
        }
        .sheet(isPresented: $choosingLogo) { SavedLogoGallery(model: model) }
        .sheet(isPresented: $model.choosingPersonas) {
            if let id = model.personaSceneID {
                PersonaLibraryView(library: model.personas, onChoose: { persona in
                    model.usePersona(persona, in: id)
                    model.choosingPersonas = false
                })
            } else {
                PersonaLibraryView(library: model.personas)
            }
        }
        .alert("Create a text logo", isPresented: $creatingTextLogo) {
            TextField("Company name", text: $textLogoName)
            Button("Create") { model.makeTextLogo(String(textLogoName.prefix(80))) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("A simple wordmark you can use now and replace with the real logo later.") }
        .alert("Remove this scene?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { if let captured = removalCandidate { model.remove(captured) }; removalCandidate = nil }
        } message: { Text("The saved layout will be removed. If scene sync is enabled, removal also syncs to your devices. Original pictures stay on this Mac.") }
    }
    private func previewSize(in editor: CGSize) -> CGSize {
        // Keep the saved scene and everyday controls together at the minimum
        // window size. Expanded adjustments can scroll without stretching it.
        let width = max(1, editor.width - 48)
        let logoControlsHeight: CGFloat = model.selected?.logo == nil ? 0 : 64
        let height = max(200, editor.height - 365 - logoControlsHeight)
        return CGSize(width: min(width, height * model.screenAspect), height: min(width / model.screenAspect, height))
    }
    private func personaControls(_ scene: DemoScene) -> some View {
        HStack(spacing: 12) {
            Button { model.showPersonas(for: scene.id) } label: {
                Label(scene.persona == nil ? "Add persona…" : "Change persona…", systemImage: "person.crop.rectangle")
            }.disabled(model.storageBlocked)
            if let persona = scene.persona {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.selected?.persona?.width ?? persona.width }, set: { width in
                    guard var value = model.selected, value.id == scene.id else { return }
                    value.persona?.width = width; model.update(value)
                }), in: 0.06...0.40).accessibilityLabel("Persona size")
                Menu("Position") {
                    Button("Bottom left") { movePersona(scene, x: 0.02, y: 0.02) }
                    Button("Bottom right") { movePersona(scene, x: 0.98, y: 0.02) }
                    Button("Top left") { movePersona(scene, x: 0.02, y: 0.98) }
                    Button("Top right") { movePersona(scene, x: 0.98, y: 0.98) }
                }.fixedSize()
                Button { var value = scene; value.persona = nil; model.update(value) } label: {
                    Image(systemName: "xmark.circle")
                }.buttonStyle(.plain).accessibilityLabel("Remove persona from scene")
            }
            Spacer(minLength: 0)
        }.font(.caption)
    }
    private func movePersona(_ scene: DemoScene, x: Double, y: Double) {
        var value = scene; value.persona?.x = x; value.persona?.y = y; model.update(value)
    }
    @ViewBuilder private func viewportControls(_ scene: DemoScene) -> some View {
        if scene.showsPhone {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Menu("Device shape") {
                        Button("Phone") { setViewport(.phone) }
                        Button("Tablet") { setViewport(.tablet) }
                        Button("Tablet landscape") { setViewport(.landscape) }
                        Divider()
                        Button("My device") { if let profile = model.myDevice { setViewport(profile) } }.disabled(model.myDevice == nil)
                    }.fixedSize()
                    Button("Rotate") { var value = scene.viewport ?? .legacy; value.aspect = 1 / value.aspect; setViewport(value) }
                    Spacer()
                    Button("Save as my device") { model.saveMyDevice() }.buttonStyle(.link)
                }.font(.caption)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Width").font(.caption).foregroundStyle(.secondary)
                        Slider(value: viewportBinding(\.aspect), in: 0.3...2.4).accessibilityLabel("Device width")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Corners").font(.caption).foregroundStyle(.secondary)
                        Slider(value: viewportBinding(\.corners), in: 0...0.3).accessibilityLabel("Corner radius")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Border").font(.caption).foregroundStyle(.secondary)
                        Slider(value: viewportBinding(\.border), in: 0.003...0.035).accessibilityLabel("Border thickness")
                    }
                }
            }
        }
    }
    private func setViewport(_ viewport: DeviceViewport) {
        guard var scene = model.selected else { return }; scene.viewport = viewport; model.update(scene)
    }
    private func viewportBinding(_ key: WritableKeyPath<DeviceViewport, Double>) -> Binding<Double> {
        Binding(get: { (model.selected?.viewport ?? .legacy)[keyPath: key] }, set: { value in
            var viewport = model.selected?.viewport ?? .legacy; viewport[keyPath: key] = value; setViewport(viewport)
        })
    }
    @ViewBuilder private func handControls(_ scene: DemoScene) -> some View {
        if let hand = scene.hand {
            DisclosureGroup("Hand cutout") {
                VStack(spacing: 10) {
                    HStack {
                        Picker("Tone", selection: handBinding(\.tone, fallback: .original)) {
                            ForEach(HandTone.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Toggle("Flip", isOn: handBinding(\.mirrored, fallback: false))
                        Button("Replace…") { model.importHand() }
                        Button("Remove") { var value = scene; value.hand = nil; model.update(value) }
                    }
                    HStack {
                        Text("Size"); Slider(value: handBinding(\.scale, fallback: 1), in: 0.35...2).accessibilityLabel("Hand size")
                        Text("Across"); Slider(value: handBinding(\.x, fallback: 0), in: -1...1).accessibilityLabel("Hand horizontal position")
                        Text("Up"); Slider(value: handBinding(\.y, fallback: 0), in: -1...1).accessibilityLabel("Hand vertical position")
                    }
                    if model.handImage(for: scene) == nil { Text("Hand missing — replace or remove it to present.").foregroundStyle(.orange) }
                }.font(.caption).padding(.top, 8)
            }.font(.caption).id(hand.image)
        } else {
            Button("Add hand cutout…") { model.importHand() }.font(.caption)
        }
    }
    private func handBinding<T>(_ key: WritableKeyPath<SceneHand, T>, fallback: T) -> Binding<T> {
        Binding(get: { model.selected?.hand?[keyPath: key] ?? fallback }, set: { value in
            guard var scene = model.selected, var hand = scene.hand else { return }
            hand[keyPath: key] = value; scene.hand = hand; model.update(scene)
        })
    }
    @ViewBuilder private func logoControls(_ scene: DemoScene) -> some View {
        if scene.logo != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Customer logo", systemImage: "photo.badge.checkmark").font(.caption)
                    Spacer()
                    Button("Paste logo") { model.pasteLogo() }
                    logoMenu("Replace…")
                    Button("Remove") { var value = scene; value.logo = nil; model.update(value) }
                }
                HStack(spacing: 16) {
                    Picker("Corner", selection: logoBinding(\.corner, fallback: .topRight)) {
                        ForEach(LogoCorner.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.fixedSize()
                    Picker("Backing", selection: logoBinding(\.backing, fallback: .light)) {
                        ForEach(LogoBacking.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.fixedSize()
                    Text("Size").foregroundStyle(.secondary)
                    Slider(value: logoBinding(\.width, fallback: 0.16), in: 0.08...0.28)
                        .accessibilityLabel("Logo size")
                }.font(.caption)
                if model.logoImage(for: scene) == nil {
                    Text("Logo missing — replace or remove it to export this scene.").font(.caption).foregroundStyle(.orange)
                }
            }
        } else {
            HStack {
                logoMenu("Add logo…")
                Button("Paste logo") { model.pasteLogo() }
            }
        }
    }
    private func logoMenu(_ title: String) -> some View {
        Menu(title) {
            Button("Choose image…") { model.importLogo() }
            Button("Saved logos…") { choosingLogo = true }.disabled(model.savedLogos.isEmpty)
            Button("Create text logo…") { creatingTextLogo = true }
            if !model.savedLogos.isEmpty {
                Divider()
                ForEach(model.savedLogos.prefix(8)) { logo in Button(logo.name) { model.useSavedLogo(logo) } }
            }
        }.fixedSize()
    }
    private func logoBinding<T>(_ key: WritableKeyPath<SceneLogo, T>, fallback: T) -> Binding<T> {
        let sceneID = model.selectedID
        return Binding(get: { model.selected?.logo?[keyPath: key] ?? fallback }, set: { value in
            guard var scene = model.selected, scene.id == sceneID, var logo = scene.logo else { return }
            logo[keyPath: key] = value; scene.logo = logo; model.update(scene)
        })
    }
    private func binding<T>(_ key: WritableKeyPath<DemoScene, T>) -> Binding<T> {
        let fallback = model.selected![keyPath: key], sceneID = model.selectedID
        return Binding(get: { model.selected?[keyPath: key] ?? fallback }, set: { value in
            guard var scene = model.selected, scene.id == sceneID else { return }; scene[keyPath: key] = value; model.update(scene)
        })
    }
    private func position(_ x: Double) {
        guard var scene = model.selected else { return }; scene.phoneX = x; model.update(scene)
    }
    private func commitName() {
        guard var scene = renameSnapshot, scene.id == model.selectedID else { return }
        let trimmed = rename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { rename = scene.name; return }
        guard trimmed != scene.name else { return }
        scene.name = String(trimmed.prefix(160))
        // A rename can leave the current search. Keep this customer selected so
        // the following Start or Export action cannot act on a different scene.
        if !model.query.isEmpty && !scene.name.localizedCaseInsensitiveContains(model.query) { model.query = "" }
        if model.update(scene) { renameSnapshot = model.selected; rename = model.selected?.name ?? rename }
    }
}

private struct SceneCanvas: NSViewRepresentable {
    let scene: DemoScene
    let image: NSImage
    let logoImage: NSImage?
    let handImage: NSImage?
    let personaImage: NSImage?
    let editable: Bool
    let update: (DemoScene) -> DemoScene?
    func makeNSView(context: Context) -> SceneCanvasView { SceneCanvasView() }
    func updateNSView(_ view: SceneCanvasView, context: Context) {
        view.receive(scene); view.image = image; view.logoImage = logoImage; view.handImage = handImage; view.personaImage = personaImage; view.update = update; view.editable = editable; view.needsDisplay = true
    }
}

final class SceneCanvasView: NSView {
    var scene: DemoScene?
    var image: NSImage?
    var logoImage: NSImage?
    var handImage: NSImage?
    var personaImage: NSImage?
    var update: ((DemoScene) -> DemoScene?)?
    var editable = true
    private var origin = CGPoint.zero
    private var initial: DemoScene?
    private var dragPreview: DemoScene?
    func receive(_ value: DemoScene) {
        if scene?.id != value.id { initial = nil; dragPreview = nil }
        scene = value
    }
    private var movingPhone = false
    private var movingPersona = false
    private var resizingWidth = false
    private var resizingSize = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let scene = dragPreview ?? scene, let image else { return }
        SceneRenderer.draw(scene, image: image, size: bounds.size, logoImage: logoImage, handImage: handImage, personaImage: personaImage)
        if scene.showsPhone {
            let rect = SceneRenderer.phoneRect(scene, in: bounds.size)
            NSColor.controlAccentColor.setFill()
            for point in [CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.minY)] {
                NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard editable else { return }
        origin = convert(event.locationInWindow, from: nil); initial = scene
        movingPersona = false
        if let scene {
            if let persona = scene.persona, let personaImage {
                movingPersona = PersonaGeometry.rect(persona, imageSize: personaImage.size, in: bounds.size).contains(origin)
            }
            let rect = SceneRenderer.phoneRect(scene, in: bounds.size)
            resizingWidth = scene.showsPhone && abs(origin.x - rect.maxX) < 12 && abs(origin.y - rect.midY) < 12
            resizingSize = scene.showsPhone && abs(origin.x - rect.maxX) < 12 && abs(origin.y - rect.minY) < 12
            movingPhone = scene.showsPhone && rect.contains(origin)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard editable, var draft = initial, let image else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if movingPersona, var persona = draft.persona, let personaImage {
            let rect = PersonaGeometry.rect(persona, imageSize: personaImage.size, in: bounds.size)
            persona.x += delta.x / max(1, bounds.width - rect.width)
            persona.y += delta.y / max(1, bounds.height - rect.height)
            draft.persona = persona
        } else if resizingWidth {
            let geometry = ViewportGeometry(scene: draft, size: bounds.size)
            var viewport = draft.viewport ?? .legacy
            viewport.aspect = max(1, geometry.screen.width + delta.x) / max(1, geometry.screen.height)
            draft.viewport = try? viewport.validated()
            let resized = SceneRenderer.phoneRect(draft, in: bounds.size)
            draft.phoneX = geometry.outer.minX / max(1, bounds.width - resized.width)
        } else if resizingSize {
            let rect = SceneRenderer.phoneRect(draft, in: bounds.size)
            draft.phoneHeight = min(ViewportGeometry.heightRange.upperBound, max(ViewportGeometry.heightRange.lowerBound, (rect.height - delta.y) / max(1, bounds.height)))
        } else if movingPhone {
            let frame = SceneRenderer.phoneRect(draft, in: bounds.size)
            draft.phoneX += delta.x / max(1, bounds.width - frame.width)
            draft.phoneY += delta.y / max(1, bounds.height - frame.height)
        } else {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height) * draft.zoom
            let overflowX = image.size.width * scale - bounds.width
            let overflowY = image.size.height * scale - bounds.height
            if overflowX > 1 { draft.backgroundX -= delta.x / overflowX }
            if overflowY > 1 { draft.backgroundY -= delta.y / overflowY }
        }
        dragPreview = try? draft.validated(); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let pending = dragPreview; dragPreview = nil; initial = nil
        // Commit once per drag. The captured revision rejects an intervening
        // remote edit, and large immutable pictures are not rehashed per pixel.
        if let pending, let saved = update?(pending) { scene = saved }
        needsDisplay = true
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { dragPreview = nil; initial = nil }
        super.viewWillMove(toWindow: newWindow)
    }
}

private struct DesktopMotionControls: View {
    @ObservedObject var controller: DesktopMotionController
    var body: some View {
        if controller.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Desktop motion", systemImage: "photo")
                    Spacer()
                    Button(controller.isPaused ? "Resume" : "Pause") { controller.togglePause() }
                    Button("Stop motion") { controller.stop() }
                }
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
