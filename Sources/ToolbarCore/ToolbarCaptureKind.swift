/// Direct capture choices in the revealed Snap and Snap & Talk row. These are actions,
/// not a remembered setting: the shortcuts retain their existing capture source.
public enum ToolbarCaptureKind: String, CaseIterable, Sendable {
    case region, window, screen

    public var title: String {
        switch self {
        case .region: return "Region"
        case .window: return "Window"
        case .screen: return "Screen"
        }
    }

    public var symbol: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .window: return "macwindow"
        case .screen: return "display"
        }
    }

    /// Active input always keeps its Stop, Pause or Cancel. An unprepared Snap & Talk
    /// session keeps its existing setup door, before capture sources become useful.
    public static func offered(for live: ToolbarLiveState) -> [Self] {
        switch ToolbarNextAction.resolve(live).operation {
        case .start(.snap), .captureNext: return allCases
        default: return []
        }
    }

    public func help(in mode: ToolbarMode) -> String {
        let capture: String
        switch self {
        case .region: capture = "Select a region"
        case .window: capture = "Choose a window"
        case .screen: capture = "Capture the screen under the pointer"
        }
        return capture + (mode == .snapAndTalk ? ", then record narration" : " to mark up or copy")
    }

    public func usesShortcut(in mode: ToolbarMode) -> Bool {
        (mode == .snap && self == .region) || (mode == .snapAndTalk && self == .screen)
    }
}
