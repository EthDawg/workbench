import CoreGraphics
import Foundation
import QuartzCore

/// A fixed photograph with a few authored, independently moving details.
///
/// All rig rectangles use normalized PHOTO coordinates: (0, 0) is top-left,
/// x increases right and y increases down. Bounds describe the entire photo;
/// the caller owns aspect-preserving sizing/crop, visibility and energy policy.
/// In an ordinary unflipped AppKit host this layer flips its child geometry.
/// UIKit already supplies top-left geometry, so its default is retained there.
/// Do not flip CGImage inputs or apply a second vertical transform in the host.
/// An unusual flipped AppKit host must set `isGeometryFlipped = false`.
@MainActor
public final class AmbientPhotoLayer: CALayer {
    public private(set) var isPlaying = false

    private let plateLayer = CALayer()
    private let detailContainer = CALayer()
    private var rig: Rig?
    private var detailImage: CGImage?
    private var movingLayers: [CALayer] = []
    private var isReplica = false
    private var animatedSize: CGSize?
    private static let animationKey = "workbench.ambientDetail"

    public override init() {
        super.init()
        MainActor.assumeIsolated { prepareLayers() }
    }

    public override init(layer: Any) {
        super.init(layer: layer)
        // Core Animation copies the existing layer tree for presentation.
        // Its copy must not allocate or reconfigure another authored tree.
        isReplica = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        MainActor.assumeIsolated { prepareLayers() }
    }

    private func prepareLayers() {
        #if os(macOS)
        isGeometryFlipped = true
        #endif
        masksToBounds = true
        plateLayer.contentsGravity = .resize
        plateLayer.magnificationFilter = .linear
        plateLayer.minificationFilter = .trilinear
        addSublayer(plateLayer)
        detailContainer.masksToBounds = true
        addSublayer(detailContainer)
    }

