import CoreGraphics
import Foundation
import QuartzCore
import XCTest
@testable import SceneSyncKit

@MainActor final class AmbientPhotoLayerTests: XCTestCase {
    private let size = CGSize(width: 320, height: 180)

    func testWindowPosterChangesOnlyAuthoredSkyAndPreservesRoom() throws {
        let base = try plate(), detail = try cutout()
        let poster = try XCTUnwrap(AmbientPhotoLayer.makePoster(preset: "window-light", cleanPlate: base, detail: detail))
        assertChanges(poster, versus: base,
            confinedTo: CGRect(x: 0.523 * 320, y: 0.071 * 180, width: 0.423 * 320, height: 0.446 * 180))
    }

    func testCoastalPosterChangesOnlyUpperSky() throws {
        let base = try plate()
        let poster = try XCTUnwrap(AmbientPhotoLayer.makePoster(preset: "coastal-sky", cleanPlate: base, detail: try cutout()))
        assertChanges(poster, versus: base, confinedTo: CGRect(x: 0, y: 0, width: 320, height: 0.32 * 180))
    }

    func testCampusBranchesRemainAboveLandscapeAndAppearAtBothEdges() throws {
        let base = try plate()
        let poster = try XCTUnwrap(AmbientPhotoLayer.makePoster(preset: "campus-breeze", cleanPlate: base, detail: try cutout()))
        assertChanges(poster, versus: base, confinedTo: CGRect(x: 0, y: 0, width: 320, height: 0.34 * 180))
        let changes = changedPixels(poster, base)
        XCTAssertTrue(changes.contains { $0.x < 80 && $0.y < 40 })
        XCTAssertTrue(changes.contains { $0.x > 260 && $0.y < 40 })
    }

    func testAllNativeModelLayersMatchCanonicalPostersInBothHostOrientations() throws {
        let base = try plate(), detail = try cutout()
        for preset in ["window-light", "campus-breeze", "coastal-sky"] {
            let poster = try XCTUnwrap(AmbientPhotoLayer.makePoster(preset: preset, cleanPlate: base, detail: detail))
            for flippedHost in [false, true] {
                let layer = AmbientPhotoLayer()
                // Test the two documented host boundaries on the same machine:
                // AppKit unflipped + flipped subgeometry; UIKit the opposite.
                layer.isGeometryFlipped = !flippedHost
                layer.bounds = CGRect(origin: .zero, size: size)
                XCTAssertTrue(layer.configure(preset: preset, cleanPlate: base, detail: detail))
                let actual = try render(layer, flippedHost: flippedHost)
                assertAligned(actual, poster, context: "\(preset), host flipped \(flippedHost)")
            }
        }
    }

    func testNativeCloudClipAlsoContainsDisplacedDetails() throws {
        let base = try plate(), layer = AmbientPhotoLayer()
        layer.isGeometryFlipped = true
        layer.bounds = CGRect(origin: .zero, size: size)
        XCTAssertTrue(layer.configure(preset: "window-light", cleanPlate: base, detail: try cutout()))
        let region = try XCTUnwrap(layer.sublayers?.last)
        XCTAssertTrue(region.masksToBounds)
        let cloud = try XCTUnwrap(region.sublayers?.first)
        // Force the real image layer across its clip edge. The fixed room and
        // window surround must remain untouched even at a noncanonical phase.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cloud.transform = CATransform3DMakeTranslation(region.bounds.width * 0.6, 0, 0)
        CATransaction.commit()
        let baseline = try renderPlate(base)
        assertChanges(try render(layer), versus: baseline,
            confinedTo: CGRect(x: 0.523 * 320, y: 0.071 * 180, width: 0.423 * 320, height: 0.446 * 180))
    }

