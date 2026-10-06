#!/usr/bin/env python3
"""Run AppModel's exact cleanup/cancel methods with an in-memory delayed engine.

No AppModel initialization, user defaults, state files, windows, model downloads,
clipboard or network access. Dependency fixtures supply responses; the methods
under test are extracted verbatim from the current application source.
"""

import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from swift_extract import SwiftFile


PROJECT = Path(__file__).resolve().parents[1]
model = SwiftFile(PROJECT / "Sources/LocalVoice/AppModel.swift").type("AppModel")
methods = model.extract(["canCancelCurrentCapture", "cancelCurrentCapture", "cleanCurrentDraft", "exportTranscript", "useOriginal"])
transcript = model.extract(["transcript"])

fixture = r'''
import Foundation
import Combine

@MainActor final class NSSavePanel {
    enum ContentType { case plainText }
    enum Response { case OK, cancel }
    static var response = Response.OK
    static var destination: URL?
    static var whileOpen: (() -> Void)?
    var allowedContentTypes: [ContentType] = []
    var nameFieldStringValue = ""
    var url: URL? { Self.destination }
    func runModal() -> Response { Self.whileOpen?(); return Self.response }
}

struct CleanupResult { let text: String; let method: String }
struct FixtureSettings {
    struct Preferences { let cleanup = "Natural" }
    let preferences = Preferences()
    let cleanup = "Fixture local engine"
    let replacements: [String] = []
}
enum TextRules {
    static func apply(_ text: String, replacements: [String]) -> String { text }
}
@MainActor final class ReceiptFixture {
    var dismissals = 0
    func dismissHUD() { dismissals += 1 }
}
@MainActor final class ShortcutFixture {
    var cancellations = 0
    func cancel() { cancellations += 1 }
}
@MainActor final class LiveCaptureFixture {
    func cancelRecognition() { preconditionFailure("Draft cleanup must not own live recognition") }
}
@MainActor final class DelayedCleanup {
    var immediate = false
    var calls = 0
    var pending: CheckedContinuation<CleanupResult, Never>?
    func clean(_ text: String, style: String, configuration: String) async -> CleanupResult {
        calls += 1
        if immediate { return CleanupResult(text: "Replacement from engine", method: "Fixture natural") }
        // Deliberately ignores cancellation until release. The host must reject
        // this late result and keep its capture gate closed while it unwinds.
        return await withCheckedContinuation { pending = $0 }
    }
    func release() {
        let continuation = pending; pending = nil
        continuation?.resume(returning: CleanupResult(text: "Replacement from engine", method: "Fixture natural"))
    }
}
@MainActor final class AppModelCleanupHarness {
    var rememberedCorrection: String?
    var reportedError: String?
    func fail(_ message: String) { reportedError = message }
    enum Phase { case idle, requesting, recording, transcribing, cleaning, delivering, cancelling }
    var phase: Phase = .idle
    var transcriptionTask: Task<Void, Never>?
    var liveCapture: LiveCaptureFixture?
    var transcriptionID: UUID?
    var draftRevision: UInt64 = 0
    // The production property's revision increment is part of the test.
    __TRANSCRIPT_PROPERTY__
    var rawTranscript = "Previously retained original"
    var cleanupMethod = "Previous method"
    var captureFailure: String? = "Previous failure"
    var previewingPanel = true
    var destination: String? = "Previous target"
    var captureProcessingLabel = ""
    var status = ""
    var attention: Attention?
    var error: String? { attention?.message }
    func report(_ message: String, on page: Attention.Page, code: String? = nil) { attention = Attention(message: message, page: page, code: code) }
    var persistenceCalls = 0
    var transitions: [Phase] = []
    var onPhaseChange: (() -> Void)?
    let clipboardReceipt = ReceiptFixture()
    let shortcutRequest = ShortcutFixture()
    let cleanupEngine = DelayedCleanup()
    init() {
        transcript = "Draft before cleanup"
        persistenceCalls = 0
        onPhaseChange = { [weak self] in if let self { self.transitions.append(self.phase) } }
    }
    func persist() { persistenceCalls += 1 }
    func captureSettings() -> FixtureSettings { FixtureSettings() }
    func cancelRecording() { preconditionFailure("This harness must exercise cleanup, not microphone capture") }
    /// Starting cleanup replaces any no-speech cue still on the floating surface.
    var cueDismissals = 0
    func dismissCaptureCue() { cueDismissals += 1 }
    __EXACT_METHODS__
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
@main struct Checks {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("CLEAN_DRAFT_CHECK_FAILED: \(error)\n".utf8))
            exit(1)
        }
    }
    @MainActor static func run() async throws {
        let start = Date()
        var count = 0
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw CheckFailure(description: description) }
            count += 1
        }
        func unchanged(_ model: AppModelCleanupHarness) -> Bool {
            model.transcript == "Draft before cleanup" && model.rawTranscript == "Previously retained original"
                && model.cleanupMethod == "Previous method"
        }
        func finished(_ model: AppModelCleanupHarness) -> Bool {
            model.phase == .idle && model.transcriptionTask == nil && model.transcriptionID == nil
        }
        func waitForEngine(_ model: AppModelCleanupHarness) async throws {
            for _ in 0..<1000 {
                if model.cleanupEngine.pending != nil { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw CheckFailure(description: "Cleanup did not reach the delayed engine")
        }

        let immediate = AppModelCleanupHarness()
        immediate.cleanupEngine.immediate = true
        immediate.cleanCurrentDraft()
        try check(immediate.canCancelCurrentCapture, "Cancel must be available immediately after Clean text")
        try check(!immediate.previewingPanel && immediate.destination == nil, "Cleanup must clear preview and stale paste destination")
        let immediateTask = immediate.transcriptionTask
        immediate.cancelCurrentCapture()
        try check(immediate.phase == .cancelling && !immediate.canCancelCurrentCapture, "Cancel must close the gate while the task unwinds")
        await immediateTask?.value
        try check(unchanged(immediate) && immediate.persistenceCalls == 0, "Immediate cancellation must preserve draft, original and method")
        try check(finished(immediate), "Immediate cancellation must return the gate to idle")
        try check(immediate.transitions == [.cleaning, .cancelling, .idle], "UI must observe cleaning, cancellation and completion")

        let delayed = AppModelCleanupHarness()
        delayed.cleanCurrentDraft()
        try await waitForEngine(delayed)
        let delayedTask = delayed.transcriptionTask
        let invocation = delayed.transcriptionID
        delayed.cancelCurrentCapture()
        delayed.cleanCurrentDraft()
        try check(delayed.phase == .cancelling && delayed.transcriptionID == invocation && delayed.cleanupEngine.calls == 1,
                  "A new cleanup must not start while cancelled work is still unwinding")
        delayed.cleanupEngine.release()
        await delayedTask?.value
        try check(unchanged(delayed) && delayed.persistenceCalls == 0, "An uncooperative engine's late result must not modify the draft")
        try check(finished(delayed), "Delayed cancellation must release the gate after unwinding")

        let edited = AppModelCleanupHarness()
        var editedOutcome: String?
        edited.cleanCurrentDraft { editedOutcome = $0 }
        try await waitForEngine(edited)
        let editedTask = edited.transcriptionTask
        edited.transcript = "Newer user edit"
        let savesAfterEdit = edited.persistenceCalls
        edited.cleanupEngine.release()
        await editedTask?.value
        try check(edited.transcript == "Newer user edit" && edited.rawTranscript == "Previously retained original"
                  && edited.cleanupMethod == "Previous method", "Editing mid-cleanup must preserve the new draft, original and method")
        try check(edited.persistenceCalls == savesAfterEdit && finished(edited), "Discarded cleanup must not save over the user's edit or hold the gate")
        try check(editedOutcome == "Your draft changed during cleanup. Your latest text was kept.",
                  "cleanup reports the kept edit through its own completion")

        let success = AppModelCleanupHarness()
        var completedOutcomes: [String] = []
        success.cleanCurrentDraft { completedOutcomes.append($0) }
        try await waitForEngine(success)
        let successTask = success.transcriptionTask
        success.cleanupEngine.release()
        await successTask?.value
        try check(success.transcript == "Replacement from engine" && success.rawTranscript == "Draft before cleanup"
                  && success.cleanupMethod == "Fixture natural", "The positive control must apply successful cleanup and preserve its original")
        try check(success.persistenceCalls > 0 && finished(success), "Successful cleanup must persist and release the gate")
        success.status = "Finished reading."
        try check(completedOutcomes == ["Fixture natural · original retained"],
                  "unrelated status cannot replace a cleanup's completed outcome")

        let saveFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: saveFolder) }
        let saveURL = saveFolder.appendingPathComponent("Transcript.txt")
        NSSavePanel.destination = saveURL
        let firstSave = success.exportTranscript(), secondSave = success.exportTranscript()
        try check(firstSave == "Transcript saved." && secondSave == firstSave,
                  "each successful save reports completion even when its text is unchanged")
        let savedBytes = try Data(contentsOf: saveURL)
        NSSavePanel.response = .cancel
        NSSavePanel.whileOpen = { success.status = "Finished reading." }
        try check(success.exportTranscript() == nil && (try Data(contentsOf: saveURL)) == savedBytes,
                  "cancelling Save text cannot borrow another operation's status or change the file")
        NSSavePanel.whileOpen = nil; NSSavePanel.response = .OK
        NSSavePanel.destination = saveFolder.appendingPathComponent("missing/Transcript.txt")
        try check(success.exportTranscript() == nil && success.reportedError != nil,
                  "failed text export reports its error without a success result")
        try check(success.useOriginal() == "Original transcript restored." && success.useOriginal() == "Original transcript restored.",
                  "each explicit original restore has its own completion")
        print(String(format: "CLEAN_DRAFT_CHECKS_OK: %d checks in %.3fs", count, Date().timeIntervalSince(start)))
    }
}
'''.replace("__TRANSCRIPT_PROPERTY__", transcript).replace("__EXACT_METHODS__", methods)

started = time.monotonic()
with tempfile.TemporaryDirectory(prefix="workbench-clean-draft-", dir="/private/tmp") as directory:
    directory = Path(directory)
    harness = directory / "Checks.swift"
    harness.write_text(fixture)
    binary = directory / "checks"
    subprocess.run([
        "swiftc", "-parse-as-library", "-swift-version", "5", "-module-cache-path", str(directory / "ModuleCache"),
        str(harness), str(PROJECT / "Sources/LocalVoice/Attention.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
print(f"Exact application methods SHA-256: {hashlib.sha256(methods.encode()).hexdigest()}")
print(f"Compilation and checks: {time.monotonic() - started:.3f}s")
