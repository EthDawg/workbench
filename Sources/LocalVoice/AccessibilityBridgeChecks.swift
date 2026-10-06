import AppKit

/// The bridge's rule, without touching another application: a call runs in
/// place on the calling thread, whatever that thread is, returns its result,
/// and the helpers around the calls read values the way delivery expects.
enum AccessibilityBridgeChecks {
    private struct Failure: LocalizedError { let label: String; var errorDescription: String? { label } }
    static func run() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw Failure(label: "ACCESSIBILITY_BRIDGE_CHECK_FAILED: " + label) }
            count += 1
        }
        // In place: the body runs on the thread that called, with no hop. A
        // main-thread caller stays on main, a detached task's call stays off
        // it, and a plain GCD frame stays on its own thread.
        let fromMain = await MainActor.run { AccessibilityBridge.perform { Thread.isMainThread } }
        try check(fromMain, "a main actor call runs on the main thread")
        let detached = await Task.detached {
            let caller = pthread_self()
            return AccessibilityBridge.perform { (pthread_equal(pthread_self(), caller) != 0, Thread.isMainThread) }
        }.value
        try check(detached == (true, false), "a detached task's call runs on the task's own thread, not the main thread")
        let plain = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let caller = pthread_self()
                continuation.resume(returning: AccessibilityBridge.perform { pthread_equal(pthread_self(), caller) != 0 })
            }
        }
        try check(plain, "a plain frame's call runs where it is")
        try check(AccessibilityBridge.perform { AccessibilityBridge.perform { 7 } } == 7, "a nested call runs inline and returns its result")
        var order: [Int] = []
        for index in 0..<5 { AccessibilityBridge.perform { order.append(index) } }
        try check(order == [0, 1, 2, 3, 4], "calls return in order with their results")

        let range = NSRange(location: 3, length: 4)
        try check(AccessibilityBridge.range(AccessibilityBridge.value(range)) == range
                  && AccessibilityBridge.range("text" as CFString) == nil
                  && AccessibilityBridge.range(AccessibilityBridge.value(NSRange(location: -1, length: 2))) == nil,
                  "text ranges round-trip and other values or negative ranges read as none")
        try check(AccessibilityBridge.element("text" as CFString) == nil
                  && AccessibilityBridge.element(AccessibilityBridge.application(getpid())) != nil,
                  "only elements read as elements")

        // A caller's own budget is honoured on the element it set it on: a
        // 20 ms bound keeps a read of this process, which serves no
        // accessibility tree, under that budget's order, with nothing
        // process-wide changed for elements without one.
        let app = AccessibilityBridge.application(getpid())
        try check(AccessibilityBridge.setMessagingTimeout(app, 0.02) == .success, "a caller can bound an element's messaging timeout")
        let budgetStart = Date()
        let (error, value) = AccessibilityBridge.attribute(app, kAXFocusedUIElementAttribute)
        let budgetTime = Date().timeIntervalSince(budgetStart)
        try check(error != .success || AccessibilityBridge.element(value) == nil, "a budgeted read of this process reads no focus")
        try check(budgetTime < 0.5, "a budgeted read returns within its budget's order (\(Int(budgetTime * 1000)) ms)")
        print("ACCESSIBILITY_BRIDGE_CHECKS_OK: \(count) checks; a 20 ms-budgeted read of this process's focus in \(Int(budgetTime * 1000)) ms; "
              + "this process only, no other application read")
    }
}
