import Foundation

/// A review owns a frozen, validated exchange document and the library it was
/// compared with. Incoming bookmarks are discarded before comparison or probing.
struct DemoLibraryImport: Identifiable {
    enum Status: String, CaseIterable { case new = "New", changed = "Changed", unchanged = "Unchanged" }
    struct Entry: Identifiable {
        let incoming: DemoResource
        let current: DemoResource?
        let status: Status
        var id: UUID { incoming.id }
    }
    let id = UUID()
    let sourceName: String
    let baseline: [DemoResource]
    let entries: [Entry]
    let unavailableFileCount: Int

    init(incoming: [DemoResource], existing: [DemoResource], sourceName: String) throws {
        try DemoLibraryStore.validate(incoming)
        try DemoLibraryStore.validate(existing)
        self.sourceName = sourceName
        baseline = existing
        let local = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        entries = incoming.map { resource in
            var safe = resource; safe.bookmark = nil; safe.browserTarget = nil
            let current = local[safe.id]
            let status: Status = current.map {
                Self.comparable($0, resolveLocalFile: true) == Self.comparable(safe, resolveLocalFile: false) ? .unchanged : .changed
            } ?? .new
            return Entry(incoming: safe, current: current, status: status)
        }
        unavailableFileCount = entries.filter { $0.incoming.kind == .file && !$0.incoming.fileAvailable }.count
    }

    func count(_ status: Status) -> Int { entries.filter { $0.status == status }.count }

    func applying(useIncoming: Set<UUID>) throws -> [DemoResource] {
        let changed = Set(entries.filter { $0.status == .changed }.map(\.id))
        guard useIncoming.isSubset(of: changed) else { throw VoiceError.message("The import choices no longer match this review. Open the library again.") }
        var next = baseline
        let indexes = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element.id, $0.offset) })
        for entry in entries {
            if entry.status == .new { next.append(entry.incoming) }
            else if useIncoming.contains(entry.id), let index = indexes[entry.id] {
                var replacement = entry.incoming
                // Retain this Mac's grant only when the selected incoming file
                // still names the same resolved local path. Never import a grant.
                if let current = entry.current, current.kind == .file, replacement.kind == .file,
                   current.fileURL?.resolvingSymlinksInPath().standardizedFileURL == URL(fileURLWithPath: replacement.content).resolvingSymlinksInPath().standardizedFileURL {
                    replacement.bookmark = current.bookmark
                }
                if let current = entry.current, current.kind == .link, replacement.kind == .link,
                   current.content == replacement.content { replacement.browserTarget = current.browserTarget }
                next[index] = replacement
            }
        }
        try DemoLibraryStore.validate(next)
        return next
    }

    private static func comparable(_ resource: DemoResource, resolveLocalFile: Bool) -> DemoResource {
        var result = resource
        if result.kind == .file {
            let url = resolveLocalFile ? result.fileURL : URL(fileURLWithPath: result.content)
            if let url { result.content = url.resolvingSymlinksInPath().standardizedFileURL.path }
        }
        result.bookmark = nil
        result.browserTarget = nil
        // A timestamp alone is not an edit that warrants replacing local data.
        result.modified = .distantPast
        return result
    }
}
