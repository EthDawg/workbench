import Foundation
import StageKit
import ToolbarCore

/// What a panel row does when clicked. Every row with a toolbar mode carries a
/// `ToolbarOperation`; Timer, which is not a mode, has its own two.
enum WorkbenchRowAction: Hashable {
    case operation(ToolbarOperation)
    case startTimer, stopTimer
}

/// One switch from an operation to the owner that already does it, shared by
/// the floating toolbar and the panel. A label and its click can never
/// disagree, because both come from the same operation. Only `start` differs
/// per surface: each door starts a capability its own way.
@MainActor struct WorkbenchOperationDispatch {
    let model: AppModel
    let readback: ReadbackModel
    let stage: StageKitController
    let meetings: MeetingModel
    let start: (ToolbarMode) -> Void

    func perform(_ operation: ToolbarOperation) {
        switch operation {
        case .stopInserting: model.promptInsertion.cancel()
        case .cancelDictationRequest: model.cancelRecording()
        case .stopDictation: model.stopRecording()
        case .finishNarration: readback.stopNarration()
        case .finishDrawing: stage.finishDrawing()
        case .pauseReading, .resumeReading: model.listen()
        case .cancelReading: model.cancelReading()
        case .stopReading: model.stopPlayback()
        case .hidePersona, .pauseOverlays, .resumeOverlays: stage.togglePersona()
        case .captureNext: start(.snapAndTalk)
        case .stopMeetingTranscription: Task { await meetings.stop() }
        case .endPresentation: stage.endDeviceScene()
        case .wait: break
        case .start(let mode):
            model.toolbarMode = mode
            start(mode)
        }
    }
}
