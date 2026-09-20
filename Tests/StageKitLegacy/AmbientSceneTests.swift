import AppKit
import ImageIO
import SceneSyncKit
import UniformTypeIdentifiers

final class AmbientSceneTests {
    private var resources: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/SceneBackdrops")
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AmbientSceneTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw SceneError.invalidImage }; return value
    }

    func testAllStartersKeepExactPortableAssetsThroughDuplicateAndReopen() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let model = DemoScenes(root: root, systemIntegrationEnabled: false)
            let starters = SceneStarters.all.filter { $0.ambientPreset != nil }
            XCTAssertEqual(starters.map(\.id), ["window-light", "campus-breeze", "coastal-sky"])
            var saved: [UUID: ScenePackage] = [:]
            for starter in starters {
                try model.useStarter(starter, directory: resources)
                let scene = try require(model.selected), adapter = try require(model.sceneSync)
                let record = try require(adapter.library.records.first { $0.id == scene.id })
                let recipe = try require(record.scene.ambience)
                XCTAssertEqual(scene.ambience, recipe); XCTAssertEqual(recipe.preset, starter.id)
                XCTAssertEqual(scene.gentleMotion, true); XCTAssertFalse(scene.showsPhone)
                let package = try adapter.library.package(for: record.scene)
                XCTAssertEqual(package.version, 2); XCTAssertEqual(package.assets.count, 3)
                let directory = resources.deletingLastPathComponent().appendingPathComponent("AmbientScenes")
                for (asset, url) in [(record.scene.background, starter.url(in: resources)),
                                     (recipe.cleanPlate, directory.appendingPathComponent(starter.id + ".png")),
                                     (recipe.detail, directory.appendingPathComponent(starter.detailFilename))] {
                    let bytes = try Data(contentsOf: url)
                    XCTAssertEqual(package.assets[asset], bytes)
                    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(MacSceneSync.materializedName(asset))), bytes)
                }
                XCTAssertNotNil(model.ambienceImages(for: scene))
                XCTAssertEqual(try ScenePackage.decode(package.encoded()), package)
                saved[scene.id] = package
                model.duplicate()
                let duplicate = try require(model.selected)
                XCTAssertTrue(duplicate.id != scene.id); XCTAssertEqual(duplicate.ambience, scene.ambience)
                let copied = try require(adapter.library.records.first { $0.id == duplicate.id })
                XCTAssertEqual(try adapter.library.package(for: copied.scene).assets, package.assets)
            }
            let reopened = DemoScenes(root: root, systemIntegrationEnabled: false)
            let library = try require(reopened.sceneSync).library
            XCTAssertEqual(reopened.scenes.count, 6); XCTAssertFalse(library.isConfigured)
            XCTAssertEqual(try SceneLibraryStore(directory: library.directory).load().version, 2)
            for (id, original) in saved {
                let scene = try require(library.records.first { $0.id == id }).scene
                XCTAssertEqual(try library.package(for: scene), original)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scenes.json").path))
        }
    }

    func testCropKeepsRecipeAndReplacementClearsItWithoutRemovingOriginals() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let model = DemoScenes(root: root, systemIntegrationEnabled: false)
            try model.useStarter(try require(SceneStarters.all.first { $0.id == "window-light" }), directory: resources)
            var initial = try require(model.selected)
            initial.phoneX = 0.17; initial.phoneY = 0.8
            initial.logo = SceneLogo(image: initial.background, corner: .bottomLeft, width: 0.2)
            initial.persona = PersonaPlacement(image: initial.background, x: 0.18, y: 0.72, width: 0.13)
            XCTAssertTrue(model.update(initial)); initial = try require(model.selected)
            let library = try require(model.sceneSync).library
            let original = try library.package(for: require(library.records.first { $0.id == initial.id }).scene)
            let crop = BackdropReplacement(scene: initial, root: root)
            crop.x = 0.23; crop.y = 0.71; crop.zoom = 1.6
            try model.applyBackdrop(crop)
            let cropped = try require(model.selected)
            XCTAssertEqual(cropped.ambience, initial.ambience); XCTAssertEqual(cropped.gentleMotion, true)
            XCTAssertEqual(cropped.backgroundX, 0.23); XCTAssertEqual(cropped.backgroundY, 0.71); XCTAssertEqual(cropped.zoom, 1.6)
            let source = root.appendingPathComponent("synthetic-replacement.png"), bytes = try png(plate())
            try bytes.write(to: source)
            let replacement = BackdropReplacement(scene: cropped, root: root)
            try replacement.chooseImage(source); try model.applyBackdrop(replacement)
            let changed = try require(model.selected)
            XCTAssertTrue(changed.ambience == nil); XCTAssertTrue(changed.gentleMotion == nil)
            XCTAssertEqual(changed.logo, initial.logo); XCTAssertEqual(changed.persona, initial.persona)
            XCTAssertEqual(changed.phoneX, initial.phoneX); XCTAssertEqual(changed.phoneY, initial.phoneY)
            XCTAssertEqual(changed.backgroundX, 0.5); XCTAssertEqual(changed.backgroundY, 0.5); XCTAssertEqual(changed.zoom, 1)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(changed.background)), bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            for (asset, data) in original.assets {
                XCTAssertEqual(try Data(contentsOf: library.assetURL(asset)), data)
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(MacSceneSync.materializedName(asset))), data)
            }
            let reopened = DemoScenes(root: root, systemIntegrationEnabled: false)
            XCTAssertEqual(reopened.scenes.first, changed)
            XCTAssertEqual(try SceneLibraryStore(directory: library.directory).load().version, 2)
        }
    }

    func testStaleCropAndSceneDraftRejectAnInterveningRecipeChange() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let model = DemoScenes(root: root, systemIntegrationEnabled: false)
            try model.useStarter(try require(SceneStarters.all.first { $0.id == "window-light" }), directory: resources)
            let old = try require(model.selected), crop = BackdropReplacement(scene: try require(model.selected), root: root)
            crop.x = 0.19
            var changedRecipe = old; changedRecipe.ambience?.preset = "coastal-sky"
            XCTAssertTrue(model.update(changedRecipe))
            let current = try require(model.selected)
            let manifest = SceneLibraryStore(directory: try require(model.sceneSync).library.directory).manifest
            let bytes = try Data(contentsOf: manifest)
            XCTAssertThrowsError(try model.applyBackdrop(crop))
            var stale = old; stale.name = "Must not replace a newer recipe"
            XCTAssertFalse(model.update(stale))
            XCTAssertEqual(model.selected, current); XCTAssertEqual(try Data(contentsOf: manifest), bytes)
            XCTAssertEqual(model.selected?.ambience?.preset, "coastal-sky")
            XCTAssertTrue(crop.active, "A rejected draft remains available until the user cancels")
            crop.cancel()
        }
    }

    func testMovingSceneViewMatchesPosterOrientationAndClipsCloudsToWindow() throws {
        try MainActor.assumeIsolated {
            let base = try plate(), detail = try detail(), size = CGSize(width: 320, height: 180)
            for preset in ["window-light", "campus-breeze", "coastal-sky"] {
                let poster = try require(AmbientPhotoLayer.makePoster(preset: preset, cleanPlate: base, detail: detail))
                let scene = DemoScene(background: "poster.png", gentleMotion: true, ambience: recipe(preset), showsPhone: false)
                let view = MovingSceneView(frame: CGRect(origin: .zero, size: size))
                view.configure(scene: scene, backdrop: NSImage(cgImage: poster, size: size), logo: nil, hand: nil, persona: nil,
                    ambience: AmbientSceneImages(preset: preset, cleanPlate: base, detail: detail))
                view.layout()
                let rendered = try render(view)
                XCTAssertTrue(changedPixels(rendered, poster).count < 320 * 180 / 100,
                              "The complete native \(preset) composition must match its still poster")
                let ambient = try require(view.layer?.sublayers?.compactMap { $0 as? AmbientPhotoLayer }.first)
                XCTAssertEqual(ambient.frame, view.bounds)
                if preset == "window-light" {
                    let region = try require(ambient.sublayers?.last), cloud = try require(region.sublayers?.first)
                    XCTAssertTrue(region.masksToBounds)
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    cloud.transform = CATransform3DMakeTranslation(region.bounds.width * 0.6, 0, 0)
                    CATransaction.commit()
                    let changes = changedPixels(try render(view), base)
                    XCTAssertGreaterThan(changes.count, 50, "A displaced cloud must still be rendered")
                    let allowed = CGRect(x: 0.523 * 320, y: 0.071 * 180, width: 0.423 * 320, height: 0.446 * 180).insetBy(dx: -1, dy: -1)
                    XCTAssertTrue(changes.allSatisfy { allowed.contains($0) }, "The animated detail must never cover the room or window surround")
                }
            }
        }
    }

    func testMissingRigAssetKeepsCompletePosterAndDoesNotBecomePhotoZoom() throws {
        try MainActor.assumeIsolated {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let model = DemoScenes(root: root, systemIntegrationEnabled: false)
            try model.useStarter(try require(SceneStarters.all.first { $0.id == "window-light" }), directory: resources)
            let scene = try require(model.selected), recipe = try require(scene.ambience)
            let poster = try require(model.image(for: scene)), library = try require(model.sceneSync).library
            let sourceBytes = try Data(contentsOf: library.assetURL(recipe.detail))
            try FileManager.default.removeItem(at: root.appendingPathComponent(MacSceneSync.materializedName(recipe.detail)))
            XCTAssertTrue(model.ambienceImages(for: scene) == nil)
            XCTAssertEqual(try Data(contentsOf: library.assetURL(recipe.detail)), sourceBytes)

            // No window is ordered on screen. Only its visibility getters are
            // synthetic, so the actual view's eligible-playback branch is used.
            let window = AmbientVisibilityWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
                styleMask: .borderless, backing: .buffered, defer: true)
            let view = MovingSceneView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
            window.contentView = view
            defer { window.contentView = nil }
            view.configure(scene: scene, backdrop: poster, logo: nil, hand: nil, persona: nil, ambience: model.ambienceImages(for: scene))
            view.layout(); view.motionRequested = true
            XCTAssertFalse(view.isAnimating)
            let expected = try require(CGImageSourceCreateWithData(SceneRenderer.png(scene, image: poster, size: view.bounds.size) as CFData, nil))
            let expectedImage = try require(CGImageSourceCreateImageAtIndex(expected, 0, nil))
            XCTAssertTrue(changedPixels(try render(view), expectedImage).count < 320 * 180 / 100)
            var ordinaryPhoto = scene; ordinaryPhoto.ambience = nil
            view.configure(scene: ordinaryPhoto, backdrop: poster, logo: nil, hand: nil, persona: nil)
            view.layout(); view.motionRequested = true
            let permitted = GentlePhotoMotion.permitted(requested: true, visible: true,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.processInfo.thermalState)
            XCTAssertEqual(view.isAnimating, permitted, "Ordinary photo is the positive control for the same visibility and energy conditions")
            view.motionRequested = false
        }
    }

    private func recipe(_ preset: String) -> SceneAmbience {
        SceneAmbience(preset: preset, cleanPlate: String(repeating: "a", count: 64) + ".image", detail: String(repeating: "b", count: 64) + ".image")
    }
    private func plate() throws -> CGImage {
        try image(width: 320, height: 180) { x, y in [UInt8(30 + x / 4), UInt8(35 + y / 2), UInt8(60 + (x + y) / 5), 255] }
    }
    private func detail() throws -> CGImage {
        try image(width: 100, height: 60) { x, y in
            if x < 4 || y < 4 || x > 95 || y > 55 { return [0, 0, 0, 0] }
            return x < 40 ? [245, 180, 100, 255] : [100, 230, 180, 255]
        }
    }
    private func image(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) throws -> CGImage {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { bytes += pixel(x, y) } }
        return try require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }
    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let output = try require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw SceneError.invalidImage }
        return data as Data
    }
    private func render(_ view: MovingSceneView) throws -> CGImage {
        let context = try require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try require(view.layer).render(in: context)
        return try require(context.makeImage())
    }
    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        return bytes
    }
    private func changedPixels(_ a: CGImage, _ b: CGImage) -> [CGPoint] {
        let lhs = rgba(a), rhs = rgba(b)
        var changes: [CGPoint] = []
        for y in 0..<180 { for x in 0..<320 {
            let offset = (y * 320 + x) * 4
            if (0..<4).contains(where: { abs(Int(lhs[offset + $0]) - Int(rhs[offset + $0])) > 3 }) { changes.append(CGPoint(x: x, y: y)) }
        } }
        return changes
    }
}

private final class AmbientVisibilityWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
}
