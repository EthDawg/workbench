import AppKit
import SwiftUI
import Combine
import Carbon

/// Carbon key codes and modifier masks, shared with macOS global shortcuts.
public struct StageShortcutDescriptor: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let enabled: Bool
    public let error: String?
    public let keyLabel: String
}

/// Presentation capabilities hosted by Workbench's single application shell.
/// StageKit never creates a menu-bar item or independently terminates the app.
@MainActor
public final class StageKitController: ObservableObject {
    private let coordinator: AppCoordinator
    private var observations = Set<AnyCancellable>()
    private var started = false

    public var onOpenControls: (() -> Void)? {
        didSet { coordinator.onOpenControls = onOpenControls }
    }
    public var onOpenScenes: (() -> Void)? {
        didSet { coordinator.onOpenScenes = onOpenScenes; coordinator.demoScenes.onOpen = onOpenScenes }
    }
    public var onOpenShortcuts: (() -> Void)? {
        didSet { coordinator.onOpenShortcuts = onOpenShortcuts }
    }
    public var onEditShortcuts: (() -> Void)? {
        get { onOpenShortcuts }
        set { onOpenShortcuts = newValue }
    }
    public var mayBeginInteraction: (() -> Bool)? {
        didSet {
            coordinator.mayBeginInteraction = mayBeginInteraction; coordinator.demoScenes.mayBeginInteraction = mayBeginInteraction
            coordinator.demoScenes.personas.mayBeginInteraction = mayBeginInteraction
        }
    }
    /// Hide the shell before drawing, starting a timer or presenting a scene.
    public var onBeginActivity: (() -> Void)? {
        didSet {
            coordinator.onBeginActivity = onBeginActivity
            coordinator.demoScenes.onBeginPresentation = onBeginActivity
            coordinator.demoScenes.personas.onShow = onBeginActivity
        }
    }
    /// Supply the other modules' shortcuts so every entry point checks conflicts.
    /// Return a concise reason when the combination belongs to another module.
    public var validateExternalShortcut: ((UInt32, UInt32) -> String?)? {
        didSet {
            coordinator.validateExternalShortcut = { [weak self] code, modifiers in
                self?.validateExternalShortcut?(code, modifiers) ?? Self.reservedVoiceShortcut(code, modifiers)
            }
            if started { coordinator.setShortcutsSuspended(true); coordinator.setShortcutsSuspended(false) }
        }
    }

    public init(onOpenControls: (() -> Void)? = nil, onOpenScenes: (() -> Void)? = nil) {
        let migrationNotice = Workbench.prepareStageData()
        let settings = SettingsStore(defaults: Workbench.stageDefaults)
        let coordinator = AppCoordinator(settings: settings, embedded: true, migrationFailure: migrationNotice)
        self.coordinator = coordinator
        self.onOpenControls = onOpenControls
        self.onOpenScenes = onOpenScenes
        coordinator.onOpenControls = onOpenControls
        coordinator.onOpenScenes = onOpenScenes
        coordinator.demoScenes.onOpen = onOpenScenes
        coordinator.validateExternalShortcut = Self.reservedVoiceShortcut
        if let migrationNotice { coordinator.notice = migrationNotice }
        coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        coordinator.demoScenes.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        coordinator.demoScenes.personas.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }

    public var controlsView: AnyView { AnyView(ControlCenter(app: coordinator, settings: coordinator.settings)) }
    public var scenesView: AnyView { AnyView(DemoScenesView(model: coordinator.demoScenes)) }
    public var quickControlsView: AnyView { AnyView(QuickControlsView(app: coordinator, settings: coordinator.settings)) }
    /// Opens an existing-scene choice followed by the ordinary backdrop preview.
    /// The caller presents this as a sheet; no scene changes until Use backdrop.
    public func backdropReplacementView(imageURL: URL, title: String) -> AnyView {
        AnyView(PhotoBackdropChooser(model: coordinator.demoScenes, imageURL: imageURL, title: title))
    }
    public var isDrawing: Bool { coordinator.isDrawing }
    public var isPresenting: Bool { coordinator.demoScenes.isPresenting }
    public var hasOverlaySession: Bool { coordinator.demoScenes.personas.sessionState.phase != .idle }
    public var areOverlaysPaused: Bool { coordinator.demoScenes.personas.sessionState.phase == .paused }
    public var canStepOverlays: Bool { coordinator.demoScenes.personas.sessionState.groups.count > 1 }
    public var timerText: String { coordinator.timerText }
    public var isTimerRunning: Bool { coordinator.timerRunning }
    public var notice: String? { coordinator.notice ?? coordinator.settings.notice ?? coordinator.demoScenes.notice }

