import AppKit
import Combine
import StageKit
import SwiftUI

struct ReadbackView: View {
    @ObservedObject var model: ReadbackModel
    @State private var orderingSections = false
    @State private var confirmEmptyTrash = false

    var body: some View {
        HStack(spacing: 0) {
            recentSessions
            Divider()
            Group {
                if model.sessionURL == nil { emptyState }
                else { sessionEditor }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $orderingSections) {
            if let root = model.sessionURL { ReadbackOrderingView(model: model, sessionURL: root) }
        }
        .confirmationDialog("Permanently delete every section in Recently Deleted?", isPresented: $confirmEmptyTrash) {
            Button("Empty Recently Deleted", role: .destructive) { model.emptyRecentlyDeleted() }
        } message: { Text("Workbench cannot recover these screenshots, recordings or transcripts afterward.") }
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SNAP & TALK SESSIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Button { model.createSession() } label: { Label("New session…", systemImage: "folder.badge.plus") }
                .buttonStyle(.borderedProminent).disabled(model.isRecording)
            Button { model.openSession() } label: { Label("Open folder…", systemImage: "folder") }
                .buttonStyle(.bordered).disabled(model.isRecording)
            Divider()
            if model.recentSessionURLs.isEmpty {
                Text("Named session folders you open will stay available here.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.recentSessionURLs, id: \.path) { url in
                            Button { model.openRecent(url) } label: {
                                HStack {
                                    Image(systemName: model.sessionURL?.standardizedFileURL == url.standardizedFileURL ? "folder.fill" : "folder")
                                    Text(url.lastPathComponent).lineLimit(2)
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(7)
                            }.buttonStyle(.plain)
                                .background(model.sessionURL?.standardizedFileURL == url.standardizedFileURL ? Workbench.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
            Spacer()
            Text("Each folder stays portable and self-contained.").font(.caption2).foregroundStyle(.tertiary)
        }.padding(16).frame(width: 220).background(Workbench.surface.opacity(0.45))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Start a Snap & Talk session", systemImage: "rectangle.and.pencil.and.ellipsis")
        } description: {
            Text("Create a named Finder folder, then use one shortcut to capture the display under your pointer and narrate it.")
        } actions: {
            HStack {
                Button("New session…") { model.createSession() }.buttonStyle(.borderedProminent)
                Button("Open session…") { model.openSession() }
            }
        }
    }

    private var sessionEditor: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    permissionCard
                    captureCard
                    if model.activeSections.isEmpty {
                        ContentUnavailableView("No sections yet", systemImage: "rectangle.dashed",
                            description: Text("Move the pointer to the display you want and use \(model.shortcutLabel). The screenshot is taken before narration begins."))
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        HStack {
                            Text("SECTIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(model.activeSections.count) slides").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.activeSections.enumerated()), id: \.element.id) { index, section in
                            sectionCard(section, number: index + 1)
                        }
                    }
                    if !model.deletedSections.isEmpty { recentlyDeleted }
                }.padding(24).frame(maxWidth: 940)
            }.frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.manifest?.title ?? "Snap & Talk").font(.title2.weight(.semibold))
                Text(model.sessionURL?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if model.pendingTranscriptionCount > 0 {
                Label("\(model.pendingTranscriptionCount) processing", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
            }
            Button { orderingSections = true } label: { Label("Reorder…", systemImage: "arrow.up.arrow.down") }
                .disabled(model.activeSections.count < 2 || model.isRecording || model.isCapturing)
                .help("Arrange sections in a compact list")
            Menu {
                ForEach(ReadbackHandoffTarget.allCases) { target in
                    Button { model.handOff(to: target) } label: {
                        Label(target.title, systemImage: target == .claude ? "sparkles" : "bubble.left.and.text.bubble.right")
                    }
                }
            } label: {
                Label("Hand off…", systemImage: "arrow.up.forward.app")
            }
            .disabled(model.isRecording)
            .help("Copy an agent prompt, reveal this session in Finder and open the chosen app")
            Button("Show in Finder") { model.revealSession() }
            Button("Close session") { model.closeSession() }.disabled(model.isRecording)
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var permissionCard: some View {
        HStack(spacing: 16) {
            permission("Screen Recording", granted: model.screenPermissionGranted, symbol: "display") { model.openScreenRecordingSettings() }
            Divider().frame(height: 34)
            permission("Microphone", granted: model.microphonePermission == .authorized, symbol: "mic") { model.openMicrophoneSettings() }
            Spacer()
            Button("Check access") { Task { await model.preflightPermissions() } }
        }.padding(14).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func permission(_ title: String, granted: Bool, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(granted ? Workbench.accent : .orange)
                VStack(alignment: .leading, spacing: 1) { Text(title); Text(granted ? "Ready" : "Open settings").font(.caption).foregroundStyle(.secondary) }
            }
        }.buttonStyle(.plain)
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isRecording ? "Narrating section" : "Capture, then speak").font(.headline)
                    Text(model.isRecording ? "Use \(model.shortcutLabel) again to stop and save." : "\(model.shortcutLabel) captures the display under the pointer, including the pointer, then starts narration.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRecording {
                    Text(time(model.recordingElapsed)).font(.title3.monospacedDigit()).foregroundStyle(.red)
                    Button("Stop and save") { model.stopNarration() }.buttonStyle(.borderedProminent)
                    Button("Cancel") { model.cancelNarration() }
                } else {
                    Button { Task { await model.captureNewSection(fromEditor: true) } } label: {
                        Label(model.isCapturing ? "Capturing…" : "Capture & narrate", systemImage: "camera.viewfinder")
                    }.buttonStyle(.borderedProminent).disabled(!model.permissionsReady || model.isCapturing)
                }
            }
            HStack {
                Toggle("Show Snap & Talk HUD", isOn: $model.showHUD).toggleStyle(.switch)
                Spacer()
                Text("Original audio and transcript are kept locally.").font(.caption).foregroundStyle(.secondary)
            }
            if let notice = model.notice {
                Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(notice.localizedCaseInsensitiveContains("failed") || notice.localizedCaseInsensitiveContains("off") ? .orange : .secondary)
                    .textSelection(.enabled)
            }
            if let failure = model.shortcutFailure {
                HStack {
                    Label(failure, systemImage: "keyboard.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Change shortcut…") { model.onEditShortcut?() }
                }
            }
        }.padding(16).background(Workbench.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Workbench.accent.opacity(0.18)))
    }

    private func sectionCard(_ section: ReadbackSection, number: Int) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topLeading) {
                    ReadbackThumbnail(root: model.sessionURL, relative: section.screenshot, revision: section.capturedAt)
                        .frame(width: 250, height: 142).background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 9)).clipped()
                    Text("\(number)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.ultraThickMaterial, in: Capsule()).padding(7)
                }
                Text(section.displayName).font(.caption).foregroundStyle(.secondary)
                Text(section.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(section.status.title, systemImage: statusSymbol(section.status))
                        .font(.callout.weight(.semibold)).foregroundStyle(section.status == .failed ? .orange : .primary)
                    Spacer()
                    Button { model.deleteSection(section.id) } label: { Label("Trash", systemImage: "trash") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.isRecording || model.isCapturing || [.queued, .transcribing].contains(section.status))
                        .help("Move this section to Recently Deleted")
                    Menu {
                        Button("Replace screenshot…") { Task { await model.replaceScreenshot(section.id) } }
                        Button("Re-record narration") { model.startNarration(for: section.id) }
                        Button("Redo screenshot and narration…") { Task { await model.redoBoth(section.id) } }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                        .disabled(model.isRecording || model.isCapturing || [.queued, .transcribing].contains(section.status))
                }
                if let failure = section.failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if section.status == .ready {
                    Text("NARRATION · EDITABLE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { model.transcriptDrafts[section.id] ?? "" }, set: { model.updateTranscript($0, for: section.id) }))
                        .font(.body).frame(minHeight: 82).padding(5).background(.background, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Workbench.border))
                    Text("The original transcription remains preserved. This edited text becomes the slide's speaker notes.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if section.status == .failed, section.audio != nil {
                    Button("Retry transcription") { model.retryTranscription(section.id) }.buttonStyle(.bordered)
                } else if section.status == .needsNarration {
                    Button("Record narration") { model.startNarration(for: section.id) }.buttonStyle(.borderedProminent)
                        .disabled(model.isRecording || model.microphonePermission != .authorized)
                } else {
                    ProgressView().controlSize(.small)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(15).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Workbench.border))
            .contentShape(Rectangle())
    }

    private var recentlyDeleted: some View {
        DisclosureGroup {
            VStack(spacing: 10) {
                ForEach(model.deletedSections) { section in
                    HStack {
                        ReadbackThumbnail(root: model.sessionURL, relative: section.screenshot, revision: section.capturedAt)
                            .frame(width: 120, height: 68).clipped().opacity(0.72)
                        VStack(alignment: .leading) {
                            Text(section.displayName).font(.callout)
                            if let deletedAt = section.deletedAt { Text("Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Restore") { model.restoreSection(section.id) }
                    }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                }
                HStack { Spacer(); Button("Empty Recently Deleted…", role: .destructive) { confirmEmptyTrash = true } }
            }.padding(.top, 10)
        } label: { Label("Recently Deleted · \(model.deletedSections.count)", systemImage: "trash") }
            .padding(15).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusSymbol(_ status: ReadbackSectionStatus) -> String {
        switch status {
        case .needsNarration: "mic.badge.plus"
        case .recording: "mic.fill"
        case .queued: "clock"
        case .transcribing: "waveform"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        }
    }
}

struct ReadbackThumbnail: View {
    let root: URL?
    let relative: String
    let revision: Date
    var body: some View {
        Group {
            if let root, let url = try? ReadbackStore.safeURL(root: root, relative: relative), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo.badge.exclamationmark").font(.title).foregroundStyle(.secondary)
            }
        }.accessibilityLabel("Snap & Talk screenshot")
    }
}

struct ReadbackHUDView: View {
    @ObservedObject var model: ReadbackModel
    @ObservedObject var controls: CaptureHUDControls
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var size: NSSize { controls.isExpanded ? CaptureHUDLayout.expanded : CaptureHUDLayout.compact }

    var body: some View {
        HStack(spacing: 8) {
            PanelDragHandle(accessibilityLabel: "Drag Snap & Talk panel; named positions are available in options")
                .frame(width: 24, height: 40)
            if controls.isExpanded { expandedRecording }
            else { compactRecording }
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
            Image(systemName: "mic.fill").foregroundStyle(.red).accessibilityLabel("Recording narration")
            VStack(alignment: .leading, spacing: 5) {
                Text(time(model.recordingElapsed)).font(.system(size: 14, weight: .medium, design: .monospaced)).monospacedDigit()
                    .accessibilityLabel("\(Int(model.recordingElapsed)) seconds recorded; five minute limit")
                CaptureLevelMeter(level: model.recordingLevel).frame(width: 62, height: 9)
            }
            Spacer(minLength: 0)
            stopButton
            expansionButton
        }
    }

    private var expandedRecording: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text("Recording Snap & Talk").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(time(model.recordingElapsed)) / 5:00").font(.system(size: 12, design: .monospaced)).monospacedDigit()
                stopButton
                expansionButton
            }
            HStack(spacing: 7) {
                CaptureLevelMeter(level: model.recordingLevel).frame(width: 56, height: 12)
                Text(model.recordingLevel < 0.03 && model.recordingElapsed >= 6 ? "Low microphone level" : "Microphone on")
                    .font(.system(size: 12)).foregroundStyle(model.recordingLevel < 0.03 && model.recordingElapsed >= 6 ? Color.orange : Color.secondary)
            }
            Text("Narrating the captured screen. Use \(model.shortcutLabel) again to stop and save.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Button("Cancel") { model.cancelNarration() }.buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("Cancel narration and keep the screenshot")
                Spacer(minLength: 0)
                CapturePositionMenu(controls: controls, accessibilityName: "Snap & Talk panel options")
            }
        }
    }

    private var stopButton: some View {
        Button { model.stopNarration() } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill").font(.system(size: 8))
                Text("Stop")
            }.frame(minWidth: 42, minHeight: 28)
        }.buttonStyle(.borderedProminent).controlSize(.small)
            .accessibilityLabel("Stop narration, save and transcribe")
    }

    private var expansionButton: some View {
        Button { controls.isExpanded.toggle() } label: {
            Image(systemName: controls.isExpanded ? "chevron.down" : "chevron.up").frame(width: 28, height: 28)
        }.buttonStyle(.plain)
            .accessibilityLabel(controls.isExpanded ? "Collapse narration controls" : "Expand narration controls")
            .help(controls.isExpanded ? "Show compact narration controls" : "Show details, Cancel and position options")
    }
}

