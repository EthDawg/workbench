#!/usr/bin/env python3
"""Exercise exact capture commit/transcribe/retry/cancel/recovery methods with inert IO.

Production AppModel initialization, user defaults, keychain, clipboard, microphone,
UI and network are never used. A synthetic WAV and recovery store live in /tmp;
recognition, delivery and the state writer are injected fixtures.
"""
import hashlib
from pathlib import Path
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
source = (PROJECT / 'Sources/LocalVoice/AppModel.swift').read_text()
core = (PROJECT / 'Sources/LocalVoice/Core.swift').read_text()
shortcuts = (PROJECT / 'Sources/LocalVoice/Shortcuts.swift').read_text()

def extract(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)].rstrip()

methods = '\n'.join([
    extract('    func cancelShortcut(', '\n    func transcribeForShortcut'),
    extract('    func cancelRecording()', '\n    func importAudio()'),
    extract('    func retryTranscription()', '\n    private func captureSettings()'),
    extract('    private func transcribe(', '\n    func copyTranscript()'),
    extract('    func fail(', '\n    func persist()'),
    extract('    func saveNow()', '\n    func shutdown()'),
    source[source.index('    func shutdown()'):source.rindex('\n}')],
])
labels = '\n'.join(line for line in source.splitlines() if any(name in line for name in ['var retryCapture', 'var hasCaptureRecovery:', 'var canDiscardCaptureRecovery:']))
request = shortcuts[shortcuts.index('@MainActor\nfinal class DictationRequest'):shortcuts.index('/// Shortcuts owns Record Audio')]
fixture = r'''
import AppKit
import AVFoundation
import Combine

__VALUES__
__REQUEST__

enum FixtureFailure: Error { case write }
@MainActor final class StateStore {
    var saved: SavedState?
    var fails = false
    var calls = 0
    var beforeSave: (() -> Void)?
    func save(_ state: SavedState) throws {
        calls += 1; beforeSave?()
        if fails { throw FixtureFailure.write }
        saved = state
    }
}
struct CaptureSettings {
    struct Preferences { var cleanup = "Light"; var delivery = "Copy"; var restoreClipboard = false }
    var preferences = Preferences()
    var cleanup = "Fixture"
    var replacements: [Replacement] = []
}
@MainActor final class Engine {
    struct Configuration { enum Provider { case parakeet }; var provider = Provider.parakeet; var model = "Fixture" }
    var calls = 0
    var delayed = false
    var continuation: CheckedContinuation<String, Never>?
    func configuration() async -> Configuration { Configuration() }
    func transcribe(_ url: URL) async throws -> String {
        calls += 1
        if delayed { return await withCheckedContinuation { continuation = $0 } }
        return "um synthetic captured words"
    }
    func release() { let c = continuation; continuation = nil; c?.resume(returning: "um synthetic captured words") }
}
@MainActor final class Cleanup {
    struct Result { let text: String; let method: String }
    var calls = 0
    func clean(_ raw: String, style: String, configuration: String) async -> Result {
        calls += 1; return Result(text: "Synthetic captured words.", method: "Fixture Light")
    }
}
@MainActor enum TextDelivery {
    static var calls = 0
    static var delayed = false
    static var continuation: CheckedContinuation<Void, Never>?
    static var beforeDelivery: (() -> Void)?
    struct Outcome { let message = "Fixture delivered after save" }
    static func deliver(_ text: String, target: String?, mode: String, restoreClipboard: Bool) async -> Outcome {
        beforeDelivery?(); calls += 1
        if delayed { await withCheckedContinuation { continuation = $0 } }
        return Outcome()
    }
    static func release() { let c = continuation; continuation = nil; c?.resume() }
}
@MainActor final class ClipboardReceipt {
    var receipts = 0
    func clear() {}
    func record(outcome: TextDelivery.Outcome, wordCount: Int) { receipts += 1 }
}
enum AudioRenderer { static func remove(_ url: URL?) {} }

@MainActor final class CaptureHarness {
    enum Phase { case idle, requesting, recording, transcribing, cleaning, delivering, cancelling }
    var phase = Phase.idle
    let engine = Engine(), cleanupEngine = Cleanup(), store = StateStore()
    let clipboardReceipt = ClipboardReceipt(), shortcutRequest = DictationRequest()
    let captureRecovery: CaptureRecoveryStore
    var captureStateWriter: ((SavedState) throws -> Void)?
    var loaded = true
    var rawTranscript = "Old original", transcript = "Old draft", cleanupMethod = "Old method"
    var speechText = "Reading stays separate", history: [Transcript] = [], replacements: [Replacement] = []
    var voice = "Fixture voice", rate = 180.0
    var transcriptionID: UUID?, transcriptionTask: Task<Void, Never>?
    var captureFailure: String?, error: String?, status = "", captureProcessingLabel = ""
    var previewingPanel = false, canRetry = false, accessibilityGranted = false, ready = true
    var destination: String? = "Original app target"
    var recordURL: URL?, elapsed = 1.0, level = 0.0
    var recorder: AVAudioRecorder?, meter: Timer?, recordingAttempt: UUID?
    var photoHandoffRefresh: Task<Void, Never>?, readingTask: Task<Void, Never>?
    var photoHandoffActivation: AnyCancellable?, audioURL: URL?
    var onPhaseChange: (() -> Void)?
    __LABELS__
    init(directory: URL, state: SavedState? = nil) {
        captureRecovery = CaptureRecoveryStore(directory: directory)
        if let state { transcript = state.draft; rawTranscript = state.rawDraft ?? state.draft; history = state.history }
    }
    func captureSettings() -> CaptureSettings { CaptureSettings() }
    func stopPlayback() {}
    func makeRecording(_ bytes: Data) throws -> URL {
        let url = try captureRecovery.beginRecording(); try bytes.write(to: url); recordURL = url; return url
    }
    func run(_ url: URL, owned: Bool) { transcribe(url, duration: 1, temporary: owned) }
    func restore() { restoreCaptureRecovery() }
    func admitsCapture() -> Bool { admitNewCapture() }
    func staleCommit(_ invocation: UUID, url: URL) throws -> Bool {
        try commitRecognizedCapture(raw: "stale", text: "Stale result", seconds: 1, method: "Fixture", ownedAudio: url, invocation: invocation)
    }
    __METHODS__
}

struct CheckFailure: Error, CustomStringConvertible { let description: String }
@main struct Checks {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ ok: @autoclosure () throws -> Bool, _ message: String) throws {
            assertions += 1
            if try !ok() { throw CheckFailure(description: message) }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
        func wave() -> Data {
            var data = Data()
            func tag(_ string: String) { data.append(contentsOf: string.utf8) }
            func le<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            tag("RIFF"); le(UInt32(32036)); tag("WAVEfmt "); le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(16000)); le(UInt32(32000)); le(UInt16(2)); le(UInt16(16)); tag("data"); le(UInt32(32000)); data.append(Data(repeating: 0, count: 32000)); return data
        }
        let wav = wave()
        func finish(_ model: CaptureHarness) async { let task = model.transcriptionTask; await task?.value }
        func waitForEngine(_ model: CaptureHarness) async throws {
            for _ in 0..<500 { if model.engine.continuation != nil { return }; await Task.yield() }
            throw CheckFailure(description: "Fixture engine was not reached")
        }

        // Normal delivery cannot observe a state that has not been committed.
        TextDelivery.calls = 0
        let normal = CaptureHarness(directory: folder("normal"))
        let normalURL = try normal.makeRecording(wav)
        let unrelatedFile = folder("normal").appendingPathComponent("unfamiliar.wav")
        try Data("Unrelated file; never owned by this capture".utf8).write(to: unrelatedFile)
        var deliveredAfterSave = false
        normal.store.beforeSave = { precondition(TextDelivery.calls == 0) }
        TextDelivery.beforeDelivery = { deliveredAfterSave = normal.store.saved?.history.count == 1 }
        normal.run(normalURL, owned: true); await finish(normal)
        try check(deliveredAfterSave && TextDelivery.calls == 1, "Normal delivery follows the durable state write")
        try check(normal.history.count == 1 && normal.store.saved?.history.first?.id == normal.history.first?.id, "Normal commit has one stable capture ID")
        try check(!FileManager.default.fileExists(atPath: normalURL.path) && !normal.captureRecovery.hasRecovery, "Normal success releases only owned audio and journal")
        try check(FileManager.default.fileExists(atPath: unrelatedFile.path), "Successful cleanup preserves unfamiliar sibling files")
        try check(normal.phase == .idle && !normal.canRetry, "Normal completion returns idle")
        TextDelivery.beforeDelivery = nil

        // Main-state failure: text is available, original audio survives, no delivery.
        TextDelivery.calls = 0
        let failed = CaptureHarness(directory: folder("failed")); failed.store.fails = true
        let failedURL = try failed.makeRecording(wav)
        failed.run(failedURL, owned: true); await finish(failed)
        let pendingID = failed.captureRecovery.pending!.id
        try check(failed.transcript == "Synthetic captured words." && failed.rawTranscript == "um synthetic captured words", "Both current recognized versions survive save failure")
        try check(TextDelivery.calls == 0 && failed.clipboardReceipt.receipts == 0 && failed.history.isEmpty, "Failure produces no delivery, success receipt or committed history")
        try check(failed.canRetry && failed.retryCaptureLabel == "Retry saving" && failed.captureFailure?.contains("No text was sent") == true, "Failure exposes a save-only retry and honest visible status")
        try check(try Data(contentsOf: failedURL) == wav, "Save failure retains the exact owned audio")
        try check(try CaptureRecoveryStore(directory: folder("failed")).load()?.capture?.rawText == failed.rawTranscript, "Independent journal contains the original text")
        try check(!failed.admitsCapture(), "A new capture cannot replace an unsaved result")
        failed.cancelCurrentCapture(); failed.cancelShortcut(UUID())
        try check(failed.captureRecovery.pending?.id == pendingID && FileManager.default.fileExists(atPath: failedURL.path), "Cancelling an ended operation cannot discard failed commit recovery")
        let recognitionCalls = failed.engine.calls, cleanupCalls = failed.cleanupEngine.calls
        failed.transcript = "Later manual draft edit"; failed.store.fails = false
        failed.retryTranscription()
        try check(failed.engine.calls == recognitionCalls && failed.cleanupEngine.calls == cleanupCalls, "Save retry does not run either model")
        try check(failed.store.saved?.history.count == 1 && failed.store.saved?.history.first?.id == pendingID, "Save retry commits the existing ID exactly once")
        try check(failed.store.saved?.draft == "Later manual draft edit" && failed.history.first?.text == "Synthetic captured words.", "Save retry preserves later draft edits and original capture independently")
        try check(TextDelivery.calls == 0 && !FileManager.default.fileExists(atPath: failedURL.path), "Save retry does not replay an old app target; releases audio after commit")
        failed.retryTranscription()
        try check(failed.history.count == 1 && failed.engine.calls == recognitionCalls, "Repeated retry cannot duplicate or re-transcribe a completed capture")

        // Quit and cold recovery use the same production methods, without init's live dependencies.
        let quitting = CaptureHarness(directory: folder("quit")); quitting.store.fails = true
        let quitURL = try quitting.makeRecording(wav)
        quitting.run(quitURL, owned: true); await finish(quitting); quitting.shutdown()
        try check(FileManager.default.fileExists(atPath: quitURL.path) && quitting.captureRecovery.hasRecovery, "Quit never deletes a failed capture")
        let cold = CaptureHarness(directory: folder("quit"), state: SavedState()); cold.restore()
        try check(cold.transcript == quitting.transcript && cold.rawTranscript == quitting.rawTranscript && cold.canRetry, "Cold recovery restores recognized draft and original without recognition")
        cold.retryTranscription()
        try check(cold.store.saved?.history.count == 1 && cold.engine.calls == 0 && TextDelivery.calls == 0, "Cold save completes once without model, clipboard or previous-target delivery")

        // Ordinary draft saving can recover independently while the failed
        // capture's ID is still absent from history. Do not confuse that saved
        // draft with the immutable capture waiting in the recovery journal.
        let editedAfterFailure = CaptureHarness(directory: folder("newer-unacknowledged")); editedAfterFailure.store.fails = true
        let editedAudio = try editedAfterFailure.makeRecording(wav)
        editedAfterFailure.run(editedAudio, owned: true); await finish(editedAfterFailure)
        let recoveredCaptureID = editedAfterFailure.captureRecovery.pending!.id
        editedAfterFailure.transcript = "Newer manually written draft"
        editedAfterFailure.rawTranscript = "Newer saved original"
        editedAfterFailure.store.fails = false
        editedAfterFailure.saveNow()
        try check(editedAfterFailure.store.saved?.history.isEmpty == true && editedAfterFailure.captureRecovery.hasRecovery,
                  "Ordinary saving persists the newer draft without acknowledging the failed capture")
        let recoveredBesideDraft = CaptureHarness(directory: folder("newer-unacknowledged"), state: editedAfterFailure.store.saved)
        recoveredBesideDraft.restore()
        try check(recoveredBesideDraft.transcript == "Newer manually written draft" && recoveredBesideDraft.rawTranscript == "Newer saved original",
                  "Cold unacknowledged recovery preserves both newer saved text fields")
        try check(recoveredBesideDraft.status.contains("saved draft is unchanged") && recoveredBesideDraft.canRetry && recoveredBesideDraft.history.isEmpty,
                  "Cold recovery explains that the independent capture awaits save")
        recoveredBesideDraft.retryTranscription()
        try check(recoveredBesideDraft.store.saved?.draft == "Newer manually written draft" && recoveredBesideDraft.store.saved?.rawDraft == "Newer saved original",
                  "Save retry retains the newer saved draft and original")
        try check(recoveredBesideDraft.history.count == 1 && recoveredBesideDraft.history.first?.id == recoveredCaptureID
                  && recoveredBesideDraft.history.first?.text == "Synthetic captured words."
                  && recoveredBesideDraft.history.first?.rawText == "um synthetic captured words",
                  "Save retry adds the immutable recovered capture with its existing identity and both original versions")
        recoveredBesideDraft.retryTranscription()
        try check(recoveredBesideDraft.history.count == 1 && recoveredBesideDraft.engine.calls == 0 && TextDelivery.calls == 0,
                  "Repeated recovery save neither duplicates history nor transcribes or pastes")

        // A committed receipt left by a crash must not overwrite a newer persisted draft.
        let acknowledged = CaptureRecoveryStore(directory: folder("acknowledged"))
        let ackURL = try acknowledged.beginRecording(); try wav.write(to: ackURL)
        let ackID = acknowledged.pending!.id
        let ackCapture = Transcript(id: ackID, text: "Already saved", seconds: 1, rawText: "already saved")
        try acknowledged.retain(CaptureRecoveryRecord(id: ackID, audioFilename: ackURL.lastPathComponent, capture: ackCapture))
        let ackState = SavedState(draft: "Newer draft", history: [ackCapture], rawDraft: "Newer original")
        let reopened = CaptureHarness(directory: folder("acknowledged"), state: ackState); reopened.restore()
        try check(reopened.transcript == "Newer draft" && reopened.rawTranscript == "Newer original", "Previously committed recovery cannot overwrite a newer draft")
        try check(!reopened.captureRecovery.hasRecovery && !FileManager.default.fileExists(atPath: ackURL.path), "Cold committed receipt only clears its owned recovery")

        // A pending recorder/transcriber survives Quit; explicit Cancel still discards it.
        let interrupted = CaptureHarness(directory: folder("interrupted"))
        let interruptedURL = try interrupted.makeRecording(wav); interrupted.engine.delayed = true
        interrupted.run(interruptedURL, owned: true); try await waitForEngine(interrupted)
        interrupted.shutdown(); interrupted.engine.release(); await finish(interrupted)
        try check(FileManager.default.fileExists(atPath: interruptedURL.path) && interrupted.history.isEmpty, "Quit invalidates a late result but keeps unfinished audio")
        let audioRecovery = CaptureHarness(directory: folder("interrupted")); audioRecovery.restore()
        try check(audioRecovery.canRetry && audioRecovery.retryCaptureLabel == "Retry transcription" && audioRecovery.elapsed == 1, "An interrupted recording is discoverable as audio-only recovery")
        let cancelled = CaptureHarness(directory: folder("cancelled"))
        let cancelURL = try cancelled.makeRecording(wav); cancelled.engine.delayed = true
        cancelled.run(cancelURL, owned: true); try await waitForEngine(cancelled)
        cancelled.cancelCurrentCapture(); cancelled.engine.release(); await finish(cancelled)
        try check(cancelled.history.isEmpty && cancelled.store.calls == 0 && !cancelled.captureRecovery.hasRecovery, "Explicit in-flight Cancel rejects a noncooperative late result and discards only that recording")
        try check(!FileManager.default.fileExists(atPath: cancelURL.path), "Explicit Cancel releases its own audio")
        let stale = CaptureHarness(directory: folder("stale")); let staleURL = try stale.makeRecording(wav)
        stale.transcriptionID = UUID()
        do { _ = try stale.staleCommit(UUID(), url: staleURL); throw CheckFailure(description: "Stale invocation accepted") }
        catch is CancellationError {}
        try check(stale.store.calls == 0 && stale.transcript == "Old draft" && stale.captureRecovery.pending?.capture == nil, "Stale generation cannot publish, journal or commit its text")

        // Shortcuts failure ends its continuation once; imported originals are never owned.
        let importedURL = root.appendingPathComponent("imported-original.wav"); try wav.write(to: importedURL)
        let shortcut = CaptureHarness(directory: folder("shortcut")); shortcut.store.fails = true
        let requestID = UUID(); var replies = 0, wasFailure = false
        try shortcut.shortcutRequest.begin(id: requestID) { result in replies += 1; if case .failure = result { wasFailure = true } }
        shortcut.run(importedURL, owned: false); await finish(shortcut)
        try check(replies == 1 && wasFailure && shortcut.shortcutRequest.id == nil, "Failed Shortcuts commit returns one error, not premature success")
        shortcut.cancelShortcut(requestID); shortcut.store.fails = false; shortcut.retryTranscription()
        try check(replies == 1 && shortcut.engine.calls == 1 && TextDelivery.calls == 0, "Save retry cannot resume a failed/cancelled Shortcuts continuation")
        try check(try Data(contentsOf: importedURL) == wav && shortcut.history.count == 1, "Imported source bytes survive failed commit, cancel and successful save retry")

        // Preserve malformed/future records and malicious paths; do not follow symlinks.
        for (name, data) in [
            ("malformed", Data("not json".utf8)),
            ("future", Data("{\"version\":2,\"id\":\"\(UUID().uuidString)\",\"audioFilename\":\"anything.wav\"}".utf8)),
            ("traversal", Data("{\"version\":1,\"id\":\"\(UUID().uuidString)\",\"audioFilename\":\"../imported-original.wav\"}".utf8))
        ] {
            let dir = folder(name); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let marker = dir.appendingPathComponent("pending.json"); try data.write(to: marker)
            let recovery = CaptureRecoveryStore(directory: dir)
            do { _ = try recovery.load(); throw CheckFailure(description: "Unsafe marker accepted: \(name)") } catch is CheckFailure { throw CheckFailure(description: "Unsafe marker accepted: \(name)") } catch {}
            try check(recovery.hasRecovery && recovery.problem != nil && (try Data(contentsOf: marker)) == data, "\(name) recovery stays intact and blocks replacement")
        }
        let symlink = CaptureRecoveryStore(directory: folder("symlink")); let linkURL = try symlink.beginRecording()
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: importedURL)
        do { try symlink.clear(symlink.pending!.id); throw CheckFailure(description: "Symlink accepted") } catch is CheckFailure { throw CheckFailure(description: "Symlink accepted") } catch {}
        try check(try Data(contentsOf: importedURL) == wav && symlink.hasRecovery, "Recovery cleanup never follows a substituted audio symlink")

        // Simultaneous state/journal failure has honest, non-durable wording and retains bytes.
        let doubleFailure = CaptureHarness(directory: folder("double-failure")); doubleFailure.store.fails = true
        let doubleURL = try doubleFailure.makeRecording(wav)
        let marker = folder("double-failure").appendingPathComponent("pending.json")
        let changed = Data("externally changed, preserved".utf8); try changed.write(to: marker)
        doubleFailure.run(doubleURL, owned: true); await finish(doubleFailure)
        try check(doubleFailure.captureFailure?.contains("Copy or Save text before quitting") == true, "Double storage failure never promises durable text")
        doubleFailure.shutdown()
        try check(try Data(contentsOf: doubleURL) == wav && Data(contentsOf: marker) == changed, "Double failure preserves owned audio and externally changed metadata on Quit")
        try check(doubleFailure.transcript == "Synthetic captured words." && TextDelivery.calls == 0, "Double failure retains current draft without automatic delivery")

        // Dismissal of confirmation does not call the owner; confirmed discard
        // affects only validated owned recovery, preserving the open draft.
        let discard = CaptureHarness(directory: folder("discard")); discard.store.fails = true
        let discardURL = try discard.makeRecording(wav)
        discard.run(discardURL, owned: true); await finish(discard)
        let discardDraft = discard.transcript, discardOriginal = discard.rawTranscript
        try check(discard.canDiscardCaptureRecovery && FileManager.default.fileExists(atPath: discardURL.path), "Opening then cancelling confirmation leaves recovery intact")
        discard.phase = .transcribing; discard.discardCaptureRecovery()
        try check(discard.captureRecovery.hasRecovery && FileManager.default.fileExists(atPath: discardURL.path), "Discard cannot interrupt an active capture")
        discard.phase = .idle; discard.discardCaptureRecovery()
        try check(!discard.captureRecovery.hasRecovery && !FileManager.default.fileExists(atPath: discardURL.path) && discard.admitsCapture(), "Confirmed discard releases owned recovery and allows the next recording")
        try check(discard.transcript == discardDraft && discard.rawTranscript == discardOriginal && discard.history.isEmpty, "Confirmed discard preserves the current draft without inventing a committed history entry")
        let discardImport = CaptureHarness(directory: folder("discard-import")); discardImport.store.fails = true
        discardImport.run(importedURL, owned: false); await finish(discardImport); discardImport.discardCaptureRecovery()
        try check(!discardImport.captureRecovery.hasRecovery && (try Data(contentsOf: importedURL)) == wav, "Confirmed discard never deletes an imported source")
        let corrupt = CaptureHarness(directory: folder("future")); corrupt.restore(); corrupt.discardCaptureRecovery()
        try check(corrupt.hasCaptureRecovery && !corrupt.canDiscardCaptureRecovery && FileManager.default.fileExists(atPath: folder("future").appendingPathComponent("pending.json").path), "Corrupt/future recovery is preserved and can only be inspected manually")

        TextDelivery.delayed = true
        let delivering = CaptureHarness(directory: folder("late-delivery")); let deliveredURL = try delivering.makeRecording(wav)
        delivering.run(deliveredURL, owned: true)
        for _ in 0..<500 { if TextDelivery.continuation != nil { break }; await Task.yield() }
        try check(TextDelivery.continuation != nil && delivering.store.saved?.history.count == 1, "Delayed delivery begins only after the capture commit")
        delivering.shutdown(); let stoppedStatus = delivering.status
        TextDelivery.release(); await finish(delivering); TextDelivery.delayed = false
        try check(delivering.clipboardReceipt.receipts == 0 && delivering.status == stoppedStatus, "An invalidated delivery cannot publish a late receipt or replace shutdown state")

        print("CAPTURE_PERSISTENCE_CHECKS_OK: \(assertions) checks; exact AppModel capture methods, real recovery files, synthetic audio, injected recognition/delivery/state writes")
    }
}
'''
values = core[:core.index('struct StateStore {')]
fixture = fixture.replace('__VALUES__', values).replace('__REQUEST__', request).replace('__LABELS__', labels).replace('__METHODS__', methods)
with tempfile.TemporaryDirectory(prefix='workbench-capture-persistence-') as temporary:
    directory = Path(temporary)
    swift = directory / 'CapturePersistenceChecks.swift'; swift.write_text(fixture)
    executable = directory / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(directory / 'ModuleCache'),
                    str(swift), str(PROJECT / 'Sources/LocalVoice/TextPrimitives.swift'), str(PROJECT / 'Sources/LocalVoice/CaptureRecovery.swift'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(directory / 'data')], check=True)
print('AppModel.swift SHA256:', hashlib.sha256(source.encode()).hexdigest())
