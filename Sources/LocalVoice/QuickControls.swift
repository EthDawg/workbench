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
            ShortcutControl(model: model, id: 1, title: "Dictate")
            ShortcutControl(model: model, id: 2, title: "Quick controls")
            ShortcutControl(model: model, id: 5, title: "Snap & Talk")
            ShortcutControl(model: model, id: 3, title: "Library")
            ShortcutControl(model: model, id: 4, title: "Switch to")
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
            // The same words the one-time hold lesson uses, with the shortcut as it is saved (#134 T5).
            Text(model.preferences.capture == .hold
                 ? HoldLesson.title(shortcut: model.preferences.dictationShortcut.label) + " " + HoldLesson.body
                 : "Press \(model.preferences.dictationShortcut.label) to start dictating, and again to finish.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    // The preference is kept for later approval; copying works now.
                    Text("Automatic paste needs Accessibility approval. Until then, transcripts are copied for ⌘V.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Set up automatic paste…") { model.requestAccessibility() }
                        Text("Your organisation may need to approve this.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.disabled(model.phase != .idle)
    }
}
