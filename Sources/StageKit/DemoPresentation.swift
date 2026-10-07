import AppKit
import Combine
import SwiftUI
import AVFoundation

final class DemoPresentation: NSObject, NSWindowDelegate {
    let sessionIdentity = UUID()
    var onEnd: (() -> Void)?
    var onRevealSharedControls: (() -> Void)?
    /// Hands the shared capture back to its owner at the end. The owner lets go of the
    /// device either way (End is final; a handoff keeps it free for the Apple app) and
    /// the completion runs once the device is released.
    var releaseCapture: ((_ forHandoff: Bool, _ completion: @escaping () -> Void) -> Void)?
    /// Reconnect and Show go through the capture's owner, which may have released it.
    var reconnect: (() -> Void)?
    var showSource: ((String) -> Void)?
    private let sharedControls: Bool
    private var window: DemoStageWindow?
    private let capture: DemoCapture
    private let phoneLink: PhoneLinkMonitor
    private let controls: PresentationControlsModel
    private let scene: DemoScene
    private let backdrop: NSImage
    private let logo: NSImage?
    private let hand: NSImage?
    private let persona: NSImage?
    private let ambience: AmbientSceneImages?
    private let screen: NSScreen?
    private let mode: PresentationMode
    private var lifecycle = PresentationLifecycle()
    private let handoff = PresentationHandoff()
    private var keepAwake: NSObjectProtocol?
    /// False only under a check's synthetic capture: the stage window is built and ended as
    /// usual but never ordered on screen, so the check neither shows a window nor activates the app.
    private let onScreen: Bool
    init(scene: DemoScene, image: NSImage, logo: NSImage?, hand: NSImage?, persona: NSImage? = nil, ambience: AmbientSceneImages? = nil, screen: NSScreen?, root: URL, capture: DemoCapture, phoneLink: PhoneLinkMonitor, mode: PresentationMode = .windowed, sharedControls: Bool = false, onScreen: Bool = true) {
        self.scene = scene; backdrop = image; self.logo = logo; self.hand = hand; self.persona = persona; self.screen = screen
        self.mode = mode; self.ambience = ambience; self.sharedControls = sharedControls; self.phoneLink = phoneLink; self.onScreen = onScreen
        self.capture = capture
        controls = PresentationControlsModel(root: root)
        super.init()
    }
    var showsPhone: Bool { scene.showsPhone }
    func start() {
        keepAwake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Presenting a Workbench demo")
        let visible = screen?.visibleFrame ?? CGRect(x: 80, y: 80, width: 1100, height: 720)
        let frame = mode == .fullScreen ? visible : FloatingControlGeometry.frame(anchor: .top,
            size: CGSize(width: min(1100, visible.width - 64), height: min(720, visible.height - 64)),
            visibleFrame: visible, inset: 32)
        let window = DemoStageWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = scene.name + " · Present"
        window.titleVisibility = mode == .fullScreen ? .hidden : .visible; window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 480, height: 320)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false; window.delegate = self
        window.onEscape = { [weak self] in
            guard let self else { return }
            if !self.controls.handleEscape() { self.end() }
        }
        window.onReconnect = { [weak self] in self?.reconnectCapture() }
        window.onRevealControls = { [weak self] in
            guard let self else { return }
            if self.sharedControls { self.onRevealSharedControls?() } else { self.controls.revealForKeyboard() }
        }
        window.contentView = NSHostingView(rootView: DemoStageContent(scene: scene, backdrop: backdrop, logo: logo, hand: hand, persona: persona, ambience: ambience, capture: capture, phoneLink: phoneLink, controls: controls, sharedControls: sharedControls,
            perform: { [weak self] in self?.perform($0) }, endAndOpen: { [weak self] in self?.endAndOpen($0) }, end: { [weak self] in self?.end() }))
        self.window = window
        guard onScreen else { return }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        if mode == .fullScreen { lifecycle.willEnter(); window.toggleFullScreen(nil) }
    }
    /// The one next step the status names, wherever it is shown. Once End is under way the
    /// stage takes no step, so a late click or ⌘R cannot take the phone back from End.
    func perform(_ step: PhoneLinkStatus.Step) {
        guard !lifecycle.ending, !lifecycle.finished else { return }
        switch step {
        case .showSource(let id, _): if let showSource { showSource(id) } else { capture.select(id) }
        case .chooseSource: controls.close(); controls.choosingSource = true; bringForward()
        case .reconnect: reconnectCapture()
        case .openCameraSettings: NSWorkspace.shared.open(PhoneConnectionSupport.cameraSettingsURL)
        }
    }
    func reconnectCapture() {
        guard !lifecycle.ending, !lifecycle.finished else { return }
        if let reconnect { reconnect() } else { capture.reconnect() }
    }
    var status: PhoneLinkStatus { MainActor.assumeIsolated { phoneLink.status } }
    func makeControlsMenu() -> NSMenu {
        let menu = NSMenu(title: "Present"); menu.autoenablesItems = false
        if scene.showsPhone {
            let status = self.status
            menu.addItem(StageMenuAction(status.title, enabled: false) {})
            if let step = status.step { menu.addItem(StageMenuAction(step.title) { [weak self] in self?.perform(step) }) }
            if capture.sources.count > 1 { menu.addSubmenu("Choose screen", items: capture.sources.map { source in
                StageMenuAction(source.name, checked: source.id == capture.selectedID) { [weak self] in self?.perform(.showSource(id: source.id, title: source.name)) }
            }) }
            if status.offersReconnect {
                menu.addItem(StageMenuAction("Reconnect") { [weak self] in self?.reconnectCapture() })
            }
            menu.addItem(StageMenuAction("Match Device Proportions", checked: controls.fitToSource) { [weak self] in self?.controls.fitToSource.toggle() })
            if status.offersHelp {
                menu.addItem(StageMenuAction("Can’t See Your Phone?…") { [weak self] in self?.showHelp() })
            }
        }
        menu.addItem(StageMenuAction("Show Presentation Window") { [weak self] in self?.bringForward() })
        let fullScreen = window?.styleMask.contains(.fullScreen) == true
        menu.addItem(StageMenuAction("Full Screen", checked: fullScreen) { [weak self] in self?.window?.toggleFullScreen(nil) })
        // Size and position only apply to a window; in full screen they would be submenus of disabled items.
        if !fullScreen {
            menu.addSubmenu("Window Size", items: [("Compact", CGFloat(640)), ("Medium", CGFloat(900)), ("Large", CGFloat(1100))].map { title, width in
                StageMenuAction(title, enabled: window?.styleMask.contains(.fullScreen) != true) { [weak self] in
                    guard let window = self?.window, !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
                    let frame = FloatingControlGeometry.clamp(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: width * 0.66)), to: screen.visibleFrame)
                    window.setFrame(frame, display: true)
                }
            })
            menu.addSubmenu("Window Position", items: FloatingControlAnchor.allCases.map { anchor in
                StageMenuAction(anchor.title, enabled: window?.styleMask.contains(.fullScreen) != true) { [weak self] in
                    guard let window = self?.window, !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
                    window.setFrame(FloatingControlGeometry.frame(anchor: anchor, size: window.frame.size, visibleFrame: screen.visibleFrame), display: true)
                }
            })
        }
        menu.addItem(.separator())
        menu.addItem(StageMenuAction("End Presentation") { [weak self] in self?.end() })
        return menu
    }
    /// The pill's View control contains only this live window and source. Ending is
    /// already a direct action.
    func makeViewMenu() -> NSMenu {
        let menu = makeControlsMenu()
        // Like the panel, the pill's menu holds only actions: the status line is not one.
        for item in menu.items where item.title == "End Presentation"
            || !item.isEnabled && !item.isSeparatorItem && item.submenu == nil {
            menu.removeItem(item)
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        return menu
    }
    /// The device this presentation's capture holds; another camera owner reports
    /// a conflict instead of taking it.
    var heldDeviceID: String? { capture.heldDeviceID }
    var liveSettingsView: some View { LiveSettings(presentation: self, capture: capture, phoneLink: phoneLink, controls: controls) }
    private struct LiveSettings: View {
        let presentation: DemoPresentation
        @ObservedObject var capture: DemoCapture
        @ObservedObject var phoneLink: PhoneLinkMonitor
        @ObservedObject var controls: PresentationControlsModel
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Live presentation · " + presentation.scene.name).font(.headline)
                Text("Adjust the running presentation here. Your saved scene stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Show presentation window") { presentation.bringForward() }
                    Button("End presentation") { presentation.end() }
                }
                Toggle("Full screen", isOn: Binding(get: { controls.fullScreen }, set: { value in
                    guard presentation.window?.styleMask.contains(.fullScreen) != value else { return }
                    presentation.window?.toggleFullScreen(nil)
                }))
                HStack { submenu("Window Size"); submenu("Window Position") }.disabled(controls.fullScreen)
                if presentation.scene.showsPhone {
                    PhoneLinkStatusRow(status: phoneLink.status, perform: { presentation.perform($0) }, help: { presentation.showHelp() },
                                       reconnect: { presentation.reconnectCapture() })
                    if capture.sources.count > 1 { submenu("Choose screen") }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Workbench.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        private func submenu(_ title: String) -> some View {
            StageLiveMenu(title: title) {
                let parent = presentation.makeControlsMenu()
                guard let item = parent.items.first(where: { $0.title == title }), let menu = item.submenu else { return NSMenu() }
                item.submenu = nil
                return menu
            }.fixedSize().frame(height: 24)
        }
    }
    func bringForward() { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    func showHelp() { controls.close(); controls.choosingSource = false; controls.showingHelp = true; bringForward() }
    func end() {
        guard !lifecycle.ending, !lifecycle.finished else { return }
        let operation = handoff
        let forHandoff = handoff.requested
        if let releaseCapture { releaseCapture(forHandoff) { operation.captureDidStop() } }
        else { capture.stop { operation.captureDidStop() } }
        releaseKeepAwake()
        apply(lifecycle.requestEnd())
    }
    func endAndOpen(_ app: NativePresentationApp) {
        guard !lifecycle.ending, !lifecycle.finished else { return }
        guard handoff.request({
            app.open { message in
                // The sheet and its parent are now closed, so a message on
                // that former capture model would be invisible.
                let alert = NSAlert()
                alert.messageText = "Could not open \(app.title)"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }) else { return }
        end()
    }
    private func apply(_ effect: PresentationLifecycle.Effect) {
        switch effect {
        case .none: break
        case .exitFullScreen:
            guard let window else { finish(); return }
            lifecycle.willExit(); window.toggleFullScreen(nil)
        case .finish: finish()
        }
    }
    private func finish() {
        guard !lifecycle.finished else { return }
        lifecycle.complete()
        controls.stop()
        releaseKeepAwake()
        window?.delegate = nil; window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil
        let operation = handoff
        let callback = onEnd; onEnd = nil; callback?()
        operation.presentationDidClose()
    }
    private func releaseKeepAwake() {
        if let keepAwake { ProcessInfo.processInfo.endActivity(keepAwake); self.keepAwake = nil }
    }
    deinit { if let keepAwake { ProcessInfo.processInfo.endActivity(keepAwake) } }
    func windowWillEnterFullScreen(_ notification: Notification) {
        lifecycle.willEnter(); window?.titleVisibility = .hidden
    }
    func windowWillExitFullScreen(_ notification: Notification) { lifecycle.willExit() }
    func windowDidEnterFullScreen(_ notification: Notification) { controls.fullScreen = true; apply(lifecycle.didEnter()) }
    func windowDidExitFullScreen(_ notification: Notification) {
        controls.fullScreen = false
        window?.titleVisibility = .visible
        apply(lifecycle.didExit())
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        window.titleVisibility = .visible
        apply(lifecycle.failedToEnter())
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { apply(lifecycle.failedToExit()) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { end(); return false }

    /// The stage's content for an offscreen render: the same view the window hosts,
    /// with its own controls and no window, capture session or app launch.
    static func offscreenStage(scene: DemoScene, image: NSImage, capture: DemoCapture, phoneLink: PhoneLinkMonitor, root: URL) -> AnyView {
        AnyView(DemoStageContent(scene: scene, backdrop: image, logo: nil, hand: nil, persona: nil, ambience: nil, capture: capture, phoneLink: phoneLink,
                                 controls: PresentationControlsModel(root: root), sharedControls: false, perform: { _ in }, endAndOpen: { _ in }, end: {}))
    }
}

/// The status, its one next step and Reconnect, as the Present page's live
/// settings and the stage controls show them.
struct PhoneLinkStatusRow: View {
    let status: PhoneLinkStatus
    let perform: (PhoneLinkStatus.Step) -> Void
    let help: () -> Void
    let reconnect: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.symbol).foregroundStyle(status.isLive ? Workbench.accent : .secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title).font(.callout.weight(.semibold))
                    if let detail = status.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }.fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let step = status.step { Button(step.title) { perform(step) } }
                if status.offersReconnect { Button("Reconnect", action: reconnect).help("Reconnect device · ⌘R in the presentation") }
                if status.offersHelp { Button("Can’t see your phone?", action: help).buttonStyle(.workbenchLink) }
            }.controlSize(.small)
        }
    }
}

