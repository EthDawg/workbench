import SwiftUI

/// General uses the live toolbar's reducer and placement owner. No second preference.
struct ToolbarSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let controls = model.toolbarControls {
            ToolbarSettingsControls(model: model, controls: controls)
        }
    }
}

private struct ToolbarSettingsControls: View {
    @Environment(\.pageSectionFrames) private var sectionFrames
    @ObservedObject var model: AppModel
    @ObservedObject var controls: CaptureHUDControls
    var body: some View {
        // Grouped under General's Floating toolbar switch, which names the group.
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Keep open", isOn: Binding(get: { controls.toolbar.state.keepsOpen }, set: {
                controls.toolbar.setKeepsOpen($0)
            })).toggleStyle(.switch)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?("settings.toolbar.keepOpen", $0) }
            Button("Position floating toolbar…") { model.showPanelPreview() }
                .disabled(model.phase != .idle)
            Text("Drag the toolbar to move it, or choose a position and reset it here. Hiding it leaves your work running.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
