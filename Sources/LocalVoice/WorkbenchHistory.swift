import Combine
import Foundation

/// What a selection can point at. Snap & Talk keeps its own session storage and
/// dictation keeps its own history; this owner only records that one was chosen.
enum WorkbenchItemKind: String, Codable {
    case transcript, snap
}

/// A reference, never a copy. No transcript text, audio or screenshot bytes are
/// stored here, so a saved selection cannot drift from the record it names.
struct WorkbenchItemReference: Hashable, Codable {
    var kind: WorkbenchItemKind
    var id: UUID
}

/// One named or ad hoc selection, frozen when it was saved. Changing the current
/// selection afterwards never rewrites this snapshot.
struct SavedWorkbenchSelection: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var items: [WorkbenchItemReference]
    var updatedAt: Date
}

/// Why a dictation was recorded. Ordinary dictation is Prompt: a category on the
/// existing capture, not a second saved-prompt record. Meetings and calls are
/// reference material. No identity is ever inferred from the words themselves.
enum TranscriptPurpose: String, Codable, CaseIterable {
    case prompt, meeting, call, note

    var title: String {
        switch self {
        case .prompt: return "Prompt"
        case .meeting: return "Meeting"
        case .call: return "Call"
        case .note: return "Note"
        }
    }
}

/// Optional details a person adds to an existing capture. Every field defaults to
/// the state a capture already had, so an older transcript keeps its original
/// text and reads as an ordinary Prompt without being changed.
struct TranscriptMetadata: Codable, Equatable {
    enum CodingKeys: String, CodingKey { case purpose, person, company, tags }

    var purpose: TranscriptPurpose = .prompt
    var person: String = ""
    var company: String = ""
    var tags: [String] = []

    /// The fields search looks at beside the transcript's own wording.
    var searchFields: [String] { [purpose.title, person, company] + tags }

    func validated() throws -> Self {
        var cleaned = self
        cleaned.person = try WorkbenchHistoryLibrary.field(person, limit: WorkbenchHistoryLibrary.maximumFieldCharacters, label: "A person’s name")
        cleaned.company = try WorkbenchHistoryLibrary.field(company, limit: WorkbenchHistoryLibrary.maximumFieldCharacters, label: "A company name")
        var kept: [String] = []
        var seen = Set<String>()
        for tag in tags {
            let value = try WorkbenchHistoryLibrary.field(tag, limit: WorkbenchHistoryLibrary.maximumTagCharacters, label: "A tag")
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            kept.append(value)
        }
        guard kept.count <= WorkbenchHistoryLibrary.maximumTags else {
            throw WorkbenchHistoryError.invalid("a capture cannot carry more than \(WorkbenchHistoryLibrary.maximumTags) tags")
        }
        cleaned.tags = kept
        return cleaned
    }
}

extension TranscriptMetadata {
    /// Missing fields take their defaults, so details saved by an earlier build
    /// stay readable. An unrecognised purpose is damage, not a default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        purpose = try container.decodeIfPresent(TranscriptPurpose.self, forKey: .purpose) ?? .prompt
        person = try container.decodeIfPresent(String.self, forKey: .person) ?? ""
        company = try container.decodeIfPresent(String.self, forKey: .company) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

struct WorkbenchTranscriptRecord: Codable, Equatable {
    var id: UUID
    var metadata: TranscriptMetadata
}

enum WorkbenchHistoryError: LocalizedError, Equatable {
    case unreadable
    case future(Int)
    case invalid(String)
    case unknownSelection

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "Workbench could not read \(WorkbenchHistoryStore.fileName), so saved selections and transcript details are unavailable. The file was kept exactly as found; move or repair it in Workbench’s Application Support folder before saving again."
        case .future(let version):
            return "\(WorkbenchHistoryStore.fileName) was written by a newer version of Workbench (format \(version)). It was kept unchanged, so this version does not save selections or transcript details."
        case .invalid(let reason):
            return "Selections and transcript details were not saved: \(reason). The saved file was kept unchanged."
        case .unknownSelection:
            return "That saved selection is no longer in the library. Nothing was changed."
        }
    }
}

