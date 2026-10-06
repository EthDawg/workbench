import Foundation
import ToolbarCore

/// All records and failures below belong to a new temporary directory. No
/// voice, recognition engine, clipboard, credential or installed app is used.
@MainActor enum ReadRetirementChecks {
    static func run() throws {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw VoiceError.message("Read retirement: " + name) }
            count += 1
        }
        func rejects(_ name: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { count += 1; return }
            throw VoiceError.message("Read retirement accepted: " + name)
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Workbench-Read-retirement-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func folder(_ name: String) throws -> URL {
            let result = root.appendingPathComponent(name)
            try fm.createDirectory(at: result, withIntermediateDirectories: true)
            return result
        }
        func library(_ directory: URL) -> DemoLibraryModel { DemoLibraryModel(store: DemoLibraryStore(directory: directory)) }
        func file(_ directory: URL) -> URL { directory.appendingPathComponent(ReadRetirement.fileName) }
        func receipt(_ directory: URL) -> URL { directory.appendingPathComponent(ReadRetirement.receiptName) }
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        let text = " \r\ne\u{301}\t🐦\r\n" + String(repeating: "x", count: 999_990) + " \t\r\n"
        let bytes = Data(text.utf8)

        let exact = try folder("exact"), stateStore = StateStore(directory: exact)
        var original = SavedState(draft: "Independent Dictate draft", speechText: text,
                                  voice: "Legacy provider voice", rate: 197.5, rawDraft: "Original Dictate wording")
        original.replacements = [Replacement(heard: "work bench", written: "Workbench")]
        try stateStore.save(original)
        let originalStateBytes = try Data(contentsOf: stateStore.url)
        let first = library(exact)
        first.preserveRetiredReading(try stateStore.load().speechText)
        try check(first.readPreservationFailure == nil && first.resources.count == 1, "complete legacy draft becomes one Library item")
        try check(first.resources[0].id == ReadRetirement.resourceID && first.resources[0].kind == .file && first.resources[0].canPreviewFile,
                  "the preserved draft is an ordinary previewable file, never a truncated prompt")
        try check(try Data(contentsOf: file(exact)) == bytes && Data(contentsOf: stateStore.url) == originalStateBytes,
                  "large decomposed Unicode, CRLF and whitespace bytes and original state remain exact")
        try check((try fm.attributesOfItem(atPath: file(exact).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  "the file is private")
        let completedReceipt = try Data(contentsOf: receipt(exact))
        for _ in 0..<2 {
            let next = library(exact), restored = try stateStore.load()
            next.preserveRetiredReading(restored.speechText)
            try check(next.readPreservationFailure == nil && next.resources.count == 1 && next.resources[0].id == ReadRetirement.resourceID,
                      "relaunch reuses the committed identity")
            try check(try Data(contentsOf: file(exact)) == bytes && Data(contentsOf: receipt(exact)) == completedReceipt,
                      "relaunch changes neither file nor receipt")
            try check(Data(restored.speechText.utf8) == bytes && restored.voice == original.voice && restored.rate == original.rate
                      && restored.draft == original.draft && restored.rawDraft == original.rawDraft && restored.replacements == original.replacements,
                      "dormant fields and unrelated saved state roundtrip")
            try stateStore.save(restored)
        }
        first.remove(first.resources[0]); try fm.removeItem(at: file(exact))
        let deleted = library(exact); deleted.preserveRetiredReading(try stateStore.load().speechText)
        try check(deleted.resources.isEmpty && deleted.readPreservationFailure == nil && !exists(file(exact)),
                  "valid separate receipt prevents resurrection after deliberate record and file deletion")

        let empty = try folder("empty"), fresh = library(empty)
        fresh.preserveRetiredReading("")
        try check(fresh.resources.isEmpty && fresh.readPreservationFailure == nil && !exists(receipt(empty)) && !exists(file(empty)),
                  "fresh empty profiles get no file, receipt or notice")
        fresh.preserveRetiredReading(" \t\r\n")
        try check(try Data(contentsOf: file(empty)) == Data(" \t\r\n".utf8), "nonempty whitespace is preserved")

        let full = try folder("full"), fullStore = DemoLibraryStore(directory: full)
        let retained = (0..<DemoLibraryStore.limit).map { DemoResource(title: "Synthetic \($0)", content: "Kept") }
        try fullStore.save(retained)
        let beforeFull = try Data(contentsOf: fullStore.url), crowded = library(full)
        crowded.preserveRetiredReading(text)
        try check(crowded.readPreservationFailure != nil && crowded.resources == retained && !exists(receipt(full)),
                  "a full Library reports recovery without recording completion")
        try check(try Data(contentsOf: file(full)) == bytes && Data(contentsOf: fullStore.url) == beforeFull,
                  "full Library retains the exact staged file and prior Library")
        crowded.remove(retained[0]); crowded.retryReadPreservation()
        try check(crowded.readPreservationFailure == nil && crowded.resources.count == DemoLibraryStore.limit
                  && crowded.resources.filter { $0.id == ReadRetirement.resourceID }.count == 1,
                  "contextual retry succeeds once room is available, without duplicates")

        for newer in [false, true] {
            let directory = try folder(newer ? "newer-library" : "corrupt-library")
            let store = DemoLibraryStore(directory: directory)
            if !newer { try Data("not a Library".utf8).write(to: store.url) }
            let model = library(directory)
            if newer { try store.save([DemoResource(title: "Another window's resource", content: "Keep")]) }
            let before = try Data(contentsOf: store.url)
            model.preserveRetiredReading(text)
            try check(model.readPreservationFailure != nil && !exists(receipt(directory)) && Data(contentsOf: store.url) == before,
                      "corrupt or newer Library is never overwritten")
            try check(try Data(contentsOf: file(directory)) == bytes, "uncommitted preservation file remains recoverable")
        }

        for stage in ["file-write", "file-readback", "receipt-write", "receipt-readback"] {
            let directory = try folder(stage), model = library(directory)
            var io = ReadRetirement.IO()
            io.writeNew = { data, url in
                if stage == "file-write" && url == file(directory) || stage == "receipt-write" && url == receipt(directory) {
                    throw VoiceError.message("Synthetic unavailable storage")
                }
                try ReadRetirement.writeNew(data, url)
            }
            io.read = { url, limit in
                if stage == "file-readback" && url == file(directory) || stage == "receipt-readback" && url == receipt(directory) {
                    throw VoiceError.message("Synthetic readback failure")
                }
                return try ReadRetirement.read(url, maximumBytes: limit)
            }
            try rejects(stage) { try ReadRetirement.preserve(text, in: model, io: io) }
            if stage != "receipt-readback" { try check(!exists(receipt(directory)), "failure before receipt leaves no completion receipt") }
            if stage == "receipt-write" {
                try check(model.resources.count == 1 && Data(contentsOf: file(directory)) == bytes,
                          "crash after reference commit retains file and reference without claiming completion")
            }
            let relaunched = library(directory); relaunched.preserveRetiredReading(text)
            try check(relaunched.readPreservationFailure == nil && relaunched.resources.count == 1
                      && Data(contentsOf: file(directory)) == bytes, "relaunch repairs the incomplete stage without duplication")
        }

        for content in [Data("malformed".utf8), try JSONEncoder().encode(ReadRetirement.Receipt(digest: "different"))] {
            let directory = try folder(UUID().uuidString)
            try ReadRetirement.writeNew(content, receipt(directory))
            let model = library(directory); model.preserveRetiredReading(text)
            try check(model.readPreservationFailure != nil && model.resources.isEmpty && !exists(file(directory))
                      && Data(contentsOf: receipt(directory)) == content, "malformed or conflicting receipt stays untouched")
        }
        let conflict = try folder("unicode-conflict"), conflictModel = library(conflict)
        try ReadRetirement.writeNew(Data("é".utf8), file(conflict))
        conflictModel.preserveRetiredReading("e\u{301}")
        try check(conflictModel.readPreservationFailure != nil && !exists(receipt(conflict)) && Data(contentsOf: file(conflict)) == Data("é".utf8),
                  "canonically equal but byte-different text is a conflict")
        try fm.removeItem(at: file(conflict)); conflictModel.retryReadPreservation()
        try check(conflictModel.readPreservationFailure == nil && Data(contentsOf: file(conflict)) == Data("e\u{301}".utf8),
                  "Library retry uses the retained exact source")
        let linked = try folder("linked"), outside = linked.appendingPathComponent("other.txt")
        try bytes.write(to: outside)
        try fm.createSymbolicLink(at: file(linked), withDestinationURL: outside)
        try rejects("linked file") { try ReadRetirement.preserve(text, in: library(linked)) }
        try check(try Data(contentsOf: outside) == bytes && !exists(receipt(linked)), "a link never redirects preservation")
        let editing = try folder("editing"), editor = library(editing)
        editor.newPrompt("Current edit"); editor.preserveRetiredReading(text)
        try check(editor.draft?.content == "Current edit" && editor.readPreservationFailure != nil && !exists(file(editing)),
                  "retry leaves an active Library edit intact")

        var preferences = VoicePreferences()
        preferences.setShortcut(VoiceShortcut(keyCode: 20, enabled: true), for: 6)
        let restoredPreferences = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(preferences))
        try check(restoredPreferences.shortcut(6) == preferences.shortcut(6) && !VoicePreferences.shortcutIDs.contains(6)
                  && !restoredPreferences.enabledCombinations.contains(preferences.shortcut(6).combination),
                  "enabled legacy Read shortcut roundtrips but never registers")
        try check(VoicePreferences.shortcutIDs.contains(5) && !VoicePreferences.shortcutIDs.contains(4), "Snap & Talk remains active and browser shortcut remains paused")
        try check(ToolbarMode(rawValue: "read") == nil && WorkbenchHome.destination("speak").page == "library"
                  && WorkbenchHome.destination("speak").section == "library",
                  "old toolbar cannot reopen Read and the old page lands on Library resources")
        try check(!AppDelegate.instancesRespond(to: NSSelectorFromString("readSelection:userData:error:"))
                  && !AppModel.instancesRespond(to: NSSelectorFromString("readSelection:userData:error:")),
                  "the old macOS Service callback has no runtime recipient")
        print("Read retirement: \(count) checks passed")
    }
}
