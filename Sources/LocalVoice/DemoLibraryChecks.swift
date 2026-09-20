import AppKit
import QuickLookUI

@MainActor
private final class DemoLibraryPreviewSpy: DemoResourcePreviewing {
    var onClose: (() -> Void)?
    var succeeds = true
    private(set) var shown: [(url: URL, title: String)] = []

    @discardableResult func show(url: URL, title: String) -> Bool {
        guard succeeds else { return false }
        shown.append((url, title))
        return true
    }

    func close() { onClose?() }
}

enum DemoLibraryChecks {
    static func run() throws {
        var passed = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw VoiceError.message("DEMO LIBRARY CHECK FAILED: \(name)") }
            passed += 1; print("PASS: \(name)")
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { passed += 1; print("PASS: \(name)"); return }
            throw VoiceError.message("DEMO LIBRARY CHECK FAILED: \(name)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-library-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DemoLibraryStore(directory: directory)
        try check(store.load().isEmpty, "library first launch is empty")
        let prompt = DemoResource(title: "Recruiting follow-up", product: "People", persona: "Hiring manager", content: "Ask about the candidate's availability.\nKeep it brief.", notes: "After the interview", favorite: true, bookmark: Data([1, 2, 3]))
        let link = DemoResource(kind: .link, title: "Portal", product: "People", content: "https://example.com/demo?step=2")
        let fileURL = directory.appendingPathComponent("Walkthrough.txt")
        try store.save([prompt, link])
        let file = DemoResource(kind: .file, title: "Walkthrough", product: "People", content: fileURL.path)
        try Data("offline walkthrough".utf8).write(to: fileURL)
        try store.save([prompt, link, file])
        try check(store.load() == [prompt, link, file], "library metadata and multiline prompts survive restart")
        try check(file.fileAvailable, "local availability is checked against a readable file")
        try check(file.canOpenFile, "ordinary document can open in its default app")
        try check(file.canPreviewFile, "ordinary text file is eligible for Quick Look")
        for suffix in ["png", "pdf", "mov"] {
            let previewURL = directory.appendingPathComponent("Synthetic.\(suffix)")
            try Data("synthetic".utf8).write(to: previewURL)
            let preview = DemoResource(kind: .file, title: suffix.uppercased(), content: previewURL.path)
            try check(preview.canPreviewFile, "\(suffix) file is eligible for Quick Look")
        }
        let unsupportedURL = directory.appendingPathComponent("Synthetic.bin")
        try Data([0, 1, 2, 3]).write(to: unsupportedURL)
        try check(!DemoResource(kind: .file, title: "Binary", content: unsupportedURL.path).canPreviewFile,
                  "unknown binary file is not falsely advertised as previewable")
        var renamedResource = file
        renamedResource.bookmark = try fileURL.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        let renamedURL = directory.appendingPathComponent("Renamed walkthrough.txt")
        try FileManager.default.moveItem(at: fileURL, to: renamedURL)
        let renamedExport = try DemoLibraryStore.decode(DemoLibraryStore.encoded([renamedResource], portable: true))
        try check(renamedExport.first?.fileURL?.resolvingSymlinksInPath() == renamedURL.resolvingSymlinksInPath() && renamedExport.first?.fileAvailable == true, "export follows the current bookmarked file after a rename")
        try FileManager.default.moveItem(at: renamedURL, to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.path)
        try check(!file.canOpenFile, "executable files cannot be launched as demo resources")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try FileManager.default.removeItem(at: fileURL)
        try check(!file.fileAvailable, "missing file is detected without deleting its resource")
        try check(DemoResource.matching([link, prompt, file], query: "people HIRING").map(\.id) == [prompt.id], "search combines product and persona words case-insensitively")
        try check(DemoResource.matching([link, prompt], query: "interview").first?.id == prompt.id, "preparation notes are searchable")
        try check(DemoResource.matching([link, prompt], query: "").first?.id == prompt.id, "favorite resources are first")
        try check(DemoResource.matching([link, prompt], query: "", favoritesOnly: true).map(\.id) == [prompt.id], "favorite filtering is explicit")
        try check(DemoResource.matching([link, prompt], query: "recruiting nonexistent").isEmpty, "every search term must match")
        try check(link.webURL?.host == "example.com", "ordinary web links are accepted")
        for address in ["javascript:alert(1)", "file:///tmp/demo", "https://user:password@example.com", "https://", "x-apple.systempreferences:com.apple.preference.security"] {
            try check(DemoResource(kind: .link, title: "Unsafe", content: address).validationMessage != nil, "invalid or command URL rejected: \(address.prefix(18))")
        }
        try check(DemoResource(title: " ", content: "hello").validationMessage != nil, "unnamed resource rejected")
        try check(DemoResource(title: "Empty", content: " \n ").validationMessage != nil, "empty prompt rejected")
        try check(DemoResource(kind: .file, title: "Relative", content: "video.mp4").validationMessage != nil, "relative file path rejected")
        let exported = try DemoLibraryStore.decode(DemoLibraryStore.encoded([prompt, link, file], portable: true))
        try check(exported[0].bookmark == nil && exported[0].content == prompt.content, "portable export omits local access grants and preserves content")
        try check(exported[2].content == file.content, "portable export retains references without copying media")
        var edited = prompt; edited.content = "An imported edit"
        let merged = try DemoLibraryStore.merging([edited, file], into: [prompt, link])
        try check(merged.count == 3 && merged.first?.content == prompt.content, "import preserves existing resources by identity")
        try check(DemoLibraryStore.merging(merged, into: merged) == merged, "reimport does not duplicate resources")
        try check(DemoLibraryStore.merging([prompt], into: []).first?.bookmark == nil, "import strips untrusted local access bookmarks")
        try rejects("duplicate resource IDs are rejected before saving") { try store.save([prompt, prompt]) }
        try check(store.load().count == 3, "failed save leaves the existing library intact")
        let future = try JSONEncoder().encode(DemoLibraryDocument(version: 99, resources: [prompt]))
        try rejects("future library versions are rejected") { _ = try DemoLibraryStore.decode(future) }
        try rejects("invalid imported resource rejects the whole import") { _ = try DemoLibraryStore.merging([DemoResource(title: "")], into: [prompt]) }
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "library is private to current user")
        try Data("broken library".utf8).write(to: store.url)
        try rejects("damaged library reports an error") { _ = try store.load() }
        try check(String(contentsOf: store.url, encoding: .utf8) == "broken library", "damaged library is not silently replaced")
        var oldPreferences = VoicePreferences(); oldPreferences.dictationShortcut.keyCode = 42; oldPreferences.restoreClipboard = false
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldPreferences)) as! [String: Any]
        oldJSON.removeValue(forKey: "libraryShortcut")
        oldJSON.removeValue(forKey: "readbackShortcut")
        let migrated = try JSONDecoder().decode(VoicePreferences.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try check(migrated.dictationShortcut == oldPreferences.dictationShortcut && !migrated.restoreClipboard, "adding library shortcut preserves older voice settings")
        try check(migrated.shortcut(3) == VoicePreferences().shortcut(3), "older preferences receive only the new library shortcut default")
        try check(migrated.shortcut(4) == VoicePreferences().shortcut(4), "older preferences receive the new readback shortcut default")
        var disabled = migrated; var shortcut = disabled.shortcut(3); shortcut.enabled = false; disabled.setShortcut(shortcut, for: 3)
        let roundtrip = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(disabled))
        try check(!roundtrip.shortcut(3).enabled, "disabled library shortcut stays disabled after restart")
        print("DEMO_LIBRARY_CHECKS_OK: \(passed) checks passed")
    }

    @MainActor static func runModelChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-library-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DemoLibraryStore(directory: directory)
        let first = DemoResource(title: "First prompt", content: "First", favorite: true)
        let second = DemoResource(title: "Second prompt", content: "Second")
        try store.save([first, second])
        let model = DemoLibraryModel(store: store)
        guard model.selection == first.id && model.selected?.id == first.id else { throw VoiceError.message("Library initial row selection does not match the visible detail") }
        model.query = "Second"
        guard model.selection == second.id && model.selected?.id == second.id else { throw VoiceError.message("Library filtered row selection does not match the visible detail") }
        model.favoritesOnly = true
        guard model.selection == nil && model.selected == nil else { throw VoiceError.message("Library retains a selection outside visible results") }
        let spacedURL = directory.appendingPathComponent("file with trailing space ")
        try Data("demo".utf8).write(to: spacedURL)
        let spaced = DemoResource(kind: .file, title: "Spaced path", content: spacedURL.path)
        guard model.save(spaced), model.selected?.content == spacedURL.path, model.selected?.fileAvailable == true else { throw VoiceError.message("Saving a file altered its exact path") }
        guard model.selection == spaced.id && !model.favoritesOnly && model.query.isEmpty else { throw VoiceError.message("Saving a new resource while filtering did not select that resource") }
        model.remove(spaced)
        guard model.selection == model.matches.first?.id && model.selected != nil else { throw VoiceError.message("Removing a resource left the visible detail without a selected row") }
        guard model.save(spaced) else { throw VoiceError.message("Exact path test could not restore its file resource") }
        let restored = DemoLibraryModel(store: store)
        guard restored.resources.first(where: { $0.id == spaced.id })?.content == spacedURL.path else { throw VoiceError.message("Exact file path was not preserved across restart") }
        for kind in DemoResourceKind.allCases {
            let unfinished = DemoResource(kind: kind, title: "Unfinished resource", product: "People", persona: "Manager", content: "Keep this draft", notes: "Unfinished notes")
            model.draft = unfinished
            model.newPrompt("New clipboard text")
            guard model.draft == unfinished && model.draftNotice != nil else { throw VoiceError.message("Clipboard prompt replaced an unfinished \(kind.rawValue.lowercased()) draft") }
            model.newPrompt()
            guard model.draft == unfinished else { throw VoiceError.message("New prompt replaced an unfinished resource draft") }
            model.draft = nil
            guard model.draftNotice == nil else { throw VoiceError.message("Draft notice remained after finishing the editor") }
        }
        model.newPrompt("Next prompt")
        guard model.draft?.content == "Next prompt" && model.draftNotice == nil else { throw VoiceError.message("Prompt creation did not resume after finishing the editor") }

        let previewDirectory = directory.appendingPathComponent("quick-look")
        let previewStore = DemoLibraryStore(directory: previewDirectory)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        let oldURL = previewDirectory.appendingPathComponent("Preview before rename.txt")
        let movedURL = previewDirectory.appendingPathComponent("Preview after rename.txt")
        try Data("Synthetic preview text".utf8).write(to: oldURL)
        var previewItem = DemoResource(kind: .file, title: "Preview fixture", content: oldURL.path)
        previewItem.bookmark = try oldURL.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        let unsupportedURL = previewDirectory.appendingPathComponent("Unsupported.bin")
        try Data([0, 1, 2, 3]).write(to: unsupportedURL)
        let unsupported = DemoResource(kind: .file, title: "Unsupported fixture", content: unsupportedURL.path)
        try previewStore.save([previewItem, unsupported])
        try FileManager.default.moveItem(at: oldURL, to: movedURL)

        let previewer = DemoLibraryPreviewSpy()
        var accessStarts = 0, accessStops = 0
        let previewModel = DemoLibraryModel(
            store: previewStore,
            previewer: previewer,
            makePreviewAccess: { url in
                DemoResourcePreviewAccess(url: url, start: { _ in accessStarts += 1; return true }, stop: { _ in accessStops += 1 })
            }
        )
        previewModel.query = "Preview fixture"
        let selectionBeforePreview = previewModel.selection
        guard let resolvedPreview = previewModel.selected else { throw VoiceError.message("Quick Look fixture did not resolve after rename") }
        previewModel.preview(resolvedPreview)
        guard previewer.shown.last?.url.resolvingSymlinksInPath() == movedURL.resolvingSymlinksInPath(),
              previewModel.previewingResourceID == resolvedPreview.id,
              accessStarts == 1, accessStops == 0 else {
            throw VoiceError.message("Quick Look did not retain access to the resolved file for the panel lifetime")
        }
        guard previewModel.query == "Preview fixture", previewModel.selection == selectionBeforePreview else {
            throw VoiceError.message("Opening Quick Look changed library search or selection")
        }
        guard let refreshedPath = previewModel.resources.first(where: { $0.id == resolvedPreview.id })?.content,
              URL(fileURLWithPath: refreshedPath).resolvingSymlinksInPath() == movedURL.resolvingSymlinksInPath() else {
            throw VoiceError.message("Quick Look did not refresh a moved file bookmark")
        }
        previewer.close()
        guard previewModel.previewingResourceID == nil, accessStops == 1,
              previewModel.query == "Preview fixture", previewModel.selection == selectionBeforePreview else {
            throw VoiceError.message("Closing Quick Look did not release access while preserving library context")
        }

        previewModel.query = "Unsupported fixture"
        guard let unsupportedItem = previewModel.selected else { throw VoiceError.message("Unsupported Quick Look fixture was not selectable") }
        let shownBeforeFailure = previewer.shown.count
        previewModel.preview(unsupportedItem)
        guard previewer.shown.count == shownBeforeFailure,
              previewModel.previewingResourceID == nil,
              previewModel.error?.contains("does not support") == true,
              accessStarts == 2, accessStops == 2 else {
            throw VoiceError.message("Unsupported Quick Look input reported success or retained access")
        }

        try FileManager.default.removeItem(at: unsupportedURL)
        previewModel.preview(unsupportedItem)
        guard previewer.shown.count == shownBeforeFailure,
              previewModel.error?.contains("unavailable") == true,
              accessStarts == 3, accessStops == 3 else {
            throw VoiceError.message("Missing Quick Look input did not report recovery or release access")
        }

        previewModel.query = "Preview fixture"
        guard let retryItem = previewModel.selected else { throw VoiceError.message("Quick Look retry fixture was not selectable") }
        previewer.succeeds = false
        previewModel.preview(retryItem)
        guard previewModel.previewingResourceID == nil,
              previewModel.error?.contains("could not open") == true,
              accessStarts == 4, accessStops == 4 else {
            throw VoiceError.message("Failed Quick Look presentation retained scoped access")
        }
        previewer.succeeds = true
        previewModel.preview(retryItem)
        guard previewModel.previewingResourceID == retryItem.id, accessStarts == 5, accessStops == 4 else {
            throw VoiceError.message("Quick Look did not recover after a presentation failure")
        }
        previewModel.remove(retryItem)
        guard previewModel.previewingResourceID == nil, accessStops == 5 else {
            throw VoiceError.message("Removing a previewed resource did not close Quick Look and release access")
        }
        print("DEMO_LIBRARY_MODEL_CHECKS_OK: selection, drafts, Quick Look lifecycle, moved bookmarks, failures, and access release passed")
    }

    @MainActor static func runQuickLookPanelChecks(_ urls: [URL]) throws {
        guard !urls.isEmpty else { throw VoiceError.message("Choose at least one synthetic file to preview.") }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.title = "Workbench Quick Look check"
        owner.center()
        owner.makeKeyAndOrderFront(nil)
        defer { owner.close() }

        let presenter = DemoQuickLookPresenter()
        var closeCount = 0
        presenter.onClose = { closeCount += 1 }
        for url in urls {
            guard FileManager.default.isReadableFile(atPath: url.path), DemoResourcePreviewPolicy.supports(url) else {
                throw VoiceError.message("Quick Look fixture is unavailable or unsupported: \(url.lastPathComponent)")
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 50_000_000 else { throw VoiceError.message("Quick Look fixture is too large: \(url.lastPathComponent)") }
            let before = try Data(contentsOf: url)
            let expectedCloseCount = closeCount + 1
            guard presenter.show(url: url, title: "Synthetic \(url.lastPathComponent)") else {
                throw VoiceError.message("Quick Look panel did not open for \(url.lastPathComponent)")
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            guard let panel = presenter.panel, panel.isVisible,
                  let preview = panel.contentView as? QLPreviewView,
                  (preview.previewItem as? NSURL)?.filePathURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else {
                throw VoiceError.message("Quick Look panel did not retain the requested file: \(url.lastPathComponent)")
            }
            panel.cancelOperation(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            guard presenter.panel == nil, closeCount == expectedCloseCount, owner.isVisible,
                  try Data(contentsOf: url) == before else {
                throw VoiceError.message("Escape did not close only Quick Look or the source changed: \(url.lastPathComponent)")
            }
        }
        print("QUICK_LOOK_PANEL_CHECKS_OK: \(urls.count) native previews opened and Escape closed only their panel")
    }
}
