import Foundation

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
        print("DEMO_LIBRARY_MODEL_CHECKS_OK: selection, exact file paths, and unfinished drafts preserved; prompt creation resumes after dismissal")
    }
}