/// The whole private sidecar: current selection, saved selections and the optional
/// details added to captures. Transcript text, recordings and Snap & Talk media
/// stay with their own owners.
struct WorkbenchHistoryLibrary: Codable, Equatable {
    enum CodingKeys: String, CodingKey { case version, selected, savedSelections, transcripts }

    static let currentVersion = 1
    // Bounds a person can reach only by mistake. History is no longer trimmed, so
    // they leave room for years of captures rather than a recent window.
    static let maximumSelections = 100
    static let maximumItemsPerSelection = 10_000
    static let maximumSelectedItems = 10_000
    static let maximumTranscripts = 20_000
    static let maximumNameCharacters = 80
    static let maximumFieldCharacters = 120
    static let maximumTags = 12
    static let maximumTagCharacters = 40

    var version = WorkbenchHistoryLibrary.currentVersion
    var selected: [WorkbenchItemReference] = []
    var savedSelections: [SavedWorkbenchSelection] = []
    var transcripts: [WorkbenchTranscriptRecord] = []

    /// A deterministic order, so identical state always produces identical bytes.
    static func ordered(_ references: [WorkbenchItemReference]) -> [WorkbenchItemReference] {
        Array(Set(references)).sorted { ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString) }
    }

    static func field(_ value: String, limit: Int, label: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= limit else { throw WorkbenchHistoryError.invalid("\(label) is longer than \(limit) characters") }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw WorkbenchHistoryError.invalid("\(label) cannot contain line breaks or control characters")
        }
        return trimmed
    }

    /// Bounds and normalisation for both directions: nothing is written or
    /// published before it passes, and a malformed file is refused rather than
    /// silently repaired.
    func validated() throws -> Self {
        guard version == Self.currentVersion else {
            throw version > Self.currentVersion ? WorkbenchHistoryError.future(version) : WorkbenchHistoryError.unreadable
        }
        let selected = Self.ordered(self.selected)
        guard selected.count <= Self.maximumSelectedItems else {
            throw WorkbenchHistoryError.invalid("more than \(Self.maximumSelectedItems) items cannot be selected at once")
        }
        guard savedSelections.count <= Self.maximumSelections else {
            throw WorkbenchHistoryError.invalid("more than \(Self.maximumSelections) saved selections cannot be kept")
        }
        var usedSelectionIDs = Set<UUID>()
        var selections: [SavedWorkbenchSelection] = []
        for selection in savedSelections {
            guard usedSelectionIDs.insert(selection.id).inserted else {
                throw WorkbenchHistoryError.invalid("two saved selections share one identifier")
            }
            let name = try Self.field(selection.name, limit: Self.maximumNameCharacters, label: "A selection name")
            guard !name.isEmpty else { throw WorkbenchHistoryError.invalid("a saved selection needs a name") }
            let items = Self.ordered(selection.items)
            guard items.count <= Self.maximumItemsPerSelection else {
                throw WorkbenchHistoryError.invalid("a saved selection cannot hold more than \(Self.maximumItemsPerSelection) items")
            }
            selections.append(SavedWorkbenchSelection(id: selection.id, name: name, items: items, updatedAt: selection.updatedAt))
        }
        var usedTranscriptIDs = Set<UUID>()
        var records: [WorkbenchTranscriptRecord] = []
        for record in transcripts {
            guard usedTranscriptIDs.insert(record.id).inserted else {
                throw WorkbenchHistoryError.invalid("two captures share one identifier in their saved details")
            }
            let metadata = try record.metadata.validated()
            // Details that say nothing more than the defaults are not stored.
            guard metadata != TranscriptMetadata() else { continue }
            records.append(WorkbenchTranscriptRecord(id: record.id, metadata: metadata))
        }
        guard records.count <= Self.maximumTranscripts else {
            throw WorkbenchHistoryError.invalid("details cannot be kept for more than \(Self.maximumTranscripts) captures")
        }
        records.sort { $0.id.uuidString < $1.id.uuidString }
        return Self(version: Self.currentVersion, selected: selected, savedSelections: selections, transcripts: records)
    }
}

extension WorkbenchHistoryLibrary {
    /// A missing field decodes to its default, so a sidecar written by an earlier
    /// build of this format stays usable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        selected = try container.decodeIfPresent([WorkbenchItemReference].self, forKey: .selected) ?? []
        savedSelections = try container.decodeIfPresent([SavedWorkbenchSelection].self, forKey: .savedSelections) ?? []
        transcripts = try container.decodeIfPresent([WorkbenchTranscriptRecord].self, forKey: .transcripts) ?? []
    }
}

