import AppKit
import AVFoundation

final class ViewportFitTests {
    func testFullHeightSurvivesSavingAndReachesBothEdges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ViewportFitTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("scenes.json")
        var scene = DemoScene(background: "photo.png")
        scene.viewport = .phone; scene.phoneHeight = 1
        try SceneStorage.save([scene], to: archive)
        let saved = try SceneStorage.load(archive)[0]
        XCTAssertEqual(saved.phoneHeight, 1, "Full height must survive save and reopen")
        let size = CGSize(width: 1920, height: 1080)
        for position in [0.0, 0.5, 1.0] {
            scene = saved; scene.phoneY = position
            let geometry = ViewportGeometry(scene: scene, size: size)
            XCTAssertEqual(geometry.outer.minY, 0)
            XCTAssertEqual(geometry.outer.maxY, size.height)
            XCTAssertEqual(geometry.screen.minY, geometry.border, accuracy: 0.00001)
            XCTAssertEqual(geometry.screen.maxY, size.height - geometry.border, accuracy: 0.00001)
        }
        scene.phoneHeight = 1.05
        XCTAssertEqual(try scene.validated().phoneHeight, 1, "Settings must stop at the canvas edge")
        XCTAssertEqual(ViewportGeometry(scene: scene, size: size).outer.height, size.height,
                       "The renderer must also contain an oversized draft")
        scene.phoneHeight = 0.96
        XCTAssertEqual(ViewportGeometry(scene: scene, size: size).outer.height, size.height * 0.96,
                       "Existing scene sizes must remain unchanged")
    }

    func testMaximumSizeFitsDisplayAndPreservesScreenShape() {
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 3440, height: 1440)] {
            for viewport in [DeviceViewport.phone, .tablet, .landscape, .legacy, DeviceViewport(aspect: 2.4, border: 0.035, corners: 0.3)] {
                for position in [0.0, 0.5, 1.0] {
                    var scene = DemoScene(background: "photo.png")
                    scene.viewport = viewport; scene.phoneHeight = 1
                    scene.phoneX = position; scene.phoneY = position
                    let geometry = ViewportGeometry(scene: scene, size: size)
                    XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.001, dy: -0.001).contains(geometry.outer),
                                  "The entire outer border must fit, including on portrait displays")
                    XCTAssertTrue(geometry.outer.contains(geometry.screen))
                    XCTAssertEqual(geometry.screen.width / geometry.screen.height, viewport.aspect, accuracy: 0.00001)
                    XCTAssertTrue(geometry.outer.width <= size.width * 0.96 + 0.001,
                                  "Wide devices retain the existing horizontal fit margin")
                }
            }
        }
    }

    func testExportAndLiveScreenUseFullHeightBorder() throws {
        var scene = DemoScene(background: "photo.png")
        scene.viewport = .phone; scene.phoneHeight = 1
        let size = CGSize(width: 800, height: 450)
        let backdrop = NSImage(size: size, flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let geometry = ViewportGeometry(scene: scene, size: size)
        let data = try SceneRenderer.png(scene, image: backdrop, size: size)
        let bitmap = NSBitmapImageRep(data: data)!
        for row in [0, bitmap.pixelsHigh - 1] {
            let borderPixel = bitmap.colorAt(x: Int(geometry.outer.midX), y: row)!
            XCTAssertTrue(borderPixel.redComponent < 0.15 && borderPixel.greenComponent < 0.15 && borderPixel.blueComponent < 0.15,
                          "The exported black frame must reach the top and bottom pixels")
            XCTAssertGreaterThan(bitmap.colorAt(x: 5, y: row)!.redComponent, 0.9,
                                 "The full-height frame must preserve the surrounding backdrop")
        }
        let previewLayer = AVCaptureVideoPreviewLayer()
        let liveView = DemoStageSurfaceView(previewLayer: previewLayer)
        liveView.frame = CGRect(origin: .zero, size: size)
        liveView.configure(scene: scene, backdrop: backdrop, logo: nil, hand: nil, persona: nil)
        liveView.viewportScene = scene; liveView.layout()
        // CALayer derives its frame from bounds and position, which can add
        // floating-point rounding even when the same rectangle was assigned.
        XCTAssertEqual(previewLayer.frame.minX, geometry.screen.minX, accuracy: 0.00001)
        XCTAssertEqual(previewLayer.frame.minY, geometry.screen.minY, accuracy: 0.00001)
        XCTAssertEqual(previewLayer.frame.width, geometry.screen.width, accuracy: 0.00001)
        XCTAssertEqual(previewLayer.frame.height, geometry.screen.height, accuracy: 0.00001)
        XCTAssertEqual(previewLayer.cornerRadius, geometry.innerRadius)
        XCTAssertEqual(SceneRenderer.phoneRect(scene, in: size), geometry.outer)
    }
}
