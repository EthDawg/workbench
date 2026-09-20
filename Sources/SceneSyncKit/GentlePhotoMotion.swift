import Foundation
import QuartzCore

/// A compositor-only photograph treatment. The authored crop is the still
/// endpoint; foreground layers and exported pixels never inherit the transform.
public enum GentlePhotoMotion {
    public static let maximumScale = 1.035
    public static let halfCycleDuration = 24.0
    public static let animationKey = "workbench.gentlePhotoMotion"

    public static func animation() -> CABasicAnimation {
        let value = CABasicAnimation(keyPath: "transform.scale")
        value.fromValue = 1.0; value.toValue = maximumScale
        value.duration = halfCycleDuration
        value.autoreverses = true; value.repeatCount = .infinity
        value.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // The default compositor refresh policy allows macOS/iOS to coalesce
        // updates. No display link, bitmap loop or keep-awake request is needed.
        return value
    }

    public static func permitted(requested: Bool, visible: Bool, reduceMotion: Bool,
                                 lowPower: Bool, thermalState: ProcessInfo.ThermalState) -> Bool {
        requested && visible && !reduceMotion && !lowPower &&
            thermalState != .serious && thermalState != .critical
    }
}