/// One versioned private sidecar beside the existing voice state. It is written
/// whole through a sibling staging file and an atomic replacement, so a failure
/// leaves the previous file in place and creates no folder per selection.
final class WorkbenchHistoryStore {
    static let fileName = "history-library.json"
    static let stagingPrefix = ".history-library-"
    static let maximumBytes = 16 * 1024 * 1024

    let url: URL
    private var expectedData: Data?
    private var directory: URL { url.deletingLastPathComponent() }

    init(directory: URL) { url = directory.appendingPathComponent(Self.fileName) }

    /// An absent sidecar is an empty library, not an error.
    func load() throws -> WorkbenchHistoryLibrary {
        guard let data = try readData() else { expectedData = nil; return WorkbenchHistoryLibrary() }
        let decoded: WorkbenchHistoryLibrary
        do { decoded = try JSONDecoder().decode(WorkbenchHistoryLibrary.self, from: data) }
        catch {
            // A newer format may not decode into this shape at all. Say so
            // instead of calling the person's saved work damaged.
            if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), probe.version > WorkbenchHistoryLibrary.currentVersion {
                throw WorkbenchHistoryError.future(probe.version)
            }
            throw WorkbenchHistoryError.unreadable
        }
        let checked = try decoded.validated()
        expectedData = data
        return checked
    }

    /// Returns exactly what reached the disk, so the caller publishes the saved
    /// state rather than its request.
    @discardableResult func save(_ library: WorkbenchHistoryLibrary) throws -> WorkbenchHistoryLibrary {
        let checked = try library.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checked)
        guard data.count <= Self.maximumBytes else {
            throw WorkbenchHistoryError.invalid("the library would be larger than \(Self.maximumBytes / (1024 * 1024)) MB")
        }
        try prepareDirectory()
        guard try readData() == expectedData else {
            throw WorkbenchHistoryError.invalid("the library changed since it was opened. Reopen Workbench before saving")
        }
        let staging = directory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString + ".json")
        do {
            try data.write(to: staging)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        expectedData = data
        return checked
    }

    private struct VersionProbe: Decodable {
        var version = 0
        private enum CodingKeys: String, CodingKey { case version }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        }
    }

    /// A huge or aliased file is refused before it is read into memory.
    private func readData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard let values, values.isSymbolicLink != true, values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= Self.maximumBytes else { throw WorkbenchHistoryError.unreadable }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumBytes else { throw WorkbenchHistoryError.unreadable }
        return data
    }

    private func prepareDirectory() throws {
        // Only a directory this store creates gets its permissions set: an
        // existing folder's own protection is left to the person and the OS.
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw WorkbenchHistoryError.invalid("“\(directory.lastPathComponent)” is not a usable folder")
        }
    }
}

/// Selection and capture details for the existing history, kept beside it rather
/// than inside transcript state. Missing references are retained and visible
/// until someone removes them deliberately.
@MainActor
final class WorkbenchHistoryModel: ObservableObject {
    @Published private(set) var selected: Set<WorkbenchItemReference> = []
    @Published private(set) var savedSelections: [SavedWorkbenchSelection] = []
    @Published private(set) var error: String?

    let store: WorkbenchHistoryStore
    /// Set when the sidecar could not be understood. Nothing is written while it
    /// holds a value, so unknown or damaged saved state is never replaced.
    private(set) var loadFailure: WorkbenchHistoryError?
    private var metadataByID: [UUID: TranscriptMetadata] = [:]
    private let now: () -> Date

