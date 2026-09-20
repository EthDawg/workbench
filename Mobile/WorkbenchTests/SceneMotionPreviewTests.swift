import XCTest
import UIKit
@testable import WorkbenchMobile

@MainActor final class SceneMotionPreviewTests: XCTestCase {
    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
    }
    func testOnlyPhotoLayerAnimatesAndStoppingRestoresAuthoredCrop() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let view = SceneMotionPhotoView(frame: window.bounds)
        let foreground = CALayer(); foreground.frame = CGRect(x: 20, y: 30, width: 40, height: 50)
        window.layer.addSublayer(foreground); window.addSubview(view)
        view.configure(image: image(), x: 0.25, y: 0.8, zoom: 1.5, playing: true)
        let authored = CGRect(x: -40, y: -36, width: 480, height: 360)
        XCTAssertEqual(view.photoLayer.frame.minX, authored.minX, accuracy: 0.0001)
        XCTAssertEqual(view.photoLayer.frame.minY, authored.minY, accuracy: 0.0001)
        XCTAssertEqual(view.photoLayer.frame.size, authored.size)
        let animation = try XCTUnwrap(view.photoLayer.animation(forKey: GentlePhotoMotion.animationKey) as? CABasicAnimation)
        XCTAssertEqual(animation.keyPath, "transform.scale")
        XCTAssertNil(foreground.animationKeys()); XCTAssertEqual(foreground.frame, CGRect(x: 20, y: 30, width: 40, height: 50))
        XCTAssertNil(view.layer.animationKeys())
        view.configure(image: image(), x: 0.25, y: 0.8, zoom: 1.5, playing: false)
        XCTAssertNil(view.photoLayer.animationKeys()); XCTAssertTrue(CATransform3DIsIdentity(view.photoLayer.transform))
        XCTAssertEqual(view.photoLayer.frame.minY, authored.minY, accuracy: 0.0001)
        XCTAssertEqual(view.photoLayer.frame.size, authored.size)
        view.removeFromSuperview()
    }
    func testDetachAndDismantleRemoveAnimationButReattachCanResumeEligiblePreview() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let view = SceneMotionPhotoView(frame: window.bounds)
        view.configure(image: image(), x: 0.5, y: 0.5, zoom: 1, playing: true)
        XCTAssertNil(view.photoLayer.animationKeys())
        window.addSubview(view); XCTAssertNotNil(view.photoLayer.animation(forKey: GentlePhotoMotion.animationKey))
        view.removeFromSuperview(); XCTAssertNil(view.photoLayer.animationKeys())
        window.addSubview(view); XCTAssertNotNil(view.photoLayer.animation(forKey: GentlePhotoMotion.animationKey))
        SceneMotionPreview.dismantleUIView(view, coordinator: ())
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertNil(view.photoLayer.animationKeys())
        view.removeFromSuperview()
    }
    func testCropMathUsesUnflippedSceneCoordinatesAcrossPortraitAndResize() {
        let bottom = SceneMotionPhotoView.authoredFrame(imageSize: CGSize(width: 100, height: 200), canvas: CGSize(width: 300, height: 200), x: 0, y: 0, zoom: 1)
        XCTAssertEqual(bottom, CGRect(x: 0, y: -400, width: 300, height: 600))
        let top = SceneMotionPhotoView.authoredFrame(imageSize: CGSize(width: 100, height: 200), canvas: CGSize(width: 300, height: 200), x: 1, y: 1, zoom: 1)
        XCTAssertEqual(top, CGRect(x: 0, y: 0, width: 300, height: 600))
        let empty = SceneMotionPhotoView.authoredFrame(imageSize: .zero, canvas: CGSize(width: 300, height: 200), x: 0.5, y: 0.5, zoom: 1)
        XCTAssertEqual(empty, .zero)
    }
    func testLifecycleSuspensionsKeepAuthoredRequestAndResumeOnlyWhenAllEligible() {
        var state = SceneMotionPlayback(requested: true, visible: true, active: true)
        XCTAssertTrue(state.isPlaying)
        state.active = false; XCTAssertFalse(state.isPlaying); state.active = true
        state.visible = false; XCTAssertFalse(state.isPlaying); state.visible = true
        state.editingCrop = true; XCTAssertFalse(state.isPlaying); state.editingCrop = false
        state.reduceMotion = true; XCTAssertFalse(state.isPlaying); state.reduceMotion = false
        state.animatedImagesEnabled = false; XCTAssertFalse(state.isPlaying); XCTAssertTrue(state.explanation.contains("Accessibility")); state.animatedImagesEnabled = true
        state.lowPower = true; XCTAssertFalse(state.isPlaying); state.lowPower = false
        state.thermalState = .serious; XCTAssertFalse(state.isPlaying)
        state.thermalState = .critical; XCTAssertFalse(state.isPlaying)
        state.thermalState = .fair; XCTAssertTrue(state.isPlaying)
        state.paused = true; state.active = false; state.active = true
        XCTAssertFalse(state.isPlaying); XCTAssertTrue(state.requested)
        state.paused = false; XCTAssertTrue(state.isPlaying)
        state.requested = false; XCTAssertFalse(state.isPlaying)
    }
    func testAmbientPreviewUsesSameCropAndReturnsToCompletePosterWhenPaused() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let view = SceneMotionPhotoView(frame: window.bounds)
        let foreground = CALayer(); foreground.frame = CGRect(x: 30, y: 20, width: 80, height: 100)
        window.addSubview(view); window.layer.addSublayer(foreground)
        let poster = image(), rig = SceneMotionImages(preset: "campus-breeze", cleanPlate: image(), detail: image())
        view.configure(image: poster, x: 0.25, y: 0.8, zoom: 1.5, playing: true, ambience: rig)
        XCTAssertTrue(view.ambientLayer.isPlaying); XCTAssertFalse(view.ambientLayer.isHidden)
        view.ambientLayer.setNeedsLayout(); view.ambientLayer.layoutIfNeeded()
        XCTAssertTrue(view.ambientLayer.isPlaying)
        XCTAssertTrue(view.photoLayer.isHidden)
        XCTAssertEqual(view.ambientLayer.frame, view.photoLayer.frame)
        XCTAssertNil(view.photoLayer.animation(forKey: GentlePhotoMotion.animationKey))
        XCTAssertNil(view.layer.animationKeys()); XCTAssertNil(foreground.animationKeys())
        let authored = view.photoLayer.frame
        view.configure(image: poster, x: 0.25, y: 0.8, zoom: 1.5, playing: false, ambience: rig)
        XCTAssertFalse(view.ambientLayer.isPlaying); XCTAssertTrue(view.ambientLayer.isHidden)
        XCTAssertFalse(view.photoLayer.isHidden); XCTAssertEqual(view.photoLayer.frame, authored)
        XCTAssertTrue(CATransform3DIsIdentity(view.photoLayer.transform))
        view.configure(image: poster, x: 0.25, y: 0.8, zoom: 1.5, playing: true, ambience: rig)
        XCTAssertTrue(view.ambientLayer.isPlaying)
        view.removeFromSuperview(); XCTAssertFalse(view.ambientLayer.isPlaying)
        window.addSubview(view); XCTAssertTrue(view.ambientLayer.isPlaying)
        SceneMotionPreview.dismantleUIView(view, coordinator: ())
        XCTAssertFalse(view.ambientLayer.isPlaying); XCTAssertFalse(view.photoLayer.isHidden)
        view.removeFromSuperview()
    }
    func testReplacingRigCannotLeaveItsAnimationOnAnOrdinaryPhoto() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let view = SceneMotionPhotoView(frame: window.bounds); window.addSubview(view)
        let poster = image(), rig = SceneMotionImages(preset: "coastal-sky", cleanPlate: image(), detail: image())
        view.configure(image: poster, x: 0.5, y: 0.5, zoom: 1, playing: true, ambience: rig)
        XCTAssertTrue(view.ambientLayer.isPlaying)
        view.configure(image: poster, x: 0.5, y: 0.5, zoom: 1, playing: false)
        XCTAssertFalse(view.ambientLayer.isPlaying); XCTAssertTrue(view.ambientLayer.isHidden)
        XCTAssertFalse(view.photoLayer.isHidden); XCTAssertNil(view.photoLayer.animationKeys())
        let invalid = SceneMotionImages(preset: "unknown-future-effect", cleanPlate: image(), detail: image())
        view.configure(image: poster, x: 0.5, y: 0.5, zoom: 1, playing: true, ambience: invalid)
        XCTAssertFalse(view.ambientLayer.isPlaying); XCTAssertFalse(view.photoLayer.isHidden)
        XCTAssertNil(view.photoLayer.animationKeys())
        view.removeFromSuperview()
    }
    func testUIKitAmbientCompositionMatchesCanonicalPosterOrientation() throws {
        let size = CGSize(width: 320, height: 180)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let clean = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.yellow.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 60))
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 60, width: 100, height: 120))
        }
        let detail = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 30), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 15))
            UIColor.white.setFill(); context.fill(CGRect(x: 20, y: 15, width: 40, height: 15))
        }
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let view = SceneMotionPhotoView(frame: window.bounds); window.addSubview(view)
        for preset in ["window-light", "campus-breeze", "coastal-sky"] {
            let poster = try XCTUnwrap(AmbientPhotoLayer.makePoster(preset: preset, cleanPlate: XCTUnwrap(clean.cgImage), detail: XCTUnwrap(detail.cgImage)))
            view.configure(image: UIImage(cgImage: poster), x: 0.5, y: 0.5, zoom: 1, playing: true,
                ambience: SceneMotionImages(preset: preset, cleanPlate: clean, detail: detail))
            let actual = UIGraphicsImageRenderer(size: size, format: format).image { context in
                view.layer.render(in: context.cgContext)
            }
            let expectedPixels = try pixels(poster), actualPixels = try pixels(XCTUnwrap(actual.cgImage))
            let error = zip(expectedPixels, actualPixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            XCTAssertLessThan(Double(error) / Double(expectedPixels.count), 1.5, "Native UIKit composition differs from its still poster for \(preset)")
        }
        view.removeFromSuperview()
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
