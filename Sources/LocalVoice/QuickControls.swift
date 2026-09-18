import AppKit
import SwiftUI

struct ShortcutKeycap: View {
    @ObservedObject var model: AppModel
    var id: UInt32
    var title: String
    var body: some View {
        Button { model.onEditShortcut?(id) } label: {
            HStack(spacing: 7) {
                Text(model.editingShortcut == id ? "Press keys…" : model.preferences.shortcut(id).label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Image(systemName: "pencil").font(.system(size: 10))
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .foregroundStyle(model.editingShortcut == id ? Workbench.accent : .primary)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.editingShortcut == id ? Workbench.accent : .clear))
        }.buttonStyle(.plain).disabled(model.phase != .idle)
            .accessibilityLabel("Edit \(title.lowercased()) shortcut")
            .help("Click to change · Escape cancels · Delete disables")
    }
}

struct ShortcutControl: View {
    @ObservedObject var model: AppModel
    var id: UInt32
    var title: String
    var shortcut: VoiceShortcut { model.preferences.shortcut(id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title); Spacer()
                if model.editingShortcut == id { Button("Cancel") { model.onCancelShortcut?() }.buttonStyle(.link) }
                ShortcutKeycap(model: model, id: id, title: title)
            }
            if model.editingShortcut == id {
                Text(model.shortcutRecordingMessage ?? "Press your combination. Use ⌃, ⌥ or ⌘ with a key.")
                    .font(.caption).foregroundStyle(model.shortcutRecordingMessage == nil ? Color.secondary : .orange)
            }
            if let failure = model.shortcutFailures[id] { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct VoiceShortcutSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Click a shortcut, then press your preferred combination.").font(.caption).foregroundStyle(.secondary)
            ShortcutControl(model: model, id: 1, title: "Dictation")
            ShortcutControl(model: model, id: 2, title: "Quick controls")
            ShortcutControl(model: model, id: 3, title: "Demo library")
            ShortcutControl(model: model, id: 4, title: "Readback capture")
            Text("Escape cancels. Delete turns a shortcut off. Existing shortcuts stay unchanged if a combination is unavailable.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Restore default shortcuts") { model.onResetShortcuts?() }
        }.disabled(model.phase != .idle)
    }
}