private final class DemoStageWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onRevealControls: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if let attachedSheet { attachedSheet.cancelOperation(sender) } else { onEscape?() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard attachedSheet == nil else { return super.performKeyEquivalent(with: event) }
        if PresentationControlsPolicy.isFullScreenCommand(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) {
            toggleFullScreen(nil); return true
        }
        if PresentationControlsPolicy.isRevealCommand(characters: event.charactersIgnoringModifiers,
            command: event.modifierFlags.contains(.command), option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control)) {
            onRevealControls?(); return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "r" {
            onReconnect?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// AppKit owns Command-/ and Escape; the model owns only this presentation's
/// controls and placement. Capture and scene state never depend on expansion.
private final class PresentationControlsModel: ObservableObject {
    @Published var fullScreen = false
    @Published private(set) var policy = PresentationControlsPolicy()
    @Published var fitToSource = true
    @Published var choosingSource = false
    @Published var showingHelp = false
    /// Set while the source sheet closes so the help opens after it, not in the same update.
    var helpAfterSource = false
    @Published private(set) var focusRequest = 0
    @Published private(set) var placement = PresentationControlPlacement()
    @Published private(set) var dragFrame: CGRect?
    @Published private(set) var snapAnchor: FloatingControlAnchor?
    @Published private(set) var placementNotice: String?
    private let url: URL
    private var archiveData: Data?
    private var storageBlocked = false
    private var dragStart: CGRect?
    private var suppressClickUntil: TimeInterval = 0
    var controlSize: CGSize { policy.isExpanded ? CGSize(width: 304, height: 192) : CGSize(width: 76, height: 40) }

    init(root: URL) {
        url = root.appendingPathComponent("presentation-controls.json")
        do {
            archiveData = try PersonaStorage.read(url)
            if let archiveData { placement = try JSONDecoder().decode(PresentationControlPlacement.self, from: archiveData).validated() }
        } catch {
            storageBlocked = true
            placementNotice = "The previous control position could not be read. Its file is unchanged; new positions apply to this presentation only."
        }
    }
    func start() { policy.close() }
    func stop() { dragStart = nil; dragFrame = nil; snapAnchor = nil }
    func close() { stop(); policy.close(); focusRequest += 1 }
    func toggleFromTile() {
        guard ProcessInfo.processInfo.systemUptime >= suppressClickUntil, dragFrame == nil else { return }
        policy.toggle()
    }
    func revealForKeyboard() { stop(); policy.open(); focusRequest += 1 }
    func handleEscape() -> Bool {
        if policy.handleEscape() { stop(); focusRequest += 1; return true }
        return false
    }
    func frame(in size: CGSize) -> CGRect {
        let visible = CGRect(origin: .zero, size: size)
        return dragFrame.map { FloatingControlGeometry.clamp($0, to: visible) }
            ?? placement.frame(size: controlSize, in: visible)
    }
    func setAnchor(_ anchor: FloatingControlAnchor) {
        stop(); placement.anchor = anchor; save()
    }
    func drag(translation: CGSize, in size: CGSize) {
        let visible = CGRect(origin: .zero, size: size)
        if dragStart == nil { dragStart = frame(in: size) }
        guard let start = dragStart else { return }
        let proposed = start.offsetBy(dx: translation.width, dy: -translation.height)
        let bounded = FloatingControlGeometry.clamp(proposed, to: visible)
        dragFrame = bounded
        snapAnchor = FloatingControlGeometry.nearestAnchor(to: bounded, in: visible)
    }
    func finishDrag(in size: CGSize) {
        guard let dragFrame else { return }
        let visible = CGRect(origin: .zero, size: size)
        let frame = snapAnchor.map { FloatingControlGeometry.frame(anchor: $0, size: controlSize, visibleFrame: visible) } ?? dragFrame
        placement.move(to: frame, in: visible, anchor: snapAnchor)
        suppressClickUntil = ProcessInfo.processInfo.systemUptime + 0.25
        stop(); save()
    }
    private func save() {
        guard !storageBlocked else { return }
        do { archiveData = try PersonaStorage.write(try placement.validated(), to: url, expected: archiveData) }
        catch {
            storageBlocked = true
            placementNotice = "The control position could not be saved. Its previous file is unchanged."
        }
    }
}

private struct DemoStageContent: View {
    private enum Control: Hashable { case tile, step, reconnect, source, position, close, end, deviceStep, deviceHelp }
    let scene: DemoScene
    let backdrop: NSImage
    let logo: NSImage?
    let hand: NSImage?
    let persona: NSImage?
    let ambience: AmbientSceneImages?
    @ObservedObject var capture: DemoCapture
    @ObservedObject var phoneLink: PhoneLinkMonitor
    @ObservedObject var controls: PresentationControlsModel
    let sharedControls: Bool
    let perform: (PhoneLinkStatus.Step) -> Void
    let endAndOpen: (NativePresentationApp) -> Void
    let end: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var pendingNativeApp: NativePresentationApp?
    @FocusState private var focusedControl: Control?
    /// The phone has been on this stage. After that the device frame never carries words:
    /// a stall keeps the last frame and a disconnect leaves the clean scene, while the
    /// controls, the menu, the page and the toolbar say what happened.
    @State private var phoneHasShown = false
    /// The stage is shared in a call, so its words name devices by kind, never by the
    /// person's own device name.
    private var status: PhoneLinkStatus { phoneLink.sharedStatus }
    private var sourceNames: [String: String] {
        Dictionary(phoneLink.signals.anonymised.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
    private var liveScene: DemoScene {
        var value = scene
        if controls.fitToSource, capture.dimensions.height > 0 {
            var viewport = scene.viewport ?? .legacy
            viewport.aspect = capture.dimensions.width / capture.dimensions.height
            value.viewport = (try? viewport.validated()) ?? viewport
        }
        return value
    }
    private var sourceName: String {
        guard scene.showsPhone else { return "Saved scene" }
        return capture.selectedID.flatMap { sourceNames[$0] } ?? "Phone"
    }
    private var inwardChevron: String {
        switch controls.placement.anchor {
        case .top, .topLeft, .topRight: return "chevron.down"
        case .bottom, .bottomLeft, .bottomRight: return "chevron.up"
        case .left: return "chevron.right"
        case .right: return "chevron.left"
        case nil: return controls.placement.x > 0.5 ? "chevron.left" : "chevron.right"
        }
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DemoStageSurface(scene: liveScene, image: backdrop, logo: logo, hand: hand, persona: persona, ambience: ambience, capture: capture, live: capture.live)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { if controls.policy.isExpanded { controls.close() } }
                if scene.showsPhone && !capture.live && !phoneHasShown {
                    // The device frame says what is true and the one next step, where the phone will appear.
                    let viewport = ViewportGeometry(scene: liveScene, size: geometry.size).screen
                    VStack(spacing: 12) {
                        Image(systemName: status.symbol).font(.largeTitle)
                        Text(status.title).font(.headline).multilineTextAlignment(.center)
                        if let detail = status.detail { Text(detail).font(.callout).multilineTextAlignment(.center).opacity(0.85) }
                        if let step = status.step {
                            Button(step.title) { perform(step) }.focused($focusedControl, equals: .deviceStep)
                                .buttonStyle(.borderedProminent)
                        }
                        if status.offersHelp {
                            Button("Can’t see your phone?") { openHelp() }.focused($focusedControl, equals: .deviceHelp).buttonStyle(.workbenchLink)
                        }
                    }.padding(20).frame(width: max(120, viewport.width - 20))
                        .foregroundStyle(.white)
                        .position(x: viewport.midX, y: geometry.size.height - viewport.midY)
                        .accessibilityElement(children: .contain).accessibilityLabel("Phone status")
                }
                if !sharedControls {
                if let dragFrame = controls.dragFrame {
                    FloatingControlGuides(controlFrame: dragFrame,
                        visibleFrame: CGRect(origin: .zero, size: geometry.size), activeAnchor: controls.snapAnchor)
                }
                let frame = controls.frame(in: geometry.size)
                Group {
                    if controls.policy.isExpanded { expandedControls(in: geometry.size) }
                    else { tile(in: geometry.size) }
                }
                .frame(width: frame.width, height: frame.height)
                .background {
                    if reduceTransparency {
                        RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor))
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(.thickMaterial)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.16)))
                .position(x: frame.midX, y: geometry.size.height - frame.midY)
                .animation(reduceMotion || controls.dragFrame != nil ? nil : .easeOut(duration: 0.16), value: controls.policy.isExpanded)
                }
            }.background(.black).coordinateSpace(name: "presentation-controls")
                .onAppear { controls.start(); if capture.live { phoneHasShown = true } }
                .onChange(of: capture.live) { _, live in if live { phoneHasShown = true } }
                .onDisappear { controls.stop() }
                .onChange(of: geometry.size) { _, _ in controls.stop() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                    controls.stop()
                }
                .onChange(of: controls.focusRequest) { _, _ in
                    focusedControl = controls.policy.isExpanded
                        ? (scene.showsPhone ? (status.step != nil ? .step : status.offersReconnect ? .reconnect : .position) : .close) : .tile
                }
                .sheet(isPresented: $controls.choosingSource, onDismiss: {
                    guard controls.helpAfterSource else { return }
                    controls.helpAfterSource = false
                    controls.showingHelp = true
                }) { sourceSheet }
                .sheet(isPresented: $controls.showingHelp, onDismiss: {
                    guard let app = pendingNativeApp else { return }
                    pendingNativeApp = nil
                    endAndOpen(app)
                }) {
                    PhoneConnectionHelp(status: status, diagnostic: { phoneLink.diagnostic(build: Workbench.buildLabel) }, endsPresentation: true) { app in
                        guard pendingNativeApp == nil else { return }
                        pendingNativeApp = app
                        controls.showingHelp = false
                    }
                }
        }.ignoresSafeArea()
    }
    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("presentation-controls"))
            .onChanged { controls.drag(translation: $0.translation, in: size) }
            .onEnded { _ in controls.finishDrag(in: size) }
    }
    private func tile(in size: CGSize) -> some View {
        Button { controls.toggleFromTile() } label: {
            HStack(spacing: 0) {
                Image(systemName: scene.showsPhone ? "iphone" : "photo").font(.system(size: 17, weight: .medium))
                    .frame(width: 42, height: 40)
                Divider().frame(height: 18)
                Image(systemName: inwardChevron).font(.system(size: 11, weight: .semibold))
                    .frame(width: 33, height: 40)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focusedControl, equals: .tile)
            .simultaneousGesture(dragGesture(in: size))
            .accessibilityLabel("Open presentation controls")
            .accessibilityHint("Command Slash also opens controls. Use the Position menu to move them.")
            .help("Click or ⌘/ for controls. Drag to move. Visible when sharing this screen.")
    }
    private func expandedControls(in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: scene.showsPhone ? status.symbol : "photo")
                    Text(scene.showsPhone ? status.title : "Saved scene").font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle()).gesture(dragGesture(in: size))
                    .help("Drag to move, or choose Position")
                Button { controls.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).frame(width: 24, height: 24).focused($focusedControl, equals: .close)
                    .accessibilityLabel("Close presentation controls").help("Close controls · Esc")
            }
            Text(scene.showsPhone ? (status.detail ?? sourceName) : "Showing your saved scene.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 30, alignment: .topLeading)
            HStack {
                if scene.showsPhone {
                    if let step = status.step {
                        Button(step.title) { perform(step) }.focused($focusedControl, equals: .step)
                    }
                    if status.offersReconnect {
                        Button("Reconnect") { perform(.reconnect) }
                            .focused($focusedControl, equals: .reconnect).help("Reconnect device · ⌘R")
                    }
                    if capture.sources.count > 1, status.step != .chooseSource {
                        Button("Choose screen…") { perform(.chooseSource) }.focused($focusedControl, equals: .source)
                    }
                }
                Spacer()
            }.frame(height: 28)
            Divider()
            HStack {
                Menu("Position") {
                    ForEach(FloatingControlAnchor.allCases) { anchor in
                        Button { controls.setAnchor(anchor) } label: {
                            if controls.placement.anchor == anchor { Label(anchor.title, systemImage: "checkmark") }
                            else { Text(anchor.title) }
                        }
                    }
                }.fixedSize().focused($focusedControl, equals: .position)
                if let notice = controls.placementNotice {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).help(notice).accessibilityLabel(notice)
                }
                Spacer()
                Button("End", action: end).focused($focusedControl, equals: .end)
                    .accessibilityLabel("End presentation").help("End presentation. Escape ends it when controls are closed.")
            }.frame(height: 28)
        }.padding(12)
            .accessibilityElement(children: .contain).accessibilityLabel("Presentation controls")
    }
    private func openHelp() {
        controls.close()
        controls.showingHelp = true
    }
    /// Which screen to show, only when the Mac offers more than one or the
    /// remembered one is away. Choosing is explicit and remembered.
    private var sourceSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Which screen?").font(.title2.bold())
                Spacer()
                Button("Done") { controls.choosingSource = false }.keyboardShortcut(.defaultAction)
            }
            Text(status.title).font(.headline)
            if let detail = status.detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if capture.sources.isEmpty {
                Text("No screen sources yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(capture.sources) { source in
                            let name = sourceNames[source.id] ?? (source.isScreen ? "Phone" : "Video device")
                            Button {
                                perform(.showSource(id: source.id, title: name)); controls.choosingSource = false
                            } label: {
                                HStack { Image(systemName: source.isScreen ? "iphone" : "video"); Text(name); Spacer(); if capture.selectedID == source.id { Image(systemName: "checkmark") } }
                            }.buttonStyle(.bordered)
                        }
                    }
                }.frame(height: min(CGFloat(capture.sources.count) * 36, 160))
            }
            Toggle("Match device proportions", isOn: $controls.fitToSource).toggleStyle(.checkbox)
            if capture.dimensions.width > 0 && capture.dimensions.height > 0 {
                Text("Video size: \(Int(capture.dimensions.width)) × \(Int(capture.dimensions.height))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Can’t see your phone?") { controls.helpAfterSource = true; controls.choosingSource = false }.buttonStyle(.workbenchLink)
                Spacer()
                Button("Look again") { capture.refresh() }
            }
        }.padding(24).frame(width: 460).onExitCommand { controls.choosingSource = false }
    }
}

