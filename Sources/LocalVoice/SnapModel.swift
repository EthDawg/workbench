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
    @Published var draft: SnapDraft? {
        didSet {
            if let closed = oldValue, closed.id != draft?.id { onDraftClosed?(closed.id, closingWithCopy) }
            onStateChange?()
        }
    }
    @Published var notice: String?
    @Published var search = ""
    @Published var showingArchived = false
    let store: SnapStore
    var onStateChange: (() -> Void)?
    /// Before acquisition, with the app the capture was started over when the
    /// door knows it better than the frontmost app (the menu-bar panel's visit).
    var onHideForCapture: ((pid_t?) -> Void)?
    /// Every capture request ends here, from any door, with what happened. The
    /// host shows the editor, or the problem, on the Snap page, or puts back
    /// what was on screen before a cancelled capture.
    var onRestoreAfterCapture: ((SnapCaptureOutcome) -> Void)?
    /// A draft left the editor: saved, saved and copied (true), or cancelled.
    var onDraftClosed: ((UUID, Bool) -> Void)?
    var mayBeginCapture: (() -> String?)?
    /// Text Vision found in each image, so search finds a Snap by what it shows.
    @Published private(set) var recognizedText: [UUID: String] = [:]
    @Published private(set) var importingScreenshots = false
    /// Whether macOS lets Workbench record the screen. Without it Region,
    /// Window and Screen cannot capture, but saved Snaps, Paste image and
    /// Import image all still work (#112).
    @Published private(set) var screenAccessGranted: Bool
    /// Back from Screen Recording settings with access still off: macOS may
    /// need Workbench to reopen before a grant applies.
    @Published private(set) var suggestsReopenForScreenAccess = false
    private var openedScreenAccessSettings = false
    private let screenAccess: ScreenCaptureAccess
    /// Removed in deinit; checks create many Snap owners.
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    let desktop: URL
    private let trash: (URL) throws -> Void
    /// Set when new screenshots are redirected into History but macOS now
    /// saves them somewhere else, for example after a change in the Screenshot app.
    @Published private(set) var screenshotRedirectPaused = false
    let screenshotLocation: any ScreenshotLocationStore
    let screenshotInbox: URL
    private let preferences: UserDefaults
    private let applyScreenshotLocation: () -> Void
    private var inboxTimer: Timer?
    private var inboxSizes: [URL: Int] = [:]
    static let redirectKey = "workbench.snap.screenshots.redirect.v1"
    static let previousLocationKey = "workbench.snap.screenshots.previous-location.v1"
    private let captureService: any SnapImageSource
    private let pasteboard: NSPasteboard
    private var captureRequest: UUID?
    private var closingWithCopy = false
    private var analysis: Task<Void, Never>?
    private var analysisRequested = false
    /// Reads an image's visible text and repeat fingerprint for search. A check
    /// that does not test search replaces it before saving, so it never runs Vision.
    var analyzeImage: @Sendable (_ png: Data, _ imageSHA256: String) throws -> SnapDerivedData = { try SnapAnalysis.analyze(png: $0, imageSHA256: $1) }
    /// Vision reads one image at a time here, off the main thread and outside
    /// Swift's shared pool. Its text reader waits for work it schedules on that
    /// pool, so a pool thread blocked inside it can deadlock the pool (#181).
    private static let analysisQueue = DispatchQueue(label: "Workbench.SnapAnalysis", qos: .utility)
    var isBusy: Bool { isCapturing || draft != nil }
    /// Capture doors (Home's card and Edit, the panel row, the toolbar) are
    /// disabled only while a capture is in flight. A pending draft keeps them
    /// open: `capture` brings its editor back instead of starting another (#151).
    var disablesCaptureDoors: Bool { isCapturing }
    var visibleItems: [SnapItem] { items.filter { ($0.archivedAt != nil) == showingArchived && matches($0, query: search) } }

    /// Snap search: title, notes, source type, tags and the text Vision read in
    /// the image. Every term must match. History searches Snaps through this too.
    func matches(_ item: SnapItem, query: String) -> Bool {
        guard let text = recognizedText[item.id], !text.isEmpty else { return item.matches(query) }
        let searchable = item.searchableText + "\n" + text
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { searchable.localizedStandardContains(String($0)) }
    }
    var activeCount: Int { items.filter { $0.archivedAt == nil }.count }

    init(store: SnapStore? = nil, desktop: URL? = nil, screenshotLocation: (any ScreenshotLocationStore)? = nil,
         preferences: UserDefaults = .standard, screenshotInbox: URL? = nil,
         trash: @escaping (URL) throws -> Void = SnapScreenshots.moveToTrash,
         applyScreenshotLocation: @escaping () -> Void = SystemScreenshotLocation.restartScreenshotService,
         imageSource: (any SnapImageSource)? = nil, pasteboard: NSPasteboard = .general,
         screenAccess: ScreenCaptureAccess = .system) {
        self.captureService = imageSource ?? SnapCapture()
        self.pasteboard = pasteboard
        self.screenAccess = screenAccess
        screenAccessGranted = screenAccess.isGranted()
        self.store = store ?? SnapStore(root: Workbench.supportDirectory(component: "Snaps"))
        self.desktop = desktop ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        self.screenshotLocation = screenshotLocation ?? SystemScreenshotLocation()
        self.preferences = preferences
        self.screenshotInbox = screenshotInbox ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Workbench Screenshots", isDirectory: true)
        self.trash = trash
        self.applyScreenshotLocation = applyScreenshotLocation
        refresh()
        if keepsScreenshotsOffDesktop { startInbox() }
        // Access can change in System Settings while Workbench runs.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnedToWorkbench() }
        }
    }

    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }

    // MARK: Screen Recording access

    static let screenAccessOff = "Screen Recording is off for Workbench, so Snap can't capture the screen. Your Snaps are still here, and you can paste or import an image you already have."

    func refreshScreenAccess() {
        let granted = screenAccess.isGranted()
        if granted != screenAccessGranted { screenAccessGranted = granted }
        if granted && suggestsReopenForScreenAccess { suggestsReopenForScreenAccess = false }
    }

    /// Workbench is active again, perhaps back from System Settings. Only a
    /// return after Snap opened Screen Recording settings suggests reopening.
    func returnedToWorkbench() {
        refreshScreenAccess()
        let suggests = openedScreenAccessSettings && !screenAccessGranted
        if suggests != suggestsReopenForScreenAccess { suggestsReopenForScreenAccess = suggests }
    }

    /// System Settings → Privacy & Security → Screen Recording. It changes nothing by itself.
    func openScreenRecordingSettings() {
        openedScreenAccessSettings = true
        screenAccess.openSettings()
    }

    // MARK: New screenshots off the Desktop

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
                if current != inboxPath {
                    preferences.set(current ?? "", forKey: Self.previousLocationKey)
                    screenshotLocation.location = inboxPath
                    applyScreenshotLocation()
                }
                preferences.set(true, forKey: Self.redirectKey)
                startInbox()
                notice = "New screenshots now go straight to History; the menu bar refreshed once to apply it. Turn this off to restore your previous screenshot location."
            } catch { notice = "Screenshots were not redirected. \(error.localizedDescription)" }
        } else {
            if screenshotLocation.location == inboxPath {
                let previous = preferences.string(forKey: Self.previousLocationKey) ?? ""
                screenshotLocation.location = previous.isEmpty ? nil : previous
                applyScreenshotLocation()
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
    /// manual location change pauses the redirect instead of fighting it. An
    /// open editor never holds this up: the draft keeps its own bytes, and
    /// Save's revision check already guards an edit after History reloads.
    func importInbox() {
        guard keepsScreenshotsOffDesktop, !importingScreenshots else { return }
        // Published only when it changes, so History and the Snap page are not redrawn every tick.
        let paused = screenshotLocation.location != screenshotInbox.path
        if paused != screenshotRedirectPaused { screenshotRedirectPaused = paused }
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
        guard added > 0 else { return }
        refresh()
        // While a Snap is being captured or edited, its own message stays; the new screenshots appear in the grid.
        if !isBusy { notice = added == 1 ? "A new screenshot was added to History." : "\(added) new screenshots were added to History." }
    }

    // MARK: Desktop screenshots

    /// Screenshots macOS saved on the Desktop, for the import confirmation. Nil,
    /// with a notice, when the Desktop could not be read.
    func desktopScreenshots() -> [URL]? {
        do { return try SnapScreenshots.listScreenCaptures(in: desktop) }
        catch {
            notice = "Workbench could not read the Desktop. Allow it in System Settings > Privacy & Security > Files and Folders, then try again."
            return nil
        }
    }

    /// Imports the listed Desktop screenshots into Snap History. Each original
    /// goes to the Trash only after its Snap is stored and read back. Returns
    /// the Snaps it added, so the workspace can select them for Organise.
    @discardableResult
    func importDesktopScreenshots(_ files: [URL]) async -> [UUID] {
        guard !importingScreenshots, !isBusy else { return [] }
        importingScreenshots = true
        defer { importingScreenshots = false }
        var moved = 0, added: [UUID] = [], kept: [String] = [], known = Set(items.map(\.originalSHA256))
        for file in files {
            do {
                if let item = try SnapScreenshots.adopt(file, store: store, known: &known, trash: trash) { added.append(item.id) }
                moved += 1
            } catch { kept.append(file.lastPathComponent) }
            await Task.yield()
        }
        refresh()
        notice = "Imported \(moved) Desktop screenshot\(moved == 1 ? "" : "s") into History. The originals are in the Trash."
            + (added.isEmpty ? "" : " They are selected, so Use selected, then Organise…, can find repeats and themes.")
            + (kept.isEmpty ? "" : " \(kept.count) could not be imported and stayed on the Desktop.")
        return added
    }

    func refresh() {
        refreshScreenAccess()
        do { let read = try store.load(); items = read.items; problems = read.problems }
        catch { problems = [error.localizedDescription] }
        refreshDerivedData()
    }

    /// Reads, or builds once, each Snap's search text and repeat fingerprint off
    /// the main thread. It never edits a Snap record, so it cannot collide with
    /// an open editor, and a failure only leaves that Snap searchable by title.
    private func refreshDerivedData() {
        guard analysis == nil else { analysisRequested = true; return }
        let root = store.root, items = self.items, analyze = analyzeImage
        analysis = Task { [weak self] in
            let found: [UUID: String] = await withCheckedContinuation { finished in
                Self.analysisQueue.async {
                    // A separate store instance: SnapStore keeps unsynchronised load state
                    // for editor conflict checks, which must never be touched off the main thread.
                    let store = SnapStore(root: root)
                    var texts: [UUID: String] = [:]
                    for item in items {
                        if let derived = store.derived(for: item) { texts[item.id] = derived.text; continue }
                        guard let image = try? store.snapshot(item.id).imagePNG,
                              let derived = try? analyze(image, item.imageSHA256) else { continue }
                        try? store.writeDerived(derived, for: item.id)
                        texts[item.id] = derived.text
                    }
                    finished.resume(returning: texts)
                }
            }
            guard let self else { return }
            self.recognizedText = found
            self.analysis = nil
            if self.analysisRequested { self.analysisRequested = false; self.refreshDerivedData() }
        }
    }

    func capture(_ mode: SnapCapture.Mode, origin: pid_t? = nil) async {
        guard !isCapturing else { notice = "Finish or cancel the current Snap first."; return }
        if let reason = mayBeginCapture?() { notice = reason; return }
        // An open editor, even one hidden with its window, never silently
        // blocks a capture door: the host brings it back to finish or cancel.
        guard draft == nil else { notice = "Finish or cancel the current Snap first."; onRestoreAfterCapture?(.pending); return }
        refreshScreenAccess()
        guard screenAccessGranted else {
            // Asked from the person's own action: the first request lists Workbench
            // in System Settings. Nothing is hidden, and the Snap page explains.
            _ = screenAccess.request()
            notice = Self.screenAccessOff
            onRestoreAfterCapture?(.failed); return
        }
        let request = UUID(); captureRequest = request
        isCapturing = true; notice = mode == .screen ? "Capturing the display under the pointer…" : "Choose a \(mode.title.lowercased()). Escape cancels."
        onStateChange?(); onHideForCapture?(origin)
        var outcome = SnapCaptureOutcome.cancelled
        defer { captureRequest = nil; isCapturing = false; onRestoreAfterCapture?(outcome); onStateChange?() }
        do {
            if captureService.settleDelay > 0 { try await Task.sleep(nanoseconds: captureService.settleDelay) }
            guard captureRequest == request else { return }
            guard let bytes = try await captureService.capture(mode) else { notice = "Capture cancelled. Nothing was added to history."; return }
            guard captureRequest == request else { return }
            outcome = .draft(try beginDraft(bytes, source: mode.source, title: "\(mode.title) \(Date().formatted(date: .abbreviated, time: .shortened))"))
            notice = nil
        } catch { notice = error.localizedDescription; outcome = .failed }
    }

    func cancelCapture() { captureRequest = nil; captureService.cancel(); notice = "Capture cancelled. Nothing was added to history." }

    func pasteImage() {
        guard !isBusy else { notice = "Finish or cancel the current Snap first."; return }
        do {
            let board = pasteboard
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

    @discardableResult
    private func beginDraft(_ bytes: Data, source: SnapSource, title: String) throws -> UUID {
        _ = try SnapRendering.image(bytes)
        let opened = SnapDraft(originalPNG: bytes, source: source, title: title, notes: "", tags: [], edit: .init())
        draft = opened
        return opened.id
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
            // Copied before the draft closes, so the host knows the image is ready to paste.
            let copied = copyAfterSaving && copyBytes(rendered)
            closingWithCopy = copied; self.draft = nil; closingWithCopy = false
            refresh()
            if copyAfterSaving { notice = copied ? "Saved to History and copied. Paste it where you need it." : "Saved to History. Copy failed; use Copy from History to try again." }
            else { notice = "Saved to History. Your original image is preserved." }
            return true
        } catch { notice = "Snap was not saved. \(error.localizedDescription)"; return false }
    }

    func copy(_ id: UUID) {
        do { let snapshot = try store.snapshot(id); notice = copyBytes(snapshot.imagePNG) ? "Image copied. Paste it where you need it." : "The image could not be copied. Try again." }
        catch { notice = error.localizedDescription }
    }
    private func copyBytes(_ bytes: Data) -> Bool { pasteboard.clearContents(); return pasteboard.setData(bytes, forType: .png) }

    func export(_ id: UUID) {
        do {
            let snapshot = try store.snapshot(id), panel = NSSavePanel()
            panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = snapshot.item.title + ".png"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try snapshot.imagePNG.write(to: url, options: .atomic); notice = "Image exported. The original remains in History."
        } catch { notice = error.localizedDescription }
    }

    func archive(_ ids: Set<UUID>, archived: Bool) {
        guard !isBusy else { notice = "Finish the current edit before changing history."; return }
        do { try store.setArchived(archived, ids: Array(ids)); notice = archived ? "Archived. Restore these Snaps from Archived at any time." : "Restored to History." }
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
