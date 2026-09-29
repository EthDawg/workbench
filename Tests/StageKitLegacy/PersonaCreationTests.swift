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
        // The workspace's own editor holder and session. Cancel calls cancel() and
        // closes the sheet, which clears the holder; Escape presses Cancel.
        var editors = PersonaEditorHolder()

        // Import portrait: choose, then edit, then Cancel.
        XCTAssertTrue(editors.open(.new(try f.library.portraitDraft(from: f.source, card: PersonaCardStyle()))))
        XCTAssertEqual(try snapshot(f), before, "Choosing a picture saves nothing")
        editors.current?.style.label = "Synthetic facilities lead"
        editors.current?.style.background = InkColor(0.6, 0.2, 0.3)
        editors.current?.appearance.shape = .card
        editors.current?.appearance.framing = PersonaFraming(x: 0.4, y: 0.6, zoom: 1.5)
        XCTAssertEqual(try snapshot(f), before, "Editing the label, colour, shape and framing saves nothing")
        editors.current?.cancel(); editors.current = nil
        XCTAssertEqual(try snapshot(f), before, "Cancel leaves the library, selection, membership and files as they were")

        // Choose a starter portrait: Use portrait, then edit, then Escape.
        let portrait = PersonaStarterLibrary.portraits[2]
        XCTAssertTrue(editors.open(.new(try f.starters.draft(portrait, for: f.library))))
        XCTAssertEqual(editors.current?.style.label, portrait.label)
        XCTAssertEqual(try snapshot(f), before, "Use portrait saves nothing")
        editors.current?.style.label = ""
        XCTAssertEqual(try snapshot(f), before)
        let escaped = editors.current
        escaped?.cancel(); editors.current = nil
        XCTAssertTrue(escaped?.isFinished == true)
        XCTAssertTrue(escaped?.commit(to: f.library) == true, "A cancelled draft can no longer be added")
        XCTAssertEqual(try snapshot(f), before)

        // Nothing reached the archive either.
        let reopened = PersonaLibrary(root: f.store); defer { reopened.shutdown() }
        XCTAssertEqual(reopened.items, before.items)
        XCTAssertEqual(reopened.selectedID, before.selectedID)
        XCTAssertEqual(reopened.groups, before.groups)
    }

    /// A second import or starter never replaces an open draft or its edits.
    func testASecondDraftNeverReplacesAnOpenOne() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        var editors = PersonaEditorHolder()
        let first = try f.library.portraitDraft(from: f.source, card: PersonaCardStyle())
        XCTAssertTrue(editors.open(.new(first)))
        editors.current?.style.label = "First draft's edits"
        let second = try f.starters.draft(PersonaStarterLibrary.portraits[0], for: f.library)
        XCTAssertFalse(editors.open(.new(second)))
        XCTAssertFalse(editors.open(.saved(f.existing[1])))
        XCTAssertEqual(editors.current?.style.label, "First draft's edits", "The open draft keeps its edits")
        if case .new(let open)? = editors.current?.subject { XCTAssertEqual(open.id, first.id) }
        else { XCTAssertTrue(false, "The first draft stays open") }
    }

    /// A new editor starts without an earlier library notice.
    func testANewDraftClearsAnEarlierNotice() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        f.library.remove(f.existing[1].id)
        XCTAssertNotNil(f.library.notice)
        _ = try f.library.portraitDraft(from: f.source, card: PersonaCardStyle())
        XCTAssertTrue(f.library.notice == nil, "Importing a portrait starts the editor without the old notice")
        f.library.notice = "An earlier message"
        _ = try f.starters.draft(PersonaStarterLibrary.portraits[0], for: f.library)
        XCTAssertTrue(f.library.notice == nil, "So does choosing a starter")
    }

    func testRepeatedCancelsLeaveNoDuplicatesOrFiles() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        let before = try snapshot(f)
        let temporary = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("persona-") }
        var editors = PersonaEditorHolder()
        for round in 0..<6 {
            let draft = try round.isMultiple(of: 2)
                ? f.library.portraitDraft(from: f.source, card: PersonaCardStyle())
                : f.starters.draft(PersonaStarterLibrary.portraits[round], for: f.library)
            XCTAssertTrue(editors.open(.new(draft)))
            editors.current?.style.label = "Draft \(round)"
            editors.current?.cancel(); editors.current = nil
        }
        XCTAssertEqual(try snapshot(f), before, "Six cancelled drafts leave no item, membership or file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("persona-") }, temporary, "Drafts write no temporary files either")
    }

    func testAddSavesOneItemWithOneMembershipOnce() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        let before = try snapshot(f)
        var editors = PersonaEditorHolder()
        let draft = try f.starters.draft(PersonaStarterLibrary.portraits[0], for: f.library)
        XCTAssertTrue(editors.open(.new(draft)))
        guard let session = editors.current else { return }
        session.style = PersonaCardStyle(label: "Synthetic reception lead", background: InkColor(0.2, 0.3, 0.6))
        XCTAssertTrue(session.commit(to: f.library), "Add persona closes the editor")
        XCTAssertEqual(f.library.items.map(\.id), before.items.map(\.id) + [draft.id], "Exactly one new saved item")
        XCTAssertEqual(f.library.selectedID, draft.id, "Add selects the new persona")
        XCTAssertEqual(f.library.activeGroup?.personaIDs, [f.existing[0].id, draft.id], "One membership, in the active group only")
        XCTAssertEqual(f.library.items.last?.card, session.style)
        guard let added = f.library.items.last else { return }
        XCTAssertEqual(try Data(contentsOf: f.store.appendingPathComponent(added.image)), draft.png, "The chosen picture is saved as chosen")
        let after = try snapshot(f)
        XCTAssertEqual(Set(after.files.keys), Set(before.files.keys).union([added.image]), "One new picture file")
        XCTAssertEqual(after.originals, before.originals, "The chosen file and starters are unchanged")

        // Add again, as a double click would: it is already saved, so the editor
        // just closes; there is no second copy and nothing is written.
        XCTAssertThrowsError(try f.library.add(draft))
        XCTAssertTrue(PersonaEditorSession(.new(draft)).commit(to: f.library))
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

        // Another window saves the library while the editor is open: Add reads it
        // again and adds to it, once, keeping the other change.
        let session = PersonaEditorSession(.new(try f.library.portraitDraft(from: f.source, card: PersonaCardStyle(label: "Synthetic site lead"))))
        guard case .new(let draft) = session.subject else { return }
        let elsewhere = PersonaLibrary(root: f.store); defer { elsewhere.shutdown() }
        elsewhere.rename(f.existing[1].id, name: "Renamed in another window")
        XCTAssertTrue(session.commit(to: f.library), "Add succeeds after the library changed on disk")
        XCTAssertEqual(f.library.items.filter { $0.id == draft.id }.count, 1)
        XCTAssertEqual(f.library.items.first { $0.id == f.existing[1].id }?.name, "Renamed in another window", "The other change is kept")
        XCTAssertEqual(f.library.activeGroup?.personaIDs.filter { $0 == draft.id }.count, 1)

        // The archive became unreadable, or was removed: the library cannot be read
        // again, so Add says to reopen Workbench and is not offered as a retry.
        for damage in ["unreadable", "missing"] {
            let blocked = PersonaEditorSession(.new(try f.starters.draft(PersonaStarterLibrary.portraits[3], for: f.library)))
            blocked.style.label = "Kept edits"
            let saved = try Data(contentsOf: archive)
            let before = try snapshot(f)
            if damage == "missing" { try FileManager.default.removeItem(at: archive) }
            else { try Data("Synthetic concurrent edit".utf8).write(to: archive) }
            XCTAssertFalse(blocked.commit(to: f.library))
            XCTAssertTrue(blocked.failure?.contains("Reopen Workbench") == true, "The \(damage) library says to reopen Workbench")
            XCTAssertFalse(blocked.canRetry, "Add is not offered again for a \(damage) library")
            XCTAssertFalse(blocked.isFinished, "The draft stays open")
            XCTAssertEqual(blocked.style.label, "Kept edits")
            var damaged = before.files
            if damage == "missing" { damaged["persona-library.json"] = nil } else { damaged["persona-library.json"] = Data("Synthetic concurrent edit".utf8) }
            XCTAssertEqual(try snapshot(f).files, damaged, "A failed Add leaves no new picture and does not overwrite the \(damage) file")
            XCTAssertEqual(f.library.items, before.items); XCTAssertEqual(f.library.selectedID, before.selectedID)
            try saved.write(to: archive)
        }

        // The library folder cannot be written: Add fails before anything is saved.
        let third = PersonaEditorSession(.new(try f.starters.draft(PersonaStarterLibrary.portraits[1], for: f.library)))
        guard case .new(let thirdDraft) = third.subject else { return }
        let middle = try snapshot(f)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.store.path)
        XCTAssertFalse(third.commit(to: f.library))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.store.path)
        XCTAssertEqual(try snapshot(f), middle, "Nothing is written by an Add that could not save")
        XCTAssertTrue(third.commit(to: f.library))
        XCTAssertEqual(f.library.items.map(\.id), middle.items.map(\.id) + [thirdDraft.id])
        XCTAssertEqual(Set(try snapshot(f).files.keys).subtracting(middle.files.keys).count, 1, "Retry saves one picture")
    }

    /// Editing a saved card keeps Save and Cancel: opening and editing it, then
    /// Cancel, changes neither the saved card nor the shown floating copy.
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
        var editors = PersonaEditorHolder()
        XCTAssertTrue(editors.open(.saved(f.existing[1])))
        XCTAssertEqual(editors.current?.style, PersonaCardStyle(label: "Synthetic lead"))
        editors.current?.style.label = "Unsaved label"
        editors.current?.style.background = InkColor(0.9, 0.1, 0.1)
        XCTAssertEqual(try snapshot(f), before, "Editing a saved card writes nothing until Save")
        editors.current?.cancel(); editors.current = nil
        XCTAssertEqual(try snapshot(f), before, "Cancel leaves the saved card as it was")
        XCTAssertEqual(f.library.items.first { $0.id == f.existing[1].id }?.card, PersonaCardStyle(label: "Synthetic lead"))
        XCTAssertTrue(f.library.overlayVisible, "Cancel leaves the shown card up")
        XCTAssertEqual(f.library.liveSelection?.currentID, shown)
        // Save is the counterpart: it changes the saved card, and the shown copy stays frozen.
        XCTAssertTrue(editors.open(.saved(f.existing[1])))
        editors.current?.style.label = "Saved label"
        XCTAssertTrue(editors.current?.commit(to: f.library) == true)
        XCTAssertEqual(f.library.items.first { $0.id == f.existing[1].id }?.card?.label, "Saved label")
        XCTAssertTrue(f.library.overlayVisible)
        XCTAssertEqual(f.library.liveSelection?.currentID, shown)
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
                try render(PersonaCardEditor(library: f.library, session: PersonaEditorSession(.new(draft))), appearance: appearance,
                           to: directory.appendingPathComponent("persona-new-portrait-\(name).png"))
                try render(PersonaCardEditor(library: f.library, session: PersonaEditorSession(.saved(saved))), appearance: appearance,
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

    func testProfileReferenceAndPhotoReplacementPreserveIdentityAndOriginals() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        let defaults = UserDefaults(suiteName: f.root.appendingPathComponent("profile-preferences").path)!
        let original = f.existing[0], before = try snapshot(f)
        XCTAssertTrue(LocalPersonaProfile.persona(in: f.library, defaults: defaults) == nil)
        XCTAssertFalse(LocalPersonaProfile.choose(UUID(), in: f.library, defaults: defaults))
        XCTAssertTrue(LocalPersonaProfile.choose(original.id, in: f.library, defaults: defaults))
        XCTAssertEqual(LocalPersonaProfile.persona(in: f.library, defaults: defaults)?.id, original.id)
        XCTAssertEqual(try snapshot(f), before, "Choosing an existing persona only stores its reference")

        let draft = try f.library.portraitDraft(from: f.source, card: PersonaCardStyle(), name: "Me")
        let cancelled = PersonaEditorSession(.new(draft)); cancelled.cancel()
        XCTAssertTrue(cancelled.commit(to: f.library, replacing: original))
        XCTAssertTrue(cancelled.committedID == nil)
        XCTAssertEqual(try snapshot(f), before, "Cancel leaves the current profile and all source bytes intact")

        let editor = PersonaEditorSession(.new(draft))
        editor.appearance.framing = PersonaFraming(x: 0.35, y: 0.5, zoom: 1.4)
        XCTAssertTrue(editor.commit(to: f.library, replacing: original))
        XCTAssertEqual(editor.committedID, original.id)
        let after = try snapshot(f)
        XCTAssertEqual(after.items.map(\.id), before.items.map(\.id), "Replacing the photo does not create a duplicate persona")
        XCTAssertEqual(after.groups, before.groups)
        XCTAssertEqual(after.selectedID, before.selectedID)
        XCTAssertEqual(after.originals, before.originals)
        XCTAssertEqual(after.files[original.image], before.files[original.image], "Saved scenes retain their original image bytes")
        XCTAssertTrue(after.items[0].image != original.image, "A new immutable asset is used for future placements")
        XCTAssertEqual(after.items[0].appearance, editor.appearance)
        XCTAssertTrue(editor.commit(to: f.library, replacing: original))
        XCTAssertEqual(try snapshot(f), after, "A repeated confirmation writes nothing")
        let reopened = PersonaLibrary(root: f.store); defer { reopened.shutdown() }
        XCTAssertEqual(LocalPersonaProfile.persona(in: reopened, defaults: defaults), after.items[0], "The profile reference survives reopening")
        f.library.remove(original.id)
        XCTAssertTrue(LocalPersonaProfile.persona(in: f.library, defaults: defaults) == nil, "A removed profile never falls back to someone else")
    }

    func testFailedProfileReplacementKeepsDraftAndFiles() throws {
        let f = try fixture()
        defer { f.library.shutdown(); try? FileManager.default.removeItem(at: f.root) }
        let original = f.existing[0]
        let draft = try f.library.portraitDraft(from: f.source, card: PersonaCardStyle(), name: "Me")
        let editor = PersonaEditorSession(.new(draft))
        // Another process changed the archive after this profile's preview opened.
        let other = PersonaLibrary(root: f.store); defer { other.shutdown() }
        other.rename(original.id, name: "Name changed elsewhere")
        let before = try snapshot(f)
        XCTAssertFalse(editor.commit(to: f.library, replacing: original))
        XCTAssertFalse(editor.isFinished)
        XCTAssertFalse(editor.canRetry, "A changed saved persona requires reopening, not repeatedly trying the stale replacement")
        XCTAssertTrue(editor.committedID == nil)
        XCTAssertNotNil(editor.failure)
        XCTAssertEqual(try snapshot(f), before, "A failed profile save removes its candidate image only and keeps external changes")
        XCTAssertEqual(f.library.items[0], original)
        XCTAssertEqual(editor.portrait(in: f.library)?.size, draft.portrait.size, "The draft stays for recovery")
    }
}
