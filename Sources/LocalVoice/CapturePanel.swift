import AppKit
import AVFoundation
import Combine
import StageKit
import SwiftUI

/// Mouse controls preserve the original application's focus and paste target.
final class CapturePanel: NSPanel {
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

final class CaptureHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class CaptureHUDControls: ObservableObject {
    @Published private(set) var toolbarDisclosure: FloatingToolbarDisclosure
    @Published var toolbarSize: NSSize
    private(set) var toolbarInteraction: FloatingToolbarInteraction
    private let defaults: UserDefaults
    private var collapseTask: Task<Void, Never>?
    private weak var trackingMenu: NSMenu?
    var pointerInside: (() -> Bool)?
    var pointerInsideCollapsed: (() -> Bool)?
    var didCollapse: (() -> Void)?
    var releaseKeyboardFocus: (() -> Void)?
    var focusFirstControl: (() -> Void)?
    private static let pinnedKey = "floatingToolbarExpanded.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interaction = FloatingToolbarInteraction(pinned: defaults.bool(forKey: Self.pinnedKey))
        toolbarInteraction = interaction; toolbarDisclosure = interaction.disclosure
        toolbarSize = interaction.disclosure.size
    }
    func hover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside { toolbarInteraction.enter(); refreshToolbar() }
        else { toolbarInteraction.leave(); scheduleCollapse() }
    }
    func expandToolbar() {
        collapseTask?.cancel(); toolbarInteraction.pinned = true
        toolbarInteraction.suppressHoverUntilExit = false
        defaults.set(true, forKey: Self.pinnedKey); refreshToolbar()
    }
    func collapseToolbar() {
        collapseTask?.cancel()
        let insideCollapsed = pointerInsideCollapsed?() ?? pointerInside?() ?? toolbarInteraction.hovered
        trackingMenu?.cancelTracking(); trackingMenu = nil
        toolbarInteraction.menuOpen = false
        toolbarInteraction.collapse()
        toolbarInteraction.hovered = false
        toolbarInteraction.suppressHoverUntilExit = insideCollapsed
        didCollapse?()
        defaults.set(false, forKey: Self.pinnedKey)
        releaseKeyboardFocus?(); refreshToolbar()
    }
    func focusToolbar() {
        collapseTask?.cancel(); toolbarInteraction.keyboardFocused = true; refreshToolbar()
    }
    func unfocusToolbar() {
        toolbarInteraction.keyboardFocused = false
        if toolbarInteraction.canCollapse { scheduleCollapse() } else { refreshToolbar() }
    }
    func beginMenu(_ menu: NSMenu) {
        collapseTask?.cancel(); trackingMenu = menu; toolbarInteraction.menuOpen = true
    }
    func endMenu() {
        trackingMenu = nil; toolbarInteraction.menuOpen = false
        hover(pointerInside?() ?? false)
    }
    func setDragging(_ value: Bool) {
        collapseTask?.cancel(); toolbarInteraction.dragging = value
        if !value { hover(pointerInside?() ?? false) }
    }
    func suspendToolbar() {
        collapseTask?.cancel(); trackingMenu?.cancelTracking()
        toolbarInteraction.suspend(); refreshToolbar()
    }
    private func refreshToolbar() {
        let next = toolbarInteraction.disclosure
        guard next != toolbarDisclosure else { return }
        let animation: Animation? = resize != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.16) : nil
        withAnimation(animation) { toolbarDisclosure = next }
        if let resize { resize() } else { toolbarSize = next.size }
    }
    private func scheduleCollapse() {
        guard toolbarInteraction.canCollapse else { return }
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self, self.toolbarInteraction.canCollapse else { return }
            if self.pointerInside?() == true { self.toolbarInteraction.enter() }
            self.refreshToolbar()
        }
    }
    @Published var isExpanded = false {
        didSet { if oldValue != isExpanded { resize?() } }
    }
    @Published var anchor: FloatingControlAnchor? = .bottom
    var resize: (() -> Void)?
    var choosePosition: ((FloatingControlAnchor) -> Void)?
}

