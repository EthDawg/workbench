import AppKit
import Combine
import UniformTypeIdentifiers

struct SnapDraft: Identifiable {
    let id = UUID()
    let originalPNG: Data
    let source: SnapSource
    var existing: SnapItem?
    var title: String
    var notes: String
    var tags: [String]
    var edit: SnapEdit
}

@MainActor
final class SnapModel: ObservableObject {
    @Published private(set) var items: [SnapItem] = []
    @Published private(set) var problems: [String] = []
    @Published private(set) var isCapturing = false
    @Published var draft: SnapDraft? { didSet { onStateChange?() } }
    @Published var notice: String?
    @Published var search = ""
    @Published var showingArchived = false
    let store: SnapStore
    var onStateChange: (() -> Void)?
    var onHideForCapture: (() -> Void)?
    var onRestoreAfterCapture: (() -> Void)?
    var mayBeginCapture: (() -> String?)?
    /// Text Vision found in each image, so search finds a Snap by what it shows.
    @Published private(set) var recognizedText: [UUID: String] = [:]
    /// Set when new screenshots are redirected into Snap History but macOS now
    /// saves them somewhere else, for example after a change in the Screenshot app.
    @Published private(set) var screenshotRedirectPaused = false
    @Published private(set) var tidyingScreenshots = false
    let screenshotLocation: any ScreenshotLocationStore
    let screenshotInbox: URL
    let desktop: URL
    private let preferences: UserDefaults
    private let trash: (URL) throws -> Void
    private var inboxTimer: Timer?
    private var inboxSizes: [URL: Int] = [:]
    static let redirectKey = "workbench.snap.screenshots.redirect.v1"
    static let previousLocationKey = "workbench.snap.screenshots.previous-location.v1"
    private let captureService = SnapCapture()
    private var captureRequest: UUID?
    private var analysis: Task<Void, Never>?
    private var analysisRequested = false
    var isBusy: Bool { isCapturing || draft != nil }
    var visibleItems: [SnapItem] { items.filter { ($0.archivedAt != nil) == showingArchived && matches($0) } }

    private func matches(_ item: SnapItem) -> Bool {
        guard let text = recognizedText[item.id], !text.isEmpty else { return item.matches(search) }
        let searchable = item.searchableText + "\n" + text
        return search.split(whereSeparator: \.isWhitespace).allSatisfy { searchable.localizedStandardContains(String($0)) }
    }
    var activeCount: Int { items.filter { $0.archivedAt == nil }.count }

    init(store: SnapStore? = nil, screenshotLocation: (any ScreenshotLocationStore)? = nil, preferences: UserDefaults = .standard,
         desktop: URL? = nil, screenshotInbox: URL? = nil, trash: @escaping (URL) throws -> Void = SnapScreenshots.moveToTrash) {
        self.store = store ?? SnapStore(root: Workbench.supportDirectory(component: "Snaps"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.screenshotLocation = screenshotLocation ?? SystemScreenshotLocation()
        self.preferences = preferences
        self.desktop = desktop ?? home.appendingPathComponent("Desktop", isDirectory: true)
        self.screenshotInbox = screenshotInbox ?? home.appendingPathComponent("Pictures/Workbench Screenshots", isDirectory: true)
        self.trash = trash
        refresh()
        if keepsScreenshotsOffDesktop { startInbox() }
    }

    // MARK: Screenshots off the Desktop

    var keepsScreenshotsOffDesktop: Bool { preferences.bool(forKey: Self.redirectKey) }

    /// Explicit and reversible. Turning it on points macOS screenshots at a
    /// Workbench folder that is imported while Workbench runs; turning it off
    /// restores the previous location unless the person has changed it since.
    func setKeepsScreenshotsOffDesktop(_ enabled: Bool) {
        let inboxPath = screenshotInbox.path
        if enabled {
            do {
                try FileManager.default.createDirectory(at: screenshotInbox, withIntermediateDirectories: true)
                let current = screenshotLocation.location
                if current != inboxPath { preferences.set(current ?? "", forKey: Self.previousLocationKey) }
                screenshotLocation.location = inboxPath
                preferences.set(true, forKey: Self.redirectKey)
                startInbox()
                notice = "New screenshots now go straight to Snap History. Turn this off to restore your previous screenshot location."
            } catch { notice = "Screenshots were not redirected. \(error.localizedDescription)" }
        } else {
            if screenshotLocation.location == inboxPath {
                let previous = preferences.string(forKey: Self.previousLocationKey) ?? ""
                screenshotLocation.location = previous.isEmpty ? nil : previous
            }
            preferences.set(false, forKey: Self.redirectKey)
            stopInbox()
            notice = screenshotRedirectPaused ? "Screenshots stay where macOS now saves them." : "Screenshots save where they did before."
            screenshotRedirectPaused = false
        }
        objectWillChange.send()
    }

    private func startInbox() {
        stopInbox()
        importInbox()
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.importInbox() }
        }
    }
    private func stopInbox() { inboxTimer?.invalidate(); inboxTimer = nil; inboxSizes.removeAll() }

