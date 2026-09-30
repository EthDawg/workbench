import AppKit
import Foundation
import ImageIO

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ text: String) throws {
    guard try condition() else { throw SnapError.message("SNAP_CHECK_FAILED: \(text)") }
    checks += 1
}
func rejects(_ text: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { checks += 1; return }
    throw SnapError.message("SNAP_CHECK_FAILED: accepted \(text)")
}
func fixture() -> Data {
    let context = CGContext(data: nil, width: 128, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (x,y,colour) in [(0.0,0.0,NSColor.blue),(64.0,0.0,NSColor.yellow),(0.0,40.0,NSColor.red),(64.0,40.0,NSColor.green)] {
        context.setFillColor(colour.cgColor); context.fill(CGRect(x: x, y: y, width: 64, height: 40))
    }
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("SnapChecks-\(UUID().uuidString)")
try fm.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: directory) }
let root = directory.appendingPathComponent("library"), store = SnapStore(root: root)
let empty = try store.load()
try check(empty.items.isEmpty && !fm.fileExists(atPath: root.path), "reading empty history creates no files")
let png = fixture(), first = try store.insert(originalPNG: png, width: 128, height: 80, title: "First", source: .region, notes: "Original note", tags: ["Theme"])
let orientedBytes = NSMutableData()
let orientedDestination = CGImageDestinationCreateWithData(orientedBytes, "public.jpeg" as CFString, 1, nil)!
CGImageDestinationAddImage(orientedDestination, try SnapRendering.image(png), [kCGImagePropertyOrientation: 6] as CFDictionary)
try check(CGImageDestinationFinalize(orientedDestination), "oriented import fixture")
let oriented = try SnapRendering.dimensions(SnapRendering.png(orientedBytes as Data))
try check(oriented.width == 80 && oriented.height == 128, "photo import applies orientation before editing")
let original = try store.snapshot(first.id)
try check(original.originalPNG == png && original.imagePNG == png, "original and untouched image exact bytes")
try check(try SnapRendering.dimensions(png).width == 128, "fixture dimensions")
let firstDir = root.appendingPathComponent(first.id.uuidString.lowercased())
for name in ["original.png", "snap.json"] {
    let mode = try fm.attributesOfItem(atPath: firstDir.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber
    try check(mode?.intValue == 0o600, "private file permissions")
}
try check((try fm.attributesOfItem(atPath: firstDir.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "private directory")

let crop = SnapEdit(crop: .init(x: 0, y: 0.5, width: 0.5, height: 0.5))
let cropped = try SnapRendering.render(png, edit: crop)
let bitmap = NSBitmapImageRep(data: cropped)!, colour = bitmap.colorAt(x: 20, y: 20)!.usingColorSpace(.deviceRGB)!
let expectedColour = NSBitmapImageRep(data: png)!.colorAt(x: 20, y: 20)!.usingColorSpace(.deviceRGB)!
try check(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 40, "crop dimensions")
try check(abs(colour.redComponent - expectedColour.redComponent) < 0.01 && abs(colour.greenComponent - expectedColour.greenComponent) < 0.01 && abs(colour.blueComponent - expectedColour.blueComponent) < 0.01, "crop preserves top-left pixel orientation and colour")
var edited = first; edited.edit = crop
edited = try store.save(edited, renderedPNG: cropped)
let afterCrop = try store.snapshot(first.id)
try check(afterCrop.originalPNG == png && afterCrop.imagePNG == cropped, "edit keeps original and exports cropped image")
try check(original.item.title == "First" && original.imagePNG == png, "already frozen snapshot unchanged")
var marked = crop
marked.marks = [.init(kind: .arrow, points: [.init(x: 0.1, y: 0.65), .init(x: 0.4, y: 0.85)], colour: "blue")]
let ink = try SnapRendering.render(png, edit: marked)
try check(ink != cropped, "annotations included in output")

let secondStore = SnapStore(root: root), staleDraft = try store.read(first.id)
var newer = try secondStore.read(first.id); newer.title = "Newer title"
_ = try secondStore.save(newer)
_ = try store.snapshot(first.id); _ = try store.load()
var stale = staleDraft; stale.title = "Stale title"
try rejects("stale editor after incidental history/snapshot reads") { _ = try store.save(stale) }
try check(try store.read(first.id).title == "Newer title", "newer title preserved")

let points = (0..<20_000).map { SnapPoint(x: Double($0 % 1_000) / 1_000, y: 0.2) }
let huge = SnapEdit(marks: (0..<10).map { _ in SnapMark(kind: .pen, points: points) })
let beforeHuge = try store.load().items.count
try rejects("serialized edit over reopening cap") { _ = try store.insert(originalPNG: png, width: 128, height: 80, title: "Too complex", source: .region, edit: huge) }
try check(try store.load().items.count == beforeHuge, "oversize insertion leaves no item")
let fileNames = try fm.contentsOfDirectory(atPath: firstDir.path)
var hugeExisting = try store.read(first.id); hugeExisting.edit = huge
try rejects("oversize edit save") { _ = try store.save(hugeExisting, renderedPNG: ink) }
try check(Set(try fm.contentsOfDirectory(atPath: firstDir.path)) == Set(fileNames), "failed edit leaves no referenced/orphan rendition")
try check(try store.snapshot(first.id).imagePNG == cropped, "failed edit remains reopenable")

let second = try store.insert(originalPNG: png, width: 128, height: 80, title: "Duplicate A", source: .clipboard)
let third = try store.insert(originalPNG: png, width: 128, height: 80, title: "Duplicate B", source: .screen)
let selection: Set<UUID> = [first.id, second.id, third.id]
let plan = try SnapOrganization.prepare(store: store, ids: selection)
try check(plan.duplicates.count == 1 && plan.duplicates[0].id == third.id, "exact duplicate proposes later copy, crop remains distinct")
let overview = SnapOrganization.markdown(plan, archivedIDs: [])
try check(overview.contains(first.id.uuidString.lowercased()) && overview.contains("Original image") && overview.contains("Original note"), "overview has original notes and source links")
let result = try store.writeOrganization(overview, key: plan.key)
let repeated = try store.writeOrganization(overview + "\nRepeated", key: plan.key)
try check(result == repeated && (try fm.contentsOfDirectory(atPath: result.deletingLastPathComponent().path)).count == 1, "repeat uses one result document")
let namedID = UUID()
let namedBefore = try SnapOrganization.prepare(store: store, ids: [first.id, second.id], selectionID: namedID)
let namedAfter = try SnapOrganization.prepare(store: store, ids: selection, selectionID: namedID)
try check(namedBefore.key == namedAfter.key && namedBefore.key != plan.key, "named selection result identity survives changed membership")
let namedURL = try store.writeOrganization(SnapOrganization.markdown(namedBefore, archivedIDs: []), key: namedBefore.key)
try check(try store.writeOrganization(SnapOrganization.markdown(namedAfter, archivedIDs: []), key: namedAfter.key) == namedURL, "updating named selection replaces its same overview")
try check(!overview.contains("file://") && overview.contains("../\(first.id.uuidString.lowercased())/original.png"), "overview links stay within portable library layout without local account paths")
try SnapOrganization.archiveReviewed([third.id], plan: plan, store: store)
try check(try store.read(third.id).archivedAt != nil, "reviewed duplicate archived")
try check(try store.snapshot(third.id).originalPNG == png, "archived original retained")
try check(try SnapOrganization.prepare(store: store, ids: selection).duplicates.isEmpty, "resolved duplicate does not reopen")
try SnapOrganization.archiveReviewed([third.id], plan: plan, store: store)
try store.setArchived(false, ids: [third.id])
try check(try store.read(third.id).archivedAt == nil, "restore retained record")
let stalePlan = try SnapOrganization.prepare(store: store, ids: selection)
var changedDuplicate = try store.read(third.id); changedDuplicate.notes = "Changed since review"
_ = try store.save(changedDuplicate)
try rejects("stale archive proposal") { try SnapOrganization.archiveReviewed([third.id], plan: stalePlan, store: store) }
try check(try store.read(third.id).archivedAt == nil, "stale review leaves current source active")

let altered = try SnapRendering.render(png, edit: .init(crop: .init(x: 0.5, y: 0, width: 0.5, height: 1)))
let originalURL = root.appendingPathComponent(second.id.uuidString.lowercased()).appendingPathComponent("original.png")
try altered.write(to: originalURL)
try rejects("changed media") { _ = try store.snapshot(second.id) }
try png.write(to: originalURL)
let alias = directory.appendingPathComponent("alias")
try fm.createSymbolicLink(at: alias, withDestinationURL: root)
try rejects("root symlink") { _ = try SnapStore(root: alias).load() }
let leaf = firstDir.appendingPathComponent("snap.json"), backup = try Data(contentsOf: leaf)
try fm.removeItem(at: leaf); try fm.createSymbolicLink(at: leaf, withDestinationURL: directory.appendingPathComponent("missing"))
try rejects("dangling record link") { _ = try store.read(first.id) }
try fm.removeItem(at: leaf); try backup.write(to: leaf)
var future = try JSONSerialization.jsonObject(with: backup) as! [String: Any]; future["formatVersion"] = 999
try JSONSerialization.data(withJSONObject: future).write(to: leaf)
let recovery = try store.load()
try check(recovery.problems.count == 1 && recovery.items.count == 2, "damaged/future record remains visible as problem without losing valid items")
try check(try Data(contentsOf: firstDir.appendingPathComponent("original.png")) == png, "unsupported record preserves original file")
try backup.write(to: leaf)
try rejects("missing selected source") { _ = try SnapOrganization.prepare(store: store, ids: [UUID()]) }

// Compile and exercise the actual portable session store and importer, keeping
// all captured content and pack fixtures synthetic and local.
let sessionRoot = directory.appendingPathComponent("narrated-session")
let skill = ReadbackSkillPackSnapshot(reference: .init(id: "example-private", version: "1.0.0", name: "Example"),
                                    files: ["SKILL.md": Data("Keep supplied screenshots and notes.".utf8), "assets/example.txt": Data("Synthetic asset".utf8)])
let session = try ReadbackStore.create(at: sessionRoot, title: "Synthetic session", skillPack: skill)
let packReceipt = try Data(contentsOf: sessionRoot.appendingPathComponent("skill-pack.json"))
let customSkill = Data("Custom skill must remain unchanged.".utf8)
try customSkill.write(to: sessionRoot.appendingPathComponent("SKILL.md"))
let snapA = SnapHandoffSnapshot(id: first.id, title: "Selected crop", createdAt: first.createdAt, originalPNG: png, renderedPNG: cropped, note: "Optional source note", tags: ["Theme"])
let snapB = SnapHandoffSnapshot(id: third.id, title: "Second selected source", createdAt: third.createdAt, originalPNG: png, renderedPNG: nil, note: "", tags: [])
let imported = try SnapReadback.importSnapshots([snapA, snapB], at: sessionRoot, expectedSessionID: session.id)
try check(imported.added == 2 && imported.alreadyAdded == 0 && imported.warning == nil, "selected batch imported")
try check(imported.manifest.sections.map(\.displayName) == [snapA.title, snapB.title], "selected source order retained")
try check(imported.manifest.sections.allSatisfy { $0.status == .ready && $0.audio == nil && $0.originalTranscript == nil }, "narration optional without inventing original audio/transcription")
let importedSection = imported.manifest.sections[0], importedFolder = sessionRoot.appendingPathComponent(importedSection.directory)
try check(try Data(contentsOf: importedFolder.appendingPathComponent("original-snap.png")) == png, "portable original exact bytes")
try check(try Data(contentsOf: importedFolder.appendingPathComponent("screen.png")) == cropped, "portable rendered crop exact bytes")
try check(ReadbackStore.readText(root: sessionRoot, relative: importedSection.transcript) == snapA.note, "optional source note retained")
let provenance = try JSONDecoder().decode(SnapReadback.Source.self, from: Data(contentsOf: importedFolder.appendingPathComponent("source-snap.json")))
try check(provenance.snapID == first.id && provenance.tags == ["Theme"], "portable source identity and tags retained")
try check(try Data(contentsOf: sessionRoot.appendingPathComponent("skill-pack.json")) == packReceipt, "frozen pack receipt preserved")
try check(try Data(contentsOf: sessionRoot.appendingPathComponent("SKILL.md")) == customSkill, "customised skill preserved")
let beforeRepeat = try Data(contentsOf: sessionRoot.appendingPathComponent("session.json"))
let repeatedImport = try SnapReadback.importSnapshots([snapA, snapB], at: sessionRoot, expectedSessionID: session.id)
try check(repeatedImport.added == 0 && repeatedImport.alreadyAdded == 2, "repeated selected batch is idempotent")
try check(try Data(contentsOf: sessionRoot.appendingPathComponent("session.json")) == beforeRepeat, "repeat does not rewrite manifest")
try check((try fm.contentsOfDirectory(atPath: sessionRoot.appendingPathComponent("items").path)).count == 2, "repeat creates no duplicate folders")
try rejects("different current session") { _ = try SnapReadback.importSnapshots([snapA], at: sessionRoot, expectedSessionID: UUID()) }
let malformed = SnapHandoffSnapshot(id: UUID(), title: "Damaged", createdAt: Date(), originalPNG: Data("broken".utf8), renderedPNG: nil, note: "", tags: [])
try rejects("malformed image in a batch") { _ = try SnapReadback.importSnapshots([snapB, malformed], at: sessionRoot, expectedSessionID: session.id) }
try check(try Data(contentsOf: sessionRoot.appendingPathComponent("session.json")) == beforeRepeat, "invalid batch leaves previous manifest untouched")
try check((try fm.contentsOfDirectory(atPath: sessionRoot.appendingPathComponent("items").path)).count == 2, "invalid batch creates no folders")
var reordered = try ReadbackStore.load(from: sessionRoot); reordered.sections.reverse(); try ReadbackStore.save(reordered, at: sessionRoot)
let newSnap = SnapHandoffSnapshot(id: UUID(), title: "Later source", createdAt: Date(), originalPNG: png, renderedPNG: nil, note: "New note", tags: [])
let appended = try SnapReadback.importSnapshots([snapA, newSnap], at: sessionRoot, expectedSessionID: session.id)
try check(appended.added == 1 && appended.alreadyAdded == 1 && Array(appended.manifest.sections.prefix(2)) == reordered.sections, "append retains latest existing section order")
let receiptURL = importedFolder.appendingPathComponent("source-snap.json")
let savedReceipt = try Data(contentsOf: receiptURL); try Data("damaged".utf8).write(to: receiptURL)
try rejects("damaged source receipt instead of duplicate import") { _ = try SnapReadback.importSnapshots([snapA], at: sessionRoot, expectedSessionID: session.id) }
try savedReceipt.write(to: receiptURL)

try MainActor.assumeIsolated {
    let canonical = SnapStore(root: directory.appendingPathComponent("canonical-captured-history"))
    let model = SnapModel(store: canonical)
    let capture = try model.saveNarratedCapture(png, displayName: "Synthetic session · Example display")
    try check(model.activeCount == 1 && model.items[0].id == capture.id && model.items[0].source == .narrated, "narrated capture enters the canonical Snap history")
    try check(try canonical.snapshot(capture.id).originalPNG == png, "narrated capture keeps exact original bytes")
    let composed = try SnapReadback.importSnapshots([capture], at: sessionRoot, expectedSessionID: session.id)
    try check(composed.added == 1, "new narrated capture composes a portable session section")
    let fromHistory = try model.handoffSnapshots(ids: [capture.id])
    let recomposed = try SnapReadback.importSnapshots(fromHistory, at: sessionRoot, expectedSessionID: session.id)
    try check(recomposed.added == 0 && recomposed.alreadyAdded == 1, "adding narrated capture back from history creates no duplicate")
    model.edit(capture.id)
    try check(model.isBusy && model.draft?.originalPNG == png, "history edit reopens the original")
    model.draft = nil
    try check(!model.isBusy && model.activeCount == 1, "cancel editor retains saved history without a new record")
    var changed = try canonical.read(capture.id); changed.title = "Later title"
    _ = try canonical.save(changed)
    try check(capture.title != changed.title && fromHistory[0].title == capture.title, "running input snapshots keep their frozen titles")
    try rejects("missing ID in a mixed handoff selection") { _ = try model.handoffSnapshots(ids: [capture.id, UUID()]) }
    try canonical.setArchived(true, ids: [capture.id])
    try rejects("archived selected capture") { _ = try model.handoffSnapshots(ids: [capture.id]) }
    try check(try canonical.snapshot(capture.id).originalPNG == png, "archiving does not change a narrated original")
}
// Search text and repeats: Vision on synthetic screens, entirely on this Mac.
func screen(_ lines: [String], clock: String, pointer: CGPoint?) -> Data {
    let width = 1_440, height = 900
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
    (clock as NSString).draw(at: NSPoint(x: width - 90, y: height - 22), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
    NSColor.white.setFill(); NSRect(x: 220, y: 120, width: 1_000, height: 640).fill()
    for (index, line) in lines.enumerated() { (line as NSString).draw(at: NSPoint(x: 260, y: 700 - index * 44), withAttributes: [.font: NSFont.systemFont(ofSize: 22)]) }
    if let pointer { NSColor.black.setFill(); NSBezierPath(ovalIn: NSRect(x: pointer.x, y: pointer.y, width: 14, height: 14)).fill() }
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}
let settingsLines = ["Privacy & Security", "Accessibility", "Workbench Preview    On", "Allow apps to control your computer"]
let screens = [screen(settingsLines, clock: "10:41", pointer: CGPoint(x: 700, y: 400)),
               screen(settingsLines, clock: "10:42", pointer: CGPoint(x: 712, y: 396)),
               screen(["Release report", "21 tests passed, 75 assertions", "6 shortcut conflicts"], clock: "10:43", pointer: nil)]
let repeatsStore = SnapStore(root: directory.appendingPathComponent("repeats"))
let repeatItems = try screens.enumerated().map { index, bytes in
    try repeatsStore.insert(originalPNG: bytes, width: 1_440, height: 900, title: "Screen \(index + 1)", source: .region)
}
try check(repeatItems[0].imageSHA256 != repeatItems[1].imageSHA256, "the recapture fixture is not byte-identical")
for item in repeatItems {
    try repeatsStore.writeDerived(try SnapAnalysis.analyze(png: try repeatsStore.snapshot(item.id).imagePNG, imageSHA256: item.imageSHA256), for: item.id)
}
try check(repeatsStore.derived(for: repeatItems[2])?.text.contains("shortcut conflicts") == true, "Vision reads a Snap's visible text")
let reportData = repeatsStore.derived(for: repeatItems[2])!
try repeatsStore.writeDerived(SnapDerivedData(imageSHA256: String(repeating: "0", count: 64), text: "stale", featurePrint: nil), for: repeatItems[2].id)
try check(repeatsStore.derived(for: repeatItems[2]) == nil, "search data made from another image is ignored")
try repeatsStore.writeDerived(reportData, for: repeatItems[2].id)
let repeatPlan = try SnapOrganization.prepare(store: repeatsStore, ids: Set(repeatItems.map(\.id)))
try check(repeatPlan.duplicates.count == 1 && repeatPlan.duplicates[0].id == repeatItems[1].id
          && repeatPlan.duplicates[0].retained.id == repeatItems[0].id && repeatPlan.duplicates[0].distance != nil,
          "a near-identical recapture is proposed as a repeat of the earlier Snap, and a different screen is not")
try SnapOrganization.archiveReviewed([repeatItems[1].id], plan: repeatPlan, store: repeatsStore)
try check(try repeatsStore.read(repeatItems[1].id).archivedAt != nil && (try repeatsStore.snapshot(repeatItems[1].id).originalPNG) == screens[1],
          "archiving a reviewed repeat keeps its original")
try MainActor.assumeIsolated {
    let model = SnapModel(store: repeatsStore)
    let deadline = Date().addingTimeInterval(30)
    while model.recognizedText.count < repeatItems.count && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    model.search = "shortcut conflicts"
    try check(model.visibleItems.map(\.id) == [repeatItems[2].id], "search finds a Snap by the text inside its image")
    try check(model.matches(repeatItems[2], query: "shortcut conflicts") && !model.matches(repeatItems[0], query: "shortcut conflicts"),
              "the query search History uses also reads the text inside each image")
}
// Desktop screenshots: only files macOS marked as screen captures are imported,
// and each reaches Snap History before its file goes to the Trash.
func markScreenCapture(_ url: URL) throws {
    let value = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
    let status = value.withUnsafeBytes { setxattr(url.path, SnapScreenshots.attribute, $0.baseAddress, value.count, 0, 0) }
    try check(status == 0, "fixture screen-capture attribute")
}
let shots = directory.appendingPathComponent("screenshots"), desktopFolder = shots.appendingPathComponent("Desktop"),
    trashed = shots.appendingPathComponent("Trash")
for folder in [desktopFolder, trashed] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
let olderShot = desktopFolder.appendingPathComponent("Screenshot 2026-09-01 at 9.00.00 am.png"),
    newerShot = desktopFolder.appendingPathComponent("Bildschirmfoto 2026-09-02 um 10.00.00.png"),
    plainImage = desktopFolder.appendingPathComponent("Holiday.png"), notes = desktopFolder.appendingPathComponent("notes.txt"),
    hidden = desktopFolder.appendingPathComponent(".Screenshot pending.png")
try png.write(to: olderShot); try cropped.write(to: newerShot); try png.write(to: plainImage); try Data("x".utf8).write(to: notes); try png.write(to: hidden)
for file in [olderShot, newerShot, notes, hidden] { try markScreenCapture(file) }
let olderDate = Date(timeIntervalSince1970: 1_756_000_000), newerDate = Date(timeIntervalSince1970: 1_756_090_000)
try fm.setAttributes([.creationDate: newerDate], ofItemAtPath: newerShot.path)
try fm.setAttributes([.creationDate: olderDate], ofItemAtPath: olderShot.path)
try check(SnapScreenshots.screenCaptures(in: desktopFolder).map(\.lastPathComponent) == [olderShot, newerShot].map(\.lastPathComponent),
          "only images macOS marked as screen captures are found, oldest first, in any language")
let screenshotStore = SnapStore(root: directory.appendingPathComponent("screenshot-history"))
var trashCalls: [URL] = [], failTrash = true
let trashFixture: (URL) throws -> Void = { url in
    if failTrash { failTrash = false; throw SnapError.message("Synthetic Trash failure") }
    trashCalls.append(url); try fm.moveItem(at: url, to: trashed.appendingPathComponent(url.lastPathComponent))
}
var known = Set<String>()
try rejects("a Trash failure is reported") { _ = try SnapScreenshots.adopt(olderShot, store: screenshotStore, known: &known, trash: trashFixture) }
try check(fm.fileExists(atPath: olderShot.path) && (try screenshotStore.load().items.count) == 1, "the Snap is stored before the file would move")
try check(try SnapScreenshots.adopt(olderShot, store: screenshotStore, known: &known, trash: trashFixture) == nil
          && (try screenshotStore.load().items.count) == 1 && trashCalls == [olderShot],
          "retrying after a failed Trash move clears the file without a duplicate Snap")
let adopted = try SnapScreenshots.adopt(newerShot, store: screenshotStore, known: &known, trash: trashFixture)!
try check(adopted.createdAt == newerDate && adopted.title == "Bildschirmfoto 2026-09-02 um 10.00.00"
          && (try screenshotStore.snapshot(adopted.id)).originalPNG == cropped,
          "an imported screenshot keeps its exact bytes, capture date and name")
try check(fm.fileExists(atPath: plainImage.path) && fm.fileExists(atPath: notes.path) && fm.fileExists(atPath: hidden.path),
          "ordinary images, other files and hidden files stay on the Desktop")
try MainActor.assumeIsolated {
    let model = SnapModel(store: SnapStore(root: directory.appendingPathComponent("import-history")), desktop: desktopFolder,
                          trash: { url in try fm.moveItem(at: url, to: trashed.appendingPathComponent(UUID().uuidString + ".png")) })
    let importFile = desktopFolder.appendingPathComponent("Screenshot 2026-09-04 at 8.00.00 am.png")
    try ink.write(to: importFile); try markScreenCapture(importFile)
    var imported: [UUID]? = nil
    Task { @MainActor in imported = await model.importDesktopScreenshots(model.desktopScreenshots() ?? []) }
    let until = Date().addingTimeInterval(10)
    while imported == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try check(imported?.count == 1 && model.activeCount == 1 && !fm.fileExists(atPath: importFile.path) && fm.fileExists(atPath: plainImage.path),
              "importing moves only screenshots and returns them for selection")
    let unreadable = SnapModel(store: SnapStore(root: directory.appendingPathComponent("unreadable-history")),
                               desktop: shots.appendingPathComponent("Missing Desktop"), trash: { _ in })
    try check(unreadable.desktopScreenshots() == nil && unreadable.notice?.contains("could not read the Desktop") == true,
              "an unreadable Desktop is reported, never shown as empty")
}
// New screenshots off the Desktop: an explicit, reversible change of the macOS
// save location, restored unless the person changed it since.
final class FakeScreenshotLocation: ScreenshotLocationStore { var location: String? }
let inboxFolder = shots.appendingPathComponent("Inbox")
try fm.createDirectory(at: inboxFolder, withIntermediateDirectories: true)
try MainActor.assumeIsolated {
    // An absolute suite path keeps the preferences file in this run's temporary
    // folder, never in the contributor's ~/Library/Preferences (#128).
    let location = FakeScreenshotLocation(), suite = directory.appendingPathComponent("SnapScreenshots-" + UUID().uuidString).path,
        preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    var applied = 0
    let model = SnapModel(store: SnapStore(root: directory.appendingPathComponent("inbox-history")), screenshotLocation: location,
                          preferences: preferences, screenshotInbox: inboxFolder,
                          trash: { url in try fm.moveItem(at: url, to: trashed.appendingPathComponent(UUID().uuidString + ".png")) },
                          applyScreenshotLocation: { applied += 1 })
    try check(!model.keepsScreenshotsOffDesktop && location.location == nil && applied == 0, "nothing changes until the person turns it on")
    model.setKeepsScreenshotsOffDesktop(true)
    try check(location.location == inboxFolder.path && model.keepsScreenshotsOffDesktop && applied == 1,
              "new screenshots are pointed at the Workbench folder and macOS is asked to apply it")
    let incoming = inboxFolder.appendingPathComponent("Screenshot 2026-09-03 at 11.00.00 am.png"),
        ordinary = inboxFolder.appendingPathComponent("Holiday.png")
    try png.write(to: incoming); try markScreenCapture(incoming); try png.write(to: ordinary)
    model.importInbox()
    try check(model.activeCount == 0 && fm.fileExists(atPath: incoming.path), "a screenshot still being written waits for its size to settle")
    model.importInbox()
    try check(model.activeCount == 1 && !fm.fileExists(atPath: incoming.path) && fm.fileExists(atPath: ordinary.path),
              "a settled screenshot moves into Snap History and other images stay")
    model.setKeepsScreenshotsOffDesktop(false)
    try check(location.location == nil && !model.keepsScreenshotsOffDesktop, "turning it off restores the macOS default location")
    location.location = "/Users/example/Screens"
    model.setKeepsScreenshotsOffDesktop(true); location.location = "/Users/example/Elsewhere"
    model.importInbox()
    try check(model.screenshotRedirectPaused, "a later manual location change pauses collecting instead of fighting it")
    model.setKeepsScreenshotsOffDesktop(false)
    let appliedBeforeManual = applied
    try check(location.location == "/Users/example/Elsewhere", "turning it off never overrides the person's later choice")
    model.setKeepsScreenshotsOffDesktop(true); model.setKeepsScreenshotsOffDesktop(false)
    try check(location.location == "/Users/example/Elsewhere", "a previous custom location is restored")
    try check(appliedBeforeManual == 3 && applied == 5, "macOS is asked to apply only real location changes, never a kept manual choice")
}
// An open editor never stalls new screenshots (#151). The draft keeps its own
// bytes, Save's revision check still guards an edit after History reloads, and
// a later manual location change still pauses collecting instead of fighting it.
try MainActor.assumeIsolated {
    let location = FakeScreenshotLocation(), suite = directory.appendingPathComponent("SnapInboxDraft-" + UUID().uuidString).path,
        preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let inbox = shots.appendingPathComponent("Inbox while editing")
    try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
    let model = SnapModel(store: SnapStore(root: directory.appendingPathComponent("inbox-draft-history")), screenshotLocation: location,
                          preferences: preferences, screenshotInbox: inbox,
                          trash: { url in try fm.moveItem(at: url, to: trashed.appendingPathComponent(UUID().uuidString + ".png")) },
                          applyScreenshotLocation: {})
    model.setKeepsScreenshotsOffDesktop(true)
    func arrive(_ name: String, _ bytes: Data) throws -> URL {
        let file = inbox.appendingPathComponent(name)
        try bytes.write(to: file); try markScreenCapture(file)
        return file
    }
    model.draft = SnapDraft(originalPNG: ink, source: .region, title: "Open in the editor", notes: "", tags: [], edit: .init())
    let opened = model.draft!.id
    model.notice = "Give this Snap a title before saving."
    let first = try arrive("Screenshot 2026-09-05 at 9.00.00 am.png", png)
    model.importInbox(); model.importInbox()
    try check(model.activeCount == 1 && !fm.fileExists(atPath: first.path) && model.draft?.id == opened && model.draft?.originalPNG == ink,
              "a settled screenshot is adopted while a draft is open, and the draft is untouched")
    try check(model.notice == "Give this Snap a title before saving.", "adoption leaves the open editor's own message in place")
    try check(model.saveDraft(model.draft!, copyAfterSaving: false) && model.activeCount == 2 && model.draft == nil,
              "the draft still saves after adoption, as a separate Snap")
    model.edit(model.items.first { $0.title == "Open in the editor" }!.id)
    let second = try arrive("Screenshot 2026-09-05 at 9.01.00 am.png", cropped)
    model.importInbox(); model.importInbox()
    var renamed = model.draft!; renamed.title = "Renamed while a screenshot arrived"
    try check(model.activeCount == 3 && !fm.fileExists(atPath: second.path) && model.saveDraft(renamed, copyAfterSaving: false)
              && model.items.contains { $0.title == "Renamed while a screenshot arrived" },
              "an edit opened before adoption still saves once History has reloaded")
    model.draft = SnapDraft(originalPNG: ink, source: .window, title: "Still open", notes: "", tags: [], edit: .init())
    location.location = "/Users/example/Manual"
    model.importInbox()
    try check(model.screenshotRedirectPaused && location.location == "/Users/example/Manual" && model.draft?.title == "Still open",
              "a later manual location change pauses collecting with a draft open, and is kept")
    model.draft = nil
}
// Saves and exports are classified where they happen (#134 T5): a full success
// gets a four-second confirmation that clears only itself, and VoiceOver hears
// it; a save whose copy failed is a partial failure whose notice stays;
// nothing times an editor. Every absent ✓ is checked after one was showing.
try MainActor.assumeIsolated {
    var clock: TimeInterval = 500
    let root = directory.appendingPathComponent("confirmed-history")
    let model = SnapModel(store: SnapStore(root: root), clock: { clock })
    var heard: [String] = []
    model.announce = { heard.append($0) }
    model.draft = SnapDraft(originalPNG: png, source: .region, title: "Saved quietly", notes: "", tags: [], edit: .init())
    try check(model.saveDraft(model.draft!, copyAfterSaving: false) && model.lastOutcome == .saved
              && model.confirmation?.kind == .saved && model.notice == nil, "a save is confirmed as Saved to History, with no lingering notice")
    try check(heard == ["Saved to History"], "VoiceOver hears the save once, in the label's words")
    let savedEvent = model.confirmation!.lifetime.event
    clock += 3.9; model.expireConfirmation(savedEvent)
    try check(model.confirmation?.kind == .saved, "the confirmation lasts four seconds")
    let before = model.items
    clock += 0.1; model.expireConfirmation(savedEvent)
    try check(model.confirmation == nil && model.items == before && model.lastOutcome == .saved, "expiry clears only the confirmation")

    var pasted: [Data] = []
    model.copyImage = { pasted.append($0); return true }
    model.draft = SnapDraft(originalPNG: png, source: .window, title: "Saved and copied", notes: "", tags: [], edit: .init())
    try check(model.saveDraft(model.draft!, copyAfterSaving: true) && model.lastOutcome == .savedAndCopied
              && model.confirmation?.kind == .savedAndCopied && pasted.count == 1, "Save & Copy confirms both only after both happened")
    try check(heard.last == "Saved and copied" && heard.count == 2, "VoiceOver hears that both happened")
    let copiedEvent = model.confirmation!.lifetime.event
    try check(model.pendingConfirmationExpiry == copiedEvent, "a check is showing, and waiting to close, before the partial failure")
    model.copyImage = { _ in false }
    model.draft = SnapDraft(originalPNG: png, source: .screen, title: "Copy refused", notes: "", tags: [], edit: .init())
    try check(model.saveDraft(model.draft!, copyAfterSaving: true) && model.lastOutcome == .savedButCopyFailed
              && model.confirmation == nil && model.notice?.contains("Copy failed") == true && heard.count == 2,
              "a save whose copy failed replaces the showing check with its notice, and is not announced as a success")
    try check(model.pendingConfirmationExpiry == nil, "nothing is left waiting to close: the partial failure is untimed")
    clock += 60; model.expireConfirmation(copiedEvent)
    try check(model.notice?.contains("Copy failed") == true && model.lastOutcome == .savedButCopyFailed && model.confirmation == nil,
              "the earlier success's deadline passing changes nothing")

    let exported = directory.appendingPathComponent("Exported.png")
    model.export(model.items[0].id, to: exported)
    try check(fm.fileExists(atPath: exported.path) && model.lastOutcome == .exported && model.confirmation?.kind == .exported && model.notice == nil,
              "an export is confirmed only once its file is written")
    try check(heard.last == "Image exported" && heard.count == 3, "VoiceOver hears the export")
    model.export(model.items[0].id, to: directory.appendingPathComponent("missing-folder/Exported.png"))
    try check(model.lastOutcome == .failed && model.confirmation == nil && model.notice != nil && heard.count == 3,
              "a failed export replaces the showing check with its reason, and says nothing of success")

    model.export(model.items[0].id, to: directory.appendingPathComponent("Exported again.png"))
    try check(model.confirmation?.kind == .exported, "a check is showing before the refused save")
    model.draft = SnapDraft(originalPNG: png, source: .region, title: "   ", notes: "", tags: [], edit: .init())
    try check(!model.saveDraft(model.draft!, copyAfterSaving: false) && model.lastOutcome == .failed && model.draft != nil
              && model.confirmation == nil && heard.count == 4, "a refused save keeps the editor open, ends the showing check and claims nothing")

    // The store itself refuses the write: its folder is read-only for this one save.
    model.export(model.items[0].id, to: directory.appendingPathComponent("Exported a third time.png"))
    try check(model.confirmation?.kind == .exported && heard.count == 5, "a check is showing before the store refuses a write")
    let count = model.items.count
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    model.draft = SnapDraft(originalPNG: png, source: .region, title: "Store refuses", notes: "", tags: [], edit: .init())
    let refusedByStore = model.saveDraft(model.draft!, copyAfterSaving: true)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try check(!refusedByStore && model.lastOutcome == .failed && model.confirmation == nil && model.draft?.title == "Store refuses"
              && model.notice?.hasPrefix("Snap was not saved.") == true && model.items.count == count && heard.count == 5,
              "a write the store refuses keeps the editor and its reason, ends the showing check and claims nothing")
    model.draft = nil
}

// Editable text and rotation retain originals, render identically after reopening,
// and version only records that need the newer editor.
let v2store = SnapStore(root: directory.appendingPathComponent("text-and-rotation"))
var modern = try v2store.insert(originalPNG: png, width: 128, height: 80, title: "Comment", source: .imported)
let modernFolder = v2store.root.appendingPathComponent(modern.id.uuidString.lowercased())
let oldRecord = try Data(contentsOf: modernFolder.appendingPathComponent("snap.json"))
let oldRevision = modern.revision
modern.edit = SnapEdit(marks: [SnapMark(kind: .text, points: [.init(x: 0.05, y: 0.3), .init(x: 0.95, y: 0.9)],
    colour: "black", text: "Slide note", fontSize: 0.12, background: "white")], rotation: 1)
let modernPNG = try SnapRendering.render(png, edit: modern.edit)
let modernSize = try SnapRendering.dimensions(modernPNG)
try check(modernSize.width == 80 && modernSize.height == 128, "clockwise rotation exchanges output dimensions")
modern = try v2store.save(modern, renderedPNG: modernPNG)
let reopenedModern = try SnapStore(root: v2store.root).snapshot(modern.id)
try check(reopenedModern.originalPNG == png, "text and rotation leave original bytes untouched")
try check(reopenedModern.item.formatVersion == 2, "new edit semantics declare version two")
try check(reopenedModern.item.edit == modern.edit && reopenedModern.imagePNG == modernPNG, "text and rotation round-trip with the rendered image")
try check(try Data(contentsOf: modernFolder.appendingPathComponent("before-v2-\(oldRevision.uuidString.lowercased()).json")) == oldRecord, "the first v2 save retains the exact previous metadata")
try check(try SnapRendering.render(reopenedModern.originalPNG, edit: reopenedModern.item.edit) == modernPNG, "reopened text renders exactly as saved")
let legacyEdit = try JSONDecoder().decode(SnapEdit.self, from: Data(#"{"crop":{"x":0,"y":0,"width":1,"height":1},"marks":[]}"#.utf8))
try check(legacyEdit == SnapEdit(), "v1 records decode with unchanged defaults")
for turn in 0...3 {
    let rotated = try SnapRendering.render(png, edit: SnapEdit(rotation: turn))
    let image = NSBitmapImageRep(data: rotated)!
    let dims = turn % 2 == 0 ? (128,80) : (80,128)
    try check(image.pixelsWide == dims.0 && image.pixelsHigh == dims.1, "rotation \(turn) keeps expected dimensions")
}
let invalidText = SnapMark(kind: .text, points: [.init(x: 0, y: 0), .init(x: 1, y: 1)], text: "Invalid", fontSize: .nan)
try rejects("invalid text size") { _ = try SnapRendering.render(png, edit: SnapEdit(marks: [invalidText])) }
let noteEdit = SnapEdit(marks: [SnapMark(kind: .text, points: [.init(x: 0.1, y: 0.1), .init(x: 0.9, y: 0.9)], colour: "black", text: "Hello", fontSize: 0.18, background: "white")])
let notePixels = NSBitmapImageRep(data: try SnapRendering.render(png, edit: noteEdit))!
var blackPixels = 0
for y in 8..<70 { for x in 14..<114 {
    let c = notePixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    if c.redComponent < 0.15 && c.greenComponent < 0.15 && c.blueComponent < 0.15 { blackPixels += 1 }
} }
try check(blackPixels > 15, "text produces visible glyph pixels inside its comment box")
for turn in 1...3 {
    var upright = noteEdit
    upright.rotation = turn
    upright.marks[0].textRotation = (4 - turn) % 4
    let rendered = NSBitmapImageRep(data: try SnapRendering.render(png, edit: upright))!
    let rotatedSource = try SnapRendering.render(png, edit: SnapEdit(rotation: turn))
    let reference = NSBitmapImageRep(data: try SnapRendering.render(rotatedSource, edit: noteEdit))!
    var intersection = 0, union = 0
    for y in 0..<rendered.pixelsHigh { for x in 0..<rendered.pixelsWide {
        func ink(_ bitmap: NSBitmapImageRep) -> Bool {
            let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return c.redComponent < 0.15 && c.greenComponent < 0.15 && c.blueComponent < 0.15
        }
        let a = ink(rendered), b = ink(reference)
        if a && b { intersection += 1 }
        if a || b { union += 1 }
    } }
    try check(union > 15 && Double(intersection) / Double(union) > 0.9, "new text stays upright at image rotation \(turn), matching ordinary horizontal text")
    try check(try JSONDecoder().decode(SnapEdit.self, from: JSONEncoder().encode(upright)) == upright, "text direction survives save/reopen at rotation \(turn)")
}

print("SNAP_CHECKS_OK: \(checks) checks for rendering, Desktop screenshot import, screenshots off the Desktop and while editing, revision conflicts, private storage, immutable snapshots, reversible review, repeats, search text and portable optional narration")
