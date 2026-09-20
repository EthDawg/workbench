import AppKit
import SwiftUI

@MainActor
enum ReadbackOrderingChecks {
    static func run() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw ReadbackError.message("READBACK_ORDER_CHECK_FAILED: \(message)") }
            checks += 1
        }
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, root = fixture.root, ids = model.activeSections.map(\.id)
        let before = try fixture.snapshot()
        let order = ReadbackSectionOrder(ids: ids)
        try check(order.moving(ids[0], to: ids.count) == Array(ids.dropFirst()) + [ids[0]], "first row can move after the final row")
        try check(order.moving(ids.last!, to: 0) == [ids.last!] + Array(ids.dropLast()), "last row can move before the first")
        try check(order.moving(ids[0], to: 2) == [ids[1], ids[0]] + Array(ids.dropFirst(2)), "adjacent downward insertion moves exactly once")
        try check(order.moving(ids[1], to: 0) == [ids[1], ids[0]] + Array(ids.dropFirst(2)), "adjacent upward insertion moves exactly once")
        try check(order.moving(ids[0], to: 0) == nil && order.moving(ids[0], to: 1) == nil, "dropping next to the source is a no-op")
        try check(order.moving(ids[0], to: -1) == nil && order.moving(ids[0], to: ids.count + 1) == nil && order.moving(UUID(), to: 0) == nil, "invalid boundaries and missing sources are rejected")

        var drag = ReadbackSectionDrag()
        let token = drag.begin(ids[0])
        try check(drag.proposedOrder(payload: token, fromThisTable: false, ids: ids, boundary: ids.count) == nil, "foreign drag sources are rejected even with a matching token")
        try check(drag.proposedOrder(payload: ids[0].uuidString, fromThisTable: true, ids: ids, boundary: ids.count) == nil, "plain section IDs are not accepted as drag tokens")
        let moved = drag.proposedOrder(payload: token, fromThisTable: true, ids: ids, boundary: ids.count)!
        try check(drag.proposedOrder(payload: token, fromThisTable: true, ids: ids, boundary: ids.count) == moved && order.ids == ids, "repeated hover validation is stable and does not mutate the draft")
        drag.end()
        try check(drag.proposedOrder(payload: token, fromThisTable: true, ids: ids, boundary: ids.count) == nil, "cancelled or completed drag tokens are retired")
        _ = drag.begin(ids[1])
        try check(drag.proposedOrder(payload: token, fromThisTable: true, ids: ids, boundary: ids.count) == nil, "a later drag rejects an earlier token")
        let afterHover = try fixture.snapshot()
        try check(afterHover == before, "hover and cancellation leave every session file unchanged")
        try check(!model.saveSectionOrder(Array(ids.dropLast()), expectedOrder: ids, session: root), "incomplete orders are rejected")
        try check(!model.saveSectionOrder([ids[0]] + Array(ids.dropLast()), expectedOrder: ids, session: root), "duplicate IDs are rejected")
        try check(!model.saveSectionOrder([UUID()] + Array(ids.dropFirst()), expectedOrder: ids, session: root), "foreign IDs are rejected")
        try check(model.saveSectionOrder(ids, expectedOrder: ids, session: root), "unchanged order succeeds without a write")
        let afterInvalid = try fixture.snapshot()
        try check(afterInvalid == before, "invalid and unchanged orders preserve the manifest byte for byte")

        var latest = try ReadbackStore.load(from: root)
        latest.sections[0].failure = "Synthetic latest metadata"
        try ReadbackStore.save(latest, at: root)
        try check(model.saveSectionOrder(moved, expectedOrder: ids, session: root), "intentional complete order saves")
        let saved = try ReadbackStore.load(from: root)
        try check(saved.sections.filter { $0.deletedAt == nil }.map(\.id) == moved, "saved order survives reload")
        try check(saved.sections.first(where: { $0.id == ids[0] })?.failure == "Synthetic latest metadata", "ordering merges the latest section metadata")
        try check(saved.sections.filter { $0.deletedAt != nil } == latest.sections.filter { $0.deletedAt != nil }, "Recently Deleted is preserved")
        let afterSave = try fixture.snapshot().filter { $0.key != ReadbackStore.manifestName }
        try check(afterSave == before.filter { $0.key != ReadbackStore.manifestName }, "screenshots, audio, original and edited narration remain byte for byte unchanged")
        let afterSaveManifest = try Data(contentsOf: root.appendingPathComponent(ReadbackStore.manifestName))
        try check(!model.saveSectionOrder(ids, expectedOrder: ids, session: root), "stale sheets cannot overwrite a newer order")
        let afterStale = try Data(contentsOf: root.appendingPathComponent(ReadbackStore.manifestName))
        try check(afterStale == afterSaveManifest, "stale order rejection leaves the saved manifest unchanged")
        model.closeSession()
        try check(!model.saveSectionOrder(ids, expectedOrder: moved, session: root), "closing or switching sessions prevents the old sheet from saving")
        print("READBACK_ORDER_CHECKS_OK: \(checks) checks")
    }

    /// Exercises the actual AppKit table delegate with an isolated pasteboard,
    /// and optionally renders the synthetic sheet for visual inspection.
    static func runNative(output: URL?) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let fixture = try Fixture(thumbnails: true)
        defer { fixture.cleanUp() }
        let original = try fixture.snapshot()
        let window = NSWindow(contentViewController: NSHostingController(rootView: ReadbackOrderingView(model: fixture.model, sessionURL: fixture.root)))
        window.isReleasedWhenClosed = false; window.title = "Synthetic section ordering"
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        guard let content = window.contentView, let table = table(in: content),
              let coordinator = table.delegate as? ReadbackOrderTable.Coordinator else {
            throw ReadbackError.message("The native ordering table did not open")
        }
        let ids = coordinator.parent.order
        guard let writer = coordinator.tableView(table, pasteboardWriterForRow: 0) else { throw ReadbackError.message("Native drag did not supply a pasteboard item") }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([writer])
        let info = OrderingDragInfo(pasteboard: pasteboard, source: table)
        for _ in 0..<3 {
            guard coordinator.tableView(table, validateDrop: info, proposedRow: ids.count, proposedDropOperation: .above) == .move,
                  coordinator.parent.order == ids else { throw ReadbackError.message("Native hover moved the draft or rejected a valid insertion") }
        }
        let foreign = OrderingDragInfo(pasteboard: pasteboard, source: NSTableView())
        guard coordinator.tableView(table, validateDrop: foreign, proposedRow: ids.count, proposedDropOperation: .above).isEmpty else {
            throw ReadbackError.message("Native table accepted a foreign drag")
        }
        guard coordinator.tableView(table, acceptDrop: info, row: ids.count, dropOperation: .above) else { throw ReadbackError.message("Native completed drop was rejected") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard coordinator.parent.order == Array(ids.dropFirst()) + [ids[0]], table.numberOfRows == ids.count,
              coordinator.tableView(table, validateDrop: info, proposedRow: 0, proposedDropOperation: .above).isEmpty else {
            throw ReadbackError.message("Native drop order, row refresh or token retirement failed")
        }
        guard try fixture.snapshot() == original else { throw ReadbackError.message("Native drop persisted before Save order") }
        if let output {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), output.path]
            try capture.run(); capture.waitUntilExit()
            guard capture.terminationStatus == 0 else { throw ReadbackError.message("Could not render the synthetic ordering window") }
        }
        print("READBACK_ORDER_NATIVE_OK: native table hover, foreign rejection, completed insertion, row refresh and single-use drag; session unchanged before Save")
    }

    @MainActor private final class Fixture {
        let root: URL
        let domain: String
        let defaults: UserDefaults
        let model: ReadbackModel
        init(thumbnails: Bool = false) throws {
            domain = "Workbench.OrderingChecks.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: domain)!
            root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
            var manifest = try ReadbackStore.create(at: root, title: "Synthetic walkthrough")
            let titles = ["Start with the overview", "Choose the right workspace", "Review the draft together", "Check the final details", "Share the finished work", "Keep an original for later", "Deleted example"]
            for (index, title) in titles.enumerated() {
                let id = UUID(), deleted = index == titles.count - 1
                let directory = "\(deleted ? "trash" : "items")/\(id.uuidString.lowercased())"
                try ReadbackStore.createPrivateDirectory(root.appendingPathComponent(directory))
                let section = ReadbackSection(id: id, capturedAt: Date(timeIntervalSince1970: 1_000 + Double(index)), displayName: "Synthetic display",
                    directory: directory, screenshot: directory + "/screen.png", audio: directory + "/narration.wav",
                    originalTranscript: directory + "/narration-original.txt", transcript: directory + "/narration.txt", status: .ready,
                    failure: nil, deletedAt: deleted ? Date(timeIntervalSince1970: 2_000) : nil)
                for path in [section.screenshot, section.audio!, section.originalTranscript!, section.transcript!] {
                    try ReadbackStore.writePrivate(Data(title.utf8), to: root.appendingPathComponent(path))
                }
                if thumbnails {
                    let image = NSImage(size: NSSize(width: 480, height: 270))
                    image.lockFocus()
                    NSColor(calibratedHue: CGFloat(index) / 8, saturation: 0.28, brightness: 0.92, alpha: 1).setFill()
                    NSRect(x: 0, y: 0, width: 480, height: 270).fill()
                    (title as NSString).draw(in: NSRect(x: 32, y: 88, width: 416, height: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: NSColor.black])
                    image.unlockFocus()
                    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(section.screenshot))
                }
                manifest.sections.append(section)
            }
            try ReadbackStore.save(manifest, at: root)
            defaults.set([root.path], forKey: "readback.recentSessionPaths.v1")
            model = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults)), defaults: defaults)
        }
        func snapshot() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))] = try Data(contentsOf: url)
            }
            return result
        }
        func cleanUp() { model.shutdown(); defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
    }
}

@MainActor
private final class OrderingDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    init(pasteboard: NSPasteboard, source: Any?) { draggingPasteboard = pasteboard; draggingSource = source }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