private struct DemoStageSurface: NSViewRepresentable {
    let scene: DemoScene
    let image: NSImage
    let logo: NSImage?
    let hand: NSImage?
    let persona: NSImage?
    let ambience: AmbientSceneImages?
    let capture: DemoCapture
    let live: Bool
    func makeNSView(context: Context) -> DemoStageSurfaceView { DemoStageSurfaceView(previewLayer: capture.makePreviewLayer(for: .stage)) }
    func updateNSView(_ view: DemoStageSurfaceView, context: Context) {
        view.configure(scene: scene, backdrop: image, logo: logo, hand: hand, persona: persona, ambience: ambience)
        view.viewportScene = scene; view.isLive = live
        view.needsLayout = true
    }
}

/// Device video remains between its stationary frame and foreground branding.
/// The backdrop is a still: motion is never requested on the stage.
final class DemoStageSurfaceView: MovingSceneView {
    var viewportScene: DemoScene?
    private let videoLayer: AVCaptureVideoPreviewLayer
    var isLive = false { didSet { videoLayer.isHidden = !isLive || viewportScene?.showsPhone != true } }
    init(previewLayer: AVCaptureVideoPreviewLayer) {
        videoLayer = previewLayer
        super.init(frame: .zero)
        videoLayer.backgroundColor = NSColor.black.cgColor
        insertVideoLayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        guard let scene = viewportScene else { return }
        let geometry = ViewportGeometry(scene: scene, size: bounds.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = geometry.screen; videoLayer.cornerRadius = geometry.innerRadius
        videoLayer.isHidden = !scene.showsPhone || !isLive
        CATransaction.commit()
    }
}
