import Foundation

// MARK: - Catalogue

/// `catalog.json` at the repository root. It lists the published releases and
/// the digest of each release manifest, so the manifest itself is verified
/// before any payload byte is requested.
///
/// ```json
/// {"formatVersion":1,"id":"example-company","name":"Example Company",
///  "releases":[{"version":"1.0.0","minimumAppVersion":"2.2.0",
///               "manifestPath":"releases/1.0.0/pack.json","sha256":"<manifest digest>"}]}
/// ```
public struct PackCatalog: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var id: String
    public var name: String
    public var releases: [PackRelease]

    public init(formatVersion: Int = PackFormat.current, id: String, name: String, releases: [PackRelease]) {
        self.formatVersion = formatVersion; self.id = id; self.name = name; self.releases = releases
    }

    @discardableResult
    public func validated() throws -> PackCatalog {
        guard formatVersion == PackFormat.current else {
            throw PackError.content("This pack catalogue uses format version \(formatVersion). Update Workbench to install it.")
        }
        try PackIdentifier.validated(id, label: "The catalogue pack id")
        try PackText.validated(name, label: "The catalogue pack name")
        guard !releases.isEmpty, releases.count <= PackLimits.maximumReleaseCount else {
            throw PackError.content("This pack catalogue lists no releases, or more than \(PackLimits.maximumReleaseCount).")
        }
        var versions: Set<PackVersion> = []
        for release in releases {
            try release.validated()
            guard versions.insert(release.version).inserted else {
                throw PackError.content("This pack catalogue lists version \(release.version) more than once.")
            }
        }
        return self
    }

    /// The newest release this app can run. Selection never falls back to a
    /// release that declares a newer minimum app version.
    public func release(compatibleWith appVersion: PackVersion) throws -> PackRelease {
        try validated()
        let usable = releases.filter { $0.minimumAppVersion <= appVersion }
        guard let best = usable.max(by: { $0.version < $1.version }) else {
            let required = releases.map(\.minimumAppVersion).min() ?? appVersion
            throw PackError.compatibility("This pack needs Workbench \(required) or later. Update Workbench, then install the pack again.")
        }
        return best
    }

    /// One pinned version, still subject to the same compatibility rule.
    public func release(version: PackVersion, compatibleWith appVersion: PackVersion) throws -> PackRelease {
        try validated()
        guard let release = releases.first(where: { $0.version == version }) else {
            throw PackError.content("This pack catalogue does not publish version \(version).")
        }
        guard release.minimumAppVersion <= appVersion else {
            throw PackError.compatibility("Version \(version) of this pack needs Workbench \(release.minimumAppVersion) or later.")
        }
        return release
    }

    public var latestVersion: PackVersion? { releases.map(\.version).max() }
    public var minimumRequiredAppVersion: PackVersion? { releases.map(\.minimumAppVersion).min() }
}

public struct PackRelease: Codable, Equatable, Sendable {
    public var version: PackVersion
    public var minimumAppVersion: PackVersion
    /// Relative to the directory that contains the catalogue.
    public var manifestPath: String
    /// SHA-256 of the manifest bytes.
    public var sha256: String

    public init(version: PackVersion, minimumAppVersion: PackVersion, manifestPath: String, sha256: String) {
        self.version = version; self.minimumAppVersion = minimumAppVersion
        self.manifestPath = manifestPath; self.sha256 = sha256
    }

    @discardableResult
    public func validated() throws -> PackRelease {
        try PackPath.validated(manifestPath)
        try PackDigest.validated(sha256, label: "A release manifest digest")
        return self
    }
}

// MARK: - Manifest

/// What a pack entry offers the app. Unknown kinds fail to decode, so a future
/// pack cannot quietly install content this version does not understand.
public enum PackEntryKind: String, Codable, Equatable, Sendable, CaseIterable {
    case skill, scene, personas, resources

    /// A skill is a directory of instructions, artwork and helper files, and it
    /// travels into a session as one subtree. The other kinds are single files.
    public var includesDirectorySubtree: Bool { self == .skill }
}

public enum PackInputKind: String, Codable, Sendable {
    case snapAndTalk = "snap-and-talk"
    case transcripts
}

public struct PackEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: PackEntryKind
    public var name: String
    public var path: String
    public var inputKinds: [PackInputKind]?

    public init(id: String, kind: PackEntryKind, name: String, path: String, inputKinds: [PackInputKind]? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.path = path; self.inputKinds = inputKinds
    }
}

public struct PackFile: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
    public var size: Int

    public init(path: String, sha256: String, size: Int) {
        self.path = path; self.sha256 = sha256; self.size = size
    }
}

/// Optional workspace branding. Branded artwork is inert content: it is stored,
/// read and copied, never executed or imported as code.
public struct PackBranding: Codable, Equatable, Sendable {
    public var label: String
    public var logoPath: String?

    public init(label: String, logoPath: String? = nil) {
        self.label = label; self.logoPath = logoPath
    }