    /// Imports screenshots whose size has settled since the last check. A later
    /// manual location change pauses the redirect instead of fighting it.
    func importInbox() {
        guard keepsScreenshotsOffDesktop, !isBusy else { return }
        screenshotRedirectPaused = screenshotLocation.location != screenshotInbox.path
        var sizes: [URL: Int] = [:], added = 0, known = Set(items.map(\.originalSHA256))
        for file in SnapScreenshots.screenCaptures(in: screenshotInbox) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sizes[file] = size
            guard inboxSizes[file] == size else { continue }
            do {
                if try SnapScreenshots.adopt(file, store: store, known: &known, trash: trash) != nil { added += 1 }
                sizes[file] = nil
            } catch { /* Left in the folder; an identical retry only clears it. */ }
        }
        inboxSizes = sizes
        if added > 0 { refresh(); notice = added == 1 ? "A new screenshot was added to Snap History." : "\(added) new screenshots were added to Snap History." }
    }

    /// Screenshots macOS saved on the Desktop, for the tidy confirmation.
    func desktopScreenshots() -> [URL] { SnapScreenshots.screenCaptures(in: desktop) }

    /// Moves the listed Desktop screenshots into Snap History. Originals go to
    /// the Trash only after each Snap is stored and read back.
    /// Returns the Snaps it added, so the workspace can select them for Organise.
    @discardableResult
    func tidyDesktopScreenshots(_ files: [URL]) async -> [UUID] {
        guard !tidyingScreenshots, !isBusy else { return [] }
        tidyingScreenshots = true
        defer { tidyingScreenshots = false }
        var moved = 0, added: [UUID] = [], kept: [String] = [], known = Set(items.map(\.originalSHA256))
        for file in files {
            do {
                if let item = try SnapScreenshots.adopt(file, store: store, known: &known, trash: trash) { added.append(item.id) }
                moved += 1
            } catch { kept.append(file.lastPathComponent) }
            await Task.yield()
        }
        refresh()
        notice = "Moved \(moved) screenshot\(moved == 1 ? "" : "s") from the Desktop into Snap History. The originals are in the Trash."
            + (added.isEmpty ? "" : " They are selected: choose Organise… to find repeats and summarise the themes.")
            + (kept.isEmpty ? "" : " \(kept.count) could not be added and stayed on the Desktop.")
        return added
    }

    func refresh() {
        do { let read = try store.load(); items = read.items; problems = read.problems }
        catch { problems = [error.localizedDescription] }
        refreshDerivedData()
    }

    /// Reads, or builds once, each Snap's search text and repeat fingerprint off
    /// the main thread. It never edits a Snap record, so it cannot collide with
    /// an open editor, and a failure only leaves that Snap searchable by title.
    private func refreshDerivedData() {
        guard analysis == nil else { analysisRequested = true; return }
        // A separate store instance: SnapStore keeps unsynchronised load state
        // for editor conflict checks, which must never be touched off the main thread.
        let store = SnapStore(root: self.store.root), items = self.items
        analysis = Task.detached(priority: .utility) { [weak self] in
            var texts: [UUID: String] = [:]
            for item in items {
                if Task.isCancelled { break }
                if let derived = store.derived(for: item) { texts[item.id] = derived.text; continue }
                guard let image = try? store.snapshot(item.id).imagePNG,
                      let derived = try? SnapAnalysis.analyze(png: image, imageSHA256: item.imageSHA256) else { continue }
                try? store.writeDerived(derived, for: item.id)
                texts[item.id] = derived.text
            }
            let found = texts
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recognizedText = found
                self.analysis = nil
                if self.analysisRequested { self.analysisRequested = false; self.refreshDerivedData() }
            }
        }
    }

    func capture(_ mode: SnapCapture.Mode) async {
        guard !isBusy else { notice = "Finish or cancel the current Snap first."; return }
        if let reason = mayBeginCapture?() { notice = reason; return }
        let request = UUID(); captureRequest = request
        isCapturing = true; notice = mode == .screen ? "Capturing the display under the pointer…" : "Choose a \(mode.title.lowercased()). Escape cancels."
        onStateChange?(); onHideForCapture?()
        defer { captureRequest = nil; isCapturing = false; onRestoreAfterCapture?(); onStateChange?() }
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            guard captureRequest == request else { return }
            guard let bytes = try await captureService.capture(mode) else { notice = "Capture cancelled. Nothing was added to history."; return }
            guard captureRequest == request else { return }
            try beginDraft(bytes, source: mode.source, title: "\(mode.title) \(Date().formatted(date: .abbreviated, time: .shortened))")
            notice = nil
        } catch { notice = error.localizedDescription }
    }

    func cancelCapture() { captureRequest = nil; captureService.cancel(); notice = "Capture cancelled. Nothing was added to history." }

    func pasteImage() {
        guard !isBusy else { notice = "Finish or cancel the current Snap first."; return }
        do {
            let board = NSPasteboard.general
            guard let bytes = board.data(forType: .png) ?? board.data(forType: .tiff) else {
                notice = "Copy an image, then choose Paste image. Clipboard text and files are not imported."; return
            }
            try beginDraft(SnapRendering.png(bytes), source: .clipboard, title: "Pasted image")
        } catch { notice = error.localizedDescription }
    }

    func importImage() {
        guard !isBusy else { notice = "Finish or cancel the current Snap first."; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.prompt = "Open in Snap"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= SnapStore.maximumImageBytes else { throw SnapError.message("Choose an image file under 100 MB.") }
            try beginDraft(SnapRendering.png(Data(contentsOf: url)), source: .imported, title: String(url.deletingPathExtension().lastPathComponent.prefix(240)))
        } catch { notice = error.localizedDescription }
    }

    private func beginDraft(_ bytes: Data, source: SnapSource, title: String) throws {
        _ = try SnapRendering.image(bytes)
        draft = .init(originalPNG: bytes, source: source, title: title, notes: "", tags: [], edit: .init())
    }

    func edit(_ id: UUID) {
        guard !isBusy else { notice = "Finish or cancel the current Snap first."; return }
        do {
            let snapshot = try store.snapshot(id)
            guard snapshot.item.archivedAt == nil else { throw SnapError.message("Restore this Snap before editing it.") }
            draft = .init(originalPNG: snapshot.originalPNG, source: snapshot.item.source, existing: snapshot.item,
                          title: snapshot.item.title, notes: snapshot.item.notes, tags: snapshot.item.tags, edit: snapshot.item.edit)
        } catch { notice = error.localizedDescription }
    }

    @discardableResult
    func saveDraft(_ draft: SnapDraft, copyAfterSaving: Bool) -> Bool {
        do {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw SnapError.message("Give this Snap a title before saving.") }
            let rendered = try SnapRendering.render(draft.originalPNG, edit: draft.edit)
            if var existing = draft.existing {
                existing.title = title; existing.notes = draft.notes; existing.tags = draft.tags; existing.edit = draft.edit
                _ = try store.save(existing, renderedPNG: rendered)
            } else {
                let dimensions = try SnapRendering.dimensions(draft.originalPNG)
                _ = try store.insert(originalPNG: draft.originalPNG, renderedPNG: rendered, width: dimensions.width,
                                        height: dimensions.height, title: title, source: draft.source, edit: draft.edit, notes: draft.notes, tags: draft.tags)
            }
            self.draft = nil; refresh()
            if copyAfterSaving { notice = copyBytes(rendered) ? "Saved to Snap History and copied. Paste it where you need it." : "Saved to Snap History. Copy failed; use Copy from history to try again." }
            else { notice = "Saved to Snap History. Your original image is preserved." }
            return true
        } catch { notice = "Snap was not saved. \(error.localizedDescription)"; return false }
    }

    func copy(_ id: UUID) {
        do { let snapshot = try store.snapshot(id); notice = copyBytes(snapshot.imagePNG) ? "Image copied. Paste it where you need it." : "The image could not be copied. Try again." }
        catch { notice = error.localizedDescription }
    }
    private func copyBytes(_ bytes: Data) -> Bool { NSPasteboard.general.clearContents(); return NSPasteboard.general.setData(bytes, forType: .png) }

    func export(_ id: UUID) {
        do {
            let snapshot = try store.snapshot(id), panel = NSSavePanel()
            panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = snapshot.item.title + ".png"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try snapshot.imagePNG.write(to: url, options: .atomic); notice = "Image exported. The original remains in Snap History."
        } catch { notice = error.localizedDescription }
    }

    func archive(_ ids: Set<UUID>, archived: Bool) {
        guard !isBusy else { notice = "Finish the current edit before changing history."; return }
        do { try store.setArchived(archived, ids: Array(ids)); notice = archived ? "Archived. Restore these Snaps from Archived at any time." : "Restored to Snap History." }
        catch { notice = "Some Snaps could not be updated. \(error.localizedDescription)" }
        refresh()
    }

    /// The host routes a fresh Snap & Talk capture through this same history
    /// owner before the narrated session receives its portable frozen copy.
    func saveNarratedCapture(_ bytes: Data, displayName: String) throws -> SnapHandoffSnapshot {
        let image = try SnapRendering.image(bytes)
        let title = String("\(displayName) · \(Date().formatted(date: .abbreviated, time: .shortened))".prefix(240))
        let item = try store.insert(originalPNG: bytes, width: image.width, height: image.height, title: title, source: .narrated)
        refresh()
        return .init(id: item.id, title: item.title, createdAt: item.createdAt, originalPNG: bytes, renderedPNG: nil, note: "", tags: [])
    }

    func handoffSnapshots(ids: Set<UUID>) throws -> [SnapHandoffSnapshot] {
        guard ids.count <= 100 else { throw SnapError.message("Choose up to 100 Snaps for one handoff.") }
        let current = try store.load().items
        let found = Set(current.map(\.id))
        guard ids.isSubset(of: found) else { throw SnapError.message("A selected Snap is missing or unreadable. Review the selection before handing it off.") }
        var totalBytes = 0
        return try current.filter { ids.contains($0.id) }.map { item in
            let snapshot = try store.snapshot(item.id)
            guard snapshot.item.archivedAt == nil else { throw SnapError.message("A selected Snap is archived. Restore it or remove it from the selection.") }
            totalBytes += snapshot.originalPNG.count + (snapshot.imagePNG == snapshot.originalPNG ? 0 : snapshot.imagePNG.count)
            guard totalBytes <= 256 * 1_024 * 1_024 else { throw SnapError.message("The selected Snaps exceed 256 MB. Choose fewer images for this handoff.") }
            return .init(id: item.id, title: snapshot.item.title, createdAt: snapshot.item.createdAt,
                         originalPNG: snapshot.originalPNG, renderedPNG: snapshot.imagePNG == snapshot.originalPNG ? nil : snapshot.imagePNG,
                         note: snapshot.item.notes, tags: snapshot.item.tags)
        }
    }
}
