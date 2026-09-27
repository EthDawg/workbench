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
// Screenshots off the Desktop: only files macOS marked as screen captures move,
// each reaches Snap History before its file goes to the Trash, and the person's
// own screenshot location is restored unless they changed it since.
final class FakeScreenshotLocation: ScreenshotLocationStore { var location: String? }
func markScreenCapture(_ url: URL) throws {
    let value = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
    let status = value.withUnsafeBytes { setxattr(url.path, SnapScreenshots.attribute, $0.baseAddress, value.count, 0, 0) }
    try check(status == 0, "fixture screen-capture attribute")
}
let shots = directory.appendingPathComponent("screenshots"), desktopFolder = shots.appendingPathComponent("Desktop"),
    inboxFolder = shots.appendingPathComponent("Inbox"), trashed = shots.appendingPathComponent("Trash")
for folder in [desktopFolder, inboxFolder, trashed] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
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
          "an adopted screenshot keeps its exact bytes, capture date and name")
try check(fm.fileExists(atPath: plainImage.path) && fm.fileExists(atPath: notes.path) && fm.fileExists(atPath: hidden.path),
          "ordinary images, other files and hidden files stay on the Desktop")
try MainActor.assumeIsolated {
    let location = FakeScreenshotLocation(), suite = "SnapScreenshots-" + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = SnapModel(store: SnapStore(root: directory.appendingPathComponent("inbox-history")), screenshotLocation: location,
                          preferences: preferences, desktop: desktopFolder, screenshotInbox: inboxFolder,
                          trash: { url in try fm.moveItem(at: url, to: trashed.appendingPathComponent(UUID().uuidString + ".png")) })
    model.setKeepsScreenshotsOffDesktop(true)
    try check(location.location == inboxFolder.path && model.keepsScreenshotsOffDesktop, "new screenshots are pointed at the Workbench folder")
    let incoming = inboxFolder.appendingPathComponent("Screenshot 2026-09-03 at 11.00.00 am.png")
    try png.write(to: incoming); try markScreenCapture(incoming)
    model.importInbox()
    try check(model.activeCount == 0 && fm.fileExists(atPath: incoming.path), "a screenshot still being written waits for its size to settle")
    model.importInbox()
    try check(model.activeCount == 1 && !fm.fileExists(atPath: incoming.path), "a settled screenshot moves into Snap History")
    model.setKeepsScreenshotsOffDesktop(false)
    try check(location.location == nil && !model.keepsScreenshotsOffDesktop, "turning it off restores the macOS default location")
    location.location = "/Users/example/Screens"
    model.setKeepsScreenshotsOffDesktop(true); location.location = "/Users/example/Elsewhere"
    model.importInbox()
    try check(model.screenshotRedirectPaused, "a later manual location change pauses collecting instead of fighting it")
    model.setKeepsScreenshotsOffDesktop(false)
    try check(location.location == "/Users/example/Elsewhere", "turning it off never overrides the person's later choice")
    model.setKeepsScreenshotsOffDesktop(true); model.setKeepsScreenshotsOffDesktop(false)
    try check(location.location == "/Users/example/Elsewhere", "a previous custom location is restored")
    let tidyFile = desktopFolder.appendingPathComponent("Screenshot 2026-09-04 at 8.00.00 am.png")
    try ink.write(to: tidyFile); try markScreenCapture(tidyFile)
    var tidied: [UUID]? = nil
    Task { @MainActor in tidied = await model.tidyDesktopScreenshots(model.desktopScreenshots() ?? []) }
    let until = Date().addingTimeInterval(10)
    while tidied == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try check(tidied?.count == 1 && !fm.fileExists(atPath: tidyFile.path) && fm.fileExists(atPath: plainImage.path),
              "tidying moves only screenshots and returns them for selection")
    let unreadable = SnapModel(store: SnapStore(root: directory.appendingPathComponent("unreadable-history")), screenshotLocation: FakeScreenshotLocation(),
                               preferences: preferences, desktop: shots.appendingPathComponent("Missing Desktop"), screenshotInbox: inboxFolder, trash: { _ in })
    try check(unreadable.desktopScreenshots() == nil && unreadable.notice?.contains("could not read the Desktop") == true,
              "an unreadable Desktop is reported, never shown as empty")
}
print("SNAP_CHECKS_OK: \(checks) checks for rendering, screenshots off the Desktop, revision conflicts, private storage, immutable snapshots, reversible review and portable optional narration")