    public func start() {
        guard !started else { return }
        started = true
        coordinator.start()
    }
    public func shutdown() {
        guard started else { return }
        started = false
        coordinator.shutdown()
    }
    public func draw() { coordinator.startDrawing(.pen, latched: true) }
    public func clear() { coordinator.perform(.clear) }
    public func showBoard() { coordinator.toggleBoard(.white) }
    public func showTimer() { coordinator.toggleTimer() }
    public func showScenes() { coordinator.showDemoScenes() }
    public func showPersonas() { coordinator.demoScenes.showPersonas() }
    public func focusOverlayControls() { coordinator.demoScenes.personas.focusOverlayControls() }
    public func stepOverlaySet(_ offset: Int) { coordinator.demoScenes.personas.performOverlayAction(.stepGroup(offset)) }
    public func toggleOverlayVisibility() { coordinator.demoScenes.personas.performOverlayAction(.pauseResume) }
    public func endOverlays() { coordinator.demoScenes.personas.hideOverlay() }
    public func endPresentation() { coordinator.demoScenes.endPresentation(); coordinator.demoScenes.personas.hideOverlay(); coordinator.hideTimer(); coordinator.escape() }
    public func escape() { coordinator.escape() }
    public func performShortcut(id: String) {
        guard let action = Action(rawValue: id) else { return }
        coordinator.perform(action)
    }
    public func setShortcutsSuspended(_ suspended: Bool) { coordinator.setShortcutsSuspended(suspended) }
    public func resetShortcuts() { coordinator.restoreShortcuts() }

    public var shortcutDescriptors: [StageShortcutDescriptor] {
        Action.allCases.map { action in
            let shortcut = coordinator.settings.value.shortcut(for: action)
            return StageShortcutDescriptor(id: action.rawValue, label: action.title,
                keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, enabled: shortcut.enabled,
                error: coordinator.shortcutFailures[action], keyLabel: shortcut.label)
        }
    }

    /// Returns a validation failure without changing the saved shortcut.
    @discardableResult
    public func updateShortcut(id: String, keyCode: UInt32, modifiers: UInt32, enabled: Bool) -> String? {
        guard let action = Action(rawValue: id) else { return "That action is no longer available." }
        let shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers, enabled: enabled)
        if enabled {
            guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else { return "Include Control, Option or Command." }
            if let message = coordinator.validateExternalShortcut?(keyCode, modifiers) { return message }
            if let conflict = Action.allCases.first(where: { $0 != action && coordinator.settings.value.shortcut(for: $0) == shortcut }) {
                return "That shortcut belongs to \(conflict.title). Choose another combination."
            }
        }
        coordinator.settings.value.shortcuts[action.rawValue] = shortcut
        return nil
    }

    private static func reservedVoiceShortcut(_ code: UInt32, _ modifiers: UInt32) -> String? {
        guard modifiers == UInt32(controlKey | optionKey), [UInt32(kVK_Space), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_J)].contains(code) else { return nil }
        return "This combination is reserved for Voice. Choose another combination."
    }
}

@MainActor
private struct PhotoBackdropChooser: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DemoScenes
    let imageURL: URL
    let title: String
    @State private var sceneID: UUID?
    @State private var draft: BackdropReplacement?
    @State private var notice: String?
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let draft {
                BackdropReplacementView(model: model, draft: draft)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Use photo as backdrop").font(.title2.weight(.semibold))
                        Spacer()
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    HStack(spacing: 16) {
                        Group {
                            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                            else { Image(systemName: "photo").foregroundStyle(.secondary) }
                        }.frame(width: 120, height: 90).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.headline).lineLimit(2)
                            Text("Choose a saved scene. Review the crop next, then apply when it looks right.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.storageBlocked {
                        ContentUnavailableView("Saved scenes need attention", systemImage: "exclamationmark.folder",
                            description: Text("The scene library could not be read. Its original files are preserved. You can still save a separate copy of this photo."))
                    } else if model.scenes.isEmpty {
                        ContentUnavailableView("Prepare a scene first", systemImage: "rectangle.on.rectangle",
                            description: Text("Create a scene in Present a device, then return to this photo. Choosing a backdrop never creates a duplicate scene."))
                    } else {
                        List(selection: $sceneID) {
                            ForEach(model.scenes) { scene in
                                Label(scene.name, systemImage: "rectangle.on.rectangle")
                                    .padding(.vertical, 7).tag(scene.id)
                            }
                        }.accessibilityLabel("Choose a saved scene")
                            .accessibilityIdentifier("handoff.backdrop-scenes")
                    }
                    if let notice { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    Spacer(minLength: 0)
                    Divider()
                    HStack {
                        Text("Only the backdrop changes. Foreground layers and the current presentation stay as they are.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Preview backdrop") {
                            guard let sceneID else { return }
                            do { draft = try model.makeBackdropReplacement(sceneID: sceneID, imageURL: imageURL, title: title) }
                            catch { notice = error.localizedDescription }
                        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(model.storageBlocked || thumbnail == nil || !model.scenes.contains { $0.id == sceneID })
                            .accessibilityIdentifier("handoff.preview-backdrop")
                    }
                }.padding(20).frame(width: 840, height: 660)
                    .background(Workbench.background).tint(Workbench.accent).workbenchTheme()
            }
        }.onAppear {
            sceneID = model.selected?.id ?? model.scenes.first?.id
            do { thumbnail = try BackdropImage.thumbnail(imageURL) }
            catch { notice = "The photo could not be opened. " + error.localizedDescription }
        }.onDisappear { draft?.cancel() }
    }
}
