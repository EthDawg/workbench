import AppKit
import AVFoundation
import SwiftUI

/// The editor reserves room for everyday controls and its fixed action bar.
/// Expanded details scroll; the preview never asks for a wider canvas than the editor.
struct DemoScenesLayout {
    static let padding: CGFloat = 18
    static func sidebarWidth(in width: CGFloat) -> CGFloat { width < 900 ? 210 : 245 }
    static func previewSize(in editor: CGSize, aspect: CGFloat) -> CGSize {
        let width = max(1, editor.width - padding * 2)
        let availableHeight = max(1, editor.height)
        let height = min(availableHeight * 0.5, max(120, availableHeight - 330))
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 16 / 9
        return CGSize(width: min(width, height * ratio), height: min(width / ratio, height))
    }
}

/// Present's page: the scene on the left, the stage as it will look on the right
/// with the phone already in it when the Mac can see it, one Present button and the
/// phone's status beneath. Scene adjustments fold away under the preview.
struct DemoScenesView: View {
    @ObservedObject var model: DemoScenes
    @ObservedObject var phoneLink: PhoneLinkMonitor
    @ObservedObject var capture: DemoCapture
    @State private var removalRequest: SceneRemovalRequest?
    @State private var choosingStarter = false
    @State private var choosingLogo = false
    @State private var searchingLogo = false
    @State private var logoSceneID: UUID?
    @State private var adjustingScene = false
    @State private var adjustingPersona = false
    @State private var personaSelectionAfterPopover: UUID?
    @State private var showingHelp = false
    @State private var choosingSource = false
    @State private var helpAfterSource = false
    @State private var pendingNativeApp: NativePresentationApp?
    @State private var resizingDevice = false
    @State private var creatingTextLogo = false
    @State private var textLogoName = "Your company"
    @State private var backdropReplacement: BackdropReplacement?
    init(model: DemoScenes) {
        self.model = model; phoneLink = model.phoneLink; capture = model.capture
    }
    var body: some View {
        GeometryReader { workspace in
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    // Workbench's page title above names Present; this column is its scenes (#134).
                    Label("Scenes", systemImage: "iphone.and.landscape").font(.body.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("The clean background your phone appears in.").font(.callout).foregroundStyle(.secondary)
                }
                TextField("Find a customer or scene", text: $model.query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Find a scene")
                SceneList(model: model) { scenes in removalRequest = SceneRemovalRequest(scenes: scenes) }
                Text(model.query.isEmpty ? "Double-click to rename · Drag to reorder" : "Clear search to reorder scenes")
                    .font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Choose a starter…") { choosingStarter = true }
                    Button("Choose a backdrop…") { model.importImage() }
                    Divider()
                    Button("Import scene copy…") { model.importSceneCopy() }
                } label: { Label("Add scene", systemImage: "plus") }
                    .disabled(model.storageBlocked)
                if let adapter = model.sceneSync { MacSceneSyncControls(adapter: adapter) }
            }.padding(24).frame(width: DemoScenesLayout.sidebarWidth(in: workspace.size.width))
            Divider()
            GeometryReader { editor in
            VStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let live = model.liveSettingsView { live; Divider() }
                Group {
                if let scene = model.selected {
                    HStack {
                        Text(scene.name).font(.title2.weight(.semibold)).lineLimit(2).truncationMode(.tail)
                            .help(scene.name).frame(maxWidth: .infinity, alignment: .leading)
                        scenePersonaButton(scene)
                        Menu {
                            Button("Save editable copy…") { model.exportSceneCopy() }
                                .disabled(model.isSceneReadOnly(scene))
                            Button("Duplicate scene") { model.duplicate() }
                            Button("Delete scene…", role: .destructive) { removalRequest = SceneRemovalRequest(scenes: [scene]) }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("Scene actions")
                    }
                    if let image = model.image(for: scene) {
                        SceneCanvas(scene: scene, image: image, logoImage: model.logoImage(for: scene), handImage: model.handImage(for: scene), personaImage: model.personaImage(for: scene), editable: !model.isSceneReadOnly(scene),
                                    editing: adjustingScene || resizingDevice,
                                    covered: searchingLogo || choosingLogo || choosingStarter || backdropReplacement != nil || model.choosingPersonas || adjustingPersona || showingHelp || choosingSource,
                                    capture: capture, live: capture.live, dimensions: capture.dimensions,
                                    loadAmbience: model.ambienceImages, visibility: { model.setPageVisible($0) }) { value in
                            model.update(value) ? model.scenes.first(where: { $0.id == value.id }) : nil
                        }
                            .frame(width: DemoScenesLayout.previewSize(in: editor.size, aspect: model.screenAspect).width, height: DemoScenesLayout.previewSize(in: editor.size, aspect: model.screenAspect).height)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)))
                            .overlay { if scene.showsPhone && !capture.live { phoneFrameStatus(scene: scene, in: DemoScenesLayout.previewSize(in: editor.size, aspect: model.screenAspect)) } }
                            .accessibilityLabel(capture.live ? "Scene preview with your phone live. Drag the phone or persona to position it; drag the background to crop it."
                                                : "Scene preview. Drag the phone or persona to position it; drag the background to crop it.")
                            .frame(maxWidth: .infinity)
                            .onChange(of: scene.id) { _, _ in adjustingScene = false; resizingDevice = false }
                        if scene.showsPhone {
                            PhoneLinkStatusRow(status: phoneLink.status,
                                               perform: { step in model.performPhoneStep(step) { choosingSource = true } },
                                               help: { showingHelp = true }, reconnect: { model.reconnectPhone() })
                        } else {
                            Text("This scene shows your backdrop without a phone. Turn on Device frame to add one.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            if model.onViewImages != nil { Button("View image") { model.viewImages(startingAt: scene.id) } }
                            Text("Drag to position · saves automatically").fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Change backdrop…") { backdropReplacement = BackdropReplacement(scene: model.selected ?? scene, root: model.root) }
                                .disabled(model.storageBlocked)
                        }.font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Scene options", isExpanded: $adjustingScene) {
                        VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 22) {
                            Toggle("Device frame", isOn: binding(\.showsPhone)).toggleStyle(.switch)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Device size").font(.caption).foregroundStyle(.secondary)
                                Slider(value: binding(\.phoneHeight), in: ViewportGeometry.heightRange, onEditingChanged: { resizingDevice = $0 }).disabled(!scene.showsPhone)
                                    .accessibilityLabel("Device size")
                            }
                            Button("Maximise") {
                                var value = scene; value.phoneHeight = ViewportGeometry.heightRange.upperBound; model.update(value)
                            }.disabled(!scene.showsPhone).help("Fill the available height while keeping the whole frame visible")
                        }
                        logoControls(scene)
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
                } else if model.selection.ids.count > 1 {
                    VStack(spacing: 14) {
                        Image(systemName: "square.stack").font(.system(size: 38)).foregroundStyle(.secondary)
                        Text("\(model.selection.ids.count) scenes selected").font(.title2.weight(.semibold))
                        Text(model.query.isEmpty ? "Drag them together to reorder, or delete the selection." : "Select one scene to edit, or delete the selection.")
                            .foregroundStyle(.secondary)
                        Button("Delete selected scenes…", role: .destructive) {
                            removalRequest = SceneRemovalRequest(scenes: model.selectedScenes)
                        }.disabled(model.selectedScenes.contains { model.isSceneReadOnly($0) })
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !model.scenes.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "magnifyingglass").font(.system(size: 38)).foregroundStyle(.secondary)
                        Text("No matching scenes").font(.title2.weight(.semibold))
                        Button("Clear search") { model.query = "" }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "iphone.and.landscape").font(.system(size: 48)).foregroundStyle(Workbench.accent)
                        Text("Your phone, on a clean stage").font(.title2.weight(.semibold))
                        Text("Choose a backdrop, add your logo, plug in your phone and press Present.\nYour setup is saved for next time.")
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
                        Text(model.desktopBusy ? "Waiting for macOS…" : "A desktop picture from an earlier version can be put back.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore desktop") { model.restoreDesktop() }.disabled(model.desktopBusy)
                    }
                }
                #endif
                }.disabled(model.selected.map { model.isSceneReadOnly($0) } ?? false)
            }.padding(DemoScenesLayout.padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let scene = model.selected, model.image(for: scene) != nil {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        presentButton
                        #if !APP_STORE
                        presentOptions
                        #endif
                        Spacer(minLength: 0)
                        Text(model.usesSharedControls ? "Share the Workbench presentation window in your call. Command-/ focuses the floating toolbar."
                             : "Share the Workbench presentation window in your call. Esc ends it.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }.padding(.horizontal, DemoScenesLayout.padding).padding(.vertical, 12).background(Workbench.surface)
            }
            }
            }
        }
        }
        .background(Workbench.background).tint(Workbench.accent).workbenchTheme()
        .onChange(of: model.selectedID) { _, _ in adjustingPersona = false }
        .sheet(isPresented: $showingHelp, onDismiss: {
            guard let app = pendingNativeApp else { return }
            pendingNativeApp = nil
            model.openNativeApp(app)
        }) {
            // While a presentation runs, opening an Apple app ends it first, through its own handoff.
            PhoneConnectionHelp(status: phoneLink.status, diagnostic: { phoneLink.diagnostic(build: Workbench.buildLabel) }, endsPresentation: model.isPresenting) { app in
                pendingNativeApp = app
                showingHelp = false
            }
        }
        .sheet(isPresented: $choosingSource, onDismiss: {
            guard helpAfterSource else { return }
            helpAfterSource = false
            showingHelp = true
        }) { sourceSheet }
        .sheet(item: $backdropReplacement) { draft in BackdropReplacementView(model: model, draft: draft) }
        .sheet(item: $removalRequest) { request in
            SceneRemovalConfirmation(request: request) { model.removeScenes(request.scenes) }
        }
        .sheet(isPresented: $choosingStarter) {
            SceneStarterGallery(model: model) { starter in
                do { try model.useStarter(starter); choosingStarter = false }
                catch { model.notice = error.localizedDescription; choosingStarter = false }
            }
        }
        .sheet(isPresented: $choosingLogo) { SavedLogoGallery(model: model) }
        .sheet(isPresented: $searchingLogo) {
            LogoBrowser { image in
                guard let id = logoSceneID else { throw SceneError.noScene }
                try model.addLogo(image, to: id)
            }
        }
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
    }
    /// The one way to start. The saved choice between a window and full screen is an option.
    private var presentButton: some View {
        Group {
            #if !APP_STORE
            Button(model.isPresenting ? "Show presentation" : "Present") { model.startDemo() }.buttonStyle(.borderedProminent)
                .disabled(model.desktopBusy || !model.systemIntegrationEnabled)
                .accessibilityLabel(model.isPresenting ? "Show the running presentation" : (model.startsFullScreen ? "Present full screen" : "Present in a window"))
                .help(model.startsFullScreen ? "Opens the stage full screen" : "Opens the stage in a window you can share in a call")
            #else
            Button("Export image…") { model.exportPNG() }.buttonStyle(.borderedProminent)
            #endif
        }.fixedSize()
    }
    #if !APP_STORE
    private var presentOptions: some View {
        Menu("Options") {
            Toggle("Start full screen", isOn: Binding(get: { model.startsFullScreen }, set: { model.setStartsFullScreen($0) }))
            Divider()
            Button("Export image…") { model.exportPNG() }
        }.fixedSize().accessibilityLabel("Present options")
    }
    #endif
    /// What is true about the phone, inside the frame where it will appear.
    private func phoneFrameStatus(scene: DemoScene, in size: CGSize) -> some View {
        let status = phoneLink.status
        let viewport = ViewportGeometry(scene: scene, size: size).screen
        return VStack(spacing: 6) {
            Image(systemName: status.symbol).font(.title2)
            Text(status.title).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
            if let step = status.step {
                Button(step.title) { model.performPhoneStep(step) { choosingSource = true } }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }.padding(10).frame(width: max(80, viewport.width - 12))
            .foregroundStyle(.white)
            .position(x: viewport.midX, y: size.height - viewport.midY)
            .allowsHitTesting(status.step != nil)
            .accessibilityHidden(true)
    }
    /// Which screen to show, only when the Mac offers more than one or the
    /// remembered one is away. Choosing is explicit and remembered.
    private var sourceSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Which screen?").font(.title2.bold())
                Spacer()
                Button("Done") { choosingSource = false }.keyboardShortcut(.defaultAction)
            }
            Text(phoneLink.status.title).font(.headline)
            if let detail = phoneLink.status.detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if capture.sources.isEmpty {
                Text("No screen sources yet.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(capture.sources) { source in
                        Button {
                            model.performPhoneStep(.showSource(id: source.id, title: source.name)) {}
                            choosingSource = false
                        } label: {
                            HStack { Image(systemName: source.isScreen ? "iphone" : "video"); Text(source.name); Spacer(); if capture.selectedID == source.id { Image(systemName: "checkmark") } }
                        }.buttonStyle(.bordered)
                    }
                }
            }
            Divider()
            HStack {
                Button("Can’t see your phone?") { helpAfterSource = true; choosingSource = false }.buttonStyle(.link)
                Spacer()
                Button("Look again") { capture.refresh() }
            }
        }.padding(24).frame(width: 460).onExitCommand { choosingSource = false }
    }
    private func scenePersonaButton(_ scene: DemoScene) -> some View {
        Button {
            if scene.persona == nil { model.showPersonas(for: scene.id) }
            else { adjustingPersona = true }
        } label: {
            Label(scene.persona == nil ? "Add persona…" : "Persona…", systemImage: "person.crop.rectangle")
        }.fixedSize().disabled(model.storageBlocked)
            .accessibilityLabel(scene.persona == nil ? "Add persona to scene" : "Persona in this scene")
            .popover(isPresented: $adjustingPersona, arrowEdge: .bottom) {
                personaControls(scene).padding(18).frame(width: 310)
                    .onDisappear {
                        guard let sceneID = personaSelectionAfterPopover else { return }
                        personaSelectionAfterPopover = nil
                        model.showPersonas(for: sceneID)
                    }
            }
    }
    private func personaControls(_ scene: DemoScene) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Persona in this scene").font(.headline)
                Spacer()
                Button("Done") { adjustingPersona = false }.keyboardShortcut(.cancelAction)
            }
            Text("Part of this presentation window. Use Persona for a separate overlay over other apps.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Change persona…") {
                personaSelectionAfterPopover = scene.id
                adjustingPersona = false
            }.disabled(model.storageBlocked)
            if let persona = scene.persona {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.selected?.persona?.width ?? persona.width }, set: { width in
                    guard var value = model.selected, value.id == scene.id else { return }
                    value.persona?.width = width; model.update(value)
                }), in: 0.06...0.40).accessibilityLabel("Persona size in scene")
                HStack {
                    Menu("Position") {
                        Button("Bottom left") { movePersona(scene, x: 0.02, y: 0.02) }
                        Button("Bottom right") { movePersona(scene, x: 0.98, y: 0.02) }
                        Button("Top left") { movePersona(scene, x: 0.02, y: 0.98) }
                        Button("Top right") { movePersona(scene, x: 0.98, y: 0.98) }
                    }.fixedSize()
                    Spacer()
                    Button("Remove from scene") {
                        guard var value = model.selected, value.id == scene.id else { return }
                        value.persona = nil; model.update(value); adjustingPersona = false
                    }
                }
            }
        }
    }
    private func movePersona(_ scene: DemoScene, x: Double, y: Double) {
        guard var value = model.selected, value.id == scene.id else { return }
        value.persona?.x = x; value.persona?.y = y; model.update(value)
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
                Text(capture.live ? "While the phone is live, the frame follows its own proportions." : "The frame follows the phone’s proportions once it is live.")
                    .font(.caption).foregroundStyle(.secondary)
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
            Button("Find on the web…") { logoSceneID = model.selectedID; searchingLogo = true }
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
}

