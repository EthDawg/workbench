import AppKit
import SceneSyncKit

final class SceneAssetTests {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneAssets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private var resources: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/SceneBackdrops")
    }
    private func swatch(_ color: NSColor, size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in color.setFill(); rect.fill(); return true }
    }
    func testLegacyScenesAndLogoValidation() throws {
        let old = Data("""
        {"id":"9C699E4C-3BFC-4DDF-9C44-3560A484EA32","name":"Saved customer","background":"original.png","backgroundX":0.3,"backgroundY":0.4,"zoom":1.2,"showsPhone":true,"phoneX":0.2,"phoneY":0.5,"phoneHeight":0.8}
        """.utf8)
        let scene = try JSONDecoder().decode(DemoScene.self, from: old).validated()
        XCTAssertTrue(scene.logo == nil)
        XCTAssertEqual(scene.phoneX, 0.2); XCTAssertEqual(scene.backgroundX, 0.3)
        for path in ["../logo.png", "/logo.png", ".hidden", "folder\\logo.png", ""] {
            XCTAssertThrowsError(try SceneLogo(image: path).validated())
        }
        var logo = SceneLogo(image: "logo.png"); logo.width = .nan
        XCTAssertThrowsError(try logo.validated())
        logo.width = 2; XCTAssertEqual(try logo.validated().width, 0.28)
    }
    func testStartersNeverOverwriteSavedCustomers() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = DemoScene(name: "BaptistCare custom", background: "customer.png")
        let archive = root.appendingPathComponent("scenes.json")
        var picture = DemoScene(background: "fixture.png"); picture.showsPhone = false
        try SceneRenderer.png(picture, image: swatch(.green, size: CGSize(width: 80, height: 45)), size: CGSize(width: 80, height: 45))
            .write(to: root.appendingPathComponent(original.background))
        try SceneStorage.save([original], to: archive)
        let before = try Data(contentsOf: archive)
        let model = DemoScenes(root: root, systemIntegrationEnabled: false)
        let adopted = model.scenes.first!
        XCTAssertEqual(adopted.id, original.id); XCTAssertEqual(adopted.name, original.name)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(adopted.background)), try Data(contentsOf: root.appendingPathComponent(original.background)))
        XCTAssertEqual(try Data(contentsOf: archive), before, "Opening a new app version must not seed or rewrite user data")
        XCTAssertEqual(SceneStarters.all.count, 11)
        XCTAssertFalse(SceneStarters.all.contains { $0.id == "operations-field" })
        for starter in SceneStarters.all {
            try model.useStarter(starter, directory: resources)
            XCTAssertEqual(model.selected?.name, starter.name)
            XCTAssertNotNil(model.image(for: model.selected!))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(model.selected!.background)),
                           try Data(contentsOf: starter.url(in: resources)), "Import the exact original")
        }
        var customized = model.selected!; customized.phoneX = 0.12; customized.name = "Customer mining demo"
        model.update(customized)
        try model.useStarter(SceneStarters.all.last!, directory: resources)
        XCTAssertEqual(model.scenes.first, adopted)
        XCTAssertEqual(model.scenes.first { $0.id == customized.id }, customized)
        XCTAssertEqual(model.selected?.phoneX, 0.5, "A fresh starter keeps its original layout")
        model.remove()
        let count = model.scenes.count
        let reopened = DemoScenes(root: root, systemIntegrationEnabled: false)
        XCTAssertEqual(reopened.scenes.count, count, "Deleted scenes must not reappear on update or launch")
        XCTAssertEqual(reopened.scenes.first, adopted)
        XCTAssertEqual(try Data(contentsOf: archive), before, "Later edits still leave the legacy archive unchanged")
    }
    func testLogoImportReplacementAndRecovery() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = DemoScenes(root: root.appendingPathComponent("store"), systemIntegrationEnabled: false)
        try model.useStarter(SceneStarters.all[0], directory: resources)
        let source = root.appendingPathComponent("logo.png")
        var fixture = DemoScene(background: "fixture.png"); fixture.showsPhone = false
        func writeLogo(_ colour: NSColor) throws {
            try SceneRenderer.png(fixture, image: swatch(colour, size: CGSize(width: 300, height: 100)),
                                  size: CGSize(width: 300, height: 100)).write(to: source)
        }
        try writeLogo(.blue); try model.addLogo(source, to: model.selected!.id)
        var scene = model.selected!; scene.logo!.corner = .bottomLeft; scene.logo!.backing = .dark
        XCTAssertTrue(model.update(scene)); model.duplicate()
        let sharedLogo = model.selected!.logo!.image
        try model.addLogo(source, to: model.selected!.id)
        XCTAssertEqual(model.selected?.logo?.image, sharedLogo, "Identical immutable artwork is deduplicated")
        try writeLogo(.red); try model.addLogo(source, to: model.selected!.id)
        XCTAssertEqual(model.selected?.logo?.corner, .bottomLeft); XCTAssertEqual(model.selected?.logo?.backing, .dark)
        XCTAssertTrue(model.selected?.logo?.image != sharedLogo, "Replacing artwork owns different bytes without changing the other scene")
        try FileManager.default.removeItem(at: source)
        let reopened = DemoScenes(root: model.root, systemIntegrationEnabled: false)
        XCTAssertNotNil(reopened.logoImage(for: reopened.scenes[0])); XCTAssertNotNil(reopened.logoImage(for: reopened.scenes[1]))
        let logoFile = model.root.appendingPathComponent(sharedLogo)
        try FileManager.default.removeItem(at: logoFile)
        let repaired = DemoScenes(root: model.root, systemIntegrationEnabled: false)
        XCTAssertTrue(repaired.logoImage(for: repaired.scenes[0]) != nil, "A missing renderer cache is recreated from the canonical asset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logoFile.path))
        let firstAsset = MainActor.assumeIsolated { repaired.sceneSync!.library.records[0].scene.logo!.image }
        let assetURL = try MainActor.assumeIsolated { try repaired.sceneSync!.library.assetURL(firstAsset) }
        try FileManager.default.removeItem(at: assetURL); try FileManager.default.removeItem(at: logoFile)
        let missing = DemoScenes(root: model.root, systemIntegrationEnabled: false)
        XCTAssertEqual(missing.scenes.count, 2, "Missing canonical artwork must not discard a saved scene")
        XCTAssertTrue(missing.image(for: missing.scenes[0]) == nil, "An incomplete scene cannot be presented as complete")
        XCTAssertThrowsError(try missing.renderPNG(missing.scenes[0], image: swatch(.green, size: CGSize(width: 800, height: 450)), size: CGSize(width: 800, height: 450)))
        XCTAssertTrue(missing.logoImage(for: missing.scenes[1]) != nil, "Replacing a duplicate's logo must not affect the earlier scene")
        XCTAssertNotNil(missing.notice)
    }
    func testLogoPixelsCornersAndSceneCompositions() throws {
        let backdrop = swatch(.red, size: CGSize(width: 160, height: 90))
        let logoImage = swatch(.blue, size: CGSize(width: 300, height: 100))
        for size in [CGSize(width: 960, height: 540), CGSize(width: 960, height: 600), CGSize(width: 540, height: 960)] {
            for corner in LogoCorner.allCases {
                var scene = DemoScene(background: "fixture.png"); scene.showsPhone = false
                scene.logo = SceneLogo(image: "logo.png", corner: corner)
                let rect = SceneRenderer.logoRect(scene.logo!, imageSize: logoImage.size, in: size)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect.insetBy(dx: -min(size.width, size.height) * 0.012, dy: -min(size.width, size.height) * 0.012)))
                XCTAssertEqual(rect.width / rect.height, 3, accuracy: 0.001)
                let bitmap = NSBitmapImageRep(data: try SceneRenderer.png(scene, image: backdrop, size: size, logoImage: logoImage))!
                let color = bitmap.colorAt(x: Int(rect.midX), y: Int(size.height - rect.midY))!.usingColorSpace(.deviceRGB)!
                XCTAssertGreaterThan(color.blueComponent, 0.9, "Export must contain the logo at the selected corner")
            }
        }
        // Optional review artifacts use the shipping compositor; no window or desktop changes.
        let evidence = ProcessInfo.processInfo.environment["STAGEMARK_SCENE_REVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let evidence { try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true) }
        for starter in SceneStarters.all {
            let backdrop = NSImage(contentsOf: starter.url(in: resources))!
            for (label, size) in [("16x9", CGSize(width: 960, height: 540)), ("16x10", CGSize(width: 960, height: 600))] {
                for (position, x) in [("left", 0.12), ("centre", 0.5), ("right", 0.88)] {
                    var scene = DemoScene(background: starter.filename); scene.phoneX = x
                    scene.logo = SceneLogo(image: "logo.png", corner: x > 0.5 ? .topLeft : .topRight)
                    let png = try SceneRenderer.png(scene, image: backdrop, size: size, logoImage: logoImage)
                    let bitmap = NSBitmapImageRep(data: png)!
                    XCTAssertEqual(bitmap.pixelsWide, Int(size.width)); XCTAssertEqual(bitmap.pixelsHigh, Int(size.height))
                    if let evidence { try png.write(to: evidence.appendingPathComponent("\(starter.id)-\(label)-\(position).png")) }
                }
            }
        }
    }
}