@MainActor
final class CapturePanelController: NSWindowController, NSWindowDelegate, FloatingHUDDragController {
    private let positionKey = "capturePanelOrigin.v1"
    private let anchorKey = "capturePanelAnchor.v2"
    private let sizeKey = "capturePanelSize.v1"
    private let controls: CaptureHUDControls
    private weak var model: AppModel?
    private weak var readback: ReadbackModel?
    private weak var stage: StageKitController?
    private var positioning = false
    private var dragging = false
    private let snapGuide = FloatingControlGuideController()
    private var observations = Set<AnyCancellable>()
    private var surface: FloatingToolbarSurface = .hidden
    private var keyboardTarget: TextDelivery.Target?
    private var pointerTracker = FloatingToolbarPointerTracker(lastPoint: NSEvent.mouseLocation)
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var animationTask: Task<Void, Never>?
    private var animationTarget: NSRect?
    private var animationGeneration = UUID()
    var isAnimatingToolbar: Bool { animationTarget != nil }

    init(model: AppModel, readback: ReadbackModel, stage: StageKitController,
         dictate: @escaping () -> Void, snap: @escaping () -> Void,
         draw: @escaping () -> Void, present: @escaping () -> Void,
         controls suppliedControls: CaptureHUDControls? = nil, monitorsPointer: Bool = true) {
        let controls = suppliedControls ?? CaptureHUDControls()
        self.controls = controls
        let panel = CapturePanel(contentRect: NSRect(origin: .zero, size: CaptureHUDLayout.message),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        self.model = model
        self.readback = readback; self.stage = stage
        let savedAnchor = UserDefaults.standard.string(forKey: anchorKey).flatMap(FloatingControlAnchor.init(rawValue:))
        controls.anchor = savedAnchor ?? (UserDefaults.standard.string(forKey: positionKey) == nil ? .bottom : nil)
        controls.resize = { [weak self, weak model] in if let model { self?.update(model: model) } }
        controls.choosePosition = { [weak self] in self?.choosePosition($0) }
        controls.pointerInside = { [weak self] in self?.pointerFrame?.contains(NSEvent.mouseLocation) == true }
        controls.pointerInsideCollapsed = { [weak self] in
            guard let self, let preferred = self.preferredScreen else { return false }
            return CaptureHUDGeometry.frame(size: FloatingToolbarDisclosure.collapsed.size,
                anchor: self.controls.anchor, previous: self.window?.frame,
                screens: NSScreen.screens.map(\.visibleFrame), preferred: preferred).contains(NSEvent.mouseLocation)
        }
        controls.didCollapse = { [weak self] in self?.pointerTracker.lastPoint = NSEvent.mouseLocation }
        controls.releaseKeyboardFocus = { [weak self] in self?.releaseKeyboardFocus() }
        panel.title = "Workbench floating toolbar"
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = CaptureHostingView(rootView: WorkbenchFloatingContent(model: model, readback: readback,
            stage: stage, controls: controls, dictate: dictate, snap: snap, draw: draw, present: present))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.delegate = self
        panel.acceptsMouseMovedEvents = true
        let pointerEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if monitorsPointer {
            localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
                self?.pointerMoved(); return event
            }
            globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] _ in
                self?.pointerMoved()
            }
        }
        // Published emits before assignment; read committed state on the next loop.
        model.clipboardReceipt.$isHUDVisible.combineLatest(model.clipboardReceipt.$receipt)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in if let model { self?.update(model: model) } }
            .store(in: &observations)
        model.$floatingToolbarVisible.receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in if let model { self?.update(model: model) } }
            .store(in: &observations)
        stage.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in if let model { self?.update(model: model) } }
            .store(in: &observations)
        model.$phase.combineLatest(model.$captureFailure, model.$previewingPanel)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in if let model { self?.update(model: model) } }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cancelDragging(); self?.position() }
            .store(in: &observations)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(model: AppModel) {
        guard let window else { return }
        let previousSurface = self.surface
        let surface = FloatingToolbarSurface.resolve(enabled: model.floatingToolbarVisible,
            capturingScreen: readback?.isCapturing == true || stage?.isTakingScreenshot == true,
            dictation: Self.showsDictation(model), narration: readback?.isRecording == true)
        if surface != self.surface {
            cancelAnimation()
            self.surface = surface
            controls.suspendToolbar()
            releaseKeyboardFocus()
        }
        guard surface != .hidden else {
            window.orderOut(nil); cancelDragging()
            controls.isExpanded = false
            return
        }
        let size = surface == .tools ? controls.toolbarDisclosure.size : CaptureHUDLayout.size(
            recording: surface == .narration || model.phase == .recording,
            preview: model.previewingPanel, expanded: controls.isExpanded)
        if !window.isVisible { place(size: size, restoreSaved: true) }
        else if (animationTarget?.size ?? window.frame.size) != size {
            place(size: size, restoreSaved: false, animated: surface == .tools && previousSurface == .tools && !dragging)
        }
        window.orderFrontRegardless()
    }

    func pointerMoved(to point: NSPoint = NSEvent.mouseLocation) {
        guard pointerTracker.moved(to: point), surface == .tools, window?.isVisible == true,
              let pointerFrame else { return }
        let inside = pointerFrame.contains(point)
        if inside != controls.toolbarInteraction.hovered || (!inside && controls.toolbarInteraction.suppressHoverUntilExit) {
            controls.hover(inside)
        }
    }

    private var pointerFrame: NSRect? {
        guard let window else { return nil }
        return controls.toolbarDisclosure == .collapsed ? (animationTarget ?? window.frame)
            : (animationTarget.map { window.frame.union($0) } ?? window.frame)
    }

    static func showsDictation(_ model: AppModel) -> Bool {
        model.previewingPanel || model.phase != .idle || model.captureFailure != nil ||
            (model.clipboardReceipt.isHUDVisible && model.clipboardReceipt.receipt != nil)
    }

    func focusToolbar() {
        guard let model, let panel = window as? CapturePanel else { return }
        let target = TextDelivery.capture()
        model.floatingToolbarVisible = true
        update(model: model)
        guard surface == .tools else { return }
        keyboardTarget = target
        controls.focusToolbar()
        panel.allowsKeyboardFocus = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, panel?.allowsKeyboardFocus == true, self.surface == .tools else { return }
            self.controls.focusFirstControl?()
        }
    }

    func targetForDictation() -> TextDelivery.Target? {
        let target = window?.isKeyWindow == true ? keyboardTarget : TextDelivery.capture()
        releaseKeyboardFocus()
        return target
    }

    private func releaseKeyboardFocus() {
        guard let panel = window as? CapturePanel, panel.allowsKeyboardFocus else { return }
        let target = keyboardTarget
        panel.allowsKeyboardFocus = false
        panel.resignKey()
        target?.app.activate(options: [])
        keyboardTarget = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        (window as? CapturePanel)?.allowsKeyboardFocus = false
        keyboardTarget = nil; controls.unfocusToolbar()
    }

    func position(reset: Bool = false) {
        if reset { choosePosition(.bottom); return }
        guard let window else { return }
        place(size: animationTarget?.size ?? window.frame.size, restoreSaved: !window.isVisible)
    }

    private var preferredScreen: NSRect? {
        (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
    }

    private func place(size: NSSize, restoreSaved: Bool, animated: Bool = false) {
        guard let window, let preferred = preferredScreen else { return }
        let saved = UserDefaults.standard.string(forKey: positionKey).map(NSPointFromString)
        let savedSize = UserDefaults.standard.string(forKey: sizeKey).map(NSSizeFromString) ?? size
        let previous = restoreSaved ? saved.map { NSRect(origin: $0, size: savedSize) } : window.frame
        setFrame(CaptureHUDGeometry.frame(size: size, anchor: controls.anchor, previous: previous,
                                         screens: NSScreen.screens.map(\.visibleFrame), preferred: preferred), animated: animated)
    }

    private func choosePosition(_ anchor: FloatingControlAnchor) {
        controls.anchor = anchor
        guard let window else { return }
        place(size: animationTarget?.size ?? window.frame.size, restoreSaved: false)
    }

    private func cancelAnimation() {
        animationTask?.cancel(); animationTask = nil
        animationGeneration = UUID(); animationTarget = nil; positioning = false
    }

    private func setFrame(_ frame: NSRect, animated: Bool = false) {
        guard let window, animationTarget != frame else { return }
        cancelAnimation()
        positioning = true
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            controls.toolbarSize = frame.size
            window.setFrame(frame, display: true, animate: false)
            positioning = false; savePosition(); return
        }
        let start = window.frame, began = ProcessInfo.processInfo.systemUptime
        let generation = animationGeneration
        animationTarget = frame
        animationTask = Task { @MainActor [weak self, weak window] in
            while !Task.isCancelled {
                guard let self, let window, self.animationGeneration == generation else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let next = FloatingToolbarMotion.frame(from: start, to: frame,
                    progress: FloatingToolbarMotion.progress(at: elapsed))
                self.controls.toolbarSize = next.size
                window.setFrame(next, display: true, animate: false)
                if elapsed >= FloatingToolbarMotion.duration {
                    self.animationTarget = nil; self.animationTask = nil; self.positioning = false
                    self.savePosition(); return
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func savePosition() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: positionKey)
        UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: sizeKey)
        if let anchor = controls.anchor { UserDefaults.standard.set(anchor.rawValue, forKey: anchorKey) }
        else { UserDefaults.standard.removeObject(forKey: anchorKey) }
    }

    func windowDidMove(_ notification: Notification) {
        guard !positioning, !dragging, window?.isVisible == true else { return }
        savePosition()
    }

    func beginDragging() {
        let target = animationTarget
        cancelAnimation()
        if let target { setFrame(target) }
        dragging = true; controls.setDragging(true); previewDragging()
    }

    func cancelDragging() {
        let wasDragging = dragging
        dragging = false; snapGuide.hide()
        if wasDragging { controls.setDragging(false) }
    }

    func windowWillClose(_ notification: Notification) { cancelDragging() }

    override func close() {
        observations.removeAll()
        controls.resize = nil; controls.choosePosition = nil
        cancelAnimation(); controls.suspendToolbar(); cancelDragging(); releaseKeyboardFocus()
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        localPointerMonitor = nil; globalPointerMonitor = nil
        super.close()
    }

    func previewDragging() {
        guard dragging, let window, let preferred = preferredScreen else { snapGuide.hide(); return }
        let screen = CaptureHUDGeometry.screen(for: window.frame, screens: NSScreen.screens.map(\.visibleFrame), preferred: preferred)
        let anchor = FloatingControlGeometry.nearestAnchor(to: window.frame, in: screen)
        snapGuide.show(controlFrame: window.frame, visibleFrame: screen, activeAnchor: anchor, below: window)
    }

    func finishDragging() {
        defer { cancelDragging() }
        guard dragging, let window, let preferred = preferredScreen else { return }
        let screen = CaptureHUDGeometry.screen(for: window.frame, screens: NSScreen.screens.map(\.visibleFrame), preferred: preferred)
        controls.anchor = FloatingControlGeometry.nearestAnchor(to: window.frame, in: screen)
        let frame = controls.anchor.map { FloatingControlGeometry.frame(anchor: $0, size: window.frame.size, visibleFrame: screen) }
            ?? FloatingControlGeometry.clamp(window.frame, to: screen)
        setFrame(frame); savePosition()
    }
}

