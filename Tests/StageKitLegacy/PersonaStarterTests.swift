import AppKit
import ImageIO
import UniformTypeIdentifiers

final class PersonaStarterTests {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaStarterTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func portraitPNG() throws -> Data {
        let context = CGContext(data: nil, width: 30, height: 40, bitsPerComponent: 8, bytesPerRow: 120,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: 30, height: 40))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.7, alpha: 1))
        context.fillEllipse(in: CGRect(x: 6, y: 2, width: 18, height: 36))
        let bytes = NSMutableData()
        let output = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(output) else { throw PersonaStarterError.unavailable }
        return bytes as Data
    }

    func testCatalogHasStableUniqueBundleNamesAndEditableLabels() throws {
        let portraits = PersonaStarterLibrary.portraits
        XCTAssertEqual(portraits.count, 8)
        XCTAssertEqual(Set(portraits.map(\.id)), Set(["care-lead", "field-lead", "front-desk", "operations-lead",
            "logistics-lead", "care-coordinator", "hospitality-lead", "field-technician"]))
        XCTAssertEqual(Set(portraits.map(\.filename)).count, portraits.count)
        for portrait in portraits {
            XCTAssertEqual(URL(fileURLWithPath: portrait.filename).lastPathComponent, portrait.filename)
            XCTAssertEqual(URL(fileURLWithPath: portrait.filename).pathExtension, "png")
            XCTAssertTrue(!portrait.label.isEmpty)
            XCTAssertEqual(try PersonaCardStyle(label: portrait.label).validated().label, portrait.label)
        }
    }

    func testMissingCorruptOversizedAndLinkedSourcesDoNotAddBrokenPersonas() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("portraits"), store = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let starters = PersonaStarterLibrary(directory: directory), portrait = PersonaStarterLibrary.portraits[0]
        let library = PersonaLibrary(root: store)
        XCTAssertTrue(PersonaStarterLibrary(directory: nil).source(for: portrait) == nil)
        XCTAssertTrue(starters.source(for: portrait) == nil)
        XCTAssertThrowsError(try starters.draft(portrait, for: library))
        let file = directory.appendingPathComponent(portrait.filename)
        try Data("Not a portrait".utf8).write(to: file)
        XCTAssertTrue(starters.thumbnail(for: portrait) == nil)
        XCTAssertThrowsError(try starters.draft(portrait, for: library))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(LogoImport.maximumBytes + 1)); try handle.close()
        XCTAssertTrue(starters.source(for: portrait) == nil)
        XCTAssertThrowsError(try starters.draft(portrait, for: library))
        try FileManager.default.removeItem(at: file)
        let outside = root.appendingPathComponent("outside.png"); try portraitPNG().write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertTrue(starters.source(for: portrait) == nil)
        let linkedDirectory = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
        XCTAssertTrue(PersonaStarterLibrary(directory: linkedDirectory).source(for: portrait) == nil)
        XCTAssertTrue(starters.source(for: PersonaStarter(id: "../outside", label: "Outside")) == nil)
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("persona-library.json").path))
    }

    func testChoosingOneStarterUsesActiveGroupAndKeepsSeparateEditableCopies() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("portraits"), store = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = try portraitPNG()
        for portrait in PersonaStarterLibrary.portraits { try original.write(to: directory.appendingPathComponent(portrait.filename)) }
        let library = PersonaLibrary(root: store), starters = PersonaStarterLibrary(directory: directory)
        let group = try library.createGroup(name: "Synthetic prepared group")
        let beforeBrowsing = try Data(contentsOf: store.appendingPathComponent("persona-library.json"))
        for portrait in PersonaStarterLibrary.portraits { XCTAssertNotNil(starters.thumbnail(for: portrait)) }
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.appendingPathComponent("persona-library.json")), beforeBrowsing)
        let portrait = PersonaStarterLibrary.portraits[0]
        // Choosing a starter is a draft; Add persona saves it.
        let chosen = try starters.draft(portrait, for: library)
        XCTAssertTrue(library.items.isEmpty, "Choosing a starter saves nothing")
        let first = try library.add(chosen)
        XCTAssertEqual(library.items.count, 1); XCTAssertEqual(library.selectedID, first.id)
        XCTAssertEqual(library.activeGroupID, group); XCTAssertEqual(library.activeGroup?.personaIDs, [first.id])
        XCTAssertEqual(first.card?.label, portrait.label)
        XCTAssertFalse(library.overlayVisible)
        var edited = PersonaCardStyle(label: "Facilities lead"); edited.background = InkColor(0.2, 0.3, 0.6)
        XCTAssertTrue(library.updateCard(first.id, style: edited))
        let second = try library.add(starters.draft(portrait, for: library))
        XCTAssertTrue(second.id != first.id && second.image != first.image)
        XCTAssertEqual(library.items.count, 2)
        XCTAssertEqual(library.activeGroup?.personaIDs, [first.id, second.id])
        XCTAssertEqual(library.items.first { $0.id == first.id }?.card, edited)
        XCTAssertEqual(second.card, PersonaCardStyle(label: portrait.label))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(portrait.filename)), original)
        let reopened = PersonaLibrary(root: store)
        XCTAssertEqual(reopened.items, library.items)
        XCTAssertEqual(reopened.activeGroup?.personaIDs, [first.id, second.id])
        XCTAssertFalse(reopened.overlayVisible)
    }

    func testBundledPortraitsHaveReadableArtworkAndRealTransparency() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let starters = PersonaStarterLibrary(directory: repo.appendingPathComponent("Resources/PersonaPortraits"))
        for portrait in PersonaStarterLibrary.portraits {
            guard let image = starters.thumbnail(for: portrait), let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data) else {
                XCTAssertTrue(false, "Missing or unreadable bundled portrait: " + portrait.filename)
                continue
            }
            XCTAssertTrue(bitmap.hasAlpha, "Portrait must support editable card backgrounds")
            var transparent = false, visible = false
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                    let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1
                    transparent = transparent || alpha == 0; visible = visible || alpha > 0.9
                }
            }
            XCTAssertTrue(transparent && visible, "Bundled portrait must contain visible artwork and actual transparent pixels")
        }
    }
}
