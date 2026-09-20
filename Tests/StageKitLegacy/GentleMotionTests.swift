import AppKit
import SceneSyncKit

final class GentleMotionTests {
    private func image() -> NSImage {
        NSImage(size: NSSize(width: 240, height: 160), flipped: false) { rect in
            NSColor.cyan.setFill(); rect.fill()
            NSColor.orange.setFill(); CGRect(x: 20, y: 15, width: 70, height: 60).fill()
            return true
        }
    }
    func testLegacyAndPortableSceneMotion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var scene = DemoScene(name: "Motion test", background: "photo.png", showsPhone: false)
        let bitmap = try SceneRenderer.png(scene, image: image(), size: CGSize(width: 240, height: 160))
        try bitmap.write(to: root.appendingPathComponent("photo.png"))
        let legacy = try JSONEncoder().encode(scene)
        XCTAssertEqual(try JSONDecoder().decode(DemoScene.self, from: legacy).gentleMotion, nil)
        try SceneStorage.save([scene], to: root.appendingPathComponent("scenes.json"))
        try MainActor.assumeIsolated {
            let adapter = MacSceneSync(root: root, systemIntegrationEnabled: false)
            scene = adapter.scenes[0]; scene.gentleMotion = true; try adapter.save(scene)
            let package = try adapter.library.package(for: adapter.library.records[0].scene)
            let exported = try ScenePackage.decode(package.encoded())
            XCTAssertEqual(exported.scene.gentleMotion, true)
            let reopened = MacSceneSync(root: root, systemIntegrationEnabled: false)
            XCTAssertEqual(reopened.scenes[0].gentleMotion, true)
            var still = reopened.scenes[0]; still.gentleMotion = nil; try reopened.save(still)
            XCTAssertEqual(reopened.library.records[0].scene.gentleMotion, nil)
        }
        XCTAssertTrue(GentlePhotoMotion.permitted(requested: true, visible: true, reduceMotion: false, lowPower: false, thermalState: .nominal))
        for (visible, reduce, power, thermal) in [(false, false, false, ProcessInfo.ThermalState.nominal),
            (true, true, false, .nominal), (true, false, true, .nominal), (true, false, false, .serious), (true, false, false, .critical)] {
            XCTAssertFalse(GentlePhotoMotion.permitted(requested: true, visible: visible, reduceMotion: reduce, lowPower: power, thermalState: thermal))
        }
    }
    func testMotionDoesNotChangeStillExport() throws {
        var scene = DemoScene(background: "photo.png", backgroundX: 0.3, backgroundY: 0.8, zoom: 1.4)
        let photo = image(), size = CGSize(width: 420, height: 240)
        let before = try SceneRenderer.png(scene, image: photo, size: size)
        scene.gentleMotion = true
        XCTAssertEqual(try SceneRenderer.png(scene, image: photo, size: size), before)
        let animation = GentlePhotoMotion.animation()
        XCTAssertEqual(animation.keyPath, "transform.scale")
        XCTAssertEqual(animation.fromValue as? Double, 1)
        XCTAssertTrue((animation.toValue as? Double ?? 0) <= 1.04)
        XCTAssertTrue(animation.duration >= 20)
        XCTAssertTrue(animation.autoreverses)
    }
    func testForegroundExcludesPhotograph() throws {
        let size = CGSize(width: 320, height: 240)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 240, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        SceneRenderer.draw(DemoScene(background: "photo.png"), image: image(), size: size, drawsBackground: false)
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)!.alphaComponent, 0)
        XCTAssertTrue(bitmap.colorAt(x: 160, y: 120)!.alphaComponent > 0.99, "Device frame stays in the stationary foreground")
    }
    func testTransparentPhotographKeepsStillBase() throws {
        let scene = DemoScene(background: "transparent.png", showsPhone: false)
        let photo = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { _ in
            NSColor.blue.setFill(); CGRect(x: 10, y: 10, width: 20, height: 20).fill(); return true
        }
        let png = try SceneRenderer.png(scene, image: photo, size: CGSize(width: 40, height: 40))
        let still = NSBitmapImageRep(data: png)!.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        let view = MovingSceneView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        view.configure(scene: scene, backdrop: photo, logo: nil, hand: nil, persona: nil)
        view.layout()
        let rendered = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rendered)!
        view.layer!.render(in: context.cgContext)
        // Compare rendered PNGs in the same profile, not a source CGColor to
        // a colour-converted exported pixel.
        let movingPNG = rendered.representation(using: .png, properties: [:])!
        let moving = NSBitmapImageRep(data: movingPNG)!.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        XCTAssertEqual(still.redComponent, moving.redComponent, accuracy: 0.005)
        XCTAssertEqual(still.greenComponent, moving.greenComponent, accuracy: 0.005)
        XCTAssertEqual(still.blueComponent, moving.blueComponent, accuracy: 0.005)
        XCTAssertEqual(moving.alphaComponent, 1)
    }
}
