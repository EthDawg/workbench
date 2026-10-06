import AppKit
import ApplicationServices
import AVFoundation

// Times a main-actor voice lookup and a main-actor AX read while a detached
// voice listing is in flight, with the listing on the same queue ("shared",
// the bridge before) or on a queue of its own ("split", the bridge after).
// Each hop is a DispatchWorkItem waited on, as the bridge does it.
let elements = DispatchQueue(label: "lanes.elements", qos: .userInitiated)
let voices = DispatchQueue(label: "lanes.voices", qos: .userInitiated)
func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
func hop<T>(_ queue: DispatchQueue, _ body: @escaping () -> T) -> T {
    var out: T?; let work = DispatchWorkItem { out = body() }; queue.async(execute: work); work.wait(); return out!
}
func listing() -> Int {
    let av = AVSpeechSynthesisVoice.speechVoices().map { ($0.identifier, $0.name, $0.language, $0.quality, $0.voiceTraits) }
    let ns = NSSpeechSynthesizer.availableVoices.map { ($0, NSSpeechSynthesizer.attributes(forVoice: $0)) }
    return av.count + ns.count
}
let mode = CommandLine.arguments.dropFirst().first ?? "split"
let listingQueue = mode == "shared" ? elements : voices
let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.processIdentifier ?? getpid()
let app = AXUIElementCreateApplication(finder)
_ = hop(voices) { listing() } // warm, as after launch
let done = DispatchSemaphore(value: 0)
Task.detached(priority: .utility) {
    let t = now(); let n = hop(listingQueue) { listing() }
    print(" \(mode): detached listing of \(n) voices took \(Int((now() - t) * 1000)) ms on \(listingQueue.label)")
}
Task { @MainActor in
    try? await Task.sleep(nanoseconds: 20_000_000)
    var t = now()
    let code = hop(elements) { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v).rawValue }
    let axMs = Int((now() - t) * 1000)
    t = now()
    let name = hop(voices) { AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-GB.Daniel")?.name ?? "nil" }
    let voiceMs = Int((now() - t) * 1000)
    print(" \(mode): main-actor AX read of Finder (code \(code)) blocked main \(axMs) ms; voice lookup (\(name)) blocked main \(voiceMs) ms")
    done.signal()
}
let deadline = Date().addingTimeInterval(20)
while done.wait(timeout: .now()) != .success, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
Thread.sleep(forTimeInterval: 1)
