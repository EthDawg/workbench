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
    /// A settings row that already names the shortcut shows only its keys.
    var showsTitle = true
    var shortcut: VoiceShortcut { model.preferences.shortcut(id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if showsTitle { Text(title); Spacer() }
                if model.editingShortcut == id { Button("Cancel") { model.onCancelShortcut?() }.buttonStyle(.link) }
                ShortcutKeycap(model: model, id: id, title: title)
                if !showsTitle { Spacer() }
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

/// A row in a settings sheet: its name in one fixed column, its control and note beside it, so
/// every option on the sheet starts at the same edge.
struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Dictate's other options: the shortcut that starts it and how that shortcut records.
struct VoiceOptions: View {
    @ObservedObject var model: AppModel
    var showShortcut = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showShortcut {
                SettingsRow("Shortcut") { ShortcutControl(model: model, id: 1, title: "Dictation", showsTitle: false) }
            }
            SettingsRow("Activation") {
                Picker("Activation", selection: $model.preferences.capture) {
                    ForEach(CaptureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize()
                // The same words the one-time hold lesson uses, with the shortcut as it is saved (#134 T5).
                Text(model.preferences.capture == .hold
                     ? HoldLesson.title(shortcut: model.preferences.dictationShortcut.label) + " " + HoldLesson.body
                     : "Press \(model.preferences.dictationShortcut.label) to start dictating, and again to finish.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(model.phase != .idle)
    }
}

/// Where Dictate's words go and how they are tidied (#134). A copy for ⌘V is a finished result
/// (#165), so the caption says what happens today: until Accessibility is approved, Paste
/// automatically copies, and Set up automatic paste… sits beside it as an option, never a step
/// to wait on. Each text style shows its description and one example checked against the real
/// cleanup.
struct DictateTaskOptions: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow("Delivery") {
                HStack(spacing: 10) {
                    Picker("Delivery", selection: $model.preferences.delivery) {
                        ForEach(DeliveryMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize()
                    if model.preferences.delivery == .paste {
                        if model.accessibilityGranted {
                            Label("Ready", systemImage: "checkmark.circle").foregroundStyle(Workbench.accent).font(.caption)
                        } else {
                            // The choice is kept for a later approval; copying works now.
                            Button("Set up automatic paste…") { model.requestAccessibility() }
                        }
                    }
                }
                Text(deliveryCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsRow("Text style") {
                Picker("Text style", selection: $model.preferences.cleanup) {
                    ForEach(CleanupStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize()
                Text(model.preferences.cleanup.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(model.preferences.cleanup.exampleText).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(model.phase != .idle)
    }
    private var deliveryCaption: String {
        switch model.preferences.delivery {
        case .clipboard: return "Your words are copied. Paste with ⌘V."
        case .paste where model.accessibilityGranted: return "Your words go back into the text field you started in."
        case .paste: return "Until Accessibility is approved, your words are copied and you paste with ⌘V. On a work Mac, IT may need to approve it."
        }
    }
}
