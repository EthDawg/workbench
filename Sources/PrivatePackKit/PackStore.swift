import Foundation

public struct InstalledPack: Codable, Equatable, Sendable, Identifiable {
    public var id: String { source.storageKey }
    public let source: PackSource
    public let revision: PackRevision
    public let manifest: PackManifest
    public let manifestDigest: String
    public let installedAt: Date
    var directory: String { manifest.version.description + "-" + String(manifestDigest.prefix(16)) }
}

public struct PackInstallResult: Sendable {
    public let pack: InstalledPack
    public let downloadedFiles: Int
    public let reusedFiles: Int
}

/// Only this store owns downloaded packs. Sessions and imported personal copies
/// are outside its root. Activation is one atomic pointer replacement after all
/// bytes have been verified; a failed download leaves the previous pointer alone.
public actor PackStore {
    public let root: URL
    private var updating = false
    private let fm = FileManager.default

    public init(root: URL) { self.root = root }

    public func installed() throws -> [InstalledPack] {
        try prepareRoot()
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: "^github-[0-9a-f]{32}$", options: .regularExpression) != nil }
            .compactMap { directory in
                // Never collect an in-flight staging directory across an actor
                // suspension. At startup, abandoned directories are owned data.
                if !updating { try? recover(directory) }
                return try? readActive(directory)
            }.sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    public func payload(for pack: InstalledPack) throws -> PackPayload {
        let directory = try sourceDirectory(pack.source)
        let current = try readActive(directory)
        guard current == pack else { throw PackError.content("This pack changed. Refresh Packs and try again.") }
        let folder = directory.appendingPathComponent("versions/" + pack.directory)
        var files: [String: Data] = [:]
        for file in pack.manifest.files {
            files[file.path] = try read(try PackPath.url(file.path, in: folder), limit: file.size)
        }
        return try PackPayload(manifest: pack.manifest, files: files)
    }

    public func install(from source: any PackContentSource, appVersion: PackVersion) async throws -> PackInstallResult {
        guard !updating else { throw PackError.content("A pack update is already running. Try again when it finishes.") }
        updating = true
        defer { updating = false }
        try prepareRoot()
        let directory = try sourceDirectory(source.source)
        try mkdir(directory)
        try clearAbandonedStaging(in: directory)
        let previous = try activeIfPresent(directory)
        let revision = try await source.currentRevision()
        let catalog = try await source.catalog(at: revision).validated()
        let release = try catalog.release(compatibleWith: appVersion)
        let document = try await source.manifest(for: release, in: catalog, at: revision)
        let manifest = try document.manifest.validated()
        try manifest.agrees(with: release, in: catalog)
        guard document.digest == release.sha256 else { throw PackError.content("The release manifest digest changed.") }
        if let previous {
            guard previous.manifest.id == manifest.id else { throw PackError.content("This repository changed pack identity. Remove its installed pack before choosing a different pack.") }
            guard manifest.version >= previous.manifest.version else { throw PackError.content("This catalogue is older than the installed pack. The installed version was kept.") }
            if manifest.version == previous.manifest.version {
                guard document.digest == previous.manifestDigest else { throw PackError.content("This pack changed a published version. Its owner must publish a new version; the installed pack was kept.") }
            }
        }
        let versions = directory.appendingPathComponent("versions")
        let blobs = directory.appendingPathComponent("blobs")
        try mkdir(versions); try mkdir(blobs)
        let staging = directory.appendingPathComponent("staging-" + UUID().uuidString)
        try mkdir(staging)
        defer {
            try? fm.removeItem(at: staging)
            if (try? activeIfPresent(directory)) == nil { try? fm.removeItem(at: directory) }
            else { try? prune(directory) }
        }
        var downloaded = 0, reused = 0
        var bytes: [String: Data] = [:]
        for file in manifest.files {
            try Task.checkCancellation()
            let cached = blobs.appendingPathComponent(file.sha256)
            let data: Data
            if let candidate = try? read(cached, limit: file.size), candidate.count == file.size,
               PackDigest.hex(candidate) == file.sha256 {
                data = candidate; reused += 1
            } else {
                data = try await source.file(file, for: release, at: revision)
                guard data.count == file.size, PackDigest.hex(data) == file.sha256 else {
                    throw PackError.content("A downloaded file failed its integrity check. The installed pack was kept.")
                }
                try write(data, to: cached); downloaded += 1
            }
            let destination = try PackPath.url(file.path, in: staging)
            try mkdir(destination.deletingLastPathComponent())
            try write(data, to: destination)
            bytes[file.path] = data
        }
        _ = try PackPayload(manifest: manifest, files: bytes)
        let pack = InstalledPack(source: source.source, revision: revision, manifest: manifest,
                                 manifestDigest: document.digest, installedAt: Date())
        let version = versions.appendingPathComponent(pack.directory)
        try Task.checkCancellation()
        if fm.fileExists(atPath: version.path) {
            // An interrupted earlier install may already have committed this
            // version directory. Verify it before reusing it.
            var existing: [String: Data] = [:]
            for file in manifest.files { existing[file.path] = try read(try PackPath.url(file.path, in: version), limit: file.size) }
            _ = try PackPayload(manifest: manifest, files: existing)
        } else {
            try noSymlinks(version)
            try fm.moveItem(at: staging, to: version)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try write(try encoder.encode(pack), to: version.appendingPathComponent(".receipt.json"))
        try Task.checkCancellation()
        // active.json is the sole activation record. Its old bytes remain until
        // the atomic write succeeds. No other state owns the selected version.
        try write(try encoder.encode(pack), to: directory.appendingPathComponent("active.json"))
        return PackInstallResult(pack: pack, downloadedFiles: downloaded, reusedFiles: reused)
    }

    public func remove(_ pack: InstalledPack) throws {
        guard !updating else { throw PackError.content("Finish or cancel the pack update before removing a pack.") }
        let directory = try sourceDirectory(pack.source)
        guard try readActive(directory).source == pack.source else { throw PackError.content("The installed source changed.") }
        try noSymlinks(directory)
        try fm.removeItem(at: directory)
    }

    private func sourceDirectory(_ source: PackSource) throws -> URL {
        try prepareRoot()
        let url = root.appendingPathComponent(source.storageKey)
        try noSymlinks(url)
        return url
    }
    private func activeIfPresent(_ directory: URL) throws -> InstalledPack? {
        let url = directory.appendingPathComponent("active.json")
        try noSymlinks(url)
        return fm.fileExists(atPath: url.path) ? try readActive(directory) : nil
    }
    private func readActive(_ directory: URL) throws -> InstalledPack {
        let data = try read(directory.appendingPathComponent("active.json"), limit: PackLimits.maximumReceiptBytes)
        let pack = try JSONDecoder().decode(InstalledPack.self, from: data)
        try pack.manifest.validated()
        guard pack.source.storageKey == directory.lastPathComponent,
              PackDigest.isValid(pack.manifestDigest) else { throw PackError.content("The installed pack record is invalid.") }
        try noSymlinks(directory.appendingPathComponent("versions/" + pack.directory))
        return pack
    }
    private func prepareRoot() throws { try mkdir(root) }
    private func mkdir(_ url: URL) throws {
        try noSymlinks(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func noSymlinks(_ url: URL) throws {
        var cursor = url
        while cursor.path != "/" {
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw PackError.content("Pack storage cannot contain symbolic links (\(cursor.path)). Choose an ordinary local folder.")
            }
            cursor.deleteLastPathComponent()
        }
    }
    private func read(_ url: URL, limit: Int) throws -> Data {
        try noSymlinks(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= limit else {
            throw PackError.content("An installed pack file is missing or has an unexpected size.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw PackError.content("An installed pack file is too large.") }
        return data
    }
    private func write(_ data: Data, to url: URL) throws {
        try noSymlinks(url)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func recover(_ directory: URL) throws {
        try noSymlinks(directory)
        try clearAbandonedStaging(in: directory)
        let active = directory.appendingPathComponent("active.json")
        try noSymlinks(active)
        // A first install interrupted before activation has no user-selected
        // version to preserve. This qualified directory contains only downloads.
        guard fm.fileExists(atPath: active.path) else { try fm.removeItem(at: directory); return }
        try prune(directory)
    }

    private func clearAbandonedStaging(in directory: URL) throws {
        try noSymlinks(directory)
        for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = child.lastPathComponent
            guard name.hasPrefix("staging-"), UUID(uuidString: String(name.dropFirst(8))) != nil else { continue }
            try noSymlinks(child)
            try fm.removeItem(at: child)
        }
    }

    private func prune(_ directory: URL) throws {
        guard let active = try activeIfPresent(directory) else { return }
        let versions = directory.appendingPathComponent("versions")
        let candidates = try fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)
        var records: [(URL, InstalledPack)] = []
        for candidate in candidates {
            if let bytes = try? read(candidate.appendingPathComponent(".receipt.json"), limit: PackLimits.maximumReceiptBytes),
               let record = try? JSONDecoder().decode(InstalledPack.self, from: bytes), record.source == active.source,
               record.directory == candidate.lastPathComponent, (try? record.manifest.validated()) != nil {
                records.append((candidate, record))
            } else if candidate.lastPathComponent != active.directory,
                      candidate.lastPathComponent.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{16}$"#, options: .regularExpression) != nil {
                // A crash after directory promotion but before its receipt was
                // written must not leave an unbounded collection of payloads.
                try noSymlinks(candidate); try fm.removeItem(at: candidate)
            }
        }
        records.sort { $0.1.installedAt > $1.1.installedAt }
        var keep = Set(records.prefix(3).map { $0.0.lastPathComponent }); keep.insert(active.directory)
        var hashes = Set<String>()
        for (url, record) in records {
            if keep.contains(url.lastPathComponent) { hashes.formUnion(record.manifest.files.map(\.sha256)) }
            else { try noSymlinks(url); try fm.removeItem(at: url) }
        }
        for blob in try fm.contentsOfDirectory(at: directory.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
            where PackDigest.isValid(blob.lastPathComponent) && !hashes.contains(blob.lastPathComponent) {
            try noSymlinks(blob); try fm.removeItem(at: blob)
        }
    }
}
