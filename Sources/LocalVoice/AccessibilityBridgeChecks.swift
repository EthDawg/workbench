import AppKit

/// The bridge's hop rule, without touching another application: a call made
/// inside a task runs on its lane's queue, a plain frame's call runs where it
/// is, a call from the queue itself runs inline rather than waiting, an
/// element call never waits behind the voice lane, and the waiting caller's
/// priority travels with the work.
enum AccessibilityBridgeChecks {
    private struct Failure: LocalizedError { let label: String; var errorDescription: String? { label } }
    static func run() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw Failure(label: "ACCESSIBILITY_BRIDGE_CHECK_FAILED: " + label) }
            count += 1
        }
        try check(AccessibilityBridge.currentLane == nil && AccessibilityBridge.perform { AccessibilityBridge.currentLane } == .elements,
                  "a call from a task hops to the element lane's queue")
        let detached = await Task.detached { AccessibilityBridge.perform { (AccessibilityBridge.currentLane, Thread.isMainThread) } }.value
        try check(detached == (.elements, false), "a detached task's call also hops, and never to the main thread")
        let fromMain = await MainActor.run { AccessibilityBridge.perform { AccessibilityBridge.currentLane } }
        try check(fromMain == .elements, "a main actor task's call hops too")
        let plain = await withCheckedContinuation { (continuation: CheckedContinuation<AccessibilityBridge.Lane?, Never>) in
            DispatchQueue.global().async { continuation.resume(returning: AccessibilityBridge.perform { AccessibilityBridge.currentLane }) }
        }
        try check(plain == nil, "a plain frame's call runs in place")
        try check(AccessibilityBridge.perform { AccessibilityBridge.perform { AccessibilityBridge.currentLane } } == .elements,
                  "a call from the queue runs inline instead of waiting on itself")
        var order: [Int] = []
        for index in 0..<5 { AccessibilityBridge.perform { order.append(index) } }
        try check(order == [0, 1, 2, 3, 4], "calls return in order with their results")

        // Lanes: a voice call hops to its own queue, and an element call made
        // while the voice lane is busy returns at once. With one shared queue
        // the element call would wait for the whole voice body (bounded to 2 s
        // here so a regression fails instead of hanging).
        try check(AccessibilityBridge.perform(on: .voices) { AccessibilityBridge.currentLane } == .voices,
                  "a voice catalogue call hops to the voice lane")
        try check(AccessibilityBridge.perform(on: .voices) { AccessibilityBridge.perform { AccessibilityBridge.currentLane } } == .voices,
                  "an element call from the voice lane runs in place, as plain code")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let listing = Task.detached {
            AccessibilityBridge.perform(on: .voices) { entered.signal(); _ = release.wait(timeout: .now() + 2); return AccessibilityBridge.currentLane }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { entered.wait(); continuation.resume() }
        }
        let started = Date()
        let lane = await MainActor.run { AccessibilityBridge.perform { AccessibilityBridge.currentLane } }
        let waited = Date().timeIntervalSince(started)
        release.signal()
        let listed = await listing.value
        try check(lane == .elements && listed == .voices && waited < 0.5,
                  "a main actor field read does not wait behind a voice listing (\(Int(waited * 1000)) ms)")

        // Priority: the queues' own class is user-initiated, GCD's ceiling for
        // work handed off the main thread, so no caller's call runs below it;
        // the override a waiting main actor adds is a libdispatch promise
        // (dispatch_block_wait) that qos_class_self cannot see.
        let onMain = await MainActor.run { AccessibilityBridge.perform { qos_class_self() } }
        let fromUtility = await Task.detached(priority: .utility) { AccessibilityBridge.perform { qos_class_self() } }.value
        try check(onMain.rawValue >= QOS_CLASS_USER_INITIATED.rawValue && fromUtility.rawValue >= QOS_CLASS_USER_INITIATED.rawValue,
                  "a call's work runs at user-initiated or above whether the main actor or a utility task waits on it")

        // The async hop suspends the task instead of holding its thread.
        let hopped = await AccessibilityBridge.performAsync { (AccessibilityBridge.currentLane, Thread.isMainThread) }
        try check(hopped == (.elements, false), "an async call runs on the lane's queue off the main thread")
        let voicesHopped = await AccessibilityBridge.performAsync(on: .voices) { AccessibilityBridge.currentLane }
        try check(voicesHopped == .voices, "an async voice call runs on the voice lane")
        async let first = AccessibilityBridge.performAsync { 1 }
        async let second = AccessibilityBridge.performAsync { 2 }
        let both = await (first, second)
        try check(both == (1, 2), "async calls return their own results")

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

        // Focus helpers, aimed at this process: it serves no accessibility
        // tree, so both read as no focus, within the default timeout, and the
        // snapshot keeps the application element it was asked about.
        let pid = getpid()
        let readStart = Date()
        let focused = AccessibilityBridge.focusedElement(of: pid)
        let snapshot = AccessibilityBridge.snapshot(of: pid)
        let readTime = Date().timeIntervalSince(readStart)
        try check(focused == nil && snapshot.focusedElement == nil && snapshot.focusedWindow == nil,
                  "focusedElement(of:) and snapshot(of:) read this process as having no focus")
        try check(CFEqual(snapshot.application, AccessibilityBridge.application(pid)), "a snapshot carries its application element")
        try check(readTime < Double(AccessibilityBridge.defaultTimeout) * 2 + 0.5,
                  "the focus reads return within the default timeout (\(Int(readTime * 1000)) ms)")
        print("ACCESSIBILITY_BRIDGE_CHECKS_OK: \(count) checks; a field read beside a busy voice lane waited \(Int(waited * 1000)) ms, "
              + "this process's focus read in \(Int(readTime * 1000)) ms; this process only, no other application read")
    }
}
