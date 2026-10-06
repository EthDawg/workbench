import Foundation
import Darwin

/// A value projected from RecognitionEngine; it is not another readiness owner.
struct RecognitionSnapshot: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, checkingCache, downloading, loading, cancelling }
    enum Admission: Equatable, Sendable { case unavailable, localReady, serverUnverified, serverVerified }
    var sequence: UInt64 = 0
    var configurationRevision: UInt64 = 0
    var configuration = RecognitionConfiguration()
    var operationID: UUID?
    var phase: Phase = .idle
    var admission: Admission = .unavailable
    var failure: RecognitionFailure?
    var detail: String?
    var canTranscribe: Bool { admission != .unavailable && operationID == nil }
    var isPreparing: Bool { operationID != nil }
    var line: String {
        if let detail { return detail }
        if let failure { return failure.message }
        switch admission {
        case .localReady: return configuration.summary
        case .serverUnverified: return "\(configuration.model) · local server configured, not yet verified"
        case .serverVerified: return "\(configuration.model) · local server · last transcription succeeded"
        case .unavailable: return "Download Parakeet to turn speech into text on this Mac."
        }
    }
}

struct RecognitionFailure: Error, LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case missingAssets, invalidCache, network, storage, load, configuration, service }
    let kind: Kind
    let message: String
    var details: String? = nil
    var errorDescription: String? { message + (details.map { " \($0)" } ?? "") }

    static func classify(_ error: Error, acquiring: Bool) -> RecognitionFailure {
        if let failure = error as? RecognitionFailure { return failure }
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            return .init(kind: .network, message: "The download did not finish. Retry when a connection is available.", details: error.localizedDescription)
        }
        if value.domain == NSCocoaErrorDomain || (value.domain == NSPOSIXErrorDomain && [ENOSPC, EACCES, EPERM, EROFS, ENOENT, ENOTDIR, EIO].contains(Int32(value.code))) {
            return .init(kind: .storage, message: "The model files could not be read or saved. Your previous files were kept.", details: error.localizedDescription)
        }
        return .init(kind: .load, message: acquiring ? "The downloaded model could not be prepared. Your previous files were kept." : "The saved model could not be prepared. Retry the saved files or explicitly download a replacement.", details: error.localizedDescription)
    }
}

struct RecognitionBackend: Sendable {
    var transcribe: @Sendable (URL) async throws -> String
    var transcribeLive: @Sendable ([Float]) async throws -> [LiveVoiceWord]
}

struct PreparedRecognition: Sendable {
    var backend: RecognitionBackend
    /// Called only by the current engine operation, with no actor suspension between
    /// admission and adoption. Cached preparations have nothing to adopt or discard.
    var adopt: @Sendable () throws -> Void = {}
    var discard: @Sendable () -> Void = {}
}

struct RecognitionServices: Sendable {
    var prepareCached: @Sendable (_ progress: @escaping RecognitionLocalModels.Progress) async throws -> PreparedRecognition
    var acquire: @Sendable (_ progress: @escaping RecognitionLocalModels.Progress) async throws -> PreparedRecognition
    var send: @Sendable (URLRequest) async throws -> Data
}
