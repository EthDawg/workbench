import AppKit
import SwiftUI

@main struct LibraryImportChecks {
    @MainActor static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }

    @MainActor static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-import-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        let store = DemoLibraryStore(directory: root)
        let first = DemoResource(title: "Follow-up prompt", product: "People", persona: "Hiring manager", content: "Ask about availability.\nKeep it brief.", notes: "My existing preparation notes", favorite: true)
        let second = DemoResource(kind: .link, title: "Demo portal", content: "https://example.com/demo")
        let fileURL = root.appendingPathComponent("Guide.txt")
        let original = Data("Synthetic original file — retain these bytes.".utf8)
        try original.write(to: fileURL)
        let bookmark = try fileURL.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        let file = DemoResource(kind: .file, title: "Guide", content: fileURL.path, notes: "Local file", bookmark: bookmark)
        let initial = [first, second, file]
        try store.save(initial)
        let originalLibrary = try Data(contentsOf: store.url)
        let model = DemoLibraryModel(store: store, copyText: { _ in fatalError("Import cannot copy") }, openURL: { _ in fatalError("Import cannot open a resource") })
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw VoiceError.message("IMPORT REVIEW FAILED: \(name)") }; count += 1
        }
        let exchange = root.appendingPathComponent("Shared library.json")
        func prepare(_ resources: [DemoResource]) throws {
            try DemoLibraryStore.encoded(resources).write(to: exchange)
            model.prepareImport(from: exchange)
        }
        var changed = first; changed.content = "Ask about availability and the preferred start date.\nOffer two time slots."; changed.notes = "Incoming preparation notes"; changed.favorite = false
        var identical = second; identical.modified = second.modified.addingTimeInterval(50)
        var fileUpdate = file; fileUpdate.notes = "Updated file notes"; fileUpdate.bookmark = Data([1, 2, 3])
        let missing = DemoResource(kind: .file, title: "Shared deck", content: root.appendingPathComponent("Elsewhere/Deck.pdf").path)
        let incoming = [changed, identical, fileUpdate, missing]
        try prepare(incoming)
        let review = model.importReview!
        try check(review.count(.new) == 1 && review.count(.changed) == 2 && review.count(.unchanged) == 1, "New/Changed/Unchanged classification ignores timestamp-only changes")
        try check(review.unavailableFileCount == 1, "missing file reference count uses this Mac")
        try check(review.entries.allSatisfy { $0.incoming.bookmark == nil }, "untrusted bookmarks removed before review")
        try check(model.importChoices.isEmpty && model.resources == initial && Data(contentsOf: store.url) == originalLibrary, "review defaults to Keep mine and never saves")
        model.newPrompt("Do not replace this review")
        try check(model.draft == nil && !model.performPrimaryAction(), "review blocks background creation and recall")
        model.cancelImport()
        try check(model.importReview == nil && model.resources == initial && Data(contentsOf: store.url) == originalLibrary, "cancel preserves full original library")

        // A view render uses the exact sheet, model and synthetic exchange.
        if CommandLine.arguments.count == 2 {
            try prepare(incoming)
            _ = NSApplication.shared
            let view = NSHostingView(rootView: DemoLibraryImportView(library: model).environment(\.colorScheme, .dark))
            view.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
            view.layoutSubtreeIfNeeded()
            // onAppear/selection reconciliation runs on the native run loop.
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw VoiceError.message("Render allocation failed") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw VoiceError.message("PNG encoding failed") }
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
            model.cancelImport()
        }

        try prepare(incoming)
        model.importChoices = [changed.id, fileUpdate.id]
        try check(model.applyImport(), "chosen import commits successfully")
        let saved = try store.load()
        try check(saved.count == 4 && saved[0] == changed && saved[1] == second, "only chosen changes apply, exact incoming notes and IDs retained")
        try check(saved[2].notes == fileUpdate.notes && saved[2].bookmark == bookmark, "same-file metadata update retains this Mac's bookmark")
        try check(saved[3].bookmark == nil && saved[3].content == missing.content, "new file reference keeps exact path without copied access")
        try check(Data(contentsOf: fileURL) == original, "original referenced asset untouched")
        let after = try Data(contentsOf: store.url)
        try prepare(saved)
        try check(model.importReview?.count(.unchanged) == 4 && model.applyImport(), "identical re-import completes")
        try check(Data(contentsOf: store.url) == after && model.notice?.contains("No changes") == true, "identical import is a byte-for-byte no-op")

        var replacementPath = saved[2]; replacementPath.content = root.appendingPathComponent("Different.txt").path
        try prepare([replacementPath]); model.importChoices = [replacementPath.id]
        try check(model.applyImport() && model.resources[2].bookmark == nil, "changed file path drops the old local access grant")

        let baseline = model.resources
        let baselineBytes = try Data(contentsOf: store.url)
        try prepare([changed])
        model.importChoices = [UUID()]
        try check(!model.applyImport() && model.resources == baseline && Data(contentsOf: store.url) == baselineBytes, "invalid choice cannot mutate the library")
        model.cancelImport()

        // A save failure must preserve the existing bytes and the review choices.
        var another = changed; another.notes = "An explicit further edit"
        try prepare([another]); model.importChoices = [another.id]
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let failed = !model.applyImport()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try check(failed && model.resources == baseline && Data(contentsOf: store.url) == baselineBytes, "failed write preserves disk and in-memory originals")
        try check(model.importReview != nil && model.importChoices == [another.id] && model.importError != nil, "failed save retains review and decisions for retry")
        try check(model.applyImport(), "retry succeeds after restoring writable storage")

        try prepare([changed]); model.importChoices = [changed.id]
        var external = model.resources; external[0].notes = "Newer edit from another window"
        try store.save(external)
        let externalBytes = try Data(contentsOf: store.url)
        try check(!model.applyImport() && Data(contentsOf: store.url) == externalBytes, "stale review cannot overwrite newer disk state")
        model.refreshImportReview()
        try check(model.resources == external && model.importChoices.isEmpty && model.importReview?.baseline == external, "Review again reloads latest state and resets decisions")
        model.cancelImport()

        let beforeBad = try Data(contentsOf: store.url)
        let badInputs = [Data("malformed".utf8), try JSONEncoder().encode(DemoLibraryDocument(version: 99, resources: [])), Data(repeating: 32, count: DemoLibraryStore.byteLimit + 1), try JSONEncoder().encode(DemoLibraryDocument(resources: [first, first])), try JSONEncoder().encode(DemoLibraryDocument(resources: [DemoResource(title: "")]))]
        for data in badInputs {
            try data.write(to: exchange)
            model.prepareImport(from: exchange)
            try check(model.importReview == nil && model.error != nil && model.resources == external && Data(contentsOf: store.url) == beforeBad, "invalid or oversized input rejected without mutation")
        }

        let full = (0..<DemoLibraryStore.limit).map { DemoResource(title: "Item \($0)", content: "Synthetic") }
        let over = try DemoLibraryImport(incoming: [missing], existing: full, sourceName: "Capacity test")
        var rejected = false
        do { _ = try over.applying(useIncoming: []) } catch { rejected = true }
        try check(rejected, "merged capacity checked before write")
        let perms = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        try check(perms?.intValue == 0o600, "committed library remains private")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".library-") }
        try check(leftovers.isEmpty, "staging files cleaned after successful and failed writes")
        print("LIBRARY_IMPORT_CHECKS_OK: \(count) checks; actual model/store, synthetic files, no live user data")
    }
}
