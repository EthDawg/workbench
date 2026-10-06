import AppKit
import ApplicationServices
import AVFoundation

// Grounds which contexts macOS 26.5 counts as a "Swift Concurrent context"
// for the AXCommon unsafeForcedSync fault. One context per run, chosen by argv.
let systemWide = AXUIElementCreateSystemWide()
let queue = DispatchQueue(label: "axprobe.serial")

@discardableResult
func axRead() -> AXError {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)
}
func voices() -> Int { AVSpeechSynthesisVoice.speechVoices().count }

@MainActor func mainActorAsyncAX() async -> AXError { axRead() }
@MainActor func mainActorAsyncVoices() async -> Int { voices() }

let mode = CommandLine.arguments.dropFirst().first ?? "ax-main"
let repeats = 5
print("axprobe mode=\(mode) trusted=\(AXIsProcessTrusted())")
switch mode {
case "ax-main":
    for _ in 0..<repeats { print(" ax-main ->", axRead().rawValue) }
case "ax-mainactor-async":
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        for _ in 0..<repeats { print(" ax-mainactor-async ->", await mainActorAsyncAX().rawValue) }
        done.signal()
    }
    while done.wait(timeout: .now()) != .success { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
case "ax-detached":
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        for _ in 0..<repeats { print(" ax-detached ->", axRead().rawValue) }
        done.signal()
    }
    done.wait()
case "ax-queue":
    for _ in 0..<repeats { queue.sync { print(" ax-queue(sync) ->", axRead().rawValue) } }
    let done = DispatchSemaphore(value: 0)
    queue.async { for _ in 0..<repeats { print(" ax-queue(async) ->", axRead().rawValue) }; done.signal() }
    done.wait()
case "ax-continuation":
    // A Task hops to the serial queue and waits; the IPC itself runs on the queue.
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        for _ in 0..<repeats {
            let result: AXError = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: axRead()) }
            }
            print(" ax-continuation ->", result.rawValue)
        }
        done.signal()
    }
    done.wait()
case "ax-main-from-task-sync":
    // A Task on the main actor calls DispatchQueue.main.sync-free plain code: same frame as (b); kept for symmetry.
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        for _ in 0..<repeats { print(" ax-task-main-plain ->", axRead().rawValue) }
        done.signal()
    }
    while done.wait(timeout: .now()) != .success { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
case "voices-main":
    print(" voices-main ->", voices())
case "voices-mainactor-async":
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in print(" voices-mainactor-async ->", await mainActorAsyncVoices()); done.signal() }
    while done.wait(timeout: .now()) != .success { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
case "voices-detached":
    let done = DispatchSemaphore(value: 0)
    Task.detached(priority: .utility) { print(" voices-detached ->", voices()); done.signal() }
    done.wait()
case "voices-queue":
    let done = DispatchSemaphore(value: 0)
    queue.async { print(" voices-queue ->", voices()); done.signal() }
    done.wait()
case "voices-continuation":
    let done = DispatchSemaphore(value: 0)
    Task.detached(priority: .utility) {
        let count: Int = await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: voices()) } }
        print(" voices-continuation ->", count); done.signal()
    }
    done.wait()
case "voices-queue-sync-from-task":
    // dispatch_sync may run the block inline on the task's own thread.
    let done = DispatchSemaphore(value: 0)
    Task.detached(priority: .utility) { print(" voices-queue-sync-from-task ->", queue.sync { voices() }); done.signal() }
    done.wait()
case "voices-queue-wait-from-task":
    // async onto the queue, then wait: the block always runs on a GCD worker.
    let done = DispatchSemaphore(value: 0)
    Task.detached(priority: .utility) {
        var count = 0; let gate = DispatchSemaphore(value: 0)
        queue.async { count = voices(); gate.signal() }; gate.wait()
        print(" voices-queue-wait-from-task ->", count); done.signal()
    }
    done.wait()
