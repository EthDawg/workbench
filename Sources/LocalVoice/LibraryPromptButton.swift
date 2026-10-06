import AppKit
import SwiftUI

/// Library owns reusable prompts. Opening this picker never captures a field
/// in another app or requests Accessibility; its result is an exact Copy.
struct LibraryPromptButton: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> ButtonView { ButtonView() }
    func updateNSView(_ view: ButtonView, context: Context) {
        view.title = "Saved Prompts…"
        view.open = { [weak view] in
            guard let view else { return }
            PromptPickerController.shared.show(from: view, context: .library(model.library,
                delivery: model.promptInsertion, receipts: model.clipboardReceipt, openLibrary: { model.showLibrary() }))
        }
    }
    final class ButtonView: NSButton {
        var open: (() -> Void)?
        override init(frame: NSRect) { super.init(frame: frame); bezelStyle = .rounded; target = self; action = #selector(show) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func show() { open?() }
    }
}
