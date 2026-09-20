import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import SceneSyncKit

final class SceneAmbienceTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneAmbienceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func image(_ value: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: value, green: 0.3, blue: 0.8, alpha: 0.8))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return output as Data
    }
    private func fixture() throws -> ScenePackage {
        let data = try [CGFloat(0.1), 0.3, 0.6, 0.9].map(image)
        let names = data.map(SceneAsset.name)
        var scene = PortableScene(name: "Synthetic window", background: names[0])
        scene.ambience = SceneAmbience(preset: "window-light", cleanPlate: names[1], detail: names[2])
        scene.gentleMotion = true; scene.phoneX = 0.27; scene.backgroundY = 0.8
        scene.retainedAssets = [names[3]]; scene.legacyMobileProject = Data("Original authored composition".utf8)
        return ScenePackage(scene: scene, assets: Dictionary(uniqueKeysWithValues: zip(names, data)))
    }
    private func archive(_ scene: PortableScene) -> SceneLibraryArchive {
        var archive = SceneLibraryArchive(); archive.records = [SavedSceneRecord(scene: scene)]
        return archive
    }
    private func backups(_ store: SceneLibraryStore) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("scene-library-v1-") }
    }
    private func backupURL(_ store: SceneLibraryStore, bytes: Data) -> URL {
        store.directory.appendingPathComponent("scene-library-v1-" + SceneAsset.digest(bytes) + ".json")
    }

    func testVersionTwoPackageContainsEveryRigAndOriginalAssetExactly() throws {
        let original = try fixture()
        XCTAssertEqual(original.version, 2); XCTAssertEqual(original.scene.assets.count, 4)
        XCTAssertEqual(original.scene.ambience?.assets.count, 2)
        let reopened = try ScenePackage.decode(original.encoded())
        XCTAssertEqual(reopened, original)
        XCTAssertEqual(reopened.scene.legacyMobileProject, original.scene.legacyMobileProject)
        for (name, data) in original.assets { XCTAssertEqual(reopened.assets[name], data) }
        var missing = original; missing.assets.removeValue(forKey: original.scene.ambience!.detail)
        XCTAssertThrowsError(try missing.validated())
        var extra = original; let unrelated = try image(0.7)
        extra.assets[SceneAsset.name(for: unrelated)] = unrelated
        XCTAssertThrowsError(try extra.validated())
    }
    func testVersionOneStillPackageRemainsCompatibleAndCannotHideRecipe() throws {
        let layered = try fixture()
        var still = layered.scene; still.ambience = nil
        let package = ScenePackage(scene: still, assets: layered.assets.filter { still.assets.contains($0.key) })
        XCTAssertEqual(package.version, 1)
        XCTAssertEqual(try ScenePackage.decode(package.encoded()), package)
        var ambiguous = layered; ambiguous.version = 1
        XCTAssertThrowsError(try ambiguous.validated())
        XCTAssertThrowsError(try ScenePackage.decode(PropertyListEncoder().encode(ambiguous)))
        var future = layered; future.version = 3
        XCTAssertThrowsError(try future.validated())
    }
    func testRecipeRejectsUnknownVersionPresetAndNonAssetReferences() throws {
        let good = try XCTUnwrap(fixture().scene.ambience)
        for preset in ["window-light", "campus-breeze", "coastal-sky"] {
            var value = good; value.preset = preset; XCTAssertNoThrow(try value.validate())
        }
        for preset in ["", "window-light-v2", "WINDOW-LIGHT", "https://example.com/animation", "window-light "] {
            var value = good; value.preset = preset
            XCTAssertThrowsError(try value.validate()) { XCTAssertEqual($0 as? SceneDocumentError, .futureVersion) }
        }
        for version in [0, 2, Int.max] {
            var value = good; value.version = version; XCTAssertThrowsError(try value.validate())
        }
        for path in ["../" + good.detail, "/tmp/picture.png", good.detail.uppercased(), "data:image/png;base64,AA"] {
            var value = good; value.detail = path; XCTAssertThrowsError(try value.validate())
            value = good; value.cleanPlate = path; XCTAssertThrowsError(try value.validate())
        }
    }
    func testRigUsesExistingImageCountLimitWithoutDroppingRecoveryAssets() throws {
        let images = try (1...13).map { try image(CGFloat($0) / 15) }, names = images.map(SceneAsset.name)
        var scene = PortableScene(name: "Full original composition", background: names[0])
        scene.logo = SceneLogoLayer(image: names[1]); scene.hand = SceneHandLayer(image: names[2])
        scene.persona = ScenePersonaLayer(image: names[3])
        scene.persona?.card = SceneCardStyle(portrait: names[4], label: "Synthetic", red: 0, green: 0, blue: 0)
        scene.ambience = SceneAmbience(preset: "campus-breeze", cleanPlate: names[5], detail: names[6])
        scene.retainedAssets = Array(names[7...12]); scene.legacyMobileProject = Data("All six originals retained".utf8)
        let full = ScenePackage(scene: scene, assets: Dictionary(uniqueKeysWithValues: zip(names, images)))
        XCTAssertNoThrow(try scene.validated()); XCTAssertEqual(scene.assets.count, 13)
        XCTAssertThrowsError(try full.validated())
        XCTAssertEqual(full.scene.retainedAssets, Array(names[7...12]))
        scene.retainedAssets = Array(names[7...11])
        let bounded = ScenePackage(scene: scene, assets: full.assets.filter { scene.assets.contains($0.key) })
        XCTAssertEqual(try bounded.validated().assets.count, 12)
    }
    func testFirstRecipeCommitBacksUpExactV1ManifestAndPreservesEverySyncField() throws {
        let package = try fixture(), store = SceneLibraryStore(directory: try directory())
        _ = try store.load(); try store.installAssets(from: package)
        var scene = package.scene; scene.ambience = nil
        var old = archive(scene)
        let owner = SceneSyncAccount(container: "iCloud.com.example.synthetic", environment: "Production", userRecordName: "synthetic-owner")
        old.account = owner; old.syncEnabled = true; old.engineState = Data([2, 3, 4]); old.adoptedLegacyIDs = ["old-mobile-source"]
        old.records[0].account = owner; old.records[0].baseRevision = old.records[0].revision
        old.records[0].remoteSystemFields = Data([7, 8]); old.records[0].conflictOf = UUID()
        try store.save(old); let originalBytes = try Data(contentsOf: store.manifest)
        var next = old; next.records[0].scene.ambience = package.scene.ambience
        let committed = try store.save(next)
        XCTAssertEqual(committed.version, 2)
        var expected = next; expected.version = 2; XCTAssertEqual(committed, expected)
        XCTAssertEqual(try Data(contentsOf: backupURL(store, bytes: originalBytes)), originalBytes)
        XCTAssertEqual(try backups(store).count, 1)
        let reopened = SceneLibraryStore(directory: store.directory)
        XCTAssertEqual(try reopened.load(), expected)
        XCTAssertEqual(try reopened.package(for: committed.records[0].scene), package)
        // Removing the last rig never makes the library writable by old clients again.
        var cleared = committed; cleared.records[0].scene.ambience = nil; cleared.version = 1
        XCTAssertEqual(try reopened.save(cleared).version, 2)
        XCTAssertEqual(try backups(store).count, 1)
        XCTAssertEqual(try Data(contentsOf: backupURL(store, bytes: originalBytes)), originalBytes)
    }
    func testNewLayeredLibraryNeedsNoFictionalLegacyBackup() throws {
        let package = try fixture(), store = SceneLibraryStore(directory: try directory())
        _ = try store.load(); try store.installAssets(from: package)
        XCTAssertEqual(try store.save(archive(package.scene)).version, 2)
        XCTAssertTrue(try backups(store).isEmpty)
        XCTAssertEqual(try SceneLibraryStore(directory: store.directory).load().records[0].scene, package.scene)
    }
    func testExistingIdenticalBackupIsReusableButNeverOverwritten() throws {
        let package = try fixture(), store = SceneLibraryStore(directory: try directory())
        _ = try store.load(); try store.save(SceneLibraryArchive())
        let bytes = try Data(contentsOf: store.manifest), backup = backupURL(store, bytes: bytes)
        try bytes.write(to: backup)
        XCTAssertEqual(try store.save(archive(package.scene)).version, 2)
        XCTAssertEqual(try Data(contentsOf: backup), bytes); XCTAssertEqual(try backups(store).count, 1)
    }
    func testBadOrSymlinkBackupBlocksUpgradeWithoutChangingOriginalManifest() throws {
        for symlink in [false, true] {
            let package = try fixture(), store = SceneLibraryStore(directory: try directory())
            _ = try store.load(); try store.save(SceneLibraryArchive())
            let bytes = try Data(contentsOf: store.manifest), backup = backupURL(store, bytes: bytes)
            let sentinel = store.directory.appendingPathComponent("synthetic-unrelated.json")
            let other = Data("Must not replace".utf8)
            if symlink {
                try other.write(to: sentinel)
                try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: sentinel)
            } else { try other.write(to: backup) }
            XCTAssertThrowsError(try store.save(archive(package.scene)))
            XCTAssertEqual(try Data(contentsOf: store.manifest), bytes)
            XCTAssertEqual(try Data(contentsOf: symlink ? sentinel : backup), other)
            XCTAssertEqual(try store.load().version, 1)
        }
    }
    func testStaleUpgradeCannotReplaceNewerManifestOrCreateWrongBackup() throws {
        let package = try fixture(), store = SceneLibraryStore(directory: try directory())
        _ = try store.load(); try store.save(SceneLibraryArchive())
        let other = SceneLibraryStore(directory: store.directory); var newer = try other.load()
        newer.adoptedLegacyIDs = ["newer-writer"]; try other.save(newer)
        let bytes = try Data(contentsOf: store.manifest)
        XCTAssertThrowsError(try store.save(archive(package.scene))) { XCTAssertEqual($0 as? SceneDocumentError, .concurrentChange) }
        XCTAssertEqual(try Data(contentsOf: store.manifest), bytes); XCTAssertTrue(try backups(store).isEmpty)
    }
    func testHeldWriteLockFailsPromptlyAndLeavesManifestUntouched() throws {
        let package = try fixture(), store = SceneLibraryStore(directory: try directory())
        _ = try store.load(); try store.save(SceneLibraryArchive())
        let bytes = try Data(contentsOf: store.manifest)
        let descriptor = open(store.directory.appendingPathComponent(".scene-library-write.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0); guard descriptor >= 0 else { return }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.save(archive(package.scene))) { XCTAssertEqual($0 as? SceneDocumentError, .concurrentChange) }
        XCTAssertEqual(try Data(contentsOf: store.manifest), bytes); XCTAssertTrue(try backups(store).isEmpty)
    }
    func testSymlinkWriteLockDoesNotFollowOrModifyAnotherFile() throws {
        let store = SceneLibraryStore(directory: try directory()); _ = try store.load()
        let sentinel = store.directory.appendingPathComponent("unrelated.txt"), bytes = Data("Preserve unrelated content".utf8)
        try bytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent(".scene-library-write.lock"), withDestinationURL: sentinel)
        XCTAssertThrowsError(try store.save(SceneLibraryArchive()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.manifest.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    }
    func testUnknownRecipesAndArchiveVersionsCannotRewriteReadableBytes() throws {
        let package = try fixture(), store = SceneLibraryStore(directory: try directory())
        _ = try store.load(); try store.save(SceneLibraryArchive())
        let bytes = try Data(contentsOf: store.manifest)
        var unknown = archive(package.scene); unknown.records[0].scene.ambience?.version = 2
        XCTAssertThrowsError(try store.save(unknown)); XCTAssertEqual(try Data(contentsOf: store.manifest), bytes)
        unknown = SceneLibraryArchive(); unknown.version = 3
        XCTAssertThrowsError(try store.save(unknown)); XCTAssertEqual(try Data(contentsOf: store.manifest), bytes)
        var ambiguous = archive(package.scene)
        XCTAssertThrowsError(try ambiguous.validated())
        ambiguous.version = 2; ambiguous.records[0].scene.ambience?.preset = "future-preset"
        let unknownBytes = try JSONEncoder().encode(ambiguous); try unknownBytes.write(to: store.manifest)
        let futureReader = SceneLibraryStore(directory: store.directory)
        XCTAssertThrowsError(try futureReader.load())
        XCTAssertThrowsError(try futureReader.save(SceneLibraryArchive()))
        XCTAssertEqual(try Data(contentsOf: store.manifest), unknownBytes)
    }
    func testReceivingLayeredRevisionPromotesArchiveWithoutLosingOriginals() throws {
        let package = try fixture()
        let owner = SceneSyncAccount(container: "iCloud.com.example.synthetic", environment: "Production", userRecordName: "synthetic-owner")
        var remote = SavedSceneRecord(scene: package.scene); remote.account = owner
        var target = SceneLibraryArchive(); target.account = owner; target.adoptedLegacyIDs = ["already-adopted"]
        try SceneRevisionMerge.receive(remote, into: &target, account: owner)
        XCTAssertEqual(target.version, 2); XCTAssertEqual(target.records[0].scene, package.scene)
        XCTAssertEqual(target.adoptedLegacyIDs, ["already-adopted"])
    }
    @MainActor func testModelCreateEditDuplicateClearAndReopenKeepFormatAndAssetOwnership() throws {
        let package = try fixture(), root = try directory()
        let model = SceneLibraryModel(directory: root)
        for bytes in package.assets.values { _ = try model.importAsset(bytes) }
        let record = try model.create(package.scene)
        XCTAssertFalse(model.isConfigured); XCTAssertFalse(model.isEnabled)
        var edited = record.scene; edited.name = "Renamed without flattening"; edited.phoneX = 0.72
        let saved = try model.save(edited, expectedRevision: record.revision)
        let duplicate = try model.duplicate(id: saved.id)
        XCTAssertNotEqual(duplicate.id, saved.id); XCTAssertEqual(duplicate.scene.ambience, package.scene.ambience)
        XCTAssertEqual(duplicate.scene.legacyMobileProject, package.scene.legacyMobileProject)
        XCTAssertEqual(try model.package(for: saved.scene).assets, package.assets)
        var cleared = saved.scene; cleared.ambience = nil
        _ = try model.save(cleared, expectedRevision: saved.revision)
        let reopened = SceneLibraryModel(directory: root)
        XCTAssertNil(reopened.records.first { $0.id == saved.id }?.scene.ambience)
        XCTAssertEqual(reopened.records.first { $0.id == duplicate.id }?.scene.ambience, package.scene.ambience)
        XCTAssertEqual(try SceneLibraryStore(directory: root).load().version, 2)
        for (name, bytes) in package.assets {
            XCTAssertEqual(try Data(contentsOf: reopened.assetURL(name)), bytes, "Clearing a rig never deletes immutable originals")
        }
    }
}