    func testPlaybackRepeatedLayoutAndStopPreserveCanonicalPixels() throws {
        let layer = AmbientPhotoLayer()
        layer.isGeometryFlipped = true
        layer.bounds = CGRect(origin: .zero, size: size)
        XCTAssertTrue(layer.configure(preset: "window-light", cleanPlate: try plate(), detail: try cutout()))
        let still = try render(layer)
        let base = try XCTUnwrap(layer.sublayers?.first)
        let cloud = try XCTUnwrap(layer.sublayers?.last?.sublayers?.first)
        for _ in 0..<3 {
            layer.setPlaying(true)
            XCTAssertTrue(layer.isPlaying)
            let keys = try XCTUnwrap(cloud.animationKeys())
            XCTAssertEqual(keys.count, 1)
            let first = try XCTUnwrap(cloud.animation(forKey: keys[0]))
            let began = first.beginTime
            layer.setPlaying(true)
            layer.layoutSublayers()
            layer.layoutSublayers()
            XCTAssertTrue(layer.isPlaying)
            XCTAssertEqual(cloud.animation(forKey: keys[0])?.beginTime, began)
            XCTAssertNil(base.animationKeys(), "The clean plate must never move")
            layer.setPlaying(false)
            XCTAssertFalse(layer.isPlaying)
            XCTAssertTrue(allLayers(layer).allSatisfy { $0.animationKeys()?.isEmpty != false })
            assertAligned(try render(layer), still, context: "stop resets exactly the same still")
        }
    }

