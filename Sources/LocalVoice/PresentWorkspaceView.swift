import AppKit
import SwiftUI
import StageKit

struct PresentWorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stage: StageKitController
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PresentPromptButton(model: model).fixedSize().frame(height: 26)
                Spacer()
            }.padding(.horizontal, Workbench.pagePadding).padding(.vertical, 10)
            stage.scenesView
        }
    }
}

private struct PresentPromptButton: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> ButtonView { ButtonView() }
    func updateNSView(_ view: ButtonView, context: Context) {
        view.title = "Saved Prompts…"
        view.open = { [weak view] in
            guard let view else { return }
            // Workbench is the chosen workspace here. The picker offers Copy when there
            // is no eligible external destination, and never infers a browser target.
            PromptPickerController.shared.show(from: view, context: .init(resources: model.library.resources,
                delivery: model.promptInsertion, receipts: model.clipboardReceipt, destination: TextDelivery.capture(),
                trusted: AXIsProcessTrusted(), controls: nil, openLibrary: { model.showLibrary() }))
        }
    }
    final class ButtonView: NSButton {
        var open: (() -> Void)?
        override init(frame: NSRect) { super.init(frame: frame); bezelStyle = .rounded; target = self; action = #selector(show) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func show() { open?() }
    }
}
