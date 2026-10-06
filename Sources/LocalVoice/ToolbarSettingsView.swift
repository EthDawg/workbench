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
        // Rows of General's Floating toolbar section, beneath its switch; the footer explains them.
        Toggle("Keep open", isOn: Binding(get: { controls.toolbar.state.keepsOpen }, set: {
            controls.toolbar.setKeepsOpen($0)
        })).toggleStyle(.switch).controlSize(.mini)
            .help("Keep the toolbar's full row showing instead of resting as a handle.")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?("settings.toolbar.keepOpen", $0) }
        LabeledContent("Position") {
            Button("Position floating toolbar…") { model.showPanelPreview() }
                .disabled(model.phase != .idle)
        }
    }
}
