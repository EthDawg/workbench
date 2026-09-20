import AppKit
import SwiftUI

@MainActor
enum ReadSelectionChecks {
    private struct Failure: LocalizedError {
        let label: String
        var errorDescription: String? { "READ SELECTION CHECK FAILED: \(label)" }
    }

    static func run() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw Failure(label: label) }
            count += 1
        }
        func invoke(_ service: ReadSelectionService, pasteboard: NSPasteboard) -> String? {
            var message: NSString?
            withUnsafeMutablePointer(to: &message) { pointer in
                service.readSelection(pasteboard, userData: nil, error: AutoreleasingUnsafeMutablePointer(pointer))
            }
            return message as String?
        }

        let requestPasteboard = NSPasteboard.withUniqueName()
        var received: [ReadingSelectionImport] = []
        let exact = "  First line.\nSecond line — unchanged.  "
        let service = ReadSelectionService(reader: { _ in try ReadingSelectionImport(text: exact) }) { received.append($0) }
        try check(service.responds(to: NSSelectorFromString("readSelection:userData:error:")), "Objective-C Services selector is exported")

        try check(invoke(service, pasteboard: requestPasteboard) == nil, "explicit string selection is accepted")
        try check(received.last?.text == exact, "selection whitespace and Unicode are preserved exactly")

        let missing = ReadSelectionService(reader: { _ in
            throw VoiceError.message("Workbench received no text selection. Select text in the other app and try again.")
        }) { received.append($0) }
        try check(invoke(missing, pasteboard: requestPasteboard)?.contains("no text selection") == true, "missing input reports a selection error")
        try check(received.count == 1, "missing input never invents text from another source")

        let longText = String(repeating: "a", count: 50_001)
        let long = ReadSelectionService(reader: { _ in try ReadingSelectionImport(text: longText) }) { received.append($0) }
        try check(invoke(long, pasteboard: requestPasteboard) == nil && received.last?.text == longText,
                  "a selection beyond the local reading limit still opens intact for review")

        let oversizedText = String(repeating: "b", count: ReadingSelectionImport.maximumCharacters + 1)
        let oversized = ReadSelectionService(reader: { _ in try ReadingSelectionImport(text: oversizedText) }) { received.append($0) }
        try check(invoke(oversized, pasteboard: requestPasteboard)?.contains("too large") == true, "unbounded selection is rejected")
        try check(received.count == 2, "rejected selection never reaches the reading draft")

        try check(!ReadingSelectionImport.needsReview(current: "", incoming: "Incoming"), "empty reading can adopt the selection directly")
        try check(!ReadingSelectionImport.needsReview(current: "Incoming", incoming: "Incoming"), "identical re-import needs no destructive choice")
        try check(ReadingSelectionImport.needsReview(current: "Current", incoming: "Incoming"), "different existing reading requires replace or keep")
        print("READ_SELECTION_CHECKS_OK: \(count) checks passed")
    }

    static func runNativePasteboard() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw Failure(label: label) }
            count += 1
        }
        func invoke(_ service: ReadSelectionService, pasteboard: NSPasteboard) -> String? {
            var message: NSString?
            withUnsafeMutablePointer(to: &message) { pointer in
                service.readSelection(pasteboard, userData: nil, error: AutoreleasingUnsafeMutablePointer(pointer))
            }
            return message as String?
        }

        let exact = "Selected in a native requester — kept exactly."
        let requestPasteboard = NSPasteboard.withUniqueName()
        requestPasteboard.clearContents()
        try check(requestPasteboard.setString(exact, forType: .string), "native request pasteboard accepts selected text")
        var received: [ReadingSelectionImport] = []
        let service = ReadSelectionService { received.append($0) }
        try check(invoke(service, pasteboard: requestPasteboard) == nil, "production pasteboard reader accepts native string input")
        try check(received.map(\.text) == [exact], "production provider returns only the supplied request selection")
        requestPasteboard.clearContents()
        try check(invoke(service, pasteboard: requestPasteboard)?.contains("no text selection") == true,
                  "an empty native request fails without a fallback source")
        print("READ_SELECTION_NATIVE_OK: \(count) checks passed")
    }

    static func renderReviewCard(to url: URL) throws {
        let selection = try ReadingSelectionImport(id: UUID(uuidString: "D7A7A755-1B43-4D03-A9D5-49A4E6CA38F4")!, text: "Workbench should read only this selected passage. The current reading remains untouched until I choose Replace reading, and no online provider receives anything until I choose Listen.")
        let root = VStack(alignment: .leading, spacing: 18) {
            Text("Read aloud").font(.system(size: 26, weight: .bold))
            ReadingSelectionReviewCard(selection: selection, limitMessage: nil, keep: {}, replace: {})
            HStack {
                Label("Mac voices · on this Mac", systemImage: "desktopcomputer")
                Spacer()
                Text("Nothing has been played or sent.").foregroundStyle(.secondary)
            }.font(.caption)
        }.padding(28).frame(width: 820, height: 430, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 430)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure(label: "review card bitmap allocation")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(label: "review card PNG encoding")
        }
        try png.write(to: url, options: .atomic)
        print("READ_SELECTION_UI_RENDER_OK: \(url.path)")
    }
}