@MainActor
final class ReadbackHUDController: NSWindowController, NSWindowDelegate, FloatingHUDDragController {
    private let positionKey = "snapTalkPanelOrigin.v1"
    private let anchorKey = "snapTalkPanelAnchor.v1"
    private let controls = CaptureHUDControls()
    private weak var model: ReadbackModel?
    private var positioning = false
    private var dragging = false
    private let snapGuide = FloatingControlGuideController()
    private var observations = Set<AnyCancellable>()

    init(model: ReadbackModel) {
        let panel = CapturePanel(contentRect: NSRect(origin: .zero, size: CaptureHUDLayout.compact),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        self.model = model
        let savedAnchor = UserDefaults.standard.string(forKey: anchorKey).flatMap(FloatingControlAnchor.init(rawValue:))
        controls.anchor = savedAnchor ?? (UserDefaults.standard.string(forKey: positionKey) == nil ? .bottom : nil)
        controls.resize = { [weak self, weak model] in if let model { self?.update(model) } }
        controls.choosePosition = { [weak self] in self?.choosePosition($0) }
        panel.title = "Workbench Snap & Talk"
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isMovable = true; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = CaptureHostingView(rootView: ReadbackHUDView(model: model, controls: controls))
        panel.delegate = self
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cancelDragging(); self?.position() }
            .store(in: &observations)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ model: ReadbackModel) {
        guard let window else { return }
        guard model.isRecording, model.showHUD else {
            window.orderOut(nil); cancelDragging(); controls.isExpanded = false
            return
        }
        let size = controls.isExpanded ? CaptureHUDLayout.expanded : CaptureHUDLayout.compact
        if !window.isVisible { place(size: size, restoreSaved: true) }
        else if window.frame.size != size { place(size: size, restoreSaved: false) }
        window.orderFrontRegardless()
    }