    @discardableResult
    public func validated() throws -> PackBranding {
        try PackText.validated(label, label: "The pack branding label")
        if let logoPath { try PackPath.validated(logoPath) }
        return self
    }
}

/// `pack.json` for one release. Every path is relative to the directory that
/// contains this manifest.
///
/// ```json
/// {"formatVersion":1,"id":"example-company","name":"Example Company","version":"1.0.0",
///  "minimumAppVersion":"2.2.0",
///  "entries":[{"id":"snap-and-talk","kind":"skill","name":"Example Company slides",
///              "path":"skills/snap-and-talk/SKILL.md"}],
///  "files":[{"path":"skills/snap-and-talk/SKILL.md","sha256":"...","size":123}],
///  "branding":{"label":"Example Company","logoPath":"skills/snap-and-talk/brand/assets/logo_wordmark.png"}}
/// ```
public struct PackManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var id: String
    public var name: String
    public var version: PackVersion
    public var minimumAppVersion: PackVersion
    public var entries: [PackEntry]
    public var files: [PackFile]
    public var branding: PackBranding?

    public init(formatVersion: Int = PackFormat.current, id: String, name: String, version: PackVersion,
                minimumAppVersion: PackVersion, entries: [PackEntry], files: [PackFile], branding: PackBranding? = nil) {
        self.formatVersion = formatVersion; self.id = id; self.name = name; self.version = version
        self.minimumAppVersion = minimumAppVersion; self.entries = entries; self.files = files; self.branding = branding
    }

    @discardableResult
    public func validated() throws -> PackManifest {
        guard formatVersion == PackFormat.current else {
            throw PackError.content("This pack manifest uses format version \(formatVersion). Update Workbench to install it.")
        }
        try PackIdentifier.validated(id, label: "The pack id")
        try PackText.validated(name, label: "The pack name")
        guard !files.isEmpty, files.count <= PackLimits.maximumFileCount else {
            throw PackError.content("A pack lists between 1 and \(PackLimits.maximumFileCount) files.")
        }
        guard !entries.isEmpty, entries.count <= PackLimits.maximumEntryCount else {
            throw PackError.content("A pack lists between 1 and \(PackLimits.maximumEntryCount) entries.")
        }

        var records: [String: PackFile] = [:]
        var folded: Set<String> = []
        for file in files {
            let path = try PackPath.validated(file.path)
            try PackDigest.validated(file.sha256, label: "A pack file digest")
            guard file.size > 0, file.size <= PackLimits.maximumFileBytes else {
                throw PackError.content("“\(path)” must be between 1 byte and \(PackLimits.maximumFileBytes / 1_048_576) MB.")
            }
            guard records.updateValue(file, forKey: path) == nil,
                  folded.insert(PackPath.foldedKey(path)).inserted else {
                throw PackError.content("This pack lists “\(path)” more than once. Two paths must differ by more than letter case.")
            }
        }
        _ = try PackLimits.total(of: files.map(\.size))
        // A path cannot be both a file and a directory on disk.
        for path in records.keys {
            var directory = PackPath.directory(of: path)
            while !directory.isEmpty {
                guard !folded.contains(PackPath.foldedKey(directory)) else {
                    throw PackError.content("This pack lists “\(directory)” as a file and as a folder.")
                }
                directory = PackPath.directory(of: directory)
            }
        }

        var entryIDs: Set<String> = []
        var skillDirectories: Set<String> = []
        for entry in entries {
            try PackIdentifier.validated(entry.id, label: "A pack entry id")
            try PackText.validated(entry.name, label: "A pack entry name")
            let path = try PackPath.validated(entry.path)
            guard entryIDs.insert(entry.id).inserted else {
                throw PackError.content("This pack lists the entry “\(entry.id)” more than once.")
            }
            guard let record = records[path] else {
                throw PackError.content("“\(entry.name)” refers to \(path), which this pack does not list as a file.")
            }
            guard entry.kind.includesDirectorySubtree else { continue }
            guard PackPath.name(of: path) == "SKILL.md" else {
                throw PackError.content("The skill “\(entry.name)” must use SKILL.md as its entry point.")
            }
            let directory = PackPath.directory(of: path)
            guard !directory.isEmpty else {
                throw PackError.content("The skill “\(entry.name)” must live in its own folder inside the pack.")
            }
            guard skillDirectories.insert(PackPath.foldedKey(directory)).inserted else {
                throw PackError.content("Two skills share the folder “\(directory)”. Give each skill its own folder.")
            }
            guard record.size <= PackLimits.maximumSkillBytes else {
                throw PackError.content("The skill “\(entry.name)” is larger than \(PackLimits.maximumSkillBytes / 1_048_576) MB of instructions.")
            }
        }

        if let branding = try branding?.validated(), let logo = branding.logoPath {
            guard records[logo] != nil else {
                throw PackError.content("The branding logo \(logo) is not one of this pack's files.")
            }
        }
        return self
    }

    /// The catalogue and the manifest must describe the same release. A
    /// repository cannot advertise one version and deliver another.
    public func agrees(with release: PackRelease, in catalog: PackCatalog) throws {
        guard id == catalog.id, name == catalog.name else {
            throw PackError.content("This pack manifest names a different pack than the catalogue. Nothing was installed.")
        }
        guard version == release.version, minimumAppVersion == release.minimumAppVersion else {
            throw PackError.content("This pack manifest does not match the release the catalogue publishes. Nothing was installed.")
        }
    }

    public func file(at path: String) -> PackFile? { files.first { $0.path == path } }
    public func entry(id: String) -> PackEntry? { entries.first { $0.id == id } }
    public var totalSize: Int { (try? PackLimits.total(of: files.map(\.size))) ?? 0 }

    /// The files one entry needs. A skill brings its whole directory subtree so
    /// its artwork and helper scripts travel with its instructions.
    public func files(for entry: PackEntry) throws -> [PackFile] {
        guard let record = file(at: entry.path) else {
            throw PackError.content("“\(entry.name)” refers to a file this pack does not list.")
        }
        guard entry.kind.includesDirectorySubtree else { return [record] }
        let directory = PackPath.directory(of: entry.path)
        guard !directory.isEmpty else {
            throw PackError.content("The skill “\(entry.name)” must live in its own folder inside the pack.")
        }
        return files.filter { PackPath.isInside($0.path, directory: directory) }.sorted { $0.path < $1.path }
    }
}