struct VoiceOptions: View {
    @ObservedObject var model: AppModel
    var showShortcut = true
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if showShortcut { ShortcutControl(model: model, id: 1, title: "Dictation") }
            Picker("Activation", selection: $model.preferences.capture) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Cleanup", selection: $model.preferences.cleanup) {
                ForEach(CleanupStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Text(model.preferences.cleanup.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Delivery", selection: $model.preferences.delivery) {
                ForEach(DeliveryMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if model.preferences.delivery == .paste {
                if model.accessibilityGranted {
                    Label("Automatic paste ready", systemImage: "checkmark.circle").foregroundStyle(Workbench.accent).font(.caption)
                } else {
                    Button("Enable automatic paste…") { model.requestAccessibility() }
                    Text("Allow Accessibility once. Until then, your transcript is copied.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.disabled(model.phase != .idle)
    }
}
struct VoiceQuickControls: View {
    static let size = NSSize(width: 370, height: 650)
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                WorkbenchHeader(title: "Voice", subtitle: model.ready ? "Ready for your next thought" : "Preparing local speech…", symbol: "waveform")
                Spacer()
                Menu {
                    Button("Open editor…") { model.onShowEditor?("dictate") }
                    Button("Recent transcripts…") { model.onShowEditor?("history") }
                    Button("Demo library…") { model.showLibrary() }
                    Button("Your dictionary…") { model.onShowEditor?("dictionary") }
                    Divider()
                    Button("Quit Workbench Voice") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More options")
            }
            Picker("Quick controls", selection: $model.quickTab) {
                ForEach(["Dictate", "Read", "Recent", "Settings"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if model.quickTab == "Recent" {
                CaptureHistoryView(model: model, compact: true)
            } else { ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.error {
                        HStack(alignment: .top) { Text(error); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") } }
                            .font(.caption).foregroundStyle(.orange)
                    }
                    switch model.quickTab {
                    case "Read": reading
                    case "Settings": general
                    default: dictation
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
            } }
            Divider()
            Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
            HStack {
                Button("Open editor…") { model.onShowEditor?(model.quickTab == "Read" ? "speak" : "dictate") }.buttonStyle(.link)
                Button { model.showLibrary() } label: { Image(systemName: "square.stack.3d.up") }.buttonStyle(.link).help("Demo library · \(model.preferences.shortcut(3).label)").accessibilityLabel("Open demo library")
                Spacer()
                WorkbenchSwitcher { model.onCloseMenu?(); model.stopPlayback() }.disabled(model.phase != .idle)
            }
        }.padding(14).frame(width: Self.size.width, height: Self.size.height)
            .font(.system(size: 12)).controlSize(.small).background(Workbench.background).tint(Workbench.accent).workbenchTheme()
            .onExitCommand { model.onCloseMenu?() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Workbench Voice quick controls")
    }
    private var dictation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { model.onMenuRecording?() } label: {
                HStack {
                    Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                    Text(model.phase == .recording ? "Finish dictation" : "Start dictation")
                    Spacer()
                    if model.phase == .recording { Text(time(model.elapsed)).font(.caption).monospacedDigit() }
                }
                    .padding(.vertical, 8).frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(!model.ready || (model.phase != .idle && model.phase != .recording) || model.rendering)
            if model.phase == .requesting { Button("Cancel microphone request") { model.cancelRecording() } }
            VoiceOptions(model: model)
            Divider()
            if let latest = model.history.first {
                HStack { Text("LATEST CAPTURE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Button("Copy") { model.copyCapture(latest) }.buttonStyle(.link) }
                Text(latest.text).font(.system(size: 12)).lineLimit(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Open") { model.openTranscript(latest); model.onShowEditor?("dictate") }
                    Spacer()
                    Button("Paste") { model.onPasteTranscript?(latest.text) }.disabled(model.phase != .idle)
                }
            } else { Text("Start in any text field. Your words return there when you finish.").font(.caption).foregroundStyle(.secondary) }
            Button { model.quickTab = "Recent" } label: {
                HStack { Label("Recent transcripts", systemImage: "clock"); Spacer(); Text("\(model.history.count)").monospacedDigit(); Image(systemName: "chevron.right") }
            }.buttonStyle(.plain).foregroundStyle(Workbench.accent).padding(.vertical, 5)
            if model.history.count > 1 {
                ForEach(Array(model.history.dropFirst().prefix(2))) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Button { model.openTranscript(item); model.onShowEditor?("dictate") } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.date, format: .dateTime.hour().minute()).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                        Button { model.copyCapture(item) } label: { Image(systemName: "doc.on.doc") }.help("Copy transcript").accessibilityLabel("Copy recent transcript")
                    }.font(.system(size: 11)).padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }
    private var reading: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Give your eyes a break.").font(.headline)
            Button(model.readingProvider == .speko ? "Read clipboard with Speko" : "Read clipboard") {
                if let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.speechText = text; model.listen()
                } else { model.status = "Copy some text first." }
            }.disabled(model.phase != .idle || model.rendering || model.playing || model.paused)
            if model.readingProvider == .mac { Picker("Voice", selection: $model.voice) { ForEach(model.voices, id: \.self) { Text($0).tag($0) } }
            HStack { Text("Pace"); Slider(value: $model.rate, in: 100...300, step: 5); Text("\(Int(model.rate))").monospacedDigit() } }
            Text(model.speechText.isEmpty ? "Paste or type a longer passage in the editor." : model.speechText).lineLimit(9).foregroundStyle(.secondary)
            HStack {
                Button(model.playing ? "Pause" : model.paused ? "Resume" : "Listen") { model.listen() }.disabled(model.speechText.isEmpty || model.rendering || model.phase != .idle)
                if model.cloudRequestActive { Button("Cancel request") { model.cancelReading() } }
                if model.playing || model.paused { Button("Stop") { model.stopPlayback() } }
                Spacer(); Button("Edit text…") { model.onShowEditor?("speak") }
            }
            Text(model.readingProvider == .speko ? "Speko sends the reading online. Usage may be billed. Change provider in the editor." : "Installed Mac voices. No account or usage meter.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            VoiceShortcutSettings(model: model)
            Divider()
            Button("Position dictation panel…") { model.onCloseMenu?(); model.showPanelPreview() }.disabled(model.phase != .idle)
            Text("Drag its grip to move it. The position is remembered between recordings.").font(.caption).foregroundStyle(.secondary)
            Toggle("Restore clipboard after confirmed paste", isOn: $model.preferences.restoreClipboard)
            Text("If focus changes or paste cannot be confirmed, the transcript stays on your clipboard.").font(.caption).foregroundStyle(.secondary)
            Divider(); WorkbenchAppearancePicker()
            Text("One appearance for Voice and StageMark. Search Workbench in Spotlight to find your tools.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Label(model.modelMessage, systemImage: "cpu").font(.caption)
            Text(CleanupEngine.availability).font(.caption).foregroundStyle(.secondary)
            if !model.ready && !model.preparing { Button("Retry model") { Task { await model.prepare() } } }
            Button("All settings…") { model.onShowEditor?("settings") }
        }
    }
}
