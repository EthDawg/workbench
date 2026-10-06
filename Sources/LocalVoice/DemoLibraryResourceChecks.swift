import AppKit

/// Exercises resource admission and failure boundaries through the production
/// owner. File choice, clipboard and URL launch are injected; originals stay local.
@MainActor enum DemoLibraryResourceChecks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-Resources-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw VoiceError.message("LIBRARY_RESOURCE_CHECK_FAILED: " + name) }
            count += 1
        }
        let original = root.appendingPathComponent("Original.txt"), replacement = root.appendingPathComponent("Replacement.txt")
        let originalBytes = Data("Original material stays here.\r\n".utf8)
        try originalBytes.write(to: original)
        try Data("Different material chosen explicitly.".utf8).write(to: replacement)
        let store = DemoLibraryStore(directory: root.appendingPathComponent("Library"))
        let exact = "  e\u{301}\r\n" + String(repeating: "Long complete prompt.\n", count: 1_000) + "\tEnd.  "
        let prompt = DemoResource(title: "Saved Read text", product: "Retained product", persona: "Retained persona", content: exact, favorite: true)
        let file = DemoResource(kind: .file, title: "Reference", content: original.path, notes: "Keep these notes")
        try store.save([prompt, file])
        let before = try Data(contentsOf: store.url)
        var copied: [String] = [], opened: [URL] = [], choices = 0
        let library = DemoLibraryModel(store: store, copyText: { copied.append($0); return copied.count },
            openURL: { opened.append($0); return true }, chooseFileURL: { choices += 1; return nil })

        library.newPrompt(exact)
        try check(Data(library.draft!.content.utf8) == Data(exact.utf8), "prompt editor receives complete text without normalization")
        library.draft = nil
        try check(Data(contentsOf: store.url) == before, "Cancel does not save the editor's text")
        library.newPrompt(String(repeating: "x", count: DemoResource.promptCharacterLimit + 1))
        try check(library.draft == nil && library.error?.contains("nothing was truncated") == true
                  && Data(contentsOf: store.url) == before, "oversized prompt is refused with file guidance and no save")
        library.newPrompt(String(repeating: "x", count: DemoResource.promptCharacterLimit))
        try check(library.draft?.content.count == DemoResource.promptCharacterLimit, "the established exact prompt limit remains admitted")
        library.draft = nil

        library.selection = prompt.id
        try check(library.performPrimaryAction(expectedID: prompt.id) && Data(copied.last!.utf8) == Data(exact.utf8), "Copy uses the complete selected prompt")
        library.selection = file.id
        try check(!library.performPrimaryAction(expectedID: prompt.id) && opened.isEmpty && copied.count == 1,
                  "an old rendered action cannot act on the newly selected row")
        try check(file.fileName == "Original.txt" && file.fileLocation == root.lastPathComponent && file.primaryActionTitle == "Open file",
                  "available file projects a filename and short folder with Open")
        library.chooseFile(for: file, chooseURL: { nil })
        try check(library.draft == nil && Data(contentsOf: store.url) == before, "cancelled file choice preserves the existing reference")
        library.chooseFile(for: file, chooseURL: { replacement }, makeBookmark: { _ in throw VoiceError.message("Synthetic bookmark failure") })
        try check(library.draft == nil && library.error != nil && Data(contentsOf: store.url) == before,
                  "failed access preparation leaves the old reference intact")
        library.chooseFile(for: file, chooseURL: { replacement })
        try check(library.draft?.id == file.id && library.draft?.content == replacement.path && library.draft?.notes == file.notes
                  && library.resources.contains(file) && Data(contentsOf: store.url) == before,
                  "file replacement is a draft retaining identity and metadata until Save")
        library.draft = nil
        try check(library.resources.contains(file), "cancelling replacement retains the original reference")
        library.chooseFile(for: file, chooseURL: { replacement })
        let proposed = library.draft!
        try check(library.save(proposed), "explicit Save commits the chosen reference")
        library.draft = nil
        let committed = library.resources.first { $0.id == file.id }!
        try check(committed.content == replacement.path && committed.notes == file.notes && library.notice == "Saved.",
                  "saved file retains metadata and uses unambiguous feedback")
        library.remove(file)
        try check(library.resources.contains(committed), "a stale removal snapshot cannot delete an updated record")
        try FileManager.default.removeItem(at: replacement)
        try check(committed.primaryActionTitle == "Locate file…" && committed.primaryActionAvailable,
                  "a missing file offers Locate as its useful primary action")
        try check(library.performPrimaryAction(expectedID: committed.id) && choices == 1 && opened.isEmpty,
                  "missing-file Return reaches explicit choice; Cancel starts and opens nothing")
        try check(Data(contentsOf: original) == originalBytes, "replacement, cancellation and missing-file recovery never alter the original")

        // A whole-store failure has a separate persistent projection. A successful
        // action on retained material cannot turn it into an editable empty store.
        var newer = library.resources
        newer.append(DemoResource(title: "External addition", content: "Keep this newer resource."))
        let newerBytes = try store.save(newer)
        try check(!library.save(DemoResource(title: "Attempted edit", content: "Cannot overwrite newer data."))
                  && library.savingDisabled && library.storageFailure != nil && Data(contentsOf: store.url) == newerBytes,
                  "external replacement pauses writes and preserves the newer file")
        let failure = library.storageFailure
        library.copy(prompt)
        library.newPrompt("Cannot start an edit")
        try check(library.storageFailure == failure && library.savingDisabled && library.draft == nil && copied.last == exact,
                  "Copy remains useful while the persistent storage failure and write hold survive")
        let corruptStore = DemoLibraryStore(directory: root.appendingPathComponent("Corrupt"))
        try FileManager.default.createDirectory(at: corruptStore.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corruptBytes = Data("synthetic unreadable library".utf8)
        try corruptBytes.write(to: corruptStore.url)
        let corrupt = DemoLibraryModel(store: corruptStore, copyText: { _ in 1 }, openURL: { _ in false })
        corrupt.newPrompt("Cannot replace the unreadable saved work")
        try check(corrupt.resources.isEmpty && corrupt.savingDisabled && corrupt.storageFailure != nil && corrupt.draft == nil
                  && Data(contentsOf: corruptStore.url) == corruptBytes, "corrupt storage is held and never rewritten as an empty Library")
        print("LIBRARY_RESOURCE_CHECKS_OK: \(count) checks; synthetic stores and injected actions only")
    }
}
