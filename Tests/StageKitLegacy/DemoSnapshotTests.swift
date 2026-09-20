import AppKit
import AVFoundation
import SwiftUI

final class DemoSnapshotTests {
    private func sample(width: Int = 64, height: Int = 96, cropped: Bool = false) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "SnapshotTests.CVPixelBufferCreate", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let i = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            bytes[i] = y >= height / 2 ? 255 : 0
            bytes[i + 1] = x >= width / 2 ? 255 : 0
            bytes[i + 2] = y < height / 2 ? 255 : 0
            bytes[i + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if cropped {
            CVBufferSetAttachment(buffer, kCVImageBufferCleanApertureKey, [
                kCVImageBufferCleanApertureWidthKey: 48,
                kCVImageBufferCleanApertureHeightKey: 80,
                kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
                kCVImageBufferCleanApertureVerticalOffsetKey: 0
            ] as CFDictionary, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 2,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1
            ] as CFDictionary, .shouldPropagate)
        }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { throw DemoSnapshotError.render }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result) == noErr, let result else { throw DemoSnapshotError.render }
        return result
    }
    func testFreshnessAndReplacement() throws {
        var now = 10.0
        let store = DemoSnapshotStore(now: { now })
        XCTAssertThrowsError(try store.frame())
        let epoch = store.activate(source: "phone")
        let first = try sample(), next = try sample(width: 96, height: 64)
        store.receive(first, epoch: epoch, source: "phone", receivedAt: Date(timeIntervalSince1970: 100))
        let frame = try store.frame()
        XCTAssertTrue(frame.sample === first)
        XCTAssertEqual(frame.receivedAt, Date(timeIntervalSince1970: 100))
        now = 10.8
        store.receive(next, epoch: epoch, source: "phone")
        XCTAssertTrue(try store.frame().sample === next, "Only the newest sample is retained")
        var writes = 0
        try store.commit(frame, connected: { true }, write: { writes += 1; return true })
        XCTAssertEqual(writes, 1, "A frozen but still fresh frame may complete after a newer frame arrives")
        now = 11.01
        XCTAssertThrowsError(try store.commit(frame, connected: { true }, write: { writes += 1; return true }))
        XCTAssertEqual(writes, 1, "Rendering time counts toward the freshness limit")
        now = 12
        // No newer sample means stale, even if the UI still says live.
        XCTAssertThrowsError(try store.frame())
        now = 9
        XCTAssertThrowsError(try store.frame()) // A backwards clock is never fresh.
        now = .nan
        XCTAssertThrowsError(try store.frame())
    }
    func testLifecycleAndClipboardFailures() throws {
        let store = DemoSnapshotStore(now: { 20 })
        let sample = try sample()
        for source in ["phone", "phone", "tablet"] {
            let epoch = store.activate(source: source)
            store.receive(sample, epoch: epoch, source: source)
            let frame = try store.frame(expectedEpoch: epoch)
            var writes = 0
            XCTAssertThrowsError(try store.commit(frame, connected: { false }, write: { writes += 1; return true }))
            XCTAssertEqual(writes, 0, "A physically disconnected source cannot touch the clipboard")
            do {
                try store.commit(frame, connected: { true }, write: { false })
                XCTAssertTrue(false, "Clipboard refusal must throw")
            } catch {
                XCTAssertEqual(error.localizedDescription, DemoSnapshotError.clipboard.localizedDescription)
            }
            store.invalidate()
            XCTAssertThrowsError(try store.commit(frame, connected: { true }, write: { writes += 1; return true }))
            store.receive(sample, epoch: epoch, source: source)
            XCTAssertThrowsError(try store.frame()) // Late samples cannot restore a stopped generation.
            _ = store.activate(source: source)
            XCTAssertThrowsError(try store.frame(expectedEpoch: epoch)) // A queued request cannot adopt a replacement session.
            XCTAssertThrowsError(try store.commit(frame, connected: { true }, write: { writes += 1; return true }))
            XCTAssertEqual(writes, 0)
        }
        let epoch = store.activate(source: "phone")
        store.receive(sample, epoch: epoch, source: "tablet")
        XCTAssertThrowsError(try store.frame()) // Source identity is independently required.
        store.receive(sample, epoch: epoch, source: "phone")
        store.invalidate(source: "unrelated camera")
        XCTAssertEqual(try store.frame().source, "phone")
        store.invalidate(source: "phone")
        XCTAssertThrowsError(try store.frame())
        let ownSession = NSObject(), unrelatedSession = NSObject()
        let sessionEpoch = store.activate(source: "phone", session: ObjectIdentifier(ownSession))
        store.receive(sample, epoch: sessionEpoch, source: "phone")
        store.invalidate(session: ObjectIdentifier(unrelatedSession))
        XCTAssertEqual(try store.frame().epoch, sessionEpoch)
        store.invalidate(session: ObjectIdentifier(ownSession))
        XCTAssertThrowsError(try store.frame())
        // Exercise the real capture entry points without starting a camera.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotCapture-" + UUID().uuidString)
        let capture = DemoCapture(root: root, snapshots: store)
        let actions: [() -> Void] = [{ capture.select("phone") }, { capture.reconnect() }, { capture.stop() }]
        for action in actions {
            let epoch = store.activate(source: "phone")
            store.receive(sample, epoch: epoch, source: "phone")
            let pending = try store.frame()
            action()
            XCTAssertThrowsError(try store.commit(pending, connected: { true }, write: { true }))
            XCTAssertThrowsError(try store.frame())
        }
    }
    func testDeviceConversionAndSceneComposite() throws {
        let sample = try sample()
        let converted = try DemoSnapshotRendering.deviceImage(sample)
        XCTAssertEqual(converted.displaySize, CGSize(width: 64, height: 96))
        let device = NSImage(cgImage: converted.pixels, size: converted.displaySize)
        let pixels = NSBitmapImageRep(cgImage: converted.pixels)
        XCTAssertTrue(pixels.colorAt(x: 8, y: 8)!.redComponent > 0.9, "Top-left stays red, not flipped or mirrored")
        XCTAssertTrue(pixels.colorAt(x: 8, y: 88)!.blueComponent > 0.9, "Bottom-left stays blue")
        XCTAssertTrue(pixels.colorAt(x: 56, y: 8)!.greenComponent > 0.9, "Right-hand marker stays on the right")
        let cropped = try DemoSnapshotRendering.deviceImage(self.sample(cropped: true))
        XCTAssertEqual(cropped.displaySize, CGSize(width: 96, height: 80), "Clean aperture and nonsquare pixels match preview proportions")
        XCTAssertEqual(cropped.pixels.width, 48)
        XCTAssertEqual(cropped.pixels.height, 80)
        let backdrop = NSImage(size: CGSize(width: 180, height: 80), flipped: false) { rect in
            NSColor.orange.setFill(); rect.fill()
            NSColor.purple.setFill(); CGRect(x: 80, y: 0, width: 100, height: 80).fill(); return true
        }
        let logo = NSImage(size: CGSize(width: 40, height: 20), flipped: false) { rect in NSColor.green.setFill(); rect.fill(); return true }
        let persona = NSImage(size: CGSize(width: 40, height: 60), flipped: false) { rect in NSColor.cyan.setFill(); rect.fill(); return true }
        var original = DemoScene(background: "synthetic.png")
        original.logo = SceneLogo(image: "logo.png", corner: .topLeft)
        original.persona = PersonaPlacement(image: "persona.png", x: 0.5, y: 0.1, width: 0.2)
        original.backgroundX = 0.2; original.backgroundY = 0.7; original.zoom = 1.4
        original.viewport = .landscape
        let saved = original
        for fit in [false, true] {
            let scene = DemoSnapshotRendering.scene(original, matching: fit ? converted.displaySize : nil)
            if fit { XCTAssertEqual(scene.viewport!.aspect, 64.0 / 96, accuracy: 0.00001) }
            else { XCTAssertEqual(scene.viewport, .landscape) }
            let size = CGSize(width: 480, height: 320)
            let baseData = try SceneRenderer.png(scene, image: backdrop, size: size, logoImage: logo, personaImage: persona)
            let snapData = try SceneRenderer.png(scene, image: backdrop, size: size, logoImage: logo, personaImage: persona, deviceImage: device)
            let base = NSBitmapImageRep(data: baseData)!, snap = NSBitmapImageRep(data: snapData)!
            let screen = ViewportGeometry(scene: scene, size: size).screen
            var outsideMatches = true, changed = 0
            for y in 0..<320 { for x in 0..<480 {
                let a = base.colorAt(x: x, y: y)!, b = snap.colorAt(x: x, y: y)!
                if a != b {
                    changed += 1
                    if !screen.insetBy(dx: -1, dy: -1).contains(CGPoint(x: Double(x) + 0.5, y: 319.5 - Double(y))) { outsideMatches = false }
                }
            } }
            XCTAssertTrue(outsideMatches, "Crop, background, bezel, logo and persona outside the screen stay pixel-identical")
            XCTAssertTrue(changed > 1000, "The exported PNG actually contains device pixels")
            let personaRect = PersonaGeometry.rect(scene.persona!, imageSize: persona.size, in: size)
            let cx = Int(personaRect.midX), cy = Int(size.height - personaRect.midY)
            XCTAssertEqual(snap.colorAt(x: cx, y: cy), base.colorAt(x: cx, y: cy), "Persona remains above the live device image")
            if !fit {
                let bar = snap.colorAt(x: Int(screen.minX + 10), y: Int(size.height - screen.midY))!
                XCTAssertTrue(bar.redComponent < 0.05 && bar.greenComponent < 0.05 && bar.blueComponent < 0.05, "Fixed aspect uses black letterboxing, not stretching")
            }
        }
        XCTAssertEqual(original, saved, "Snapshot rendering never edits the saved scene")
        original.showsPhone = false
        let a = try SceneRenderer.png(original, image: backdrop, size: CGSize(width: 120, height: 80))
        let b = try SceneRenderer.png(original, image: backdrop, size: CGSize(width: 120, height: 80), deviceImage: device)
        XCTAssertEqual(a, b, "A hidden phone cannot leak its frame into a scene export")
    }
    func testCanvasBounds() throws {
        XCTAssertEqual(try DemoSnapshotRendering.canvasSize(CGSize(width: 1100, height: 720)), CGSize(width: 2200, height: 1440))
        XCTAssertEqual(try DemoSnapshotRendering.canvasSize(CGSize(width: 6000, height: 4000)), CGSize(width: 3840, height: 2560))
        XCTAssertEqual(try DemoSnapshotRendering.canvasSize(CGSize(width: 300, height: 600)), CGSize(width: 600, height: 1200))
        for size in [CGSize.zero, CGSize(width: CGFloat.nan, height: 100), CGSize(width: 10, height: CGFloat.infinity)] {
            XCTAssertThrowsError(try DemoSnapshotRendering.canvasSize(size))
        }
        let visible = CGRect(x: 0, y: 0, width: 480, height: 292)
        for anchor in FloatingControlAnchor.allCases {
            XCTAssertTrue(visible.contains(FloatingControlGeometry.frame(anchor: anchor, size: CGSize(width: 304, height: 278), visibleFrame: visible)))
        }
    }

    /// Actual production renderer/control views with synthetic data. Not a
    /// physical device, window-server screenshot or successful clipboard proof.
    @MainActor func writeEvidence(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notices: [(String, Bool, String?)] = [
            ("ready", true, nil),
            ("copied", true, "Copied PNG · Synthetic iPhone · frame received 10:30:12 AM · still backdrop"),
            ("stale", true, DemoSnapshotError.stale.localizedDescription),
            ("disconnected", false, DemoSnapshotError.unavailable.localizedDescription)
        ]
        for (name, canCopy, notice) in notices {
            let content = DemoSnapshotControls(canCopy: canCopy, copying: false, notice: notice, copy: {})
                .padding(12).frame(width: 304, height: 100).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let view = NSHostingView(rootView: content)
            view.frame = CGRect(x: 0, y: 0, width: 304, height: 100)
            view.appearance = NSAppearance(named: .darkAqua)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DemoSnapshotError.render }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DemoSnapshotError.render }
            try data.write(to: root.appendingPathComponent("snapshot-controls-" + name + ".png"))
        }
        let converted = try DemoSnapshotRendering.deviceImage(sample())
        let device = NSImage(cgImage: converted.pixels, size: converted.displaySize)
        let background = NSImage(size: CGSize(width: 960, height: 600), flipped: false) { rect in
            NSGradient(starting: .darkGray, ending: .systemIndigo)!.draw(in: rect, angle: 30); return true
        }
        let logo = NSImage(data: try SceneLibraryStorage.textLogo("SYNTHETIC DEMO"))!
        let persona = NSImage(data: try SceneLibraryStorage.textLogo("Sample presenter"))!
        var scene = DemoScene(name: "Synthetic snapshot", background: "synthetic.png")
        scene.logo = SceneLogo(image: "logo.png", corner: .topLeft, width: 0.24)
        scene.persona = PersonaPlacement(image: "persona.png", x: 0.98, y: 0.1, width: 0.25)
        scene = DemoSnapshotRendering.scene(scene, matching: converted.displaySize)
        let data = try SceneRenderer.png(scene, image: background, size: CGSize(width: 960, height: 600),
            logoImage: logo, personaImage: persona, deviceImage: device)
        try data.write(to: root.appendingPathComponent("snapshot-composite.png"))
    }
}