    /// Replaces the authored snapshot and stops previous motion. Unknown rigs
    /// or a detail without an alpha channel show only the supplied clean plate.
    /// No input is changed, written to disk, or rendered once per frame.
    @discardableResult
    public func configure(preset: String, cleanPlate: CGImage, detail: CGImage) -> Bool {
        setPlaying(false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        movingLayers.forEach { $0.removeFromSuperlayer() }
        movingLayers.removeAll()
        plateLayer.contents = cleanPlate
        rig = Rig(preset: preset)
        detailImage = Self.hasAlpha(detail) ? detail : nil
        if rig != nil, detailImage != nil {
            for _ in 0..<(rig?.detailCount ?? 0) {
                let pivot = CALayer()
                let image = CALayer()
                image.contents = detail
                image.contentsGravity = .resize
                image.magnificationFilter = .linear
                image.minificationFilter = .trilinear
                pivot.addSublayer(image)
                detailContainer.addSublayer(pivot)
                movingLayers.append(pivot)
            }
        } else {
            rig = nil
        }
        layoutAuthoredLayers()
        CATransaction.commit()
        return rig != nil
    }

    /// Pausing returns to the canonical still phase. The same still is used by
    /// makePoster, including during repeated play/stop or a resized photo crop.
    public func setPlaying(_ requested: Bool) {
        let allowed = requested && rig != nil && detailImage != nil && validBounds
        guard allowed != isPlaying else { return }
        isPlaying = allowed
        if allowed { installAnimations() }
        else {
            movingLayers.forEach { $0.removeAnimation(forKey: Self.animationKey) }
            animatedSize = nil
        }
    }

    public override func layoutSublayers() {
        super.layoutSublayers()
        // CALayer's legacy callback is not actor annotated. The native host
        // owns this layer on the main actor; assert that boundary synchronously.
        let reference = LayoutReference(layer: self)
        MainActor.assumeIsolated { reference.layer.layoutOnMainActor() }
    }

    private struct LayoutReference: @unchecked Sendable {
        let layer: AmbientPhotoLayer
    }

    private func layoutOnMainActor() {
        guard !isReplica else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutAuthoredLayers()
        CATransaction.commit()
        if isPlaying {
            if !validBounds { setPlaying(false) }
            else if animatedSize != bounds.size { installAnimations() }
        }
    }

    private var validBounds: Bool {
        bounds.width.isFinite && bounds.height.isFinite &&
        bounds.width > 0 && bounds.height > 0
    }

    private func layoutAuthoredLayers() {
        guard validBounds else {
            plateLayer.frame = .zero
            detailContainer.frame = .zero
            return
        }
        plateLayer.frame = bounds
        guard let rig, let detailImage else {
            detailContainer.frame = .zero
            return
        }
        let size = bounds.size
        let region = rig.region(in: size).offsetBy(dx: bounds.minX, dy: bounds.minY)
        detailContainer.frame = region
        let items = rig.details(in: region.size, image: detailImage)
        for (layer, item) in zip(movingLayers, items) {
            // The rotation pivot stays near the branch's attachment point.
            layer.anchorPoint = item.anchor
            layer.bounds = CGRect(origin: .zero, size: item.rect.size)
            layer.position = CGPoint(x: item.rect.minX + item.rect.width * item.anchor.x,
                                     y: item.rect.minY + item.rect.height * item.anchor.y)
            layer.opacity = item.opacity
            if let image = layer.sublayers?.first {
                image.frame = layer.bounds
                image.transform = CATransform3DMakeScale(item.mirrored ? -1 : 1, 1, 1)
            }
        }
    }

    private func installAnimations() {
        guard let rig, let detailImage, validBounds else { return }
        animatedSize = bounds.size
        let size = rig.region(in: bounds.size).size
        let items = rig.details(in: size, image: detailImage)
        for (layer, item) in zip(movingLayers, items) {
            let animation: CAAnimation
            switch item.motion {
            case .cloud(let travel, let duration, let phase):
                // Drift only in one direction. Both sides of the wrap are
                // invisible; no cloud reverses or jumps while visible.
                let drift = CABasicAnimation(keyPath: "transform.translation.x")
                drift.fromValue = -travel * phase
                drift.toValue = travel * (1 - phase)
                drift.duration = duration
                drift.timingFunction = CAMediaTimingFunction(name: .linear)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, item.opacity, item.opacity, 0, 0]
                fade.keyTimes = [0, 0.18, 0.72, 0.98, 1]
                fade.duration = duration
                fade.timingFunction = CAMediaTimingFunction(name: .linear)
                let group = CAAnimationGroup()
                group.animations = [drift, fade]
                group.duration = duration
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .linear)
                group.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - duration * phase
                animation = group
            case .branch(let radians, let duration):
                let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                sway.values = [0, radians, -radians, 0]
                sway.keyTimes = [0, 0.25, 0.75, 1]
                sway.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                sway.duration = duration
                sway.repeatCount = .infinity
                animation = sway
            }
            layer.add(animation, forKey: Self.animationKey)
        }
    }

    /// Renders the exact canonical static layout at the clean plate's pixel
    /// dimensions. Core Graphics uses bottom-left coordinates here; the same
    /// top-left rig rectangles are converted once at this output boundary.
    /// Returns nil for an unknown rig, unsuitable detail, or allocation failure.
    public static func makePoster(preset: String, cleanPlate: CGImage, detail: CGImage) -> CGImage? {
        guard let rig = Rig(preset: preset), hasAlpha(detail),
              let context = CGContext(data: nil, width: cleanPlate.width, height: cleanPlate.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGSize(width: cleanPlate.width, height: cleanPlate.height)
        context.interpolationQuality = .high
        context.draw(cleanPlate, in: CGRect(origin: .zero, size: size))
        let region = rig.region(in: size)
        context.saveGState()
        context.clip(to: bottomLeft(region, height: size.height))
        for item in rig.details(in: region.size, image: detail) {
            let rect = bottomLeft(item.rect.offsetBy(dx: region.minX, dy: region.minY), height: size.height)
            context.saveGState()
            context.setAlpha(CGFloat(item.opacity))
            if item.mirrored {
                context.translateBy(x: rect.midX, y: rect.midY)
                context.scaleBy(x: -1, y: 1)
                context.draw(detail, in: CGRect(x: -rect.width / 2, y: -rect.height / 2,
                                               width: rect.width, height: rect.height))
            } else { context.draw(detail, in: rect) }
            context.restoreGState()
        }
        context.restoreGState()
        return context.makeImage()
    }

    private static func bottomLeft(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        [.alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
    }

    private enum Rig {
        case window, campus, coast
        init?(preset: String) {
            switch preset {
            case "window-light": self = .window
            case "campus-breeze": self = .campus
            case "coastal-sky": self = .coast
            default: return nil
            }
        }
        var detailCount: Int { self == .campus ? 2 : 1 }
        func region(in size: CGSize) -> CGRect {
            let unit: CGRect
            switch self {
            case .window: unit = CGRect(x: 0.523, y: 0.071, width: 0.423, height: 0.446)
            case .coast: unit = CGRect(x: 0, y: 0, width: 1, height: 0.32)
            case .campus: unit = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
            return CGRect(x: unit.minX * size.width, y: unit.minY * size.height,
                          width: unit.width * size.width, height: unit.height * size.height)
        }
        func details(in size: CGSize, image: CGImage) -> [Detail] {
            switch self {
            case .window, .coast:
                let phase = 0.33
                let travel = size.width * 0.12
                let maximumWidth = size.width * (self == .window ? 0.92 : 0.72)
                let fit = min(maximumWidth / CGFloat(image.width), size.height * 0.84 / CGFloat(image.height))
                let width = CGFloat(image.width) * fit
                let height = CGFloat(image.height) * fit
                let rect = CGRect(x: size.width * 0.02 + travel * phase,
                                  y: size.height * 0.06, width: width, height: height)
                return [Detail(rect: rect, anchor: CGPoint(x: 0.5, y: 0.5), mirrored: false,
                               opacity: self == .window ? 0.24 : 0.30,
                               motion: .cloud(travel: travel, duration: self == .window ? 64 : 72, phase: phase))]
            case .campus:
                func branch(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                            mirrored: Bool, degrees: Double, duration: Double) -> Detail {
                    let box = CGSize(width: size.width * width, height: size.height * height)
                    let fit = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
                    let drawn = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
                    let left = mirrored ? size.width * x + box.width - drawn.width : size.width * x
                    return Detail(rect: CGRect(x: left, y: size.height * y, width: drawn.width, height: drawn.height),
                                  anchor: CGPoint(x: mirrored ? 0.95 : 0.05, y: 0.05),
                                  mirrored: mirrored, opacity: 1,
                                  motion: .branch(radians: degrees * .pi / 180, duration: duration))
                }
                return [branch(x: -0.015, y: -0.02, width: 0.38, height: 0.33, mirrored: false, degrees: 0.65, duration: 13),
                        branch(x: 0.765, y: -0.012, width: 0.25, height: 0.24, mirrored: true, degrees: 0.5, duration: 17)]
            }
        }
    }

    private struct Detail {
        let rect: CGRect
        let anchor: CGPoint
        let mirrored: Bool
        let opacity: Float
        let motion: Motion
    }
    private enum Motion {
        case cloud(travel: CGFloat, duration: Double, phase: Double)
        case branch(radians: Double, duration: Double)
    }
}
