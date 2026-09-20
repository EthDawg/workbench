import Foundation

enum PresentationMode: Equatable { case fullScreen, windowed }

/// Main-thread join for two independently asynchronous resources. The capture
/// completion retains this operation even after the scene owner releases its
/// presenter. A launch failure never retries or restarts capture implicitly.
final class PresentationHandoff {
    private var action: (() -> Void)?
    private(set) var requested = false
    private(set) var captureStopped = false
    private(set) var presentationClosed = false
    private(set) var completed = false

    @discardableResult func request(_ action: @escaping () -> Void) -> Bool {
        guard !requested, !presentationClosed else { return false }
        requested = true; self.action = action
        openWhenReleased()
        return true
    }
    func captureDidStop() { captureStopped = true; openWhenReleased() }
    func presentationDidClose() { presentationClosed = true; openWhenReleased() }
    private func openWhenReleased() {
        guard captureStopped, presentationClosed, !completed, let action else { return }
        completed = true; self.action = nil
        action()
    }
}

/// Native fullscreen transitions are asynchronous. Changing the window mode
/// must not end capture; only an explicit end/close request does that.
struct PresentationLifecycle {
    enum Effect: Equatable { case none, exitFullScreen, finish }
    private(set) var entering = false
    private(set) var exiting = false
    private(set) var isFullScreen = false
    private(set) var ending = false
    private(set) var finished = false

    mutating func willEnter() { if !finished { entering = true } }
    mutating func willExit() { if !finished { exiting = true } }
    mutating func requestEnd() -> Effect {
        guard !ending, !finished else { return .none }
        ending = true
        if entering || exiting { return .none }
        return isFullScreen ? .exitFullScreen : .finish
    }
    mutating func didEnter() -> Effect {
        guard !finished else { return .none }
        entering = false; isFullScreen = true
        return ending ? .exitFullScreen : .none
    }
    mutating func didExit() -> Effect {
        guard !finished else { return .none }
        entering = false; exiting = false; isFullScreen = false
        return ending ? .finish : .none
    }
    mutating func failedToEnter() -> Effect {
        guard !finished else { return .none }
        entering = false; isFullScreen = false
        return ending ? .finish : .none
    }
    mutating func failedToExit() -> Effect {
        guard !finished else { return .none }
        exiting = false; isFullScreen = true
        return ending ? .finish : .none
    }
    mutating func complete() {
        finished = true; ending = true; entering = false; exiting = false; isFullScreen = false
    }
}
