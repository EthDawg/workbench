import AppKit
import SwiftUI

@MainActor enum LiveVoiceExperienceChecks {
    static func run() throws {
        var count = 0
        func expect(_ value: Bool, _ label: String) throws {
            guard value else { throw VoiceError.message("Live voice experience: " + label) }
            count += 1
        }
        var guardrail = MeetingAutoFinish()
        try expect(guardrail.observe(.inactive, now: 0, suspended: false) == nil
            && guardrail.observe(.inactive, now: 100, suspended: false) == nil, "a never-active source cannot finish a session")
        _ = guardrail.observe(.active, now: 100, suspended: false)
        try expect(guardrail.observe(.inactive, now: 101, suspended: false) == nil
            && guardrail.observe(.inactive, now: 120, suspended: false) == nil, "brief audio-use gaps do not show a countdown")
        try expect(guardrail.observe(.inactive, now: 121, suspended: false) == 10, "sustained inactivity starts a ten-second grace period")
        try expect(guardrail.observe(.active, now: 124, suspended: false) == nil, "renewed call audio cancels a pending finish")
        _ = guardrail.observe(.inactive, now: 125, suspended: false)
        try expect(guardrail.observe(.inactive, now: 154, suspended: false) == 1
            && guardrail.observe(.inactive, now: 155, suspended: false) == 0, "finish waits for the full fresh grace period")
        _ = guardrail.observe(.active, now: 160, suspended: false)
        _ = guardrail.observe(.inactive, now: 161, suspended: false)
        try expect(guardrail.observe(.unknown, now: 189, suspended: false) == nil
            && guardrail.observe(.inactive, now: 250, suspended: false) == nil, "metadata failure revokes finish until fresh active evidence")
        _ = guardrail.observe(.active, now: 251, suspended: false)
        _ = guardrail.observe(.inactive, now: 252, suspended: false)
        try expect(guardrail.observe(.inactive, now: 281, suspended: true) == nil
            && guardrail.observe(.inactive, now: 330, suspended: false) == nil, "pause and route reconnection cannot finish a call")
        _ = guardrail.observe(.active, now: 331, suspended: false)
        guardrail.keepRecording()
        try expect(guardrail.observe(.inactive, now: 400, suspended: false) == nil
            && guardrail.observe(.active, now: 401, suspended: false) == nil
            && guardrail.observe(.inactive, now: 500, suspended: false) == nil, "Keep recording disables automatic finish for this session")
        let source = ActivityFixture()
        let detector = MeetingDetector(source: source)
        let app = MeetingAudioApp(id: 42, name: "Chrome", bundleID: "com.google.Chrome")
        source.values = [.init(pid: 43, bundleID: "com.google.Chrome.helper.audio", isRunningInput: false, isRunningOutput: true)]
        try expect(detector.activity(for: app) == .active, "browser helper output keeps a muted call active")
        source.values[0].isRunningOutput = false
        try expect(detector.activity(for: app) == .inactive, "both input and output must stop")
        source.failure = true
        try expect(detector.activity(for: app) == .unknown, "metadata errors cannot masquerade as a call ending")
        source.failure = false
        let unknown = MeetingAudioApp(id: 44, name: "Other app", bundleID: "example.other")
        try expect(detector.activity(for: unknown) == .unknown, "unclassified sources keep manual Finish")
        let snapshot = LiveVoiceSnapshot(phase: .listening, recognitionDelayed: true)
        try expect(snapshot.recordingTitle == "Recording" && snapshot.transcriptStatus.contains("catching up"),
                   "delayed words do not claim capture stopped")
        try expect(MeetingFollowUp.task.contains("Do not send, schedule or change anything")
            && MeetingFollowUp.task.contains("no follow-up"), "follow-up drafts allow no-action calls and retain review")
        print("Live voice experience: \(count) checks passed")
    }

    private final class ActivityFixture: MeetingProcessSource {
        var isAvailable = true
        var unavailableReason = "Synthetic fixture"
        var values: [MeetingProcessSnapshot] = []
        var failure = false
        func snapshot() throws -> [MeetingProcessSnapshot] {
            if failure { throw VoiceError.message("Synthetic metadata error") }
            return values
        }
    }

    /// Production transcript views, synthetic words only, no microphone or
    /// Accessibility inspection. Renders both appearances and recovery states.
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for phase in [LiveVoicePhase.listening, .paused, .reconnecting, .finishing, .completed] {
                let words = [
                    LiveVoiceSegment(source: .app, start: 12, end: 15, text: "Let's review the checklist before choosing a launch date.", isFinal: true),
                    LiveVoiceSegment(source: .microphone, start: 16, end: 20, text: "I'll update it tomorrow and send it for review.", isFinal: true),
                    LiveVoiceSegment(source: .app, start: 21, end: 25, text: "Great. We can decide on the date after that.", isFinal: phase == .completed)
                ]
                let snapshot = LiveVoiceSnapshot(sessionID: UUID(), phase: phase, elapsed: 25,
                    sources: [.init(source: .app, name: "Mac calling service", health: phase == .paused ? .paused : .receiving),
                              .init(source: .microphone, name: "Your microphone", health: phase == .reconnecting ? .reconnecting : .quiet)], segments: words)
                let content = VStack(alignment: .leading, spacing: 18) {
                    HStack { Text("Meetings").font(.title2.weight(.semibold)); Spacer(); Text("0:25").monospacedDigit() }
                    Text(snapshot.recordingTitle).font(.headline)
                    LiveVoiceSourcesView(sources: snapshot.sources)
                    Divider()
                    LiveVoiceTranscriptView(snapshot: snapshot, conversation: true)
                }.padding(24).frame(width: 650, height: 470).background(Workbench.background)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let view = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 470),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view; window.isReleasedWhenClosed = false
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let image = try SurfaceGallery.snapshot(view)
                guard let data = image.representation(using: .png, properties: [:]) else { throw VoiceError.message("Could not render live transcript") }
                try data.write(to: directory.appendingPathComponent("\(phase.rawValue)-\(dark ? "dark" : "light").png"))
                window.close()
            }
        }
    }
}