    func position() {
        guard let window else { return }
        place(size: window.frame.size, restoreSaved: !window.isVisible)
    }

    private var preferredScreen: NSRect? {
        if let target = model?.recordingScreenFrame,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(target) }) {
            return screen.visibleFrame
        }
        return (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
    }

    private func place(size: NSSize, restoreSaved: Bool) {
        guard let window, let preferred = preferredScreen else { return }
        let saved = UserDefaults.standard.string(forKey: positionKey).map(NSPointFromString)
        let previous = restoreSaved ? saved.map { NSRect(origin: $0, size: size) } : window.frame
        setFrame(CaptureHUDGeometry.frame(size: size, anchor: controls.anchor, previous: previous,
                                         screens: NSScreen.screens.map(\.visibleFrame), preferred: preferred))
        savePosition()
    }

    private func choosePosition(_ anchor: FloatingControlAnchor) {
        controls.anchor = anchor
        guard let window else { return }
        place(size: window.frame.size, restoreSaved: false)
    }

    private func setFrame(_ frame: NSRect) {
        positioning = true
        window?.setFrame(frame, display: true, animate: false)
        positioning = false
    }

    private func savePosition() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: positionKey)
        if let anchor = controls.anchor { UserDefaults.standard.set(anchor.rawValue, forKey: anchorKey) }
        else { UserDefaults.standard.removeObject(forKey: anchorKey) }
    }

    func windowDidMove(_ notification: Notification) {
        guard !positioning, !dragging, window?.isVisible == true else { return }
        savePosition()
    }

    func beginDragging() { dragging = true; previewDragging() }

    func cancelDragging() { dragging = false; snapGuide.hide() }

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

    func shutdown() { cancelDragging(); window?.orderOut(nil); window?.contentView = nil; close() }
}