private struct SceneCanvas: NSViewRepresentable {
    let scene: DemoScene
    let image: NSImage
    let logoImage: NSImage?
    let handImage: NSImage?
    let personaImage: NSImage?
    let editable: Bool
    let editing: Bool
    let covered: Bool
    let capture: DemoCapture
    let live: Bool
    let dimensions: CGSize
    let loadAmbience: (DemoScene) -> AmbientSceneImages?
    let visibility: (Bool) -> Void
    let update: (DemoScene) -> DemoScene?
    func makeNSView(context: Context) -> SceneCanvasView { SceneCanvasView(previewLayer: capture.makePreviewLayer()) }
    func updateNSView(_ view: SceneCanvasView, context: Context) {
        view.onVisibility = visibility
        view.layoutEditing = editing; view.previewCovered = covered
        view.isLive = live; view.liveDimensions = dimensions
        view.receive(scene, loadAmbience: loadAmbience)
        view.image = image; view.logoImage = logoImage; view.handImage = handImage; view.personaImage = personaImage; view.update = update; view.editable = editable
        view.refreshPreview()
    }
    static func dismantleNSView(_ view: SceneCanvasView, coordinator: ()) { view.onVisibility?(false); view.onVisibility = nil }
}

/// The page's preview is the stage: the same still renderer and the same capture
/// session, so the phone shows here before Present is pressed. It reports whether
/// it can be seen, which is what lets the capture run.
final class SceneCanvasView: NSView {
    var scene: DemoScene?
    var image: NSImage? { didSet { refreshPreview() } }
    var logoImage: NSImage? { didSet { refreshPreview() } }
    var handImage: NSImage? { didSet { refreshPreview() } }
    var personaImage: NSImage? { didSet { refreshPreview() } }
    var update: ((DemoScene) -> DemoScene?)?
    var editable = true
    var layoutEditing = false
    var previewCovered = false
    var isLive = false { didSet { preview.isLive = isLive; refreshPreview() } }
    var liveDimensions = CGSize.zero { didSet { refreshPreview() } }
    /// Set after the view may already be in a window, so the current state is reported at once.
    var onVisibility: ((Bool) -> Void)? { didSet { reportedVisible = false; reportVisibility() } }
    private let preview: DemoStageSurfaceView
    private let handles = SceneCanvasHandles()
    private var ambience: AmbientSceneImages?
    private var occlusionObserver: NSObjectProtocol?
    private var reportedVisible = false
    private(set) var isDragging = false
    private var origin = CGPoint.zero
    private var initial: DemoScene?
    private var dragPreview: DemoScene?
    init(previewLayer: AVCaptureVideoPreviewLayer) {
        preview = DemoStageSurfaceView(previewLayer: previewLayer)
        super.init(frame: .zero)
        addSubview(preview); addSubview(handles)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func layout() {
        super.layout(); preview.frame = bounds; handles.frame = bounds
        preview.needsLayout = true; handles.needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver); self.occlusionObserver = nil }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.reportVisibility() }
        }
        reportVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); reportVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); reportVisibility() }
    private func reportVisibility() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor } ?? false
        guard visible != reportedVisible else { return }
        reportedVisible = visible
        onVisibility?(visible)
    }
    func receive(_ value: DemoScene, loadAmbience: ((DemoScene) -> AmbientSceneImages?)? = nil) {
        if scene?.id != value.id { initial = nil; dragPreview = nil; isDragging = false }
        if scene?.id != value.id || scene?.ambience != value.ambience || scene?.background != value.background {
            ambience = loadAmbience?(value)
        }
        scene = value
        refreshPreview()
    }
    /// The live phone keeps its own proportions, as the stage does.
    private func fitted(_ value: DemoScene) -> DemoScene {
        guard isLive, liveDimensions.height > 0 else { return value }
        var fitted = value
        var viewport = value.viewport ?? .legacy
        viewport.aspect = liveDimensions.width / liveDimensions.height
        fitted.viewport = (try? viewport.validated()) ?? viewport
        return fitted
    }
    func refreshPreview() {
        guard let value = dragPreview ?? scene, let image else { return }
        let shown = fitted(value)
        preview.configure(scene: shown, backdrop: image, logo: logoImage, hand: handImage, persona: personaImage, ambience: ambience)
        preview.viewportScene = shown; preview.needsLayout = true
        handles.scene = shown; handles.needsDisplay = true
    }
    private var movingPhone = false
    private var movingPersona = false
    private var resizingWidth = false
    private var resizingSize = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard editable else { return }
        origin = convert(event.locationInWindow, from: nil); initial = scene; isDragging = true; refreshPreview()
        movingPersona = false
        if let scene {
            if let persona = scene.persona, let personaImage {
                movingPersona = PersonaGeometry.rect(persona, imageSize: personaImage.size, in: bounds.size).contains(origin)
            }
            let rect = SceneRenderer.phoneRect(fitted(scene), in: bounds.size)
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
        dragPreview = try? draft.validated(); refreshPreview()
    }
    override func mouseUp(with event: NSEvent) {
        let pending = dragPreview; dragPreview = nil; initial = nil; isDragging = false
        // Commit once per drag. The captured revision rejects an intervening
        // remote edit, and large immutable pictures are not rehashed per pixel.
        if let pending, let saved = update?(pending) { scene = saved }
        refreshPreview()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            dragPreview = nil; initial = nil; isDragging = false
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver); self.occlusionObserver = nil }
            if reportedVisible { reportedVisible = false; onVisibility?(false) }
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

private final class SceneCanvasHandles: NSView {
    var scene: DemoScene?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let scene, scene.showsPhone else { return }
        let rect = SceneRenderer.phoneRect(scene, in: bounds.size)
        NSColor.controlAccentColor.setFill()
        for point in [CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.minY)] {
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
    }
}
