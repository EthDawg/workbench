import AppKit
import Combine

/// Delivery metadata only. No transcript or arbitrary clipboard content is kept.
struct ClipboardReceipt: Identifiable, Equatable {
    let id: UUID
    var title: String
    var detail: String
    var symbolName: String
    var wordCount: Int
    var isClipboardCurrent: Bool
    var clipboardChangeCount: Int?
    var wasPasted: Bool
    /// Only show a Command-V suggestion when this action has not already tried
    /// to paste. An uncertain destination must not encourage duplicate insertion.
    var canSuggestPaste: Bool
    /// What was copied, so Review opens where it is kept: History for a
    /// transcript, Library for a prompt.
    var source: Source = .transcript
    enum Source: Equatable { case transcript, prompt, result(UUID) }
}

/// A brief delivery cue. Confirmed insertion stays quiet; clipboard fallback gives
/// a useful next step, then disappears. Saved words and unresolved delivery keep
/// their existing owners when this presentation ends.
@MainActor
final class ClipboardReceiptModel: ObservableObject {
    @Published private(set) var receipt: ClipboardReceipt?
    @Published private(set) var isHUDVisible = false
    @Published private(set) var lifetime: NoticeLifetime?
    /// The HUD's view reports the pointer, including one already resting
    /// where the HUD appears, so a receipt that appears under it starts held.
    private(set) var pointerOverHUD = false

    private let clipboardChangeCount: () -> Int
    let now: MonotonicClock
    private let automaticallySchedules: Bool
    private var observedCount: Int?
    private var timer: Timer?
    private let expiry: NoticeExpiry
    /// The HUD's pending close, for checks: its event and deadline.
    var pendingExpiry: (event: UUID, deadline: TimeInterval)? { expiry.pending }

    init(clipboardChangeCount: @escaping () -> Int = { NSPasteboard.general.changeCount },
         now: @escaping MonotonicClock = Monotonic.now, automaticallySchedules: Bool = true) {
        self.clipboardChangeCount = clipboardChangeCount
        self.now = now
        self.automaticallySchedules = automaticallySchedules
        expiry = NoticeExpiry(clock: now)
    }

    /// Three seconds, held only while the person is reading the cue.
    private func freshLifetime(for receipt: ClipboardReceipt) -> NoticeLifetime {
        var lifetime = NoticeLifetime(duration: 3)
        lifetime.present(at: now())
        if pointerOverHUD { lifetime.hold(.pointer, true, at: now()) }
        return lifetime
    }

    /// The pointer over the HUD holds its time; leaving resumes it.
    func holdHUD(_ held: Bool) {
        pointerOverHUD = held
        guard isHUDVisible, var lifetime else { return }
        lifetime.hold(.pointer, held, at: now())
        self.lifetime = lifetime
        scheduleExpiry()
    }

    /// The HUD closes at its lifetime's own deadline, rescheduled whenever a
    /// hold changes it; a stale wake-up for an older receipt changes nothing.
    private func scheduleExpiry() {
        expiry.schedule(isHUDVisible ? lifetime : nil) { [weak self] event in self?.expireHUD(event) }
    }

    /// Ends the HUD only if it is still this receipt's time and it is due.
    func expireHUD(_ event: UUID) {
        guard isHUDVisible, let lifetime, lifetime.event == event else { return }
        if lifetime.isDue(at: now()) { dismissHUD() } else { scheduleExpiry() }
    }

    deinit { timer?.invalidate() }

