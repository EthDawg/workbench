import AppKit
import Combine
import ToolbarCore

/// One cancellable deadline. Tests deliver the deadline explicitly; production
/// uses the same session with the main-actor clock below.
@MainActor public protocol ToolbarGraceClock: AnyObject {
    func start(_ elapsed: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor public final class ToolbarTaskClock: ToolbarGraceClock {
    private var task: Task<Void, Never>?
    private let delayNanoseconds: UInt64
    /// One tuning point; changing it never changes reducer behaviour.
    public init(delay: TimeInterval = 0.45) {
        precondition(delay.isFinite && delay >= 0 && delay <= 60)
        delayNanoseconds = UInt64(delay * 1_000_000_000)
    }
    public func start(_ elapsed: @escaping @MainActor () -> Void) {
        cancel()
        let delay = delayNanoseconds
        task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            elapsed()
        }
    }
    public func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

/// Executes reducer effects, without knowing about the app's tools or windows.
@MainActor public final class ToolbarSession: ObservableObject {
    @Published public private(set) var state: ToolbarState
    public private(set) var isActive = false
    public var show: ((ToolbarTier) -> Void)?
    public var releaseHolds: (() -> Void)?
    private let clock: ToolbarGraceClock
    private let defaults: UserDefaults
    private weak var menu: NSMenu?
    // Preserve the existing explicit preference without changing user choices.
    public static let keepOpenKey = "floatingToolbarExpanded.v1"

    public init(defaults: UserDefaults = .standard, clock: ToolbarGraceClock? = nil) {
        self.defaults = defaults
        self.clock = clock ?? ToolbarTaskClock()
        state = ToolbarState(keepsOpen: defaults.bool(forKey: Self.keepOpenKey))
    }

    public func activate() {
        guard !isActive else { return }
        isActive = true
        apply(.surfaceReturnedToTools)
    }

    public func suspend() {
        isActive = false // Ignore synchronous menu/focus callbacks during teardown.
        apply(.surfaceLeftTools)
        clock.cancel()
        menu?.cancelTracking(); menu = nil
    }

    public func send(_ event: ToolbarEvent) {
        guard isActive else { return }
        apply(event)
    }

    /// The view must obtain admission immediately before entering native tracking.
    @discardableResult public func beginMenu(_ menu: NSMenu) -> Bool {
        guard isActive else { return false }
        self.menu = menu
        send(.holdBegan(.menu))
        return true
    }

    public func endMenu(pointerInside: Bool) {
        menu = nil
        // Native menu tracking can swallow the owning window's exit event.
        // Reconcile before releasing the hold, including a stationary pointer.
        send(pointerInside ? .pointerEntered : .pointerLeft)
        send(.holdEnded(.menu))
    }

    private func apply(_ event: ToolbarEvent) {
        let (next, effects) = ToolbarState.reduce(state, event)
        if next != state { state = next }
        for effect in effects {
            switch effect {
            case .show(let tier): show?(tier)
            case .startGrace:
                clock.start { [weak self] in self?.send(.graceElapsed) }
            case .cancelGrace: clock.cancel()
            case .persistKeepOpen(let on): defaults.set(on, forKey: Self.keepOpenKey)
            case .releaseHolds:
                menu?.cancelTracking(); menu = nil
                releaseHolds?()
            }
        }
    }
}
