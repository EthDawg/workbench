import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReadbackView: View {
    @ObservedObject var model: ReadbackModel
    @State private var draggingSection: UUID?
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
        .confirmationDialog("Permanently delete every section in Recently Deleted?", isPresented: $confirmEmptyTrash) {
            Button("Empty Recently Deleted", role: .destructive) { model.emptyRecentlyDeleted() }
        } message: { Text("Workbench cannot recover these screenshots, recordings or transcripts afterward.") }
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("READBACK SESSIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
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
            Label("Start a narrated readback", systemImage: "rectangle.and.pencil.and.ellipsis")
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
                            Text("Drag to reorder").font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Text("\(model.activeSections.count) slides").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.activeSections.enumerated()), id: \.element.id) { index, section in
                            sectionCard(section, number: index + 1)
                                .onDrag {
                                    draggingSection = section.id
                                    return NSItemProvider(object: section.id.uuidString as NSString)
                                }
                                .onDrop(of: [UTType.text], delegate: ReadbackSectionDropDelegate(target: section.id, model: model, dragging: $draggingSection))
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
                Text(model.manifest?.title ?? "Readback").font(.title2.weight(.semibold))
                Text(model.sessionURL?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if model.pendingTranscriptionCount > 0 {
                Label("\(model.pendingTranscriptionCount) processing", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
            }
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
                Toggle("Show narration HUD", isOn: $model.showHUD).toggleStyle(.switch)
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
                    Menu {
                        Button("Replace screenshot…") { Task { await model.replaceScreenshot(section.id) } }
                        Button("Re-record narration") { model.startNarration(for: section.id) }
                        Button("Redo screenshot and narration…") { Task { await model.redoBoth(section.id) } }
                        Divider()
                        Button("Move to Recently Deleted", role: .destructive) { model.deleteSection(section.id) }
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

private struct ReadbackThumbnail: View {
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
        }.accessibilityLabel("Readback screenshot")
    }
}

private struct ReadbackSectionDropDelegate: DropDelegate {
    let target: UUID
    let model: ReadbackModel
    @Binding var dragging: UUID?
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        model.moveSection(dragging, before: target)
    }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

struct ReadbackHUDView: View {
    @ObservedObject var model: ReadbackModel
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = model.recordingThumbnail { Image(nsImage: image).resizable().scaledToFill() }
                else { Image(systemName: "camera.viewfinder").font(.title2) }
            }.frame(width: 92, height: 56).clipped().background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                HStack { Circle().fill(.red).frame(width: 7, height: 7); Text("Narrating screenshot").font(.callout.weight(.semibold)) }
                Text(time(model.recordingElapsed)).font(.title3.monospacedDigit())
                Text("\(model.shortcutLabel) to stop").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(12).frame(width: 330, height: 82)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.14)))
            .shadow(radius: 14, y: 6).workbenchTheme()
    }
}

@MainActor
final class ReadbackHUDController {
    private var panel: NSPanel?
    func update(_ model: ReadbackModel) {
        guard model.isRecording, model.showHUD else { hide(); return }
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = true; panel.contentViewController = NSHostingController(rootView: ReadbackHUDView(model: model))
            self.panel = panel
        }
        let size = NSSize(width: 330, height: 82)
        let screen = model.recordingScreenFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 26)
        panel?.setFrame(NSRect(origin: origin, size: size), display: true)
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil) }
    func shutdown() { panel?.orderOut(nil); panel?.contentView = nil; panel = nil }
}