@MainActor
protocol FloatingHUDDragController: AnyObject {
    func beginDragging()
    func cancelDragging()
    func previewDragging()
    func finishDragging()
}

struct PanelDragHandle: NSViewRepresentable {
    var accessibilityLabel = "Drag dictation panel; named positions are also available in options"
    var showsGrip = true
    func makeNSView(context: Context) -> DragHandleView { DragHandleView(accessibilityLabel: accessibilityLabel, showsGrip: showsGrip) }
    func updateNSView(_ nsView: DragHandleView, context: Context) {}
}

final class DragHandleView: NSView {
    private var anchor: NSPoint?
    private var startingOrigin: NSPoint?
    private let showsGrip: Bool
    init(accessibilityLabel: String, showsGrip: Bool = true) {
        self.showsGrip = showsGrip
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel(accessibilityLabel)
        toolTip = "Drag to move. Release near an edge guide to snap."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        anchor = window.convertPoint(toScreen: event.locationInWindow)
        (window.windowController as? FloatingHUDDragController)?.beginDragging()
        startingOrigin = window.frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let anchor, let startingOrigin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: startingOrigin.x + point.x - anchor.x, y: startingOrigin.y + point.y - anchor.y))
        (window.windowController as? FloatingHUDDragController)?.previewDragging()
    }
    override func mouseUp(with event: NSEvent) {
        (window?.windowController as? FloatingHUDDragController)?.finishDragging()
        anchor = nil; startingOrigin = nil
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            (window?.windowController as? FloatingHUDDragController)?.cancelDragging()
            anchor = nil; startingOrigin = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        guard showsGrip else { return }
        NSColor.secondaryLabelColor.setFill()
        for x in [-3.0, 3.0] { for y in [-6.0, 0.0, 6.0] {
            NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 1.4, y: bounds.midY + y - 1.4, width: 2.8, height: 2.8)).fill()
        } }
    }
}

