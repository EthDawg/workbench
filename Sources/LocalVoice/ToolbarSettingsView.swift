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
    @ObservedObject var model: AppModel
    @ObservedObject var controls: CaptureHUDControls
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkbenchSectionTitle("Floating toolbar")
            Toggle("Keep open", isOn: Binding(get: { controls.toolbar.state.keepsOpen }, set: {
                controls.toolbar.send(.keepOpenChanged($0))
            })).toggleStyle(.switch)
            Button("Position floating toolbar…") { model.showPanelPreview() }
                .disabled(model.phase != .idle)
            Text("Drag the toolbar to move it, or choose a position and reset it here. Hiding it leaves your work running.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
