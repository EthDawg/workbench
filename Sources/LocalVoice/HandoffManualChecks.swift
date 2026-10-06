import AppKit
import Foundation
import SwiftUI

enum HandoffManualChecks {
    @MainActor static func run() async throws -> Int {
        var passed = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw VoiceError.message("HANDOFF_MANUAL_CHECK_FAILED: " + message) }
            passed += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-manual-handoff-" + UUID().uuidString).resolvingSymlinksInPath()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        var switches: Set<SubscriptionProvider> = []
        let model = HandoffJobsModel(directory: root.appendingPathComponent("tasks"),
            switches: ({ switches.contains($0) }, { if $1 { switches.insert($0) } else { switches.remove($0) } }), pasteboard: pasteboard)
        let skill = try TranscriptHandoffSkills.followUpSnapshot()
        let source = HandoffSourceSnapshot(reference: .init(kind: .transcript, id: UUID()), title: "Synthetic selected meeting", capturedAt: .distantPast,
            text: "Complete selected text.\nFinal line retained.", originalText: "Original complete wording.", role: .instructions,
            captureNotes: ["The selected app stopped producing audio."])
        let task = "Draft a useful reply and explain uncertainty."
        let job = try model.prepare(sources: [source], task: task, skill: skill)
        let before = try Data(contentsOf: model.folder(job).appendingPathComponent("selection.json"))
        try check(model.copy(job), "copy succeeds with both runners off")
        let copied = pasteboard.string(forType: .string) ?? ""
        try check(copied.contains(task) && copied.contains(source.text) && copied.contains(source.originalText)
                  && copied.contains("MY INSTRUCTIONS") && copied.contains(source.captureNotes[0]), "manual copy includes the exact request, complete source, role and limitations")
        try check(copied.contains("no local folder access is required") && !copied.contains(model.folder(job).path)
                  && copied.contains("overrides any file-reading or file-writing directions"), "text-only inline handoff has no unavailable folder prerequisite")
        try check(model.feedbackJobID == job.id && model.notice?.contains("Paste them") == true, "copy feedback belongs to its task")
        try check(before == Data(contentsOf: model.folder(job).appendingPathComponent("selection.json")), "copy leaves the frozen inputs unchanged")
        var earlier = source, later = source
        earlier.capturedAt = Date(timeIntervalSince1970: 1000); earlier.seconds = 12.5
        later.reference = .init(kind: .transcript, id: UUID())
        later.capturedAt = Date(timeIntervalSince1970: 2000); later.seconds = nil
        let timedJob = try model.prepare(sources: [earlier, later], task: "Compare the two meetings in time order.", skill: skill)
        let timedSnapshot = model.folder(timedJob).appendingPathComponent("selection.json")
        let timedBefore = try Data(contentsOf: timedSnapshot)
        guard model.copy(timedJob) else { throw VoiceError.message("The multi-source timing fixture could not copy") }
        let timedCopy = pasteboard.string(forType: .string) ?? ""
        let earlierContext = "Source ID: transcript:" + earlier.reference.id.uuidString
            + "\nCaptured at (UTC): 1970-01-01T00:16:40.000Z\nRecording duration: 12.5 seconds\nText:\n" + earlier.text
        let laterContext = "Source ID: transcript:" + later.reference.id.uuidString
            + "\nCaptured at (UTC): 1970-01-01T00:33:20.000Z\nRecording duration: unknown (not recorded)\nText:\n" + later.text
        try check(timedCopy.contains(earlierContext) && timedCopy.contains(laterContext)
                  && timedBefore == Data(contentsOf: timedSnapshot),
                  "inline multi-source copy keeps each UTC capture time and known or unknown duration paired with its complete source, without rewriting the snapshot")
        var rich = source
        rich.images = [Data("first selected image".utf8), Data("second selected image".utf8)]
        rich.role = .reference
        let richJob = try model.prepare(sources: [rich], task: task, skill: skill)
        try check(model.copy(richJob), "attachment-only handoff copies without connection setup")
        let richCopy = pasteboard.string(forType: .string) ?? ""
        let record = try HandoffJobStore.read(HandoffSnapshotRecord.self, at: model.folder(richJob).appendingPathComponent("selection.json"))
        try check(record.items[0].images.allSatisfy { richCopy.contains(model.folder(richJob).appendingPathComponent($0).path) }
                  && richCopy.contains("A pasted path is not an attachment") && richCopy.contains("REFERENCE")
                  && richCopy.contains("Refer to these attachments by their filenames") && !richCopy.contains("../inputs/")
                  && !richCopy.contains("outputs/review/follow-up.md"), "every rich attachment has an exact path and honest attachment instruction")
        var files = skill.files; files["companion.txt"] = Data("Required companion".utf8)
        let companion = ReadbackSkillPackSnapshot(reference: skill.reference, files: files)
        let folderJob = try model.prepare(sources: [source], task: task, skill: companion)
        try check(!folderJob.supportsConnectedText && model.copy(folderJob), "a companion-file skill retains manual copying without claiming connected support")
        try check(pasteboard.string(forType: .string)?.contains("complete selected work folder") == true
                  && model.notice?.contains("complete selected work folder") == true, "full-folder skills explain the actual transfer requirement")
        let ready = SubscriptionConnection(provider: .codex, executable: URL(fileURLWithPath: "/synthetic/codex"), version: "synthetic", ready: true, detail: "Synthetic ready")
        for problem in [SubscriptionConnectionProblem.missing, .unsupported, .signIn, .unverified, .restricted] {
            let unavailable = SubscriptionConnection.unavailable(.codex, "Specific reason", problem: problem)
            let state = HandoffRunReadiness.evaluate(provider: .codex, enabled: true, checking: false, connection: unavailable, busy: false, compatible: true, inputProblem: nil)
            try check(!state.canStart && state.detail.contains("Specific reason") && state.detail.contains("Copy instructions"), "each unavailable selected-runner state gives its reason and manual next step")
        }
        let off = HandoffRunReadiness.evaluate(provider: .codex, enabled: false, checking: false, connection: ready, busy: false, compatible: true, inputProblem: nil)
        let checking = HandoffRunReadiness.evaluate(provider: .codex, enabled: true, checking: true, connection: ready, busy: false, compatible: true, inputProblem: nil)
        let busy = HandoffRunReadiness.evaluate(provider: .codex, enabled: true, checking: false, connection: ready, busy: true, compatible: true, inputProblem: nil)
        let runnable = HandoffRunReadiness.evaluate(provider: .codex, enabled: true, checking: false, connection: ready, busy: false, compatible: true, inputProblem: nil)
        try check(off.state == .off && checking.state == .checking && busy.state == .busy && runnable.canStart, "off, checking and busy cannot borrow a cached ready connection")
        try check(HandoffRunReadiness.inputProblem(provider: .codex, prompt: String(repeating: "a", count: 100_001), imageBytes: []) != nil, "the whole prompt text limit is checked")
        try check(HandoffRunReadiness.inputProblem(provider: .claude, prompt: "Request", imageBytes: Array(repeating: 1, count: 21)) != nil, "the selected provider's count limit is checked")
        try check(HandoffRunReadiness.inputProblem(provider: .claude, prompt: "Request", imageBytes: [4 * 1024 * 1024]) != nil, "the selected provider's per-image limit is checked")
        try check(HandoffRunReadiness.inputProblem(provider: .claude, prompt: "Request", imageBytes: Array(repeating: 3_000_000, count: 6)) != nil, "the selected provider's total-image limit is checked")
        let imageFolder = root.appendingPathComponent("encoded")
        try HandoffJobStore.privateDirectory(imageFolder)
        for size in [1, 2, 3, 100] {
            let image = imageFolder.appendingPathComponent("image.png")
            try Data(repeating: 9, count: size).write(to: image)
            let prompt = "Escaped \"words\", Unicode café and\nnew line."
            try check(SubscriptionClaudeInput.projectedBytes(prompt: prompt, imageBytes: [size])
                      == SubscriptionClaudeInput.encode(prompt: prompt, images: [image], directory: SubscriptionPaths.resolved(imageFolder)).count,
                      "projected Claude request bytes equal actual serialized bytes across base64 padding")
        }
        let manyBytes = "a" + String(repeating: "\u{0301}", count: 3_000_000)
        try check(HandoffRunReadiness.inputProblem(provider: .claude, prompt: manyBytes, imageBytes: Array(repeating: 3_000_000, count: 5)) != nil,
                  "encoded byte limit catches large grapheme content even below the character and raw-image limits")
        var calls = 0, callbacks: [@Sendable (String) -> Void] = []
        model.runner = HandoffRunner(discover: { _ in ready }, run: { _, _, _, _, onSession in
            calls += 1; callbacks.append(onSession)
            if calls == 1 { throw SubscriptionCLIError.failed("Synthetic dispatch failure; completion is unverified.") }
            onSession("current-attempt")
            try await Task.sleep(nanoseconds: 100_000_000)
            return .init(providerSessionID: nil, text: "Synthetic complete result")
        })
        model.setEnabled(.codex, true)
        for _ in 0..<100 where model.connections[.codex]?.ready != true { await Task.yield() }
        try check(calls == 0 && model.jobs.first(where: { $0.id == job.id })?.attempts == 0, "connection setup never auto-submits a prepared review")
        try check(model.start(job, provider: .codex), "explicit Start admits a ready task")
        while model.isBusy { await Task.yield() }
        let failed = model.jobs.first(where: { $0.id == job.id })!
        try check(failed.status == .failed && failed.detail.contains("unverified"), "dispatch failure stays on its originating attempt")
        var prepared = false
        try model.handOff(sources: [source], task: task, skill: skill, provider: .codex) { _ in prepared = true }
        try check(!prepared && calls == 1 && model.error?.contains("Retry") == true, "reopening an identical review cannot silently retry a failed attempt")
        try check(model.start(failed, provider: .codex, retry: true), "explicit retry starts a new attempt")
        for _ in 0..<100 where calls < 2 { await Task.yield() }
        callbacks[0]("late-prior-attempt")
        while model.isBusy { await Task.yield() }
        let completed = model.jobs.first(where: { $0.id == job.id })!
        try check(completed.providerSessionID == "current-attempt" && completed.previousAttempts.count == 1
                  && completed.previousAttempts[0].status == .failed, "late callbacks cannot overwrite a retry's provider identity or prior receipt")
        let runCount = calls
        try check(model.start(completed, provider: .codex) && calls == runCount, "a completed selection reuses its saved result without another run")
        try HandoffJobStore.verify(completed, root: model.folder(completed)); passed += 1
        // An old discovery completion cannot revive a connection after off/on.
        var probeEnabled = true
        var probes: [CheckedContinuation<SubscriptionConnection, Never>] = []
        var unintendedRuns = 0
        let probing = HandoffJobsModel(directory: root.appendingPathComponent("discovery"),
            switches: ({ $0 == .codex && probeEnabled }, { _, value in probeEnabled = value }), pasteboard: pasteboard)
        probing.runner = HandoffRunner(discover: { _ in await withCheckedContinuation { probes.append($0) } },
            run: { _, _, _, _, _ in unintendedRuns += 1; throw CancellationError() })
        let firstProbe = Task { await probing.refresh() }
        for _ in 0..<100 where probes.isEmpty { await Task.yield() }
        try check(probes.count == 1, "the first isolated discovery is pending")
        probing.setEnabled(.codex, false); probing.setEnabled(.codex, true)
        for _ in 0..<100 where probes.count < 2 { await Task.yield() }
        try check(probes.count == 2, "reenabling admits a fresh check")
        probes[1].resume(returning: .unavailable(.codex, "Current sign-in is required", problem: .signIn))
        for _ in 0..<100 where probing.refreshing { await Task.yield() }
        probes[0].resume(returning: ready); await firstProbe.value
        try check(probing.connections[.codex]?.problem == .signIn && unintendedRuns == 0,
                  "late discovery cannot replace current readiness or auto-run")

