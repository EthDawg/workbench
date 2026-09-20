import Foundation

@main struct StateTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            guard value else { fatalError(message) }
        }
        func rejects(_ selection: AudienceSelection) {
            do { try selection.validate(ownPID: 99); check(false, "Unsafe selection accepted") }
            catch { check(true, "Rejected") }
        }
        let a = AudienceSelection.Window(id: 10, ownerPID: 20)
        let b = AudienceSelection.Window(id: 11, ownerPID: 21)
        try AudienceSelection(windows: [a, b], displayIDs: [1], applicationCount: 0, isIndependentWindow: false).validate(ownPID: 99)
        check(true, "Exact multiple-window selection")
        try AudienceSelection(windows: [a], displayIDs: [], applicationCount: 0, isIndependentWindow: true).validate(ownPID: 99)
        check(true, "Exact independent window")
        rejects(.init(windows: [], displayIDs: [1], applicationCount: 0, isIndependentWindow: false))
        rejects(.init(windows: [a], displayIDs: [1], applicationCount: 1, isIndependentWindow: false))
        rejects(.init(windows: [.init(id: 10, ownerPID: 99)], displayIDs: [1], applicationCount: 0, isIndependentWindow: false))
        rejects(.init(windows: [.init(id: 10, ownerPID: nil)], displayIDs: [1], applicationCount: 0, isIndependentWindow: false))
        rejects(.init(windows: [.init(id: 0, ownerPID: 20)], displayIDs: [1], applicationCount: 0, isIndependentWindow: false))
        rejects(.init(windows: [a, a], displayIDs: [1], applicationCount: 0, isIndependentWindow: false))
        rejects(.init(windows: [a, b], displayIDs: [1, 2], applicationCount: 0, isIndependentWindow: false))
        rejects(.init(windows: [a], displayIDs: [], applicationCount: 0, isIndependentWindow: false))
        rejects(.init(windows: [a, b], displayIDs: [], applicationCount: 0, isIndependentWindow: true))
        rejects(.init(windows: (1...9).map { .init(id: UInt32($0), ownerPID: 20) }, displayIDs: [1], applicationCount: 0, isIndependentWindow: false))
        var state = AudienceSessionState()
        check(!state.acceptsFrames(0), "Stopped has no content")
        let choice = state.choose()
        check(!state.acceptsFrames(choice), "Choosing remains blank")
        let first = state.start(selectionGeneration: choice)!
        check(!state.mayRetainIdleFrame(first), "No old image before first complete frame")
        check(state.completeFrame(first), "First frame accepted")
        check(state.mayRetainIdleFrame(first), "Static content is valid")
        let nextChoice = state.choose()
        check(!state.completeFrame(first), "Old stream cannot show during selection")
        check(state.start(selectionGeneration: choice) == nil, "Stale picker callback rejected")
        let second = state.start(selectionGeneration: nextChoice)!
        check(!state.completeFrame(first), "Old stream cannot show after replacement")
        check(state.completeFrame(second), "New stream can show")
        state.stop()
        check(!state.completeFrame(second), "Late frame after stop rejected")
        check(!state.mayRetainIdleFrame(second), "Stopped never retains old picture")
        let cancelledChoice = state.choose(); state.stop()
        check(state.start(selectionGeneration: cancelledChoice) == nil, "Stop invalidates pending chooser")
        print("Audience state: \(checks) checks passed; no capture or desktop access")
    }
}
