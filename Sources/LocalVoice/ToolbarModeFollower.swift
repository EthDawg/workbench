import Combine
import Foundation
import StageKit
import ToolbarCore

/// The toolbar's mode follows every door. Whenever a capability goes from not
/// live to live, whichever door started it (a key, a panel row, a page button,
/// an app menu, the toolbar itself), that capability becomes the mode. Ending
/// changes nothing. The explicit sets in the start closures remain; this
/// catches the doors they do not cover without editing each one.
@MainActor final class ToolbarModeFollower {
    /// When several start in one tick, the one you are most likely looking at wins.
    static let priority: [ToolbarMode] = [.present, .persona, .dictate, .read, .snapAndTalk, .draw, .snap]

    private var observations = Set<AnyCancellable>()
    private var live: Set<ToolbarMode>
    private let read: () -> Set<ToolbarMode>
    private let select: (ToolbarMode) -> Void

    init(model: AppModel, readback: ReadbackModel, stage: StageKitController, meetings: MeetingModel, snap: SnapModel,
         select: @escaping (ToolbarMode) -> Void) {
        self.select = select
        read = { [weak model, weak readback, weak stage, weak meetings, weak snap] in
            guard let model, let readback, let stage, let meetings, let snap else { return [] }
            return Self.liveModes(
                dictating: model.phase != .idle || meetings.isRecording,
                reading: model.rendering || model.playing || model.paused,
                narrating: readback.isRecording || readback.isCapturing,
                drawing: stage.isDrawing, presenting: stage.isPresenting,
                persona: stage.hasActivePersona, snapping: snap.isCapturing)
        }
        // The launch snapshot is not a start: a restored Snap & Talk session or
        // a persona left showing does not move the mode by itself.
        live = read()
        let publishers: [AnyPublisher<Void, Never>] = [
            model.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            readback.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            stage.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            meetings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            snap.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        ]
        // objectWillChange fires before the value lands; read on the next turn.
        Publishers.MergeMany(publishers).receive(on: RunLoop.main)
            .sink { [weak self] in self?.reconcile() }
            .store(in: &observations)
    }

    private func reconcile() {
        let current = read()
        defer { live = current }
        if let mode = Self.modeToSelect(previous: live, current: current) { select(mode) }
    }

    static func liveModes(dictating: Bool, reading: Bool, narrating: Bool, drawing: Bool,
                          presenting: Bool, persona: Bool, snapping: Bool) -> Set<ToolbarMode> {
        var modes = Set<ToolbarMode>()
        if dictating { modes.insert(.dictate) }
        if reading { modes.insert(.read) }
        if narrating { modes.insert(.snapAndTalk) }
        if drawing { modes.insert(.draw) }
        if presenting { modes.insert(.present) }
        if persona { modes.insert(.persona) }
        if snapping { modes.insert(.snap) }
        return modes
    }

    /// Pure: the mode to select given what just started, or nil when nothing did.
    static func modeToSelect(previous: Set<ToolbarMode>, current: Set<ToolbarMode>) -> ToolbarMode? {
        let started = current.subtracting(previous)
        return priority.first { started.contains($0) }
    }
}