        // Fail the earlier task's receipt after Copy has moved feedback to another.
        var delayedSession: (@Sendable (String) -> Void)?
        model.runner = HandoffRunner(discover: { _ in ready }, run: { _, _, _, _, onSession in
            delayedSession = onSession
            try await Task.sleep(nanoseconds: 100_000_000)
            throw SubscriptionCLIError.failed("Synthetic dispatch error")
        })
        let receiptJob = try model.prepare(sources: [source], task: "Separate receipt failure", skill: skill)
        try check(model.start(receiptJob, provider: .codex), "receipt-failure fixture starts explicitly")
        for _ in 0..<100 where delayedSession == nil { await Task.yield() }
        let receipt = model.folder(receiptJob).appendingPathComponent("receipt.json")
        try FileManager.default.removeItem(at: receipt)
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: false)
        try check(model.copy(receiptJob), "a later copy of the same task starts a separate feedback action")
        let latestNotice = model.notice
        delayedSession?("late-receipt")
        while model.isBusy { await Task.yield() }
        try check(model.feedbackJobID == receiptJob.id && model.notice == latestNotice && model.error == nil
                  && model.jobs.first(where: { $0.id == receiptJob.id })?.detail.contains("receipt could not be saved") == true,
                  "background receipt failure stays on its attempt and cannot replace a later copy even for the same task")

        let selectedImage = model.folder(richJob).appendingPathComponent(record.items[0].images[0])
        try FileManager.default.removeItem(at: selectedImage)
        try check(!model.copy(richJob) && model.feedbackJobID == richJob.id && model.error != nil && model.notice == nil,
                  "a removed rich input cannot copy stale instructions or retain a success notice")
        if let path = ProcessInfo.processInfo.environment["WORKBENCH_HANDOFF_GALLERY_OUTPUT"] {
            try await renderReview(model: model, source: source, output: URL(fileURLWithPath: path))
        }
        return passed
    }

    @MainActor private static func renderReview(model: HandoffJobsModel, source: HandoffSourceSnapshot, output: URL) async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let history = WorkbenchHistoryModel(directory: output.appendingPathComponent("synthetic-library"))
        for (name, providerOn) in [("ready", true), ("manual", false)] {
            model.setEnabled(.codex, providerOn)
            let view = HandoffReviewView(history: history, jobs: model, skills: [.followUp], initialTask: "Prepare a follow-up from this meeting.", resolveSources: { [source] })
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 680, height: 720)
            host.wantsLayer = true
            defer { window.contentView = nil; window.close() }
            for _ in 0..<15 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            guard !providerOn || model.connections[.codex]?.ready == true else { throw VoiceError.message("The synthetic ready render did not finish checking") }
            let rep = try SurfaceGallery.snapshot(host)
            try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("handoff-" + name + ".png"))
        }
    }
}
