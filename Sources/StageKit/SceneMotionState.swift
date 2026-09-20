import Foundation

/// Playback is temporary view state; it never changes the scene's saved choice.
enum SceneMotionState: Equatable {
    case off, playing, paused, editing, covered, inactive, hidden, sleeping
    case reduceMotion, autoplayDisabled, lowPower, thermal, unavailable

    var description: String {
        switch self {
        case .off: return "Motion is off."
        case .playing: return "Preview playing. Exports stay still."
        case .paused: return "Preview paused."
        case .editing: return "Preview paused while adjusting layout."
        case .covered: return "Preview paused while another sheet is open."
        case .inactive: return "Preview paused while Workbench is inactive."
        case .hidden: return "Preview paused while out of view."
        case .sleeping: return "Preview paused while the display or session is asleep."
        case .reduceMotion: return "Preview paused by Reduce Motion."
        case .autoplayDisabled: return "Preview paused because animated-image autoplay is off."
        case .lowPower: return "Preview paused by Low Power Mode."
        case .thermal: return "Preview paused while this Mac is warm."
        case .unavailable: return "Motion artwork is unavailable. Showing the still picture."
        }
    }

    static func resolve(requested: Bool, suspension: Self?, available: Bool, visible: Bool,
                        active: Bool, sleeping: Bool, reduceMotion: Bool, autoplay: Bool,
                        lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Self {
        guard requested else { return .off }
        if let suspension { return suspension }
        guard available else { return .unavailable }
        if reduceMotion { return .reduceMotion }
        if !autoplay { return .autoplayDisabled }
        if lowPower { return .lowPower }
        if thermal == .serious || thermal == .critical { return .thermal }
        if sleeping { return .sleeping }
        if !active { return .inactive }
        if !visible { return .hidden }
        return .playing
    }
}
