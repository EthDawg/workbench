import XCTest
@testable import PrivatePackKit

private actor FixtureSource: PackContentSource {
    nonisolated let source: PackSource
    let manifestValue: PackManifest
    let bytes: [String: Data]
    let digest: String
    let failAfter: Int?
    var requests = 0
    init(owner: String = "company", version: String = "1.0.0", changed: Bool = false, minimum: String = "2.2.0", failAfter: Int? = nil) throws {
        source = try .github(owner: owner, repository: "pack")
        let bytes = ["skills/follow-up/SKILL.md": Data("# Prepare the requested follow-up\n".utf8),
                 "personas/example.png": Data((changed ? "changed fixture" : "original fixture").utf8)]
        manifestValue = PackManifest(id: "example", name: "Example pack", version: PackVersion(version)!, minimumAppVersion: PackVersion(minimum)!,
            entries: [PackEntry(id: "follow-up", kind: .skill, name: "Follow-up", path: "skills/follow-up/SKILL.md", inputKinds: [.transcripts])],
            files: bytes.keys.sorted().map { PackFile(path: $0, sha256: PackDigest.hex(bytes[$0]!), size: bytes[$0]!.count) })
        self.bytes = bytes
        digest = PackDigest.hex(try JSONEncoder().encode(manifestValue)); self.failAfter = failAfter
    }
    func currentRevision() async throws -> PackRevision { try PackRevision(sha: String(repeating: "a", count: 40)) }
    func catalog(at revision: PackRevision) async throws -> PackCatalog {
        PackCatalog(id: "example", name: "Example pack", releases: [PackRelease(version: manifestValue.version,
            minimumAppVersion: manifestValue.minimumAppVersion, manifestPath: "releases/\(manifestValue.version)/pack.json", sha256: digest)])
    }
    func manifest(for release: PackRelease, in catalog: PackCatalog, at revision: PackRevision) async throws -> PackManifestDocument {
        PackManifestDocument(manifest: manifestValue, digest: digest, path: release.manifestPath)
    }
    func file(_ file: PackFile, for release: PackRelease, at revision: PackRevision) async throws -> Data {
        requests += 1
        if let failAfter, requests > failAfter { throw CancellationError() }
        return bytes[file.path]!
    }
}