struct RecordingOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controls: CaptureHUDControls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var isRecordingSurface: Bool { model.phase == .recording || model.previewingPanel }
    private var size: NSSize { CaptureHUDLayout.size(recording: model.phase == .recording, preview: model.previewingPanel, expanded: controls.isExpanded) }

    var body: some View {
        HStack(spacing: 8) {
            PanelDragHandle().frame(width: 24, height: 40)
            if model.phase == .idle && !model.previewingPanel, let failure = model.captureFailure {
                failureState(failure)
            } else if model.phase == .idle && !model.previewingPanel {
                CaptureReceiptView(receipts: model.clipboardReceipt, review: { model.onShowEditor?("history") }, controls: controls)
            } else if isRecordingSurface && !controls.isExpanded {
                compactRecording
            } else {
                captureState
            }
        }.padding(.horizontal, 12)
            .frame(width: size.width, height: size.height)
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .windowBackgroundColor)) }
                else { RoundedRectangle(cornerRadius: 18).fill(.regularMaterial) }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12)))
            .transaction { $0.animation = nil }
            .tint(Workbench.accent).workbenchTheme()
    }

    private var compactRecording: some View {
        HStack(spacing: 12) {
            Image(systemName: model.previewingPanel ? "mic.slash" : "mic.fill")
                .foregroundStyle(model.previewingPanel ? Color.secondary : .red)
                .accessibilityLabel(model.previewingPanel ? "Preview; microphone off" : "Recording")
            VStack(alignment: .leading, spacing: 5) {
                Text(model.previewingPanel ? "Preview" : time(model.elapsed))
                    .font(.system(size: 14, weight: .medium, design: .monospaced)).monospacedDigit()
                    .accessibilityLabel(model.previewingPanel ? "Microphone off" : "\(Int(model.elapsed)) seconds recorded; five minute limit")
                CaptureLevelMeter(level: model.previewingPanel ? 0 : model.level).frame(width: 62, height: 9)
            }
            Spacer(minLength: 0)
            stopButton
            expansionButton
        }
    }

    private var captureState: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(model.phase == .recording ? Color.red : Workbench.accent)
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                if isRecordingSurface {
                    if !model.previewingPanel {
                        Text("\(time(model.elapsed)) / 5:00").font(.system(size: 12, design: .monospaced)).monospacedDigit()
                            .accessibilityLabel("\(Int(model.elapsed)) seconds recorded; five minute limit")
                    }
                    stopButton
                    expansionButton
                }
            }
            if isRecordingSurface {
                HStack(spacing: 7) {
                    CaptureLevelMeter(level: model.previewingPanel ? 0 : model.level).frame(width: 56, height: 12)
                    Text(model.previewingPanel ? "Microphone off" : model.isMicrophoneQuiet ? "Low microphone level" : "Microphone on")
                        .font(.system(size: 12)).foregroundStyle(model.isMicrophoneQuiet ? Color.orange : Color.secondary)
                    Spacer(minLength: 0)
                    if !model.previewingPanel {
                        Text(model.captureOutputModeLabel).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            .help("Chosen for this capture: " + model.captureOutputModeLabel)
                    }
                }
            } else if model.phase != .requesting {
                HStack(spacing: 7) {
                    if !reduceMotion { ProgressView().controlSize(.mini) }
                    Text(model.captureProcessingLabel).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(instruction).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if isRecordingSurface {
                if !model.previewingPanel && model.elapsed >= 290 {
                    Text("Stops automatically in \(max(0, Int(ceil(300 - model.elapsed))))s.")
                        .font(.system(size: 12)).foregroundStyle(.orange).monospacedDigit()
                } else if !model.previewingPanel, let name = model.captureDestinationName {
                    Text("For \(name)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack {
                if !model.previewingPanel && model.canCancelCurrentCapture {
                    Button { model.cancelCurrentCapture() } label: { Text("Cancel").frame(minWidth: 44, minHeight: 28) }
                        .buttonStyle(.bordered).controlSize(.small).accessibilityLabel("Cancel dictation and discard recording")
                }
                Spacer(minLength: 0)
                CapturePositionMenu(controls: controls, settings: { model.onShowEditor?("settings") })
            }
        }
    }

    private var stopButton: some View {
        Button {
            if model.previewingPanel { model.closePanelPreview() }
            else { model.stopRecording() }
        } label: {
            HStack(spacing: 5) {
                if !model.previewingPanel { Image(systemName: "stop.fill").font(.system(size: 8)) }
                Text(model.previewingPanel ? "Done" : "Stop")
            }.frame(minWidth: 42, minHeight: 28)
        }.buttonStyle(.borderedProminent).controlSize(.small)
            .accessibilityLabel(model.previewingPanel ? "Close microphone-off preview" : "Stop recording and transcribe")
    }

    private var expansionButton: some View {
        Button { controls.isExpanded.toggle() } label: {
            Image(systemName: controls.isExpanded ? "chevron.down" : "chevron.up").frame(width: 28, height: 28)
        }.buttonStyle(.plain)
            .accessibilityLabel(controls.isExpanded ? "Collapse recording controls" : "Expand recording controls")
            .help(controls.isExpanded ? "Show compact recording controls" : "Show details, Cancel and position options")
    }

    private func failureState(_ failure: String) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 7) {
                Label("Dictation needs attention", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                Text(failure).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).help(failure)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) {
                if model.canRetry {
                    Button { model.retryTranscription() } label: { Text(model.retryCaptureLabel).frame(minWidth: 44, minHeight: 28) }
                        .buttonStyle(.borderedProminent).help(model.retryCaptureHelp)
                }
                if !model.canRetry || model.hasCaptureRecovery {
                    Button { model.dismissCaptureFailure(); model.onShowEditor?("dictate") } label: {
                        Text("Open Workbench").font(.system(size: 12)).frame(minHeight: 28)
                    }.buttonStyle(.bordered)
                }
                Button { model.dismissCaptureFailure() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss dictation error")
            }.controlSize(.small)
            CapturePositionMenu(controls: controls)
        }
    }

    private var title: String {
        if model.previewingPanel { return "Panel preview" }
        switch model.phase {
        case .requesting:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: return "Allow microphone access"
            case .authorized: return "Starting microphone"
            case .denied, .restricted: return "Microphone access is off"
            @unknown default: return "Microphone permission needed"
            }
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .cleaning: return "Tidying your words"
        case .delivering: return "Delivering text"
        case .cancelling: return "Cancelling"
        case .idle: return "Dictation"
        }
    }
    private var symbol: String {
        if model.previewingPanel { return "mic.slash" }
        switch model.phase {
        case .requesting: return "mic.badge.plus"
        case .recording: return "mic.fill"
        case .delivering: return "arrow.up.doc"
        default: return "waveform"
        }
    }
    private var instruction: String {
        if model.previewingPanel { return "Drag to position, or choose a named position in options. No audio is recorded." }
        if model.phase == .requesting {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: return "Respond to the macOS prompt, or choose Cancel."
            case .authorized: return "You can cancel before recording starts."
            default: return "Check Privacy & Security → Microphone in System Settings."
            }
        }
        if model.phase == .recording { return model.captureShortcutInstruction }
        if model.phase == .delivering { return "Microphone off. Checking the destination." }
        if model.phase == .cancelling { return "Microphone off. Waiting for processing to stop." }
        if !model.canCancelCurrentCapture { return "Microphone off. Your original text is retained." }
        return "Microphone off. Cancel to stop processing."
    }
}

