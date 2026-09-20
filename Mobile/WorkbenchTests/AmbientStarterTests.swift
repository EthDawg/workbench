import XCTest
import UIKit
@testable import WorkbenchMobile

@MainActor final class AmbientStarterTests: XCTestCase {
    private func library() throws -> SceneLibraryModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AmbientStarterTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SceneLibraryModel(directory: directory, configuration: .unavailable)
    }

    func testEveryBundledStarterFirstSaveReopenAndExportRetainsItsOriginals() throws {
        let directory = try XCTUnwrap(AmbientStarter.bundledDirectory)
        for starter in AmbientStarter.allCases {
            let library = try library()
            let record = try starter.create(in: library)
            let rig = try XCTUnwrap(record.scene.ambience)
            XCTAssertEqual(record.scene.name, starter.title)
            XCTAssertEqual(rig.preset, starter.rawValue); XCTAssertEqual(record.scene.gentleMotion, true)
            XCTAssertFalse(record.scene.showsPhone)
            XCTAssertNotNil(starter.poster())
            let package = try library.package(for: record.scene)
            XCTAssertEqual(package.version, 2); XCTAssertEqual(package.assets.count, 3)
            let expected = [(record.scene.background, starter.rawValue + "-poster"),
                            (rig.cleanPlate, starter.rawValue), (rig.detail, starter.detailName)]
            for (asset, file) in expected {
                XCTAssertEqual(package.assets[asset], try Data(contentsOf: directory.appendingPathComponent(file + ".png")))
            }
            XCTAssertEqual(try ScenePackage.decode(package.encoded()), package)
            let reopened = SceneLibraryModel(directory: library.directory, configuration: .unavailable)
            XCTAssertFalse(reopened.isStorageBlocked)
            XCTAssertEqual(reopened.records.first?.scene, record.scene)
            XCTAssertEqual(try SceneLibraryStore(directory: library.directory).load().version, 2)
            let duplicate = try reopened.duplicate(id: record.id)
            XCTAssertEqual(duplicate.scene.ambience, rig); XCTAssertEqual(duplicate.scene.gentleMotion, true)
            XCTAssertEqual(duplicate.scene.assets, record.scene.assets)
            XCTAssertFalse(reopened.isEnabled); XCTAssertFalse(reopened.isConfigured)
        }
    }

    func testBackdropReplacementRemovesOnlyItsTreatmentAndPreservesStoredOriginals() throws {
        let library = try library(), record = try AmbientStarter.windowLight.create(in: library)
        let original = try library.package(for: record.scene)
        let replacement = try library.importAsset(syntheticImage())
        let editor = MobileSceneEditingSession(); editor.connect(library: library, sceneID: record.id)
        editor.edit {
            $0.logo = SceneLogoLayer(image: replacement, corner: "bottomLeft", width: 0.2)
            $0.persona = ScenePersonaLayer(image: replacement, x: 0.2, y: 0.7, width: 0.15)
            $0.phoneX = 0.12; $0.phoneY = 0.8; $0.backgroundX = 0.2; $0.backgroundY = 0.8; $0.zoom = 1.6
        }
        XCTAssertTrue(editor.flush())
        let prepared = try XCTUnwrap(editor.draft)
        editor.replaceImage(asset: replacement, layer: .background)
        XCTAssertNil(editor.draft?.ambience); XCTAssertNil(editor.draft?.gentleMotion)
        XCTAssertEqual(editor.draft?.background, replacement)
        XCTAssertEqual(editor.draft?.backgroundX, 0.5); XCTAssertEqual(editor.draft?.backgroundY, 0.5); XCTAssertEqual(editor.draft?.zoom, 1)
        XCTAssertEqual(editor.draft?.logo, prepared.logo); XCTAssertEqual(editor.draft?.persona, prepared.persona)
        XCTAssertEqual(editor.draft?.phoneX, prepared.phoneX); XCTAssertEqual(editor.draft?.phoneY, prepared.phoneY)
        XCTAssertTrue(editor.flush()); editor.finishForDisappearance()
        let reopened = SceneLibraryModel(directory: library.directory, configuration: .unavailable)
        XCTAssertNil(reopened.records.first?.scene.ambience); XCTAssertNil(reopened.records.first?.scene.gentleMotion)
        XCTAssertEqual(try SceneLibraryStore(directory: library.directory).load().version, 2)
        for (name, data) in original.assets { XCTAssertEqual(try Data(contentsOf: reopened.assetURL(name)), data) }
    }

    func testTurningMotionOffKeepsRecipeAndLogoReplacementDoesNotClearIt() throws {
        let library = try library(), record = try AmbientStarter.campusBreeze.create(in: library)
        let editor = MobileSceneEditingSession(); editor.connect(library: library, sceneID: record.id)
        editor.edit { $0.gentleMotion = nil }; XCTAssertTrue(editor.flush())
        editor.replaceImage(asset: record.scene.background, layer: .logo); XCTAssertTrue(editor.flush())
        XCTAssertEqual(editor.draft?.ambience, record.scene.ambience)
        XCTAssertNil(editor.draft?.gentleMotion)
        let package = try library.package(for: XCTUnwrap(editor.draft))
        XCTAssertEqual(package.version, 2); XCTAssertEqual(package.scene.assets, record.scene.assets)
        editor.finishForDisappearance()
    }

    func testMissingStarterImageCannotCreateAPartialScene() throws {
        let library = try library()
        let directory = library.directory.appendingPathComponent("IncompleteStarter")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try syntheticImage().write(to: directory.appendingPathComponent("window-light-poster.png"))
        XCTAssertThrowsError(try AmbientStarter.windowLight.create(in: library, directory: directory))
        XCTAssertTrue(library.records.isEmpty); XCTAssertFalse(library.isStorageBlocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.directory.appendingPathComponent("scene-library.json").path))
    }
    private func syntheticImage() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12), format: format).image { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }.pngData())
    }
}
