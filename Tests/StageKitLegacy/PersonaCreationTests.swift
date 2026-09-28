import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// New editable portraits are drafts until Add persona (#172). Choosing a
/// picture or a starter, editing its label and colour, and Cancel or Escape
/// (both simply drop the editor's draft) save nothing: the saved items, the
/// selection, group membership and every file stay as they were. Add saves
/// once; a failed Add keeps the draft so the same Add can be tried again.
final class PersonaCreationTests {
    private struct Fixture {
        let root: URL
        let store: URL
        let source: URL
        let library: PersonaLibrary
        let starters: PersonaStarterLibrary
        let existing: [SavedPersona]
        let group: UUID
    }
    /// What must not change before Add: the library's records and every file it owns.
    private struct Snapshot: Equatable {
        let items: [SavedPersona]
        let selectedID: UUID?
        let groups: [PersonaGroup]
        let activeGroupID: UUID?
        let files: [String: Data]
        let originals: [String: Data]
    }

    private func portraitPNG(width: Int = 36, height: Int = 48) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fillEllipse(in: CGRect(x: 4, y: 2, width: width - 8, height: height - 4))
        let bytes = NSMutableData()
        let output = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(output) else { throw PersonaError.unreadableImage }
        return bytes as Data
    }

    /// An isolated library with a finished image and an editable card, a prepared
    /// group holding the first, and synthetic starter portraits.
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaCreation-" + UUID().uuidString)
        let store = root.appendingPathComponent("library"), portraits = root.appendingPathComponent("portraits")
        try FileManager.default.createDirectory(at: portraits, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Synthetic portrait.png")
        try portraitPNG().write(to: source)
        for starter in PersonaStarterLibrary.portraits { try portraitPNG(width: 40, height: 40).write(to: portraits.appendingPathComponent(starter.filename)) }
        let library = PersonaLibrary(root: store)
        let finished = try library.addImage(source, name: "Synthetic finished")
        let card = try library.addImage(source, name: "Synthetic card", card: PersonaCardStyle(label: "Synthetic lead"))
        let group = try library.createGroup(name: "Synthetic group", members: [finished.id])
        library.selectedID = finished.id
        return Fixture(root: root, store: store, source: source, library: library,
                       starters: PersonaStarterLibrary(directory: portraits), existing: [finished, card], group: group)
    }

    private func snapshot(_ f: Fixture) throws -> Snapshot {
        func files(in directory: URL) throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: directory.path).map {
                ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
            })
        }
        var originals = try files(in: f.root.appendingPathComponent("portraits"))
        originals[f.source.lastPathComponent] = try Data(contentsOf: f.source)
        return Snapshot(items: f.library.items, selectedID: f.library.selectedID, groups: f.library.groups,
                        activeGroupID: f.library.activeGroupID, files: try files(in: f.store), originals: originals)
    }

    func testCancellingANewPortraitAtAnyStepLeavesTheLibraryUnchanged() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        let before = try snapshot(f)
        XCTAssertEqual(before.activeGroupID, f.group)
        XCTAssertEqual(before.selectedID, f.existing[0].id)

        // Import portrait for an editable card: choose, then edit, then Cancel or Escape.
        var imported: PersonaPortraitDraft? = try f.library.portraitDraft(from: f.source, card: PersonaCardStyle())
        XCTAssertEqual(try snapshot(f), before, "Choosing a picture saves nothing")
        imported?.card.label = "Synthetic facilities lead"
        imported?.card.background = InkColor(0.6, 0.2, 0.3)
        XCTAssertEqual(try snapshot(f), before, "Editing the label and colour saves nothing")
        imported = nil // Cancel and Escape both drop the editor's draft.
        XCTAssertEqual(try snapshot(f), before, "Cancel leaves the library, selection, membership and files as they were")

        // Choose a starter portrait: Use portrait, then edit, then Cancel or Escape.
        let portrait = PersonaStarterLibrary.portraits[2]
        var starter: PersonaPortraitDraft? = try f.starters.draft(portrait, for: f.library)
        XCTAssertEqual(starter?.card.label, portrait.label)
        XCTAssertEqual(try snapshot(f), before, "Use portrait saves nothing")
        starter?.card.label = ""
        XCTAssertEqual(try snapshot(f), before)
        starter = nil
        XCTAssertEqual(try snapshot(f), before)

        // Nothing reached the archive either.
        let reopened = PersonaLibrary(root: f.store); defer { reopened.shutdown() }
        XCTAssertEqual(reopened.items, before.items)
        XCTAssertEqual(reopened.selectedID, before.selectedID)
        XCTAssertEqual(reopened.groups, before.groups)
        XCTAssertTrue(imported == nil && starter == nil)
    }

    func testRepeatedCancelsLeaveNoDuplicatesOrFiles() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        let before = try snapshot(f)
        let temporary = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("persona-") }
        for round in 0..<6 {
            var draft = try round.isMultiple(of: 2)
                ? f.library.portraitDraft(from: f.source, card: PersonaCardStyle())
                : f.starters.draft(PersonaStarterLibrary.portraits[round], for: f.library)
            draft.card.label = "Draft \(round)"
            _ = draft // Cancel.
        }
        XCTAssertEqual(try snapshot(f), before, "Six cancelled drafts leave no item, membership or file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("persona-") }, temporary, "Drafts write no temporary files either")
    }

    func testAddSavesOneItemWithOneMembershipOnce() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        let before = try snapshot(f)
        var draft = try f.starters.draft(PersonaStarterLibrary.portraits[0], for: f.library)
        draft.card = PersonaCardStyle(label: "Synthetic reception lead", background: InkColor(0.2, 0.3, 0.6))
        let added = try f.library.add(draft)
        XCTAssertEqual(added.id, draft.id)
        XCTAssertEqual(f.library.items.map(\.id), before.items.map(\.id) + [draft.id], "Exactly one new saved item")
        XCTAssertEqual(f.library.selectedID, draft.id, "Add selects the new persona")
        XCTAssertEqual(f.library.activeGroup?.personaIDs, [f.existing[0].id, draft.id], "One membership, in the active group only")
        XCTAssertEqual(f.library.items.last?.card, draft.card)
        let stored = f.store.appendingPathComponent(added.image)
        XCTAssertEqual(try Data(contentsOf: stored), draft.png, "The chosen picture is saved as chosen")
        let after = try snapshot(f)
        XCTAssertEqual(Set(after.files.keys), Set(before.files.keys).union([added.image]), "One new picture file")
        XCTAssertEqual(after.originals, before.originals, "The chosen file and starters are unchanged")

        // Add again, as a double click would: no second copy, nothing written.
        XCTAssertThrowsError(try f.library.add(draft))
        XCTAssertEqual(try snapshot(f), after)
        let reopened = PersonaLibrary(root: f.store); defer { reopened.shutdown() }
        XCTAssertEqual(reopened.items, f.library.items)
        XCTAssertEqual(reopened.groups, f.library.groups)
        XCTAssertEqual(reopened.selectedID, draft.id)
    }

    func testFailedAddKeepsTheDraftAndRetryAddsExactlyOne() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        let archive = f.store.appendingPathComponent("persona-library.json")

        // The archive changes on disk while the editor is open: Add fails safely.
        var draft = try f.library.portraitDraft(from: f.source, card: PersonaCardStyle(label: "Synthetic site lead"))
        let saved = try Data(contentsOf: archive)
        let before = try snapshot(f)
        try Data("Synthetic concurrent edit".utf8).write(to: archive)
        XCTAssertThrowsError(try f.library.add(draft))
        var failed = before.files; failed["persona-library.json"] = Data("Synthetic concurrent edit".utf8)
        XCTAssertEqual(try snapshot(f).files, failed, "A failed Add leaves no new picture behind")
        XCTAssertEqual(f.library.items, before.items); XCTAssertEqual(f.library.selectedID, before.selectedID)
        XCTAssertEqual(f.library.groups, before.groups)
        // The draft is still whole; once the archive is back, the same Add succeeds once.
        try saved.write(to: archive)
        draft.card.background = InkColor(0.3, 0.3, 0.3)
        let added = try f.library.add(draft)
        XCTAssertEqual(f.library.items.filter { $0.id == draft.id }.count, 1)
        XCTAssertEqual(f.library.items.count, before.items.count + 1)
        XCTAssertEqual(f.library.activeGroup?.personaIDs.filter { $0 == added.id }.count, 1)
        XCTAssertEqual(try Data(contentsOf: f.store.appendingPathComponent(added.image)), draft.png)

        // The library folder cannot be written: Add fails before anything is saved.
        let second = try f.starters.draft(PersonaStarterLibrary.portraits[1], for: f.library)
        let middle = try snapshot(f)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.store.path)
        XCTAssertThrowsError(try f.library.add(second))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.store.path)
        XCTAssertEqual(try snapshot(f), middle, "Nothing is written by an Add that could not save")
        try f.library.add(second)
        XCTAssertEqual(f.library.items.map(\.id), middle.items.map(\.id) + [second.id])
        XCTAssertEqual(Set(try snapshot(f).files.keys).subtracting(middle.files.keys).count, 1, "Retry saves one picture")
    }

    /// Editing a saved card keeps Save and Cancel: until Save, neither the saved
    /// card nor a shown floating copy changes, and a draft made meanwhile is separate.
    func testCancellingAnEditLeavesTheSavedCardAndTheShownCardAlone() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        f.library.usesSharedControls = true
        f.library.prepareGroup(nil)
        f.library.selectedID = f.existing[1].id
        try f.library.showOverlay().get()
        XCTAssertTrue(f.library.overlayVisible)
        let shown = f.library.liveSelection?.currentID
        let before = try snapshot(f)
        var draft = try f.library.portraitDraft(from: f.source, card: PersonaCardStyle(label: "Unsaved"))
        draft.card.label = "Still unsaved"
        _ = draft
        XCTAssertEqual(try snapshot(f), before)
        XCTAssertTrue(f.library.overlayVisible, "A cancelled draft leaves the shown card up")
        XCTAssertEqual(f.library.liveSelection?.currentID, shown)
        XCTAssertEqual(f.library.items.first { $0.id == f.existing[1].id }?.card, PersonaCardStyle(label: "Synthetic lead"))
    }

    /// Set WORKBENCH_LAYOUT_EVIDENCE to render the new-portrait editor and the
    /// saved-card editor, light and dark, from a bundled starter portrait.
    func testOffscreenEditorRenders() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] else { return }
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = PersonaStarterLibrary(directory: repo.appendingPathComponent("Resources/PersonaPortraits"))
        var draft = try bundled.draft(PersonaStarterLibrary.portraits[0], for: f.library)
        draft.card.background = InkColor(0.08, 0.38, 0.31)
        let saved = try f.library.add(try bundled.draft(PersonaStarterLibrary.portraits[3], for: f.library))
        defer { renderIn(nil) }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            renderIn(name == "dark" ? "Dark" : "Light")
            try MainActor.assumeIsolated {
                try render(PersonaCardEditor(library: f.library, subject: .new(draft)), appearance: appearance,
                           to: directory.appendingPathComponent("persona-new-portrait-\(name).png"))
                try render(PersonaCardEditor(library: f.library, subject: .saved(saved)), appearance: appearance,
                           to: directory.appendingPathComponent("persona-edit-card-\(name).png"))
            }
        }
    }
    /// Chooses Workbench's appearance for renders in the argument domain, which is
    /// never saved, so no preference file is written; nil returns to the system's.
    private func renderIn(_ appearance: String?) {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["appearance"] = appearance
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        WorkbenchSettings.shared.refresh()
    }
    @MainActor private func render<V: View>(_ content: V, appearance: NSAppearance.Name, to url: URL) throws {
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        defer { window.close() }
        hosting.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw PersonaError.unreadableImage }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PersonaError.unreadableImage }
        try data.write(to: url)
        print("Offscreen persona editor: " + url.path)
    }

    func testReadOnlyLibraryMakesNoDraft() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        let before = try snapshot(f)
        let blocked = PersonaLibrary(root: f.store, readOnlyReason: "Synthetic read-only library")
        defer { blocked.shutdown() }
        XCTAssertThrowsError(try blocked.portraitDraft(from: f.source, card: PersonaCardStyle()))
        XCTAssertThrowsError(try f.starters.draft(PersonaStarterLibrary.portraits[0], for: blocked))
        XCTAssertEqual(try snapshot(f), before)
    }
}
