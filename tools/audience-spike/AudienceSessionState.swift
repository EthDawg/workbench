import Foundation

/// No AppKit or capture dependencies: admission and late-frame rules are testable
/// without requesting access to anybody's desktop.
struct AudienceSelection {
    struct Window {
        let id: UInt32
        let ownerPID: Int32?
    }
    let windows: [Window]
    let displayIDs: [UInt32]
    let applicationCount: Int
    let isIndependentWindow: Bool

    func validate(ownPID: Int32) throws {
        guard applicationCount == 0, !windows.isEmpty else { throw AudienceSelectionError.broadScope }
        guard windows.count <= 8, Set(windows.map(\.id)).count == windows.count else {
            throw AudienceSelectionError.windowCount
        }
        guard windows.allSatisfy({ $0.id > 0 && ($0.ownerPID ?? 0) > 0 && $0.ownerPID != ownPID }) else {
            throw AudienceSelectionError.privateWindow
        }
        if isIndependentWindow {
            guard windows.count == 1, displayIDs.count <= 1 else { throw AudienceSelectionError.display }
        } else {
            guard displayIDs.count == 1, displayIDs[0] != 0 else { throw AudienceSelectionError.display }
        }
    }
}

enum AudienceSelectionError: LocalizedError {
    case broadScope, windowCount, privateWindow, display
    var errorDescription: String? {
        switch self {
        case .broadScope: return "Choose specific windows. This spike rejects application and full-display capture."
        case .windowCount: return "Choose between one and eight distinct demo windows."
        case .privateWindow: return "The selection includes this spike's private/output window or an unidentifiable owner. Choose external demo windows only."
        case .display: return "Choose demo windows on one display. A single independent window is also supported."
        }
    }
}

struct AudienceSessionState {
    enum Phase: Equatable { case stopped, choosing, starting, live }
    private(set) var generation: UInt64 = 0
    private(set) var phase = Phase.stopped

    @discardableResult mutating func choose() -> UInt64 {
        generation &+= 1; phase = .choosing; return generation
    }
    mutating func start(selectionGeneration: UInt64) -> UInt64? {
        guard generation == selectionGeneration, phase == .choosing else { return nil }
        generation &+= 1; phase = .starting; return generation
    }
    func acceptsFrames(_ token: UInt64) -> Bool {
        token == generation && (phase == .starting || phase == .live)
    }
    mutating func completeFrame(_ token: UInt64) -> Bool {
        guard acceptsFrames(token) else { return false }
        phase = .live; return true
    }
    func mayRetainIdleFrame(_ token: UInt64) -> Bool { token == generation && phase == .live }
    mutating func stop() { generation &+= 1; phase = .stopped }
}