    var isBlocked: Bool { loadFailure != nil }

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        store = WorkbenchHistoryStore(directory: directory)
        self.now = now
        do {
            let library = try store.load()
            selected = Set(library.selected)
            savedSelections = library.savedSelections
            metadataByID = Dictionary(uniqueKeysWithValues: library.transcripts.map { ($0.id, $0.metadata) })
        } catch {
            let failure = error as? WorkbenchHistoryError ?? .unreadable
            loadFailure = failure
            self.error = failure.errorDescription
        }
    }

    func setSelected(_ refs: Set<WorkbenchItemReference>) {
        apply { $0.selected = Array(refs) }
    }

    /// Freezes the current selection under a name. Passing an existing id renames
    /// and re-snapshots that one record instead of adding another.
    func saveSelection(name: String, id: UUID? = nil) {
        let items = WorkbenchHistoryLibrary.ordered(Array(selected))
        let stamp = now()
        apply { library in
            if let id {
                guard let index = library.savedSelections.firstIndex(where: { $0.id == id }) else {
                    throw WorkbenchHistoryError.unknownSelection
                }
                library.savedSelections[index].name = name
                library.savedSelections[index].items = items
                library.savedSelections[index].updatedAt = stamp
            } else {
                library.savedSelections.append(SavedWorkbenchSelection(id: UUID(), name: name, items: items, updatedAt: stamp))
            }
        }
    }

    /// Restores a snapshot, including references whose capture is no longer in
    /// history: they stay visible until they are removed on purpose.
    func loadSelection(_ id: UUID) {
        apply { library in
            guard let selection = library.savedSelections.first(where: { $0.id == id }) else {
                throw WorkbenchHistoryError.unknownSelection
            }
            library.selected = selection.items
        }
    }

    func removeSelection(_ id: UUID) {
        apply { library in
            guard let index = library.savedSelections.firstIndex(where: { $0.id == id }) else {
                throw WorkbenchHistoryError.unknownSelection
            }
            library.savedSelections.remove(at: index)
        }
    }

    /// Captures without saved details read as an ordinary Prompt, exactly as they
    /// did before details existed.
    func metadata(for id: UUID) -> TranscriptMetadata { metadataByID[id] ?? TranscriptMetadata() }

    func setMetadata(_ metadata: TranscriptMetadata, for id: UUID) {
        apply { library in
            library.transcripts.removeAll { $0.id == id }
            library.transcripts.append(WorkbenchTranscriptRecord(id: id, metadata: metadata))
        }
    }

    /// Case-insensitive search across the cleaned wording, the original wording
    /// and the saved details. Several terms all have to match somewhere.
    func matching(_ transcripts: [Transcript], query: String) -> [Transcript] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return transcripts }
        return transcripts.filter { transcript in
            var fields = [transcript.text]
            if let raw = transcript.rawText { fields.append(raw) }
            fields += metadata(for: transcript.id).searchFields
            return terms.allSatisfy { term in fields.contains { $0.localizedCaseInsensitiveContains(term) } }
        }
    }

    /// Deliberate removal only. Filtering, a failed read or a moved Snap & Talk
    /// session must never reach this method.
    func removeReferences(kind: WorkbenchItemKind, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        apply { library in
            library.selected.removeAll { $0.kind == kind && ids.contains($0.id) }
            for index in library.savedSelections.indices {
                library.savedSelections[index].items.removeAll { $0.kind == kind && ids.contains($0.id) }
            }
            if kind == .transcript { library.transcripts.removeAll { ids.contains($0.id) } }
        }
    }

    private func currentLibrary() -> WorkbenchHistoryLibrary {
        WorkbenchHistoryLibrary(version: WorkbenchHistoryLibrary.currentVersion,
                                selected: Array(selected),
                                savedSelections: savedSelections,
                                transcripts: metadataByID.map { WorkbenchTranscriptRecord(id: $0.key, metadata: $0.value) })
    }

    /// Published state follows the disk. A refused or failed write keeps the
    /// previous state and reports why.
    private func apply(_ change: (inout WorkbenchHistoryLibrary) throws -> Void) {
        if let loadFailure {
            error = loadFailure.errorDescription
            return
        }
        var candidate = currentLibrary()
        do {
            try change(&candidate)
            let checked = try candidate.validated()
            if let existing = try? currentLibrary().validated(), existing == checked {
                error = nil
                return
            }
            publish(try store.save(checked))
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    private func publish(_ library: WorkbenchHistoryLibrary) {
        selected = Set(library.selected)
        savedSelections = library.savedSelections
        metadataByID = Dictionary(uniqueKeysWithValues: library.transcripts.map { ($0.id, $0.metadata) })
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? WorkbenchHistoryError { return error.errorDescription ?? "\(error)" }
        let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return WorkbenchHistoryError.invalid(reason).errorDescription ?? reason
    }
}
