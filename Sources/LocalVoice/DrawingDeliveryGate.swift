import Foundation

/// A completed transcript waits for input to return from the annotation canvas.
/// The caller still revalidates its original target through TextDelivery.
@MainActor
final class DrawingDeliveryGate {
    enum Resolution { case resume, copy, cancelled }
    private var continuation: CheckedContinuation<Resolution, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async throws -> Resolution {
        let resolution = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                precondition(self.continuation == nil, "Only one microphone delivery may wait")
                self.continuation = continuation
                if Task.isCancelled { resolve(.cancelled) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(.cancelled) }
        }
        try Task.checkCancellation()
        if resolution == .cancelled { throw CancellationError() }
        return resolution
    }
    func resolve(_ resolution: Resolution) {
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: resolution)
    }
}
