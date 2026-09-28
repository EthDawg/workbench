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

/// Dictate's other options, below its task region: how the shortcut records.
struct VoiceOptions: View {
    @ObservedObject var model: AppModel
    var showShortcut = true
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if showShortcut { ShortcutControl(model: model, id: 1, title: "Dictation") }
            Picker("Activation", selection: $model.preferences.capture) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.fixedSize()
            // The same words the one-time hold lesson uses, with the shortcut as it is saved (#134 T5).
            Text(model.preferences.capture == .hold
                 ? HoldLesson.title(shortcut: model.preferences.dictationShortcut.label) + " " + HoldLesson.body
                 : "Press \(model.preferences.dictationShortcut.label) to start dictating, and again to finish.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(model.phase != .idle)
    }
}

/// Where Dictate's words go and how they are tidied, inside the page's task region beside the
/// microphone and the result (#134). A copy for ⌘V is a finished result (#165), so its caption
/// says so; Set up automatic paste… sits beside Delivery as an option, never a step to wait on.
/// Each text style shows its description and one example checked against the real cleanup.
struct DictateTaskOptions: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Delivery", selection: $model.preferences.delivery) {
                    ForEach(DeliveryMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                if model.preferences.delivery == .paste {
                    if model.accessibilityGranted {
                        Label("Automatic paste ready", systemImage: "checkmark.circle").foregroundStyle(Workbench.accent).font(.caption)
                    } else {
                        // The choice is kept for a later approval; copying works now.
                        Button("Set up automatic paste…") { model.requestAccessibility() }
                    }
                }
            }
            Text(deliveryCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Text style", selection: $model.preferences.cleanup) {
                ForEach(CleanupStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.fixedSize().padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.preferences.cleanup.detail)
                Text(model.preferences.cleanup.exampleText).foregroundStyle(.tertiary)
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(model.phase != .idle)
    }
    private var deliveryCaption: String {
        switch model.preferences.delivery {
        case .clipboard: return "Transcripts are copied. Paste with ⌘V."
        case .paste where model.accessibilityGranted: return "Automatic paste returns to your starting text field."
        case .paste: return "Transcripts are copied; paste with ⌘V. Automatic paste needs Accessibility approval, which your organisation may need to give."
        }
    }
}