// MARK: - Payload

/// A complete pack revision in memory, checked against its manifest. Building
/// one is the only way to obtain pack bytes, so a receipt alone never stands in
/// for the actual content.
public struct PackPayload: Equatable, Sendable {
    public let manifest: PackManifest
    public let files: [String: Data]

    public init(manifest: PackManifest, files: [String: Data]) throws {
        let manifest = try manifest.validated()
        guard Set(files.keys) == Set(manifest.files.map(\.path)) else {
            throw PackError.content("This pack's files do not match the list in its manifest. Nothing was installed.")
        }
        for record in manifest.files {
            guard let data = files[record.path], data.count == record.size,
                  PackDigest.hex(data) == record.sha256 else {
                throw PackError.content("“\(record.path)” does not match the size or digest this pack publishes.")
            }
        }
        for entry in manifest.entries where entry.kind == .skill {
            try PackPayload.validateSkill(entry: entry, data: files[entry.path])
        }
        self.manifest = manifest
        self.files = files
    }

    static func validateSkill(entry: PackEntry, data: Data?) throws {
        guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PackError.content("The skill “\(entry.name)” is empty or is not readable UTF-8 text. Nothing was installed.")
        }
    }

    public func data(at path: String) throws -> Data {
        guard let data = files[path] else {
            throw PackError.content("This pack does not contain \(path).")
        }
        return data
    }

    public func snapshot(entryID: String) throws -> PackEntrySnapshot {
        guard let entry = manifest.entry(id: entryID) else {
            throw PackError.content("This pack does not contain “\(entryID)”.")
        }
        var selected: [String: Data] = [:]
        for record in try manifest.files(for: entry) { selected[record.path] = files[record.path] }
        return try PackEntrySnapshot(manifest: manifest, entry: entry, files: selected)
    }

    public var brandingLogo: Data? {
        guard let path = manifest.branding?.logoPath else { return nil }
        return files[path]
    }
}

/// One entry's complete content, keyed relative to the entry's own folder: the
/// shape a session snapshot keeps, so an installed pack and a saved session
/// never need to agree on the pack's internal layout.
public struct PackEntrySnapshot: Equatable, Sendable {
    public let packID: String
    public let packName: String
    public let version: PackVersion
    public let entry: PackEntry
    public let baseDirectory: String
    public let files: [String: Data]
    public let primaryPath: String

    public init(manifest: PackManifest, entry: PackEntry, files: [String: Data]) throws {
        let manifest = try manifest.validated()
        guard manifest.entry(id: entry.id) == entry else {
            throw PackError.content("“\(entry.name)” is not an entry of this pack.")
        }
        let records = try manifest.files(for: entry)
        guard Set(files.keys) == Set(records.map(\.path)) else {
            throw PackError.content("The files for “\(entry.name)” do not match its manifest entry.")
        }
        let base = PackPath.directory(of: entry.path)
        var relative: [String: Data] = [:]
        for record in records {
            guard let data = files[record.path], data.count == record.size,
                  PackDigest.hex(data) == record.sha256, let key = PackPath.relative(record.path, to: base) else {
                throw PackError.content("“\(record.path)” does not match the size or digest this pack publishes.")
            }
            relative[key] = data
        }
        if entry.kind == .skill { try PackPayload.validateSkill(entry: entry, data: files[entry.path]) }
        guard let primary = PackPath.relative(entry.path, to: base) else {
            throw PackError.content("“\(entry.name)” has an unusable path inside this pack.")
        }
        self.packID = manifest.id
        self.packName = manifest.name
        self.version = manifest.version
        self.entry = entry
        self.baseDirectory = base
        self.files = relative
        self.primaryPath = primary
    }
}
