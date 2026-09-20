import SwiftUI
import UIKit
import QuartzCore

/// Transient editor playback, separate from the scene's authored preference.
struct SceneMotionPlayback {
    var requested = false
    var paused = false
    var editingCrop = false
    var visible = false
    var active = false
    var reduceMotion = false
    var animatedImagesEnabled = true
    var lowPower = false
    var thermalState = ProcessInfo.ThermalState.nominal

    var isPlaying: Bool {
        GentlePhotoMotion.permitted(requested: requested && !paused && !editingCrop && animatedImagesEnabled,
            visible: visible && active, reduceMotion: reduceMotion,
            lowPower: lowPower, thermalState: thermalState)
    }
    var explanation: String {
        if editingCrop { return "Preview stays still while you adjust the crop." }
        if paused { return "Preview paused. The saved scene still uses gentle motion." }
        if reduceMotion { return "Preview stays still because Reduce Motion is on." }
        if !animatedImagesEnabled { return "Preview stays still because animated images are off in Accessibility settings." }
        if lowPower { return "Preview stays still in Low Power Mode." }
        if thermalState == .serious || thermalState == .critical { return "Preview stays still while your device cools down." }
        return "Only the backdrop moves. The device, logo and persona stay still."
    }
}

struct SceneMotionImages {
    let preset: String
    let cleanPlate: UIImage
    let detail: UIImage
}

/// Core Animation owns either the authored ambience or the simple photo motion.
/// Sibling scene layers never enter this view. A stopped preview uses its poster.
struct SceneMotionPreview: UIViewRepresentable {
    let image: UIImage
    let x: Double
    let y: Double
    let zoom: Double
    let playing: Bool
    var ambience: SceneMotionImages? = nil

    func makeUIView(context: Context) -> SceneMotionPhotoView { SceneMotionPhotoView() }
    func updateUIView(_ view: SceneMotionPhotoView, context: Context) {
        view.configure(image: image, x: x, y: y, zoom: zoom, playing: playing, ambience: ambience)
    }
    static func dismantleUIView(_ view: SceneMotionPhotoView, coordinator: ()) { view.stop() }
}

@MainActor final class SceneMotionPhotoView: UIView {
    let photoLayer = CALayer()
    let ambientLayer = AmbientPhotoLayer()
    private var imageSize = CGSize.zero
    private var cropX = 0.5, cropY = 0.5, zoom = 1.0
    private var playing = false
    private var hasAmbience = false
    private var usesAmbience = false
    private var configuredRig: SceneMotionImages?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true; isUserInteractionEnabled = false; accessibilityElementsHidden = true
        photoLayer.contentsGravity = .resize
        layer.addSublayer(photoLayer)
        layer.addSublayer(ambientLayer)
        ambientLayer.isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    func configure(image: UIImage, x: Double, y: Double, zoom: Double, playing: Bool, ambience: SceneMotionImages? = nil) {
        imageSize = image.size; cropX = x; cropY = y; self.zoom = zoom
        self.playing = playing
        usesAmbience = ambience != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        photoLayer.contents = image.cgImage
        CATransaction.commit()
        if let ambience, let clean = ambience.cleanPlate.cgImage, let detail = ambience.detail.cgImage {
            if configuredRig?.preset != ambience.preset || configuredRig?.cleanPlate !== ambience.cleanPlate || configuredRig?.detail !== ambience.detail {
                hasAmbience = ambientLayer.configure(preset: ambience.preset, cleanPlate: clean, detail: detail)
                configuredRig = ambience
            }
        } else {
            hasAmbience = false; configuredRig = nil; ambientLayer.setPlaying(false)
        }
        setNeedsLayout(); layoutIfNeeded(); updateAnimation()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        photoLayer.frame = Self.authoredFrame(imageSize: imageSize, canvas: bounds.size, x: cropX, y: cropY, zoom: zoom)
        ambientLayer.frame = photoLayer.frame
        ambientLayer.layoutIfNeeded()
        CATransaction.commit()
        updateAnimation()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); updateAnimation() }

    static func authoredFrame(imageSize: CGSize, canvas: CGSize, x: Double, y: Double, zoom: Double) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = max(canvas.width / imageSize.width, canvas.height / imageSize.height) * zoom
        let width = imageSize.width * scale, height = imageSize.height * scale
        return CGRect(x: (canvas.width - width) * x, y: (canvas.height - height) * (1 - y), width: width, height: height)
    }
    private func updateAnimation() {
        guard playing, window != nil, !isHidden, bounds.width > 0, bounds.height > 0,
              photoLayer.contents != nil, !usesAmbience || hasAmbience else {
            removeMotion(); return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ambientLayer.isHidden = !hasAmbience; photoLayer.isHidden = hasAmbience
        CATransaction.commit()
        if hasAmbience {
            photoLayer.removeAnimation(forKey: GentlePhotoMotion.animationKey)
            ambientLayer.setPlaying(true)
            return
        }
        if photoLayer.animation(forKey: GentlePhotoMotion.animationKey) == nil {
            photoLayer.add(GentlePhotoMotion.animation(), forKey: GentlePhotoMotion.animationKey)
        }
    }
    func stop() { playing = false; removeMotion() }
    private func removeMotion() {
        ambientLayer.setPlaying(false)
        photoLayer.removeAnimation(forKey: GentlePhotoMotion.animationKey)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        photoLayer.isHidden = false; ambientLayer.isHidden = true
        photoLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}
