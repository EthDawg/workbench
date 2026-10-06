import AVFoundation
import Foundation

/// Meetings' operation-specific refusal, never inferred from displayed wording.
enum MeetingProblem: Error, LocalizedError, Equatable {
    case speech(String), busy(String), closing
    case microphoneDenied, microphoneRestricted, microphoneUnconfirmed
    case appAudioUnavailable(String), appAudioPermission(Int32), appAudioUnknown(Int32)
    case sourceProbe(String), sourceDisappeared, noSource
    case noSamples, recognition(String), save(String), checkpoint(String), unknown(String)

    var errorDescription: String? { message }
    var message: String {
        switch self {
        case .speech(let detail): return "Open Models before starting speech recognition. " + detail
        case .busy(let detail), .appAudioUnavailable(let detail), .sourceProbe(let detail), .checkpoint(let detail), .unknown(let detail): return detail
        case .closing: return "Workbench is closing. Saved work is unchanged."
        case .microphoneDenied: return "Microphone access is off. Open Microphone Settings to include your voice, or explicitly choose app audio only."
        case .microphoneRestricted: return "macOS reports that microphone access is restricted. App audio only can record the selected app, but will not include your microphone."
        case .microphoneUnconfirmed: return "Microphone access was not granted. No recording started. Try again when you are ready."
        case .appAudioPermission(let code): return "Core Audio refused permission to record this app (error \(code)). Review Audio Recording access in Privacy & Security, or explicitly choose microphone only."
        case .appAudioUnknown(let code): return "Workbench could not start this app's audio (Core Audio error \(code)). Refresh the source or explicitly choose microphone only. This error does not establish a permission refusal."
        case .sourceDisappeared: return "The selected audio app is no longer available. Choose its current source or microphone only."
        case .noSource: return "Choose an app, the microphone, or both."
        case .noSamples: return "No readable audio was recorded. Nothing was added to History; the session folder was kept."
        case .recognition(let detail): return "The saved recording could not be transcribed. Its files were kept. " + detail
        case .save(let detail): return "Saving could not finish. Retained files and checkpoints are available for review. " + detail
        }
    }
    var title: String {
        switch self {
        case .speech: return "Speech setup needed"
        case .microphoneDenied: return "Microphone access is off"
        case .microphoneRestricted: return "Microphone access is restricted"
        case .sourceProbe: return "Audio sources could not be checked"
        case .sourceDisappeared, .noSource: return "Choose an audio source"
        case .appAudioUnavailable, .appAudioPermission, .appAudioUnknown: return "App audio unavailable"
        case .closing: return "Workbench is closing"
        default: return "Recording unavailable"
        }
    }
    var opensMicrophoneSettings: Bool { self == .microphoneDenied }
    var opensAudioSettings: Bool { if case .appAudioPermission = self { return true }; return false }
}

struct MeetingHostAdmission: Equatable {
    var recognition = RecognitionSnapshot()
    var captureProblem: MeetingProblem?
    var closing = false
}

/// An observable projection at the existing meeting owner, not a second model
/// readiness authority. Not-determined microphone access is deliberately passive.
struct MeetingAdmission: Equatable {
    var microphone: AVAuthorizationStatus = .notDetermined
    var captureProblem: MeetingProblem?
    var recognitionProblem: MeetingProblem?
    var canStart: Bool { captureProblem == nil }
    var title: String { captureProblem?.title ?? "Ready to record" }
}

enum MeetingAppEnumeration: Equatable {
    case unchecked, available, unavailable(String), failed(String)
}