struct CaptureLevelMeter: View {
    let level: Double
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<8) { index in
                Capsule().fill(Double(index) / 8 < max(0, min(1, level)) ? Workbench.accent : Color.secondary.opacity(0.18))
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Microphone level")
            .accessibilityValue(level < 0.05 ? "Quiet" : "Receiving sound")
    }
}

private struct CaptureReceiptView: View {
    @ObservedObject var receipts: ClipboardReceiptModel
    let review: () -> Void
    @ObservedObject var controls: CaptureHUDControls
    var body: some View {
        if let receipt = receipts.receipt {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: receipt.symbolName).foregroundStyle(Workbench.accent)
                        Text(receipt.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if receipt.wordCount > 0 { Text("\(receipt.wordCount) \(receipt.wordCount == 1 ? "word" : "words")").font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    Text(receipt.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 3) {
                    Button { receipts.dismissHUD(); review() } label: { Text("Review").frame(minWidth: 44, minHeight: 28) }
                        .buttonStyle(.bordered).controlSize(.small).help("Open recent transcripts")
                    HStack(spacing: 2) {
                        if receipt.isClipboardCurrent {
                            Button { receipts.keepVisible.toggle() } label: {
                                Image(systemName: receipts.keepVisible ? "pin.fill" : "pin").frame(width: 28, height: 28)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(receipts.keepVisible ? "Unpin receipt" : "Keep receipt visible")
                                .help("Keep visible while this text is on the clipboard")
                        }
                        Button { receipts.dismissHUD() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss dictation receipt")
                    }
                }
                CapturePositionMenu(controls: controls)
            }
        }
    }
}

struct CapturePositionMenu: View {
    @ObservedObject var controls: CaptureHUDControls
    var settings: (() -> Void)? = nil
    var accessibilityName = "Dictation panel options"
    var body: some View {
        Menu {
            Section("Position") {
                ForEach(FloatingControlAnchor.allCases) { anchor in
                    Button { controls.choosePosition?(anchor) } label: {
                        if controls.anchor == anchor { Label(anchor.title, systemImage: "checkmark") }
                        else { Text(anchor.title) }
                    }
                }
                Button("Reset to bottom centre") { controls.choosePosition?(.bottom) }
            }
            if let settings {
                Divider()
                Button("Settings for next capture", action: settings)
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 32)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(accessibilityName).help("Position and options")
    }
}
