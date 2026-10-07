import AppKit
import SwiftUI

/// Library owns reusable prompts. Opening this picker never captures a field
/// in another app or requests Accessibility; its result is an exact Copy.
/// A SwiftUI button, so it takes the page's tint like every other header button;
/// an empty AppKit view behind it is the picker's anchor.
struct LibraryPromptButton: View {
    let model: AppModel
    @State private var anchor = Anchor()
    var body: some View {
        Button("Saved Prompts…") {
            guard let view = anchor.view else { return }
            PromptPickerController.shared.show(from: view, context: .library(model.library,
                delivery: model.promptInsertion, receipts: model.clipboardReceipt, openLibrary: { model.showLibrary() }))
        }.background(AnchorView(anchor: anchor))
    }
    final class Anchor { weak var view: NSView? }
    private struct AnchorView: NSViewRepresentable {
        let anchor: Anchor
        func makeNSView(context: Context) -> NSView { let view = NSView(); anchor.view = view; return view }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }
}