final class PackStoreTests: XCTestCase {
    let app = PackVersion("2.2.0")!
    func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("PrivatePackTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testInstallUpdateReuseAndFrozenSnapshot() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PackStore(root: root)
        let first = try await store.install(from: FixtureSource(), appVersion: app)
        XCTAssertEqual(first.downloadedFiles, 2)
        let frozen = try await store.payload(for: first.pack).snapshot(entryID: "follow-up")
        let second = try await store.install(from: FixtureSource(version: "1.1.0", changed: true), appVersion: app)
        XCTAssertEqual(second.downloadedFiles, 1); XCTAssertEqual(second.reusedFiles, 1)
        XCTAssertEqual(frozen.version, PackVersion("1.0.0"))
        let packs = try await store.installed(); XCTAssertEqual(packs.map(\.manifest.version), [PackVersion("1.1.0")!])
        let mode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }
    func testInterruptedUpdateKeepsPriorActiveVersion() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PackStore(root: root)
        let first = try await store.install(from: FixtureSource(), appVersion: app)
        do { _ = try await store.install(from: FixtureSource(version: "1.1.0", changed: true, failAfter: 0), appVersion: app); XCTFail("interruption accepted") }
        catch is CancellationError {}
        let packs = try await store.installed(); XCTAssertEqual(packs, [first.pack])
        _ = try await store.payload(for: first.pack)
    }
    func testSameVersionMutationAndDowngradeRefused() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PackStore(root: root)
        let first = try await store.install(from: FixtureSource(version: "1.1.0"), appVersion: app)
        for source in [try FixtureSource(version: "1.1.0", changed: true), try FixtureSource()] {
            do { _ = try await store.install(from: source, appVersion: app); XCTFail("mutable or older release accepted") }
            catch { XCTAssertTrue(error is PackError) }
        }
        let packs = try await store.installed(); XCTAssertEqual(packs, [first.pack])
    }
    func testRepositoryIdentityIsolatesSamePackID() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PackStore(root: root)
        let a = try await store.install(from: FixtureSource(owner: "first"), appVersion: app)
        let b = try await store.install(from: FixtureSource(owner: "second"), appVersion: app)
        XCTAssertNotEqual(a.pack.id, b.pack.id)
        try await store.remove(a.pack)
        let packs = try await store.installed(); XCTAssertEqual(packs, [b.pack])
        _ = try await store.payload(for: b.pack)
    }
    func testIncompatibleReleaseCannotReplaceInstalled() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PackStore(root: root)
        let first = try await store.install(from: FixtureSource(), appVersion: app)
        do { _ = try await store.install(from: FixtureSource(version: "2.0.0", minimum: "3.0.0"), appVersion: app); XCTFail("future release accepted") }
        catch { XCTAssertTrue(error is PackError) }
        let packs = try await store.installed(); XCTAssertEqual(packs, [first.pack])
    }
    func testTamperedPayloadRefused() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PackStore(root: root)
        let result = try await store.install(from: FixtureSource(), appVersion: app)
        let file = root.appendingPathComponent(result.pack.id + "/versions/" + result.pack.directory + "/skills/follow-up/SKILL.md")
        try Data("tampered".utf8).write(to: file)
        do { _ = try await store.payload(for: result.pack); XCTFail("tampered payload accepted") }
        catch { XCTAssertTrue(error is PackError) }
    }
    func testSymlinkRootRejectedWithoutChangingTarget() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do { _ = try await PackStore(root: link).install(from: FixtureSource(), appVersion: app); XCTFail("symlink accepted") }
        catch { XCTAssertTrue(error is PackError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
    func testStartupCollectsOnlyAbandonedStaging() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PackStore(root: root)
        let installed = try await store.install(from: FixtureSource(), appVersion: app)
        let directory = root.appendingPathComponent(installed.pack.id)
        let abandoned = directory.appendingPathComponent("staging-" + UUID().uuidString)
        let unrelated = directory.appendingPathComponent("staging-personal-notes")
        let orphan = directory.appendingPathComponent("versions/9.0.0-" + String(repeating: "b", count: 16))
        for folder in [abandoned, unrelated, orphan] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("partial download".utf8).write(to: abandoned.appendingPathComponent("partial"))
        let restarted = PackStore(root: root)
        let packs = try await restarted.installed()
        XCTAssertEqual(packs, [installed.pack])
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        _ = try await restarted.payload(for: installed.pack)
    }

    func testFirstInstallCrashRemovesOnlyQualifiedUnactivatedCache() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try PackSource.parse("company/pack")
        let interrupted = root.appendingPathComponent(source.storageKey)
        let unrelated = root.appendingPathComponent("github-personal-notes")
        for folder in [interrupted.appendingPathComponent("blobs"), unrelated] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("partial".utf8).write(to: interrupted.appendingPathComponent("blobs/" + String(repeating: "a", count: 64)))
        let packs = try await PackStore(root: root).installed()
        XCTAssertTrue(packs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testSourcesRejectCredentialAndURLConfusion() throws {
        XCTAssertEqual(try PackSource.parse("https://github.com/Company/Pack.git"), try .parse("company/pack"))
        for value in ["https://token@github.com/a/b", "http://github.com/a/b", "https://github.com.evil.test/a/b", "https://github.com/a/b?ref=secret", "a/../b", "https://github.com/a/b#token"] {
            XCTAssertThrowsError(try PackSource.parse(value), value)
        }
    }
    func testPathsAndCaseCollisionsRejected() async throws {
        for path in ["../secret", "/tmp/file", "skills/../file", "skills//x", "skills\\x", ".git/config", "skills/x%2Fy"] { XCTAssertThrowsError(try PackPath.validated(path), path) }
        let source = try FixtureSource()
        var manifest = await source.manifestValue
        let file = manifest.files[0]
        manifest.files.append(PackFile(path: file.path.uppercased(), sha256: file.sha256, size: file.size))
        XCTAssertThrowsError(try manifest.validated())
    }
    func testFileDirectoryCaseCollisionRejected() async throws {
        var manifest = await (try FixtureSource()).manifestValue
        manifest.files.append(PackFile(path: "SKILLS", sha256: String(repeating: "a", count: 64), size: 1))
        XCTAssertThrowsError(try manifest.validated())
    }
}