    func testCloudWrapIsInvisibleAndTravelHasNoReverse() throws {
        let layer = AmbientPhotoLayer(); layer.bounds = CGRect(origin: .zero, size: size)
        XCTAssertTrue(layer.configure(preset: "coastal-sky", cleanPlate: try plate(), detail: try cutout()))
        layer.setPlaying(true)
        defer { layer.setPlaying(false) }
        let cloud = try XCTUnwrap(layer.sublayers?.last?.sublayers?.first)
        let key = try XCTUnwrap(cloud.animationKeys()?.first)
        let group = try XCTUnwrap(cloud.animation(forKey: key) as? CAAnimationGroup)
        let drift = try XCTUnwrap(group.animations?.compactMap { $0 as? CABasicAnimation }.first)
        let fade = try XCTUnwrap(group.animations?.compactMap { $0 as? CAKeyframeAnimation }.first)
        XCTAssertLessThan(try XCTUnwrap(drift.fromValue as? Double), try XCTUnwrap(drift.toValue as? Double))
        XCTAssertFalse(drift.autoreverses)
        XCTAssertEqual((fade.values?.first as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((fade.values?.last as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual(group.duration, drift.duration)
        XCTAssertEqual(group.duration, fade.duration)
    }

    func testResizeUsesNewPhotoCoordinatesAndZeroBoundsStopsMotion() throws {
        let layer = AmbientPhotoLayer(); layer.bounds = CGRect(origin: .zero, size: size)
        XCTAssertTrue(layer.configure(preset: "window-light", cleanPlate: try plate(), detail: try cutout()))
        layer.setPlaying(true)
        layer.bounds.size = CGSize(width: 640, height: 360)
        layer.layoutSublayers()
        XCTAssertTrue(layer.isPlaying)
        let clip = try XCTUnwrap(layer.sublayers?.last)
        XCTAssertEqual(clip.frame.minX, 640 * 0.523, accuracy: 0.001)
        XCTAssertEqual(clip.frame.minY, 360 * 0.071, accuracy: 0.001)
        XCTAssertEqual(clip.frame.width, 640 * 0.423, accuracy: 0.001)
        layer.bounds.size = .zero
        layer.layoutSublayers()
        XCTAssertFalse(layer.isPlaying)
        XCTAssertTrue(allLayers(layer).allSatisfy { $0.animationKeys()?.isEmpty != false })
        layer.bounds.size = size
        layer.layoutSublayers()
        XCTAssertFalse(layer.isPlaying, "Restoring bounds does not override the caller's playback policy")
        layer.setPlaying(true)
        XCTAssertTrue(layer.isPlaying)
        layer.setPlaying(false)
    }

    func testUnknownReconfigurationRemovesOldMotionAndShowsCleanPlate() throws {
        let base = try plate(), detail = try cutout(), layer = AmbientPhotoLayer()
        layer.isGeometryFlipped = true
        layer.bounds = CGRect(origin: .zero, size: size)
        XCTAssertTrue(layer.configure(preset: "campus-breeze", cleanPlate: base, detail: detail))
        layer.setPlaying(true)
        XCTAssertEqual(layer.sublayers?.last?.sublayers?.count, 2)
        XCTAssertFalse(layer.configure(preset: "future-rig", cleanPlate: base, detail: detail))
        layer.setPlaying(true)
        XCTAssertFalse(layer.isPlaying)
        XCTAssertTrue(layer.sublayers?.last?.sublayers?.isEmpty != false)
        assertAligned(try render(layer), try renderPlate(base), context: "unknown retains the supplied original")
        XCTAssertNil(AmbientPhotoLayer.makePoster(preset: "future-rig", cleanPlate: base, detail: detail))
    }

    func testMissingAlphaFailsClosedAndChangingRigDoesNotAccumulateLayers() throws {
        let layer = AmbientPhotoLayer(); layer.bounds = CGRect(origin: .zero, size: size)
        let base = try plate(), opaque = try cutout(alpha: false)
        XCTAssertFalse(layer.configure(preset: "window-light", cleanPlate: base, detail: opaque))
        XCTAssertNil(AmbientPhotoLayer.makePoster(preset: "window-light", cleanPlate: base, detail: opaque))
        for preset in ["campus-breeze", "window-light", "campus-breeze", "coastal-sky"] {
            XCTAssertTrue(layer.configure(preset: preset, cleanPlate: base, detail: try cutout()))
            XCTAssertFalse(layer.isPlaying)
            XCTAssertEqual(layer.sublayers?.count, 2)
            XCTAssertEqual(layer.sublayers?.last?.sublayers?.count, preset == "campus-breeze" ? 2 : 1)
            layer.setPlaying(true)
        }
        layer.setPlaying(false)
    }

    private func plate() throws -> CGImage {
        try image(width: 320, height: 180) { x, y in
            // A nonuniform image makes vertical inversion, accidental panning
            // and opacity changes observable across the entire photograph.
            [UInt8(30 + x / 4), UInt8(35 + y / 2), UInt8(60 + (x + y) / 5), 255]
        }
    }
    private func cutout(alpha: Bool = true) throws -> CGImage {
        try image(width: 100, height: 60, alpha: alpha) { x, y in
            if alpha && (x < 4 || y < 4 || x > 95 || y > 55) { return [0, 0, 0, 0] }
            return x < 40 ? [245, 180, 100, 255] : [100, 230, 180, 255]
        }
    }
    private func image(width: Int, height: Int, alpha: Bool = true,
                       pixel: (Int, Int) -> [UInt8]) throws -> CGImage {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { bytes += pixel(x, y) } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }
    private func render(_ layer: CALayer, flippedHost: Bool = false) throws -> CGImage {
        let host = CALayer(); host.bounds = CGRect(origin: .zero, size: size)
        host.isGeometryFlipped = flippedHost
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = host.bounds; host.addSublayer(layer)
        CATransaction.commit()
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
            bytesPerRow: 320 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if flippedHost { context.translateBy(x: 0, y: 180); context.scaleBy(x: 1, y: -1) }
        host.render(in: context)
        layer.removeFromSuperlayer()
        return try XCTUnwrap(context.makeImage())
    }
    private func renderPlate(_ plate: CGImage) throws -> CGImage {
        let layer = CALayer(); layer.contents = plate
        return try render(layer)
    }
    private func rgba(_ image: CGImage) -> [UInt8] {
        let data = image.dataProvider!.data!
        return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
    }
    private func changedPixels(_ lhs: CGImage, _ rhs: CGImage) -> [CGPoint] {
        let a = rgba(lhs), b = rgba(rhs)
        var changed: [CGPoint] = []
        for y in 0..<180 { for x in 0..<320 {
            let ai = y * lhs.bytesPerRow + x * 4, bi = y * rhs.bytesPerRow + x * 4
            if (0..<4).contains(where: { abs(Int(a[ai + $0]) - Int(b[bi + $0])) > 3 }) {
                changed.append(CGPoint(x: x, y: y))
            }
        } }
        return changed
    }
    private func assertChanges(_ actual: CGImage, versus base: CGImage, confinedTo region: CGRect,
                               file: StaticString = #filePath, line: UInt = #line) {
        let changes = changedPixels(actual, base)
        XCTAssertGreaterThan(changes.count, 50, "The detail must really be rendered", file: file, line: line)
        let expanded = region.insetBy(dx: -1, dy: -1)
        let escaped = changes.filter { !expanded.contains($0) }
        XCTAssertTrue(escaped.isEmpty, "Changed \(escaped.count) pixels outside the authored region; first \(String(describing: escaped.first))", file: file, line: line)
    }
    private func assertAligned(_ actual: CGImage, _ expected: CGImage, context: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let changed = changedPixels(actual, expected)
        // Quartz and Core Animation antialias subpixel image/clip boundaries
        // differently. Allow a narrow edge budget, not displaced image regions.
        XCTAssertLessThan(changed.count, 320 * 180 / 100, "\(context): \(changed.count) misaligned pixels", file: file, line: line)
    }
    private func allLayers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(allLayers)
    }
}
