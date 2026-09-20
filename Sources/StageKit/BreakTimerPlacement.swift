import AppKit

struct BreakTimerDisplay: Equatable {
    let id: String
    let visibleFrame: NSRect
}

struct BreakTimerDestination: Equatable {
    let display: BreakTimerDisplay
    let frame: NSRect
}

/// Placement is independent of countdown state and timer appearance. A named
/// anchor or normalized free position can be recovered on a resized display.
struct BreakTimerPlacement: Codable, Equatable {
    var version = 1
    var position = PresentationControlPlacement(anchor: nil, x: 0.5, y: 0.5)
    var screenID: String?

    func validated() throws -> Self {
        guard version == 1 else { throw CocoaError(.coderReadCorrupt) }
        var copy = self
        copy.position = try position.validated()
        if let screenID, screenID.isEmpty || screenID.count > 200 { throw CocoaError(.coderReadCorrupt) }
        return copy
    }

    func destination(size: NSSize, displays: [BreakTimerDisplay], fallbackID: String?) -> BreakTimerDestination? {
        guard let display = displays.first(where: { $0.id == screenID })
                ?? displays.first(where: { $0.id == fallbackID })
                ?? displays.first else { return nil }
        return BreakTimerDestination(display: display, frame: position.frame(size: size, in: display.visibleFrame))
    }

    mutating func move(to frame: NSRect, on display: BreakTimerDisplay) {
        let anchor = FloatingControlGeometry.nearestAnchor(to: frame, in: display.visibleFrame)
        position.move(to: frame, in: display.visibleFrame, anchor: anchor)
        screenID = display.id
    }

    mutating func setAnchor(_ anchor: FloatingControlAnchor, on display: BreakTimerDisplay) {
        position.anchor = anchor
        screenID = display.id
    }
}

final class BreakTimerPlacementStore {
    private(set) var value = BreakTimerPlacement()
    private(set) var notice: String?
    private(set) var storageBlocked = false
    private let url: URL
    private var archiveData: Data?

    init(url: URL) {
        self.url = url
        do {
            archiveData = try PersonaStorage.read(url)
            if let archiveData { value = try JSONDecoder().decode(BreakTimerPlacement.self, from: archiveData).validated() }
        } catch {
            storageBlocked = true
            notice = "The previous timer position is preserved. This session uses a temporary position."
        }
    }

    func move(to frame: NSRect, on display: BreakTimerDisplay) {
        value.move(to: frame, on: display)
        save()
    }

    func setAnchor(_ anchor: FloatingControlAnchor, on display: BreakTimerDisplay) {
        value.setAnchor(anchor, on: display)
        save()
    }

    private func save() {
        guard !storageBlocked else { return }
        do { archiveData = try PersonaStorage.write(try value.validated(), to: url, expected: archiveData) }
        catch {
            storageBlocked = true
            notice = "The timer position could not be saved. Its previous file is unchanged; this session uses the new position temporarily."
        }
    }
}
