import AppKit

/// The bridge's hop rule, without touching another application: a call made
/// inside a task runs on the bridge's queue, a plain frame's call runs where
/// it is, and a call from the queue itself runs inline rather than waiting.
enum AccessibilityBridgeChecks {
    private struct Failure: Error { let label: String }
    static func run() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw Failure(label: "ACCESSIBILITY_BRIDGE_CHECK_FAILED: " + label) }
            count += 1
        }
        try check(!AccessibilityBridge.isOnQueue && AccessibilityBridge.perform { AccessibilityBridge.isOnQueue },
                  "a call from a task hops to the bridge's queue")
        let detached = await Task.detached { AccessibilityBridge.perform { (AccessibilityBridge.isOnQueue, Thread.isMainThread) } }.value
        try check(detached == (true, false), "a detached task's call also hops, and never to the main thread")
        let fromMain = await MainActor.run { AccessibilityBridge.perform { AccessibilityBridge.isOnQueue } }
        try check(fromMain, "a main actor task's call hops too")
        let plain = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { continuation.resume(returning: AccessibilityBridge.perform { AccessibilityBridge.isOnQueue }) }
        }
        try check(!plain, "a plain frame's call runs in place")
        try check(AccessibilityBridge.perform { AccessibilityBridge.perform { AccessibilityBridge.isOnQueue } },
                  "a call from the queue runs inline instead of waiting on itself")
        var order: [Int] = []
        for index in 0..<5 { AccessibilityBridge.perform { order.append(index) } }
        try check(order == [0, 1, 2, 3, 4], "calls return in order with their results")
        try check(AccessibilityBridge.defaultTimeout > 0 && AccessibilityBridge.defaultTimeout <= 1,
                  "elements without a timeout of their own are bounded to a second")
        let range = NSRange(location: 3, length: 4)
        try check(AccessibilityBridge.range(AccessibilityBridge.value(range)) == range
                  && AccessibilityBridge.range("text" as CFString) == nil
                  && AccessibilityBridge.range(AccessibilityBridge.value(NSRange(location: -1, length: 2))) == nil,
                  "text ranges round-trip and other values or negative ranges read as none")
        try check(AccessibilityBridge.element("text" as CFString) == nil
                  && AccessibilityBridge.element(AccessibilityBridge.application(getpid())) != nil,
                  "only elements read as elements")
        print("ACCESSIBILITY_BRIDGE_CHECKS_OK: \(count) checks; this process only, no other application read")
    }
}
