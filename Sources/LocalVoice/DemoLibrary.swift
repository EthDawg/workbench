import AppKit
import Combine
import UniformTypeIdentifiers

enum DemoResourceKind: String, Codable, CaseIterable {
    case prompt = "Prompt", link = "Link", file = "File"
    var symbol: String { switch self { case .prompt: "text.quote"; case .link: "link"; case .file: "doc" } }
}

struct DemoResource: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: DemoResourceKind = .prompt
    var title = ""
    var product = ""
    var persona = ""
    var content = ""
    var notes = ""
    var favorite = false
    var modified = Date()
    var bookmark: Data?

    var group: String { [product, persona].filter { !$0.isEmpty }.joined(separator: " · ") }
    var primaryActionTitle: String { switch kind { case .prompt: "Copy prompt"; case .link: "Open link"; case .file: "Open file" } }
    var primaryActionAvailable: Bool {
        switch kind {
        case .prompt: return !content.isEmpty
        case .link: return webURL != nil
        case .file: return fileAvailable && canOpenFile
        }
    }
    var webURL: URL? {
        guard let url = URL(string: content), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    var fileURL: URL? { resolvedFile?.url }
    var resolvedFile: (url: URL, stale: Bool)? {
        guard kind == .file else { return nil }
        if let bookmark {
            var stale = false
            #if APP_STORE
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
            #else
            let options: URL.BookmarkResolutionOptions = [.withoutUI]
            #endif
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) { return (resolved, stale) }
        }
        return content.hasPrefix("/") ? (URL(fileURLWithPath: content), bookmark != nil) : nil
    }
    var fileAvailable: Bool {
        guard let url = fileURL else { return false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
    var canOpenFile: Bool {
        guard let url = fileURL else { return false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        // Library files are documents and media. Commands and app bundles can be
        // revealed for inspection, but are never launched by a resource action.
        return values?.isDirectory != true && !FileManager.default.isExecutableFile(atPath: url.path)
            && values?.contentType?.conforms(to: .executable) != true
            && values?.contentType?.conforms(to: .script) != true
            && values?.contentType?.conforms(to: .application) != true
    }
    var canPreviewFile: Bool {
        guard let url = fileURL else { return false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.isReadableFile(atPath: url.path) && DemoResourcePreviewPolicy.supports(url)
    }
    var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this resource a name." }
        if title.count > 200 || product.count > 200 || persona.count > 200 { return "Keep names under 200 characters." }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return kind == .file ? "Choose a local file." : (kind == .prompt ? "Add some text." : "Add a web address.") }
        if content.count > 50_000 || notes.count > 10_000 { return "Keep prompts under 50,000 characters and notes under 10,000." }
        if kind == .link && webURL == nil { return "Use a complete http or https link without an embedded username or password." }
        if kind == .file && !content.hasPrefix("/") { return "Choose an absolute local file path." }
        return nil
    }
    static func matching(_ items: [Self], query: String, favoritesOnly: Bool = false) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            (!favoritesOnly || item.favorite) && terms.allSatisfy { term in
                [item.title, item.product, item.persona, item.content, item.notes, item.kind.rawValue]
                    .joined(separator: "\n").localizedStandardContains(term)
            }
        }.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

enum DemoResourcePreviewPolicy {
    /// LaunchServices supplies richer types in the app. The extension fallback
    /// keeps the core checks deterministic when that service is unavailable.
    private static let fallbackExtensions: Set<String> = [
        "aac", "aif", "aiff", "avi", "bmp", "csv", "doc", "docx", "flac", "gif", "heic", "heif",
        "htm", "html", "jpeg", "jpg", "json", "key", "log", "m4a", "m4v", "markdown", "md", "mov",
        "mp3", "mp4", "numbers", "pages", "pdf", "png", "ppt", "pptx", "rtf", "svg", "tif", "tiff",
        "tsv", "txt", "wav", "webp", "xls", "xlsx", "xml", "yaml", "yml"
    ]

    static func supports(_ url: URL) -> Bool {
        guard !FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        guard values?.isDirectory != true,
              values?.contentType?.conforms(to: .executable) != true,
              values?.contentType?.conforms(to: .script) != true,
              values?.contentType?.conforms(to: .application) != true else { return false }
        if let type = values?.contentType {
            return type.conforms(to: .content) || type.conforms(to: .image)
                || type.conforms(to: .audio) || type.conforms(to: .movie)
        }
        return fallbackExtensions.contains(url.pathExtension.lowercased())
    }
}

struct DemoLibraryDocument: Codable {
    var format = "workbench-demo-library"
    var version = 1
    var resources: [DemoResource] = []
}

struct DemoLibraryStore {
    static let limit = 2_000
    static let byteLimit = 16_000_000
    let url: URL
    init(directory: URL = StateStore().url.deletingLastPathComponent()) { url = directory.appendingPathComponent("demo-library.json") }
    static func decode(_ data: Data) throws -> [DemoResource] {
        guard data.count <= byteLimit else { throw VoiceError.message("This library is too large to import (16 MB maximum).") }
        let document = try JSONDecoder().decode(DemoLibraryDocument.self, from: data)
        guard document.format == "workbench-demo-library", document.version == 1 else { throw VoiceError.message("This library format is not supported by this version of Workbench.") }
        try validate(document.resources)
        return document.resources
    }
    static func validate(_ items: [DemoResource]) throws {
        guard items.count <= limit else { throw VoiceError.message("A library can contain up to \(limit) resources.") }
        guard Set(items.map(\.id)).count == items.count else { throw VoiceError.message("This library contains duplicate resource identifiers.") }
        for item in items { if let problem = item.validationMessage { throw VoiceError.message("\(item.title.isEmpty ? "Resource" : item.title): \(problem)") } }
    }
    static func encoded(_ items: [DemoResource], portable: Bool = false) throws -> Data {
        try validate(items)
        let resources = items.map { item -> DemoResource in
            var item = item
            if portable {
                if item.kind == .file, let resolved = item.fileURL { item.content = resolved.path }
                item.bookmark = nil
            }
            return item
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(DemoLibraryDocument(resources: resources))
        guard data.count <= byteLimit else { throw VoiceError.message("This library exceeds the 16 MB metadata limit.") }
        return data
    }
    static func merging(_ incoming: [DemoResource], into existing: [DemoResource]) throws -> [DemoResource] {
        try validate(incoming)
        var ids = Set(existing.map(\.id))
        var merged = existing
        for var item in incoming where ids.insert(item.id).inserted {
            // Bookmarks are a local access grant, never accepted from an exchange file.
            item.bookmark = nil
            merged.append(item)
        }
        try validate(merged)
        return merged
    }
    func load() throws -> [DemoResource] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.byteLimit else { throw VoiceError.message("The saved library exceeds the 16 MB limit.") }
        return try Self.decode(Data(contentsOf: url))
    }
    func save(_ items: [DemoResource]) throws {
        let data = try Self.encoded(items)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class DemoLibraryModel: ObservableObject {
    @Published private(set) var resources: [DemoResource] = [] { didSet { reconcileSelection() } }
    @Published var selection: UUID?
    @Published var draft: DemoResource? { didSet { if draft == nil { draftNotice = nil } } }
    @Published private(set) var draftNotice: String?
    @Published var query = "" { didSet { reconcileSelection() } }
    @Published var favoritesOnly = false { didSet { reconcileSelection() } }
    @Published var notice: String?
    @Published var error: String?
    @Published private(set) var savingDisabled = false
    @Published private(set) var previewingResourceID: UUID?
    let store: DemoLibraryStore
    private let copyText: (String) -> Int?
    private let openURL: (URL) -> Bool
    private let previewer: DemoResourcePreviewing
    private let makePreviewAccess: (URL) -> DemoResourcePreviewAccess
    private var previewAccess: DemoResourcePreviewAccess?
    init(store: DemoLibraryStore = DemoLibraryStore(),
         copyText: ((String) -> Int?)? = nil,
         openURL: ((URL) -> Bool)? = nil,
         previewer: DemoResourcePreviewing? = nil,
         makePreviewAccess: ((URL) -> DemoResourcePreviewAccess)? = nil) {
        self.store = store
        self.copyText = copyText ?? { TextDelivery.copy($0) }
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
        self.previewer = previewer ?? DemoQuickLookPresenter()
        self.makePreviewAccess = makePreviewAccess ?? { DemoResourcePreviewAccess(url: $0) }
        self.previewer.onClose = { [weak self] in self?.finishPreview() }
        do { resources = try store.load(); reconcileSelection() }
        catch { self.error = "The library could not be read. Saving is paused to preserve it. \(error.localizedDescription)"; savingDisabled = true }
    }
    var matches: [DemoResource] { DemoResource.matching(resources, query: query, favoritesOnly: favoritesOnly) }
    var selected: DemoResource? { matches.first { $0.id == selection } }
    private func reconcileSelection() {
        let visible = matches
        if !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
    }
    func newPrompt(_ text: String = "") {
        guard draft == nil else { draftNotice = "Save or cancel this resource before starting another prompt."; return }
        draft = DemoResource(title: String(text.split(separator: "\n").first?.prefix(80) ?? ""), content: text)
    }
    func save(_ proposed: DemoResource) -> Bool {
        var item = proposed
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.product = item.product.trimmingCharacters(in: .whitespacesAndNewlines)
        item.persona = item.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.kind == .link { item.content = item.content.trimmingCharacters(in: .whitespacesAndNewlines) }
        item.modified = Date()
        if previewingResourceID == item.id { closePreview() }
        var next = resources
        if let index = next.firstIndex(where: { $0.id == item.id }) { next[index] = item } else { next.append(item) }
        guard commit(next) else { return false }
        query = ""; favoritesOnly = false; selection = item.id; notice = "Saved \(item.title)."; return true
    }
    @discardableResult private func commit(_ next: [DemoResource]) -> Bool {
        guard !savingDisabled else { return false }
        do { try store.save(next); resources = next; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func favorite(_ item: DemoResource) {
        var item = item; item.favorite.toggle()
        if let index = resources.firstIndex(where: { $0.id == item.id }) { var next = resources; next[index] = item; commit(next) }
    }
    func remove(_ item: DemoResource) {
        if previewingResourceID == item.id { closePreview() }
        if commit(resources.filter { $0.id != item.id }) { notice = "Removed from the library. The original file is unchanged." }
    }
    /// Both the visible button and keyboard recall act on the current filtered selection.
    /// Returning true means an action was attempted; copy/open report their own failures.
    @discardableResult func performPrimaryAction() -> Bool {
        guard draft == nil, let item = selected, item.primaryActionAvailable else { return false }
        if item.kind == .prompt { copy(item) } else { open(item) }
        return true
    }
    func copy(_ item: DemoResource) {
        let text = item.kind == .file ? (item.fileURL?.path ?? item.content) : item.content
        guard copyText(text) != nil else {
            notice = nil; error = "The clipboard could not be updated. Try copying again."
            return
        }
        if !savingDisabled { error = nil }
        notice = item.kind == .file ? "File path copied." : "\(item.kind.rawValue) copied. Paste when you are ready."
    }
    func chooseFile(for existing: DemoResource? = nil) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a video, deck, image, or demo file. Workbench keeps a reference to the original."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var item = existing ?? DemoResource(kind: .file, title: url.deletingPathExtension().lastPathComponent)
        item.kind = .file; item.content = url.path
        #if APP_STORE
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        #endif
        do { item.bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { self.error = "File access could not be saved. Choose the file again. \(error.localizedDescription)"; return }
        draft = item
    }
    func open(_ item: DemoResource, reveal: Bool = false) {
        if item.kind == .link {
            guard let url = item.webURL else { error = "This web link is not valid."; return }
            if !openURL(url) { error = "No application could open this link." }
            return
        }
        guard let resolved = item.resolvedFile else { error = "Locate this file again to reconnect it."; return }
        let url = resolved.url
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path) else { error = "This file is unavailable. Connect its drive or use Locate file to reconnect it."; return }
        guard reveal || item.canOpenFile else { error = "Applications and executable files can be inspected with Show in Finder."; return }
        _ = refreshFileReference(item, resolved: resolved)
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else if !openURL(url) { error = "No application could open this file. Use Show in Finder to choose one." }
    }
    func preview(_ item: DemoResource) {
        closePreview()
        guard item.kind == .file, let resolved = item.resolvedFile else {
            error = "Locate this file again before previewing it."
            return
        }
        let url = resolved.url
        let access = makePreviewAccess(url)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            error = "This file is unavailable. Connect its drive or use Locate file to reconnect it."
            return
        }
        guard DemoResourcePreviewPolicy.supports(url) else {
            error = "Quick Look does not support this file type here. Use Show in Finder or open it in its usual app."
            return
        }
        previewAccess = access
        previewingResourceID = item.id
        guard previewer.show(url: url, title: item.title) else {
            finishPreview()
            error = "Quick Look could not open this file. Use Show in Finder or try its usual app."
            return
        }
        if !savingDisabled { error = nil }
        _ = refreshFileReference(item, resolved: resolved)
    }
    func closePreview() { previewer.close() }
    private func finishPreview() {
        previewAccess?.release()
        previewAccess = nil
        previewingResourceID = nil
    }
    @discardableResult private func refreshFileReference(_ item: DemoResource, resolved: (url: URL, stale: Bool)) -> Bool {
        guard resolved.stale || item.content != resolved.url.path else { return true }
        do {
            var updated = item; updated.content = resolved.url.path
            #if APP_STORE
            let options: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkCreationOptions = [.minimalBookmark]
            #endif
            updated.bookmark = try resolved.url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            guard let index = resources.firstIndex(where: { $0.id == item.id }) else { return true }
            var next = resources; next[index] = updated
            return commit(next)
        } catch {
            self.error = "Saved file access could not be refreshed. Use Locate file before the next demo."
            return false
        }
    }
    func exportLibrary() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Workbench Demo Library.json"
        panel.message = "Export prompts, links, notes and file paths. Media files stay in their original folders."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DemoLibraryStore.encoded(resources, portable: true).write(to: url, options: .atomic); notice = "Library exported. Original media files were not copied." }
        catch { self.error = error.localizedDescription }
    }
    func importLibrary() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.message = "Add resources from a Workbench library. Existing resources are kept; matching IDs are skipped."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= DemoLibraryStore.byteLimit else { throw VoiceError.message("Choose a library smaller than 16 MB.") }
            let incoming = try DemoLibraryStore.decode(Data(contentsOf: url))
            let next = try DemoLibraryStore.merging(incoming, into: resources)
            let added = next.count - resources.count
            if commit(next) { notice = "Added \(added) resources. Existing resources kept. Files on another Mac may need Locate file." }
        } catch { self.error = "Import failed. \(error.localizedDescription)" }
    }
}
