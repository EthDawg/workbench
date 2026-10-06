import AppKit
import Combine
import Foundation

/// Drives the production owner with temporary files and held background work.
/// No real preferences, screenshot location, clipboard, permissions or Vision.
enum SnapRefreshChecks {
    /// Only the first call waits. Its timeout makes a scheduling regression fail
    /// instead of hanging the suite; the assertions never depend on its speed.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var count = 0
        private var mainThread = false
        private var timedOut = false
        var calls: Int { lock.withLock { count } }
        var stayedOffMain: Bool { lock.withLock { !mainThread && !timedOut } }
        func holdFirst() {
            let first = lock.withLock {
                count += 1
                mainThread = mainThread || Thread.isMainThread
                return count == 1
            }
            if first && semaphore.wait(timeout: .now() + 10) == .timedOut {
                lock.withLock { timedOut = true }
            }
        }
        func release() { semaphore.signal() }
    }

    private final class AnalysisLog: @unchecked Sendable {
        private let lock = NSLock()
        private var mismatches = 0
        func record(_ bytes: Data, _ digest: String) {
            lock.withLock { if SnapStore.digest(bytes) != digest { mismatches += 1 } }
        }
        var matchedEveryImage: Bool { lock.withLock { mismatches == 0 } }
    }

    @MainActor
    private static func wait(_ description: String, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        guard predicate() else { throw SnapError.message("SNAP_REFRESH_CHECK_FAILED: waiting for \(description)") }
    }

    @MainActor
    static func run(root: URL, png: Data) throws -> Int {
        let fm = FileManager.default
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw SnapError.message("SNAP_REFRESH_CHECK_FAILED: \(name)") }
            checks += 1
        }
        func seed(_ store: SnapStore, title: String = "Saved capture", date: Date = Date()) throws -> SnapItem {
            let size = try SnapRendering.dimensions(png)
            let item = try store.insert(originalPNG: png, width: size.width, height: size.height,
                                        title: title, source: .region, createdAt: date)
            try store.writeDerived(.init(imageSHA256: item.imageSHA256, text: "Original image words", featurePrint: nil), for: item.id)
            return item
        }
        func model(_ store: SnapStore) -> SnapModel {
            let suite = root.appendingPathComponent("Preferences-\(UUID().uuidString)").path
            return SnapModel(store: store, desktop: root.appendingPathComponent("Desktop"),
                             preferences: UserDefaults(suiteName: suite)!,
                             trash: { source in
                                 let trash = root.appendingPathComponent("Synthetic Trash")
                                 try fm.createDirectory(at: trash, withIntermediateDirectories: true)
                                 try fm.moveItem(at: source, to: trash.appendingPathComponent(UUID().uuidString + ".png"))
                             },
                             screenAccess: .init(isGranted: { true }, request: { true }, openSettings: {}))
        }
        func heldLoad(_ snap: SnapModel, failure: Bool = false) -> Gate {
            let gate = Gate()
            snap.loadLibrary = { root in
                let read = try SnapStore(root: root).load()
                gate.holdFirst()
                if failure { throw SnapError.message("Obsolete background failure") }
                return read
            }
            snap.requestRefresh()
            return gate
        }

        let store = SnapStore(root: root.appendingPathComponent("Coalescing"))
        let original = try seed(store), snap = model(store)
        try wait("initial image text") { !snap.hasPendingHistoryWork }
        let gate = heldLoad(snap)
        defer { gate.release() }
        try wait("held library read") { gate.calls == 1 }
        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        try wait("main actor heartbeat while disk read is held") { heartbeat }
        try check(gate.stayedOffMain && snap.items == [original], "a held disk read leaves the main actor and current rows available")
        let external = try seed(SnapStore(root: store.root), title: "Arrived during reload")
        for _ in 0..<20 { snap.requestRefresh() }
        try check(gate.calls == 1, "twenty refresh requests cannot start overlapping reads")
        gate.release()
        try wait("coalesced follow-up") { !snap.hasPendingHistoryWork }
        try check(gate.calls == 2 && Set(snap.items.map(\.id)) == [original.id, external.id],
                  "repeated requests become one follow-up that includes the later file")

        var itemPublications = 0, problemPublications = 0, textPublications = 0
        let subscriptions: [AnyCancellable] = [
            snap.$items.dropFirst().sink { _ in itemPublications += 1 },
            snap.$problems.dropFirst().sink { _ in problemPublications += 1 },
            snap.$recognizedText.dropFirst().sink { _ in textPublications += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }
        snap.requestRefresh()
        try wait("unchanged background refresh") { !snap.hasPendingHistoryWork }
        snap.refresh()
        try wait("unchanged synchronous refresh") { !snap.hasPendingHistoryWork }
        try check(itemPublications == 0 && problemPublications == 0 && textPublications == 0,
                  "unchanged reloads publish no item, problem or image-text invalidation")

        // Each operation accepts its own state synchronously. Release an older
        // successful or failing load afterwards and ensure it cannot replace it.
        for operation in ["save", "archive", "import", "failure"] {
            let store = SnapStore(root: root.appendingPathComponent(operation))
            let item = try seed(store), snap = model(store)
            snap.announce = { _ in }
            snap.analyzeImage = { _, digest in .init(imageSHA256: digest, text: "Saved image words", featurePrint: nil) }
            try wait("\(operation) initial analysis") { !snap.hasPendingHistoryWork }
            let gate = heldLoad(snap, failure: operation == "failure")
            defer { gate.release() }
            try wait("\(operation) held read") { gate.calls == 1 }
            // An earlier queued activation is superseded by the accepted mutation.
            snap.requestRefresh()
            switch operation {
            case "save", "failure":
                snap.edit(item.id)
                var draft = snap.draft!
                draft.title = "Accepted edit"
                try check(snap.saveDraft(draft, copyAfterSaving: false), "save commits while a passive reload waits")
            case "archive": snap.archive([item.id], archived: true)
            default:
                let source = root.appendingPathComponent("Imported screenshot.png")
                try SnapRendering.render(png, edit: .init(rotation: 1)).write(to: source)
                var imported: [UUID]?
                Task { @MainActor in imported = await snap.importDesktopScreenshots([source]) }
                try wait("Desktop import acceptance") { imported != nil }
                try check(imported?.count == 1 && snap.items.count == 2 && !fm.fileExists(atPath: source.path),
                          "Desktop import accepts its new capture while a passive load waits")
            }
            let acceptedItems = snap.items, acceptedProblems = snap.problems
            snap.draft = SnapDraft(originalPNG: png, source: .clipboard, title: "Keep current draft", notes: "", tags: [], edit: .init())
            let draftID = snap.draft!.id
            snap.notice = "Keep current notice"
            gate.release()
            try wait("\(operation) obsolete completion") { !snap.hasPendingHistoryWork }
            try check(snap.items == acceptedItems && snap.problems == acceptedProblems && gate.calls == 1,
                      "an older \(operation) reload cannot overwrite accepted state or restart superseded work")
            try check(snap.draft?.id == draftID && snap.draft?.originalPNG == png && snap.notice == "Keep current notice",
                      "\(operation) completion preserves the current draft and notice")
        }

        // A passive request made after a synchronous acceptance is still due;
        // rejecting the older read cannot accidentally discard that new request.
        let followupStore = SnapStore(root: root.appendingPathComponent("Later request"))
        let followupItem = try seed(followupStore), followup = model(followupStore)
        try wait("follow-up initial text") { !followup.hasPendingHistoryWork }
        let followupGate = heldLoad(followup)
        defer { followupGate.release() }
        try wait("follow-up held read") { followupGate.calls == 1 }
        followup.archive([followupItem.id], archived: true)
        let laterItem = try seed(SnapStore(root: followupStore.root), title: "Later external capture")
        followup.requestRefresh()
        followupGate.release()
        try wait("request after accepted archive") { !followup.hasPendingHistoryWork }
        try check(followupGate.calls == 2 && followup.items.contains { $0.id == laterItem.id } &&
                  followup.items.first { $0.id == followupItem.id }?.archivedAt != nil,
                  "a newer passive request survives rejection of a pre-archive read")

        // A current read failure keeps usable rows; an identical error is quiet,
        // and a later successful read clears it without replacing those rows.
        snap.loadLibrary = { _ in throw SnapError.message("Synthetic unreadable library") }
        snap.requestRefresh()
        try wait("read failure") { !snap.hasPendingHistoryWork }
        try check(snap.items.count == 2 && snap.problems == ["Synthetic unreadable library"], "a failed passive load retains the saved rows")
        let beforeProblems = problemPublications
        snap.requestRefresh()
        try wait("same failure") { !snap.hasPendingHistoryWork }
        try check(problemPublications == beforeProblems, "an unchanged read failure is not republished")
        snap.loadLibrary = { try SnapStore(root: $0).load() }
        snap.requestRefresh()
        try wait("recovered load") { !snap.hasPendingHistoryWork }
        try check(snap.problems.isEmpty && itemPublications == 0, "recovery clears its problem without invalidating unchanged rows")

        // Image B is being analysed when C is saved. B's delayed text may not
        // enter search or replace C's derived cache. Empty old text is removed
        // as soon as the new image is accepted, before any analysis completes.
        let ocrStore = SnapStore(root: root.appendingPathComponent("Image revisions"))
        let ocrItem = try seed(ocrStore), ocr = model(ocrStore)
        ocr.announce = { _ in }
        try wait("original OCR") { !ocr.hasPendingHistoryWork }
        try check(ocr.matches(ocrItem, query: "Original image words"), "original image text starts searchable")
        let analysisGate = Gate(), log = AnalysisLog()
        defer { analysisGate.release() }
        ocr.analyzeImage = { bytes, digest in
            log.record(bytes, digest)
            analysisGate.holdFirst()
            return .init(imageSHA256: digest, text: analysisGate.calls == 1 ? "Obsolete image words" : "Current image words", featurePrint: nil)
        }
        ocr.edit(ocrItem.id)
        var imageB = ocr.draft!; imageB.edit.rotation = 1
        try check(ocr.saveDraft(imageB, copyAfterSaving: false) && ocr.recognizedText[ocrItem.id] == nil,
                  "saving a changed image immediately removes its earlier OCR text")
        try wait("held analysis") { analysisGate.calls == 1 }
        ocr.edit(ocrItem.id)
        var imageC = ocr.draft!; imageC.edit.rotation = 2
        try check(ocr.saveDraft(imageC, copyAfterSaving: false), "a second image edit saves while old analysis waits")
        var publishedObsoleteText = false
        let textChanges = ocr.$recognizedText.dropFirst().sink { texts in
            publishedObsoleteText = publishedObsoleteText || texts.values.contains("Obsolete image words")
        }
        defer { textChanges.cancel() }
        analysisGate.release()
        try wait("latest image analysis") { !ocr.hasPendingHistoryWork }
        let latest = ocr.items[0]
        try check(analysisGate.stayedOffMain && analysisGate.calls == 2 && !publishedObsoleteText && log.matchedEveryImage,
                  "late image analysis is rejected and one pass analyses the current bytes with their own digest")
        try check(ocr.matches(latest, query: "Current image words") && !ocr.matches(latest, query: "Obsolete") &&
                  ocrStore.derived(for: latest)?.text == "Current image words",
                  "search and the saved derived cache describe only the current image")

        // While one item holds the serial analysis pass, a later item's image
        // changes on disk. The pass's old item must not label new bytes with an
        // old digest; a subsequent pass analyses the new snapshot correctly.
        let pairingStore = SnapStore(root: root.appendingPathComponent("Snapshot pairing"))
        let first = try seed(pairingStore, title: "First", date: Date(timeIntervalSince1970: 200))
        let second = try seed(pairingStore, title: "Second", date: Date(timeIntervalSince1970: 100))
        let pairing = model(pairingStore)
        try wait("pairing initial text") { !pairing.hasPendingHistoryWork }
        let pairingGate = Gate(), pairingLog = AnalysisLog()
        defer { pairingGate.release() }
        pairing.analyzeImage = { bytes, digest in
            pairingLog.record(bytes, digest)
            pairingGate.holdFirst()
            return .init(imageSHA256: digest, text: "Verified image text", featurePrint: nil)
        }
        func rotate(_ id: UUID, turns: Int) throws {
            var item = try pairingStore.read(id)
            item.edit.rotation = turns
            _ = try pairingStore.save(item, renderedPNG: SnapRendering.render(png, edit: item.edit))
        }
        try rotate(first.id, turns: 1); try rotate(second.id, turns: 1)
        pairing.refresh()
        try wait("pairing held first item") { pairingGate.calls == 1 }
        try rotate(second.id, turns: 2)
        pairing.refresh()
        pairingGate.release()
        try wait("paired current analysis") { !pairing.hasPendingHistoryWork }
        try check(pairingLog.matchedEveryImage && pairing.recognizedText.count == 2,
                  "a changed later snapshot is never analysed under the stale list digest")

        print("SNAP_REFRESH_CHECKS_OK: \(checks) checks for background reads, mutation ordering, unchanged publications and current-image search")
        return checks
    }
}