    func record(outcome: TextDelivery.Outcome, wordCount: Int, source: ClipboardReceipt.Source = .transcript) {
        clear()
        let current = clipboardChangeCount()
        let ownsClipboard = outcome.failure != .copyFailed && (outcome.clipboardChangeCount.map { $0 == current } ?? false)
        let title: String
        let detail: String
        let symbol: String
        if outcome.failure == .copyFailed {
            title = "Copy failed"; detail = outcome.message; symbol = "exclamationmark.triangle"
        } else if outcome.wasPasted {
            title = outcome.destinationName.map { "Pasted into \($0)" } ?? "Pasted"
            detail = outcome.message
            symbol = outcome.failure == .clipboardRestoreFailed ? "exclamationmark.triangle" : "checkmark.circle.fill"
        } else if outcome.pasteWasAttempted && outcome.failure == nil {
            title = outcome.destinationName.map { "Sent to \($0)" } ?? "Paste sent"
            detail = outcome.message
            symbol = "arrow.up.right"
        } else if outcome.failure == .pasteUnconfirmed {
            title = "Paste unconfirmed"
            detail = ownsClipboard ? "Check the destination before pasting again. The transcript is still copied." : "Check the destination. The transcript is available in Workbench."
            symbol = "questionmark.circle"
        } else if outcome.failure == .cancelled {
            title = "Delivery stopped"; detail = outcome.message; symbol = "pause.circle"
        } else if ownsClipboard {
            // Copying is a supported result, whether chosen or waiting for
            // Accessibility approval. A changed or unreadable field keeps its reason.
            title = "Copied"; detail = outcome.reason ?? TextDelivery.copiedDetail(outcome.failure); symbol = "doc.on.clipboard"
        } else {
            switch source {
            case .result: title = "Result ready"; detail = "Clipboard changed. Copy the saved result again from History."
            case .prompt: title = "Prompt ready"; detail = "Clipboard changed. Copy the prompt again from Library."
            case .transcript: title = "Transcript ready"; detail = "Clipboard changed. Copy the transcript again from Workbench."
            }
            symbol = "doc.text"
        }
        receipt = ClipboardReceipt(id: UUID(), title: title, detail: detail, symbolName: symbol,
                                   wordCount: max(0, wordCount), isClipboardCurrent: ownsClipboard,
                                   clipboardChangeCount: ownsClipboard ? outcome.clipboardChangeCount : nil,
                                   wasPasted: outcome.wasPasted,
                                   canSuggestPaste: ownsClipboard && !outcome.wasPasted && !outcome.pasteWasAttempted
                                       && outcome.failure != .pasteUnconfirmed, source: source)
        observedCount = current
        isHUDVisible = !outcome.wasPasted
        lifetime = isHUDVisible ? receipt.map(freshLifetime) : nil
        scheduleExpiry()
        startTimerIfNeeded()
    }

    /// Dismissing the transient HUD does not discard a still-owned clipboard shelf.
    func dismissHUD() {
        isHUDVisible = false
        lifetime = nil
        expiry.cancel()
        if receipt?.isClipboardCurrent != true { clear() }
    }

    /// Reopen the same owned receipt without writing to or reading from the clipboard.
    func revealHUD() {
        refreshClipboardOwnership()
        guard let receipt, receipt.isClipboardCurrent else { return }
        isHUDVisible = true
        lifetime = freshLifetime(for: receipt)
        scheduleExpiry()
        startTimerIfNeeded()
    }

    /// Called on new recording as well as explicit dismissal of the whole receipt.
    func clear() {
        isHUDVisible = false
        receipt = nil; observedCount = nil; lifetime = nil
        expiry.cancel()
        timer?.invalidate(); timer = nil
    }

    /// The poll watches only the clipboard; the HUD's own deadline closes it.
    func refreshClipboardOwnership() {
        guard let receipt else { clear(); return }
        let current = clipboardChangeCount()
        // Even a restored-clipboard receipt has a baseline count: a later copy
        // dismisses the cue without claiming ownership of that other content.
        if observedCount != current || (receipt.isClipboardCurrent && receipt.clipboardChangeCount != current) {
            clear(); return
        }
    }

    private func startTimerIfNeeded() {
        guard automaticallySchedules, receipt != nil, timer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshClipboardOwnership() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
