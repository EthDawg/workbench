import XCTest
import UIKit
@testable import WorkbenchMobile

@MainActor final class MobileSceneEditingTests: XCTestCase {
    private func library() throws -> SceneLibraryModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MobileSceneEditingTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return SceneLibraryModel(directory: url)
    }
    private func image(_ color: UIColor = .systemTeal) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }.pngData())
    }
    private func fixture(_ library: SceneLibraryModel) throws -> SavedSceneRecord {
        let name = try library.importAsset(image())
        return try library.create(PortableScene(name: "Synthetic scene", background: name))
    }
    func testGentleMotionPersistsThroughEditorSaveReopenAndCopyWithoutChangingCrop() throws {
        let library = try library(), record = try fixture(library)
        let editor = MobileSceneEditingSession(); editor.connect(library: library, sceneID: record.id)
        XCTAssertNil(editor.draft?.gentleMotion)
        editor.edit { $0.backgroundX = 0.19; $0.backgroundY = 0.73; $0.zoom = 1.6; $0.gentleMotion = true }
        XCTAssertTrue(editor.flush())
        let reopened = SceneLibraryModel(directory: library.directory)
        let saved = try XCTUnwrap(reopened.records.first)
        XCTAssertEqual(saved.scene.gentleMotion, true)
        XCTAssertEqual(saved.scene.backgroundX, 0.19); XCTAssertEqual(saved.scene.backgroundY, 0.73)
        XCTAssertEqual(saved.scene.zoom, 1.6); XCTAssertEqual(saved.scene.background, record.scene.background)
        let copy = try reopened.duplicate(id: saved.id)
        XCTAssertEqual(copy.scene.gentleMotion, true)
        let editingCopy = MobileSceneEditingSession(); editingCopy.connect(library: reopened, sceneID: copy.id)
        editingCopy.edit { $0.gentleMotion = nil }; XCTAssertTrue(editingCopy.flush())
        XCTAssertNil(editingCopy.draft?.gentleMotion)
        XCTAssertEqual(reopened.records.first(where: { $0.id == saved.id })?.scene.gentleMotion, true)
        editor.finishForDisappearance(); editingCopy.finishForDisappearance()
    }
    func testActivityGuardRemainsUntilEveryActiveEditorHasSaved() throws {
        let library = try library(), first = try fixture(library), second = try fixture(library)
        let one = MobileSceneEditingSession(), two = MobileSceneEditingSession()
        one.connect(library: library, sceneID: first.id); two.connect(library: library, sceneID: second.id)
        one.edit { $0.name = "Unsaved one" }; two.edit { $0.name = "Unsaved two" }
        XCTAssertTrue(SceneEditingActivity.shared.hasUnsavedEdits)
        XCTAssertTrue(one.flush()); XCTAssertTrue(SceneEditingActivity.shared.hasUnsavedEdits)
        XCTAssertTrue(two.flush()); XCTAssertFalse(SceneEditingActivity.shared.hasUnsavedEdits)
        one.finishForDisappearance(); two.finishForDisappearance()
    }
    func testDebounceCoalescesEditsAndCancelledTimerCannotCommitOldDraft() async throws {
        let library = try library(), record = try fixture(library); let delay = SceneEditingDelay()
        let editor = MobileSceneEditingSession(waitToSave: { await delay.wait() })
        editor.connect(library: library, sceneID: record.id)
        editor.edit { $0.name = "First partial edit" }; await delay.started(1)
        editor.edit { $0.name = "Final name"; $0.phoneX = 0.2 }; await delay.started(2)
        XCTAssertEqual(library.records[0].revision, record.revision)
        delay.release(); await editor.waitForPendingSave()
        XCTAssertEqual(library.records[0].scene.name, "Final name"); XCTAssertEqual(library.records[0].scene.phoneX, 0.2)
        XCTAssertFalse(editor.hasUnsavedChanges)
    }
    func testExplicitFlushSavesLastEditBeforeDebounceAndLateTimerDoesNothing() async throws {
        let library = try library(), record = try fixture(library); let delay = SceneEditingDelay()
        let editor = MobileSceneEditingSession(waitToSave: { await delay.wait() })
        editor.connect(library: library, sceneID: record.id)
        editor.edit { $0.phoneX = 0.8 }; await delay.started(1)
        XCTAssertTrue(editor.flush()); let savedRevision = library.records[0].revision
        delay.release(); await Task.yield()
        XCTAssertEqual(library.records[0].revision, savedRevision); XCTAssertEqual(library.records[0].scene.phoneX, 0.8)
    }
    func testReceiptRefreshPreservesPendingDraftAndUpdatesSyncStatus() throws {
        let library = try library(), record = try fixture(library)
        let editor = MobileSceneEditingSession(); editor.connect(library: library, sceneID: record.id)
        editor.edit { $0.phoneX = 0.7 }
        var receipt = record; receipt.baseRevision = receipt.revision
        receipt.account = SceneSyncAccount(container: "iCloud.example", environment: "Production", userRecordName: "_synthetic")
        editor.observe([receipt])
        XCTAssertEqual(editor.record?.baseRevision, receipt.revision); XCTAssertEqual(editor.draft?.phoneX, 0.7)
        XCTAssertTrue(editor.hasUnsavedChanges); XCTAssertFalse(editor.changedElsewhere); editor.cancelPending()
    }
    func testCleanEditorAdoptsRemoteEditAndDirtyEditorPreservesBoth() throws {
        let library = try library(), record = try fixture(library)
        let editor = MobileSceneEditingSession(); editor.connect(library: library, sceneID: record.id)
        var remote = record.scene; remote.name = "First remote edit"
        let updated = try library.save(remote, expectedRevision: record.revision); editor.observe(library.records)
        XCTAssertEqual(editor.draft?.name, "First remote edit")
        editor.edit { $0.phoneX = 0.3 }
        remote.name = "Second remote edit"; _ = try library.save(remote, expectedRevision: updated.revision)
        editor.observe(library.records)
        XCTAssertTrue(editor.changedElsewhere); XCTAssertEqual(editor.draft?.name, "First remote edit")
        XCTAssertEqual(editor.draft?.phoneX, 0.3); XCTAssertFalse(editor.flush())
        XCTAssertTrue(editor.keepCopy()); let copyID = try XCTUnwrap(editor.activeID)
        XCTAssertNotEqual(copyID, record.id); XCTAssertEqual(library.records.count, 2)
        XCTAssertEqual(library.records.first(where: { $0.id == record.id })?.scene.name, "Second remote edit")
        XCTAssertEqual(library.records.first(where: { $0.id == copyID })?.scene.phoneX, 0.3)
    }
    func testReloadAfterKeptCopyUsesCopyIDRatherThanOriginal() throws {
        let library = try library(), record = try fixture(library)
        let editor = MobileSceneEditingSession(); editor.connect(library: library, sceneID: record.id)
        XCTAssertTrue(editor.keepCopy()); let copy = try XCTUnwrap(editor.record)
        var changedCopy = copy.scene; changedCopy.name = "Remote copy edit"
        _ = try library.save(changedCopy, expectedRevision: copy.revision)
        editor.reloadDiscardingEdits()
        XCTAssertEqual(editor.activeID, copy.id); XCTAssertEqual(editor.draft?.name, "Remote copy edit")
    }
    func testReplacementKeepsLayerGeometryAndClearsObsoletePersonaCard() throws {
        let library = try library(), record = try fixture(library)
        var scene = record.scene
        scene.logo = SceneLogoLayer(image: scene.background, corner: "bottomLeft", width: 0.21, backing: "light")
        scene.persona = ScenePersonaLayer(image: scene.background, x: 0.13, y: 0.83, width: 0.25)
        scene.persona?.card = SceneCardStyle(portrait: scene.background, label: "Old portrait", red: 0.3, green: 0.4, blue: 0.8)
        let prepared = try library.save(scene, expectedRevision: record.revision)
        let newImage = try library.importAsset(image(.systemOrange))
        let editor = MobileSceneEditingSession(); editor.connect(library: library, sceneID: prepared.id)
        editor.replaceImage(asset: newImage, layer: .logo); editor.replaceImage(asset: newImage, layer: .persona)
        XCTAssertTrue(editor.flush())
        XCTAssertEqual(editor.draft?.logo?.corner, "bottomLeft"); XCTAssertEqual(editor.draft?.logo?.width, 0.21)
        XCTAssertEqual(editor.draft?.logo?.backing, "light"); XCTAssertEqual(editor.draft?.logo?.image, newImage)
        XCTAssertEqual(editor.draft?.persona?.x, 0.13); XCTAssertEqual(editor.draft?.persona?.y, 0.83)
        XCTAssertEqual(editor.draft?.persona?.width, 0.25); XCTAssertNil(editor.draft?.persona?.card)
    }
    func testNavigationFlushesLatestDraftAndPreservesConflictAsCopy() throws {
        let library = try library(), record = try fixture(library)
        let editor = MobileSceneEditingSession(); editor.connect(library: library, sceneID: record.id)
        editor.edit { $0.name = "Last character" }; editor.finishForDisappearance()
        XCTAssertEqual(library.records[0].scene.name, "Last character")
        editor.edit { $0.phoneX = 0.9 }
        var remote = library.records[0].scene; remote.name = "New remote"
        _ = try library.save(remote, expectedRevision: library.records[0].revision); editor.observe(library.records)
        editor.finishForDisappearance()
        XCTAssertEqual(library.records.count, 2); XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.draft?.phoneX, 0.9)
    }
    func testDeletedRemoteRetainsDraftUntilExplicitKeepCopy() throws {
        let library = try library(), record = try fixture(library)
        let editor = MobileSceneEditingSession(); editor.connect(library: library, sceneID: record.id)
        editor.edit { $0.phoneX = 0.1 }
        try library.delete(id: record.id, expectedRevision: record.revision); editor.observe(library.records)
        XCTAssertTrue(editor.changedElsewhere); XCTAssertEqual(editor.draft?.phoneX, 0.1)
        XCTAssertFalse(editor.flush()); XCTAssertTrue(editor.keepCopy())
        XCTAssertNotEqual(editor.activeID, record.id); XCTAssertTrue(library.records[0].isDeleted)
    }
}

@MainActor private final class SceneEditingDelay {
    private var count = 0
    private var waits: [CheckedContinuation<Void, Never>] = []
    private var startedWaits: [(Int, CheckedContinuation<Void, Never>)] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            count += 1; waits.append(continuation)
            let ready = startedWaits.filter { $0.0 <= count }; startedWaits.removeAll { $0.0 <= count }
            ready.forEach { $0.1.resume() }
        }
    }
    func started(_ number: Int) async {
        if count >= number { return }
        await withCheckedContinuation { startedWaits.append((number, $0)) }
    }
    func release() { let pending = waits; waits.removeAll(); pending.forEach { $0.resume() } }
}