case "voices-queue-wait-from-mainactor":
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        var count = 0; let gate = DispatchSemaphore(value: 0)
        queue.async { count = voices(); gate.signal() }; gate.wait()
        print(" voices-queue-wait-from-mainactor ->", count); done.signal()
    }
    while done.wait(timeout: .now()) != .success { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
case "voices-props-detached":
    // The app reads four properties per voice; count the faults per property read.
    let done = DispatchSemaphore(value: 0)
    Task.detached(priority: .utility) {
        let all = AVSpeechSynthesisVoice.speechVoices()
        var n = 0
        for v in all { n += v.name.count + v.language.count + v.identifier.count + Int(v.quality.rawValue) + (v.voiceTraits.contains(.isNoveltyVoice) ? 1 : 0) }
        print(" voices-props-detached ->", all.count, n); done.signal()
    }
    done.wait()
case "lang-detached":
    let done = DispatchSemaphore(value: 0)
    Task.detached { print(" lang-detached ->", AVSpeechSynthesisVoice.currentLanguageCode()); done.signal() }
    done.wait()
case "voice-by-id-detached":
    let done = DispatchSemaphore(value: 0)
    Task.detached { print(" voice-by-id-detached ->", AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-AU.Karen")?.name ?? "nil"); done.signal() }
    done.wait()
case "nsspeech-detached":
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let ids = NSSpeechSynthesizer.availableVoices
        var n = 0
        for id in ids { n += (NSSpeechSynthesizer.attributes(forVoice: id)[.name] as? String)?.count ?? 0 }
        print(" nsspeech-detached ->", ids.count, n); done.signal()
    }
    done.wait()
case "trusted-detached":
    let done = DispatchSemaphore(value: 0)
    Task.detached { for _ in 0..<repeats { print(" trusted-detached ->", AXIsProcessTrusted()) }; done.signal() }
    done.wait()
case "trusted-main":
    for _ in 0..<repeats { print(" trusted-main ->", AXIsProcessTrusted()) }
case "axapp-main", "axapp-mainactor-async", "axapp-detached", "axapp-queue-wait-from-task", "axapp-queue-sync-from-task":
    // Real IPC: this process's own AX application element and Finder's, read for their role and focused element.
    let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.processIdentifier ?? getpid()
    let targets = [AXUIElementCreateApplication(getpid()), AXUIElementCreateApplication(finder)]
    func readAll() -> [Int32] {
        var codes: [Int32] = []
        for element in targets {
            AXUIElementSetMessagingTimeout(element, 0.5)
            for key in [kAXRoleAttribute, kAXFocusedUIElementAttribute, kAXWindowsAttribute] {
                var value: CFTypeRef?
                codes.append(AXUIElementCopyAttributeValue(element, key as CFString, &value).rawValue)
            }
        }
        return codes
    }
    let done = DispatchSemaphore(value: 0)
    switch mode {
    case "axapp-main": print(" axapp-main ->", readAll()); done.signal()
    case "axapp-mainactor-async": Task { @MainActor in print(" axapp-mainactor-async ->", readAll()); done.signal() }
    case "axapp-detached": Task.detached { print(" axapp-detached ->", readAll()); done.signal() }
    case "axapp-queue-sync-from-task": Task.detached { print(" axapp-queue-sync-from-task ->", queue.sync { readAll() }); done.signal() }
    default: Task.detached { var r: [Int32] = []; let g = DispatchSemaphore(value: 0); queue.async { r = readAll(); g.signal() }; g.wait(); print(" axapp-queue-wait-from-task ->", r); done.signal() }
    }
    while done.wait(timeout: .now()) != .success { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
case "write-main", "write-mainactor", "write-detached", "write-queue-from-mainactor", "write-mainactor-bridged-voice":
    // Render a short utterance to buffers, as MacSpeechRenderer does, from each context.
    final class Box: @unchecked Sendable { var buffers = 0; var ended = false; var keep: AVSpeechSynthesizer? }
    let box = Box()
    func render(voiceOnQueue: Bool) {
        var voice: AVSpeechSynthesisVoice?
        if voiceOnQueue {
            let g = DispatchSemaphore(value: 0); queue.async { voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-GB.Daniel"); g.signal() }; g.wait()
        } else { voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-GB.Daniel") }
        let utterance = AVSpeechUtterance(string: "Alpha. Echo. India. Oscar.")
        utterance.voice = voice
        let synthesizer = AVSpeechSynthesizer(); box.keep = synthesizer
        synthesizer.write(utterance) { buffer in
            if (buffer as? AVAudioPCMBuffer)?.frameLength == 0 { box.ended = true } else { box.buffers += 1 }
        }
    }
    switch mode {
    case "write-main": render(voiceOnQueue: false)
    case "write-mainactor": Task { @MainActor in render(voiceOnQueue: false) }
    case "write-mainactor-bridged-voice": Task { @MainActor in render(voiceOnQueue: true) }
    case "write-detached": Task.detached { render(voiceOnQueue: false) }
    default: Task { @MainActor in let g = DispatchSemaphore(value: 0); queue.async { render(voiceOnQueue: false); g.signal() }; g.wait() }
    }
    let deadline = Date().addingTimeInterval(8)
    while !box.ended, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    print(" \(mode) -> buffers=\(box.buffers) ended=\(box.ended)")
case "nsspeech-queue-wait-from-mainactor":
    // Main blocked on the semaphore while the queue lists `say` voices: must not deadlock.
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        var n = 0; let g = DispatchSemaphore(value: 0)
        queue.async { for id in NSSpeechSynthesizer.availableVoices { n += (NSSpeechSynthesizer.attributes(forVoice: id)[.name] as? String)?.count ?? 0 }; g.signal() }
        g.wait(); print(" nsspeech-queue-wait-from-mainactor ->", n); done.signal()
    }
    let deadline = Date().addingTimeInterval(20)
    while done.wait(timeout: .now()) != .success, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    if Date() >= deadline { print(" nsspeech-queue-wait-from-mainactor -> TIMED OUT") }
default:
    print("unknown mode"); exit(2)
}
