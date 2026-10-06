#!/usr/bin/env python3
"""Exercise exact capture commit/transcribe/retry/cancel/recovery methods with inert IO.

Production AppModel initialization, user defaults, keychain, clipboard, microphone,
UI and network are never used. A synthetic WAV and recovery store live in /tmp;
recognition, delivery and the state writer are injected fixtures.
"""
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from swift_extract import SwiftFile

PROJECT = Path(__file__).resolve().parents[1]
app_model = SwiftFile(PROJECT / 'Sources/LocalVoice/AppModel.swift')
model = app_model.type('AppModel')
core = SwiftFile(PROJECT / 'Sources/LocalVoice/Core.swift')

methods = model.extract([
    'resumeWaitingDelivery', 'copyWaitingDelivery',
    # The Dictate shortcut's press and release, and the attempt it starts (#134 T5).
    'toggleRecording', 'recordAgain', 'shortcutChanged',
    'cancelShortcut', 'stopRecording', 'completeStoppedRecording', 'cancelRecording', 'cancelCurrentCapture', 'cancelLiveDictation', 'importAudio(_:)', 'retryTranscription',
    # Transcription, its commit and the recovery it keeps.
    'transcribe', 'admitNewCapture', 'commitRecognizedCapture', 'savePendingCapture', 'restoreCaptureRecovery',
    'discardRecordingRecovery', 'discardCaptureRecovery', 'showCaptureRecoveryFiles', 'showSavedRecordings',
    # Manual copies and the undelivered result they resolve (#134 T5).
    'copyTranscript', 'deliveryRecords', 'unresolvedDelivery', 'copyTextWithReceipt', 'copyUnresolvedDelivery',
    'dismissUnresolvedDelivery', 'reviewUnresolvedDelivery', 'openHistory', 'copyCapture',
    # History's Open, refused on History while Dictate is busy (1 October audit, finding 7).
    'openTranscript', 'applyHistoryTranscript', 'persist',
    # Removing a transcript drops an undelivered result that names it (#134 T5 review).
    'removeTranscript',
    # Failures, the routine no-speech cue (#156) and the hold lesson that can take its place (#134 T5).
    'fail', 'captureCue', 'captureCueClock', 'captureCueExpiry', 'announceForAccessibility', 'quietCapturesInARow',
    'endWithoutSpeech', 'showDroppedLessonCue', 'showCaptureCue', 'holdCaptureCue', 'dismissCaptureCue',
    'scheduleCaptureCueExpiry',
    'saveNow', 'session', 'shutdown',
    # Preparing the speech model, whose failure is Home's (#134).
    'prepare', 'dismissCaptureFailure',
])

# Static inventories of AppModel, so a new way of reaching the receipt or the
# undelivered result cannot slip past the behavioural checks below. Each member
# is read whole, so every line belongs to the declaration that holds it.
def receipt_clear_sites(scope):
    """Members that clear or hide the clipboard receipt: directly, through optional
    chaining, or through a local or captured alias; by clear() or dismissHUD()."""
    text = '\n'.join(member.code for member in scope.members)
    names = {'clipboardReceipt'}
    names |= set(re.findall(r'(?:let|var)\s+(\w+)\s*(?::\s*ClipboardReceiptModel\??\s*)?=\s*(?:self\s*[?!]?\s*\.\s*)?clipboardReceipt\b', text))
    names |= set(re.findall(r'[\[,]\s*(?:weak\s+|unowned\s+)?(\w+)\s*=\s*(?:self\s*[?!]?\s*\.\s*)?clipboardReceipt\s*[\],]', text))
    call = re.compile(r'\b(?:' + '|'.join(sorted(names)) + r')\s*[?!]?\s*\.\s*(?:clear|dismissHUD)\b')
    return {member.name for member in scope.members if call.search(member.code)}
slot = SwiftFile(PROJECT / 'Sources/LocalVoice/DeliveryOutcome.swift').type('UnresolvedDeliverySlot')
mutators = {member.name for member in slot.members if member.kind == 'func' and 'mutating' in member.modifiers}
def undelivered_writers(scope):
    """Members that change the one undelivered result: its mutating methods, an
    assignment, or an inout pass."""
    write = re.compile(r'\bundelivered\s*(?:\.\s*(?:' + '|'.join(sorted(mutators)) + r')\s*\(|=(?!=))|&\s*(?:self\s*\.\s*)?undelivered\b')
    return {member.name for member in scope.members
            if any(write.search(code) and not re.search(r'\bvar\s+undelivered\b', code) for _, code in member.lines(code=True))}
# The scans themselves catch the forms a later edit might use.
probe = SwiftFile(Path('Probe.swift'), """final class Probe {
    func direct() { clipboardReceipt.clear() }
    func chained() { self?.clipboardReceipt?.clear() }
    func hides() { clipboardReceipt.dismissHUD() }
    func aliased() {
        let receipts = clipboardReceipt
        receipts.clear()
    }
    func captured() { Task { [weak held = clipboardReceipt] in held?.dismissHUD() } }
    func reads() { _ = clipboardReceipt.receipt; undelivered.shown(in: records) }
    init() { undelivered.restore(nil) }
    func assigns() { undelivered = UnresolvedDeliverySlot() }
    func passes() { tidy(&undelivered) }
}
""").type('Probe')
assert receipt_clear_sites(probe) == {'direct', 'chained', 'hides', 'aliased', 'captured'}, receipt_clear_sites(probe)
assert {'note', 'dismiss', 'transcriptRemoved', 'restore'} <= mutators, mutators
assert undelivered_writers(probe) == {'init', 'assigns', 'passes'}, undelivered_writers(probe)
# The scans read AppModel and its extensions, which is everything AppModel.swift declares.
# Another declaration there would go unscanned, so it stops here until the scans read it too.
others = [m.name for m in app_model.members if m.kind != 'import' and m.name not in ('AppModel', 'extension AppModel')]
assert not others, f'AppModel.swift also declares {others}; scan them for receipt and undelivered changes too'
clear_sites = receipt_clear_sites(model)
writers = undelivered_writers(model)
# Launch restores the undelivered result only once capture recovery has settled the draft,
# so a draft that recovery replaced drops a draft entry instead of showing it.
launch = model.select(['init(preferences:)'])[0].code
assert 'undelivered.restore(' in launch and launch.index('restoreCaptureRecovery()') < launch.index('undelivered.restore('), \
    'launch restores the undelivered result after capture recovery'
labels = model.extract(['retryCaptureLabel', 'retryCaptureHelp', 'hasCaptureRecovery', 'canRecordAgain',
                        'hasSavedRecordings', 'canDiscardCaptureRecovery'])
request = SwiftFile(PROJECT / 'Sources/LocalVoice/Shortcuts.swift').extract(['DictationRequest'])
# Exercise the actual shell callback that Persona, Draw, Present and Timer share.
shell = SwiftFile(PROJECT / 'Sources/LocalVoice/main.swift').type('AppDelegate')
assert re.search(r'stage\.onBeginActivity\s*=\s*\{\s*\[weak self\]\s*in\s*self\?\.beginStageActivity\(\)\s*\}',
                 shell.select(['applicationDidFinishLaunching'])[0].code), 'Stage starts use the tested shell callback'
stage_start = shell.extract(['beginStageActivity'])

fixture = r'''
import AppKit
import AVFoundation
import Combine

// Trust is a fixture input, never the runner's real TCC state. These exact
// AppModel methods call this local seam before choosing whether to defer paste.
@MainActor enum FixtureAccessibility { static var trusted = true }
@MainActor func AXIsProcessTrusted() -> Bool { FixtureAccessibility.trusted }

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
enum DeliveryMode { case paste, clipboard }
struct CaptureSettings {
    struct Preferences { var cleanup = "Light"; var delivery = DeliveryMode.clipboard; var restoreClipboard = false }
    var preferences = Preferences()
    var cleanup = "Fixture"
    var replacements: [Replacement] = []
}
@MainActor final class Engine {
    struct Configuration { enum Provider { case parakeet }; var provider = Provider.parakeet; var model = "Fixture" }
    var calls = 0
    var delayed = false
    /// What recognition returns: words, nothing at all, or a failure.
    var result = "um synthetic captured words"
    var failure: Error?
    var continuation: CheckedContinuation<String, Never>?
    func configuration() async -> Configuration { Configuration() }
    func transcribe(_ url: URL) async throws -> String {
        calls += 1
        if let failure { throw failure }
        if delayed { return await withCheckedContinuation { continuation = $0 } }
        return result
    }
    func release() { let c = continuation; continuation = nil; c?.resume(returning: "um synthetic captured words") }
    /// Preparing the speech model: ready, or this failure.
    var prepareFailure: Error?
    func prepare() async throws { if let prepareFailure { throw prepareFailure } }
    func statusDescription() async -> String { "Fixture model ready" }
}
@MainActor final class Cleanup {
    struct Result { let text: String; let method: String }
    var calls = 0
    func clean(_ raw: String, style: String, configuration: String) async -> Result {
        // The usual fixture words tidy to one sentence; any other words pass through, so checks can tell dictations apart.
        calls += 1; return Result(text: raw.isEmpty ? "" : raw == "um synthetic captured words" ? "Synthetic captured words." : raw, method: "Fixture Light")
    }
}
// An observation spy allows the exact AppModel phase and destination
// observers to prove teardown, without monitoring the user's actual input.
@MainActor final class FixtureOpaqueEditor {
    var begins = 0, ends = 0, active = false
    func begin(shortcut: FixtureShortcut) { begins += 1; active = true }
    func end() { if active { ends += 1 }; active = false }
}
@MainActor enum TextDelivery {
    static var calls = 0
    static var delayed = false
    static var continuation: CheckedContinuation<Void, Never>?
    static var beforeDelivery: (() -> Void)?
    static var lastMode: DeliveryMode?, lastTarget: String?, lastFit: InsertionBoundary.Context?
    enum FailureKind: String, Equatable {
        case copyFailed, accessibilityUnavailable, focusChanged, fieldUnreadable, pasteUnavailable
        case pasteUnconfirmed, clipboardChanged, clipboardRestoreFailed, cancelled
    }
    struct Outcome: Equatable {
        var message = "Fixture delivered after save"
        var clipboardChangeCount: Int? = 1
        var wasPasted = false
        var destinationName: String? = nil
        var failure: FailureKind? = nil
        var pasteWasAttempted = false
    }
    /// What the next delivery reports: copied, pasted, or an undelivered outcome.
    static var nextOutcome = Outcome()
    static var copies: [String] = []
    static var copyFails = false
    static let copiedMessage = "Copied. Paste with ⌘V."
    static func copiedDetail(_ failure: FailureKind?) -> String { "Synthetic delivery detail" }
    struct Target: ExpressibleByStringLiteral {
        var name: String
        var opaqueEditor: FixtureOpaqueEditor?
        init(stringLiteral value: String) { name = value }
        init(_ name: String, observation: FixtureOpaqueEditor) { self.name = name; opaqueEditor = observation }
    }
    static func capture() -> Target? { "Frontmost fixture field" }
    static func copy(_ text: String) -> Int? { copies.append(text); return copyFails ? nil : copies.count }
    static func deliver(_ text: String, target: Target?, mode: DeliveryMode, restoreClipboard: Bool,
                        fit: InsertionBoundary.Context? = nil) async -> Outcome {
        lastMode = mode; lastTarget = target?.name; lastFit = fit
        beforeDelivery?(); calls += 1
        if delayed { await withCheckedContinuation { continuation = $0 } }
        return nextOutcome
    }
    static func release() { let c = continuation; continuation = nil; c?.resume() }
}
// The AppModel integration spy never touches AX. The actual owned-span algorithm
// and native synthetic receiver are exercised by test-live-dictation.py.
@MainActor final class LiveDictationDelivery {
    static var next: LiveDictationDelivery?
    var attempted = false
    var finishCalls = 0, cancelCalls = 0, endCalls = 0
    var cancellationProblem: String?
    var outcome = TextDelivery.Outcome(message: "Inserted in fixture field.", clipboardChangeCount: nil, wasPasted: true, pasteWasAttempted: true)
    var beforeFinish: (() -> Void)?
    var context: InsertionBoundary.Context?
    static func begin(target: TextDelivery.Target?, shortcut: FixtureShortcut, context: InsertionBoundary.Context = .init()) -> LiveDictationDelivery? {
        defer { next = nil }; next?.context = context; return next
    }
    func finish(_ text: String, restoreClipboard: Bool) -> TextDelivery.Outcome { finishCalls += 1; beforeFinish?(); return outcome }
    func cancel() -> String? { cancelCalls += 1; return cancellationProblem }
    func end() { endCalls += 1 }
}
@MainActor final class ReceiptSpy {
    final class Clock { var now = 0.0 }
    let clock: Clock
    let actual: ClipboardReceiptModel
    var receipts = 0
    init() {
        let clock = Clock(); self.clock = clock
        actual = ClipboardReceiptModel(clipboardChangeCount: { 1 }, now: { clock.now }, automaticallySchedules: false)
    }
    func clear() { actual.clear() }
    func dismissHUD() { actual.dismissHUD() }
    func record(outcome: TextDelivery.Outcome, wordCount: Int) {
        receipts += 1; actual.record(outcome: outcome, wordCount: wordCount)
    }
}
enum AudioRenderer { static func remove(_ url: URL?) {} }
@MainActor final class AuxiliaryCaptureWork {
    var isBusy = false
    var shutdownCount = 0
    var removedTranscripts: [UUID] = []
    func transcriptRemoved(_ id: UUID) { removedTranscripts.append(id) }
    func shutdown() { shutdownCount += 1 }
    func hasRecording(for id: UUID) -> Bool { false }
    func removeCompletedRecording(for id: UUID, commit: () throws -> Void) throws -> String? { try commit(); return nil }
}

enum CaptureMode { case toggle, hold }
struct FixtureShortcut { var label = "⌥V" }
struct FixtureVoicePreferences { var capture = CaptureMode.hold; var dictationShortcut = FixtureShortcut() }

@MainActor final class FixtureLiveCapture {
    struct Report { struct Track { var peak: Double = 0.1 }; var tracks: [Track] = [Track()]; var seconds = 1.0; var failure: String?; var gaps: [String] = [] }
    var peak: Float = -20
    var checkpoint: LiveVoiceCheckpoint? = nil
    var stopped = false
    var failure: String?
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func requestStop() { stopped = true }
    func cancelRecognition() {}
    func finish(recognize: Bool = true) async -> (Report, LiveVoiceCheckpoint?) {
        stopped = true
        if hold { await withCheckedContinuation { continuation = $0 } }
        var report = Report(); report.failure = failure
        return (report, recognize ? checkpoint : nil)
    }
}

@MainActor final class CaptureHarness {
    enum Phase { case idle, requesting, recording, transcribing, cleaning, delivering, cancelling }
    __LIFECYCLE_PROPERTIES__
    var page = "home", historyDoor: HistoryDoor?
    var pendingTranscript: Transcript?, rememberedCorrection: String?
    // The press path and the coach (#134 T5).
    var preferences = FixtureVoicePreferences()
    var coach: FeedbackCoachModel
    var holdGesture: HoldGesture?
    var captureUsesHoldShortcut = false, isMicrophoneQuiet = false, rendering = false
    var microphoneStartFailure: ((TextDelivery.Target?) -> String?)?
    var undelivered = UnresolvedDeliverySlot()
    var draftRevision: UInt64 = 0
    var persistWork: DispatchWorkItem?
    /// Starting the recorder is the one step these checks script: nothing here opens a microphone.
    var startedAttempts: [UUID] = []
    func startRecording(_ attempt: UUID) async { startedAttempts.append(attempt) }
    let engine = Engine(), cleanupEngine = Cleanup(), store = StateStore()
    let clipboardReceipt = ReceiptSpy(), shortcutRequest = DictationRequest()
    let meetings = AuxiliaryCaptureWork(), handoffJobs = AuxiliaryCaptureWork()
    let captureRecovery: CaptureRecoveryStore
    var captureStateWriter: ((SavedState) throws -> Void)?
    var loaded = true
    var rawTranscript = "Old original", cleanupMethod = "Old method"
    var transcript = "Old draft" { didSet { draftRevision &+= 1 } }
    var speechText = "Reading stays separate", history: [Transcript] = [], replacements: [Replacement] = []
    var voice = "Fixture voice", rate = 180.0
    var transcriptionID: UUID?, transcriptionTask: Task<Void, Never>?
    var captureFailure: String?, status = "", captureProcessingLabel = ""
    var attention: Attention?
    var error: String? { attention?.message }
    func report(_ message: String, on page: Attention.Page) { attention = Attention(message: message, page: page) }
    var previewingPanel = false, canRetry = false, accessibilityGranted = false, ready = true
    var preparing = false, modelMessage = "", modelFailure: String? = nil
    var recordURL: URL?, elapsed = 1.0, level = 0.0
    var liveCapture: FixtureLiveCapture?, meter: Timer?, recordingAttempt: UUID?
    var liveDictation: LiveDictationDelivery?
    var voiceSession = LiveVoiceSnapshot()
    var peakPower: Float = -160, recordingSettings: CaptureSettings?
    var photoHandoffRefresh: Task<Void, Never>?, readingTask: Task<Void, Never>?
    var photoHandoffActivation: AnyCancellable?, audioURL: URL?
    var onPhaseChange: (() -> Void)?
    var waitingForDrawing = false
    var shouldDeferDelivery: (() -> Bool)?
    let drawingDelivery = DrawingDeliveryGate()
    var captureOptions = CaptureSettings()
    __LABELS__
    /// Lessons live in a preferences file inside the check's own temporary folder, never the person's.
    init(directory: URL, state: SavedState? = nil,
         tips: CoachTips = CoachTips(defaults: UserDefaults(suiteName: FileManager.default.temporaryDirectory.appendingPathComponent("workbench-capture-tips-" + UUID().uuidString).path)!)) {
        coach = FeedbackCoachModel(tips: tips, workspace: NotificationCenter(), distributed: NotificationCenter())
        coach.voiceOverEnabled = { false }; coach.announce = { _ in }
        captureRecovery = CaptureRecoveryStore(directory: directory)
        if let state { transcript = state.draft; rawTranscript = state.rawDraft ?? state.draft; history = state.history }
        // As AppModel's launch does once the draft is settled (the writer inventory checks it calls this).
        undelivered.restore(state?.undelivered, loadedDraftRevision: draftRevision, in: deliveryRecords)
        destination = "Original app target"
    }
    func captureSettings() -> CaptureSettings { captureOptions }
    func stopPlayback() {}
    func makeRecording(_ bytes: Data) throws -> URL {
        let url = try captureRecovery.beginRecording(); try bytes.write(to: url); recordURL = url; return url
    }
    func run(_ url: URL, owned: Bool) { transcribe(url, duration: 1, temporary: owned) }
    /// The recorder started for the attempt the shortcut began, with this much audio and loudness.
    func recorderStarted(audio seconds: Double, peak: Float, wav: Data) throws {
        precondition(phase == .requesting && recordingAttempt != nil)
        _ = try makeRecording(wav); phase = .recording; elapsed = seconds; peakPower = peak
    }
    func restore() { restoreCaptureRecovery() }
    func admitsCapture() -> Bool { admitNewCapture() }
    func staleCommit(_ invocation: UUID, url: URL) throws -> Bool {
        try commitRecognizedCapture(raw: "stale", text: "Stale result", seconds: 1, method: "Fixture", ownedAudio: url, invocation: invocation) != nil
    }
    __METHODS__
}

@MainActor final class StageActivityHarness {
    final class Surface {
        var hides = 0
        func hide() { hides += 1 }
        func orderOut(_ sender: Any?) { hides += 1 }
    }
    let model: CaptureHarness
    var presenterPanel: Surface? = Surface()
    var window: Surface? = Surface()
    var closes = 0
    init(model: CaptureHarness) { self.model = model }
    func closeControls() { closes += 1 }
    __STAGE_START__
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
        let observed = CaptureHarness(directory: folder("opaque-lifecycle"))
        let firstObservation = FixtureOpaqueEditor(), replacementObservation = FixtureOpaqueEditor()
        observed.toggleRecording(target: TextDelivery.Target("Opaque fixture", observation: firstObservation))
        try check(firstObservation.begins == 1 && firstObservation.active, "Dictation arms the captured opaque target once")
        for phase in [CaptureHarness.Phase.recording, .transcribing, .cleaning, .delivering] {
            observed.phase = phase
            try check(firstObservation.active && firstObservation.ends == 0, "Observation survives every phase through delivery")
        }
        replacementObservation.begin(shortcut: FixtureShortcut())
        observed.destination = TextDelivery.Target("Replacement", observation: replacementObservation)
        try check(firstObservation.ends == 1 && !firstObservation.active, "Replacing the destination tears down the old observation")
        observed.phase = .idle
        try check(replacementObservation.ends == 1 && !replacementObservation.active, "Returning idle tears down the current observation")
        let cancelledObservation = FixtureOpaqueEditor()
        observed.toggleRecording(target: TextDelivery.Target("Cancelled", observation: cancelledObservation))
        observed.cancelRecording()
        try check(!cancelledObservation.active && cancelledObservation.ends == 1, "Cancelling the request removes its observation")

        let independent = CaptureHarness(directory: folder("stage-preserves-failure"))
        let retainedAudio = try independent.makeRecording(wav)
        let retainedJournal = try Data(contentsOf: folder("stage-preserves-failure").appendingPathComponent("pending.json"))
        independent.canRetry = true
        independent.captureFailure = "Synthetic dictation failure"
        independent.transcript = "Existing draft"
        independent.previewingPanel = true
        let stageShell = StageActivityHarness(model: independent)
        stageShell.beginStageActivity()
        try check(independent.captureFailure == "Synthetic dictation failure", "starting independent Stage work preserves the dictation result")
        try check(independent.recordURL == retainedAudio && (try Data(contentsOf: retainedAudio)) == wav && independent.transcript == "Existing draft",
                  "the same Stage start preserves recording bytes, recovery reference and draft")
        try check(!independent.previewingPanel && stageShell.closes == 1 && stageShell.presenterPanel?.hides == 1 && stageShell.window?.hides == 1,
                  "starting Stage work still hides the preparation surfaces")
        try check(independent.hasCaptureRecovery && independent.canRetry && independent.retryCaptureLabel == "Retry transcription"
                  && (try Data(contentsOf: folder("stage-preserves-failure").appendingPathComponent("pending.json"))) == retainedJournal,
                  "Stage start retains the exact recording journal and its Retry action")
        for (outcome, duration) in [(TextDelivery.Outcome(), 3.0),
                                    (TextDelivery.Outcome(clipboardChangeCount: nil, failure: .copyFailed), 3.0)] {
            let receipt = independent.clipboardReceipt
            receipt.record(outcome: outcome, wordCount: 3)
            let id = receipt.actual.receipt!.id, event = receipt.actual.lifetime!.event
            receipt.clock.now += 1
            stageShell.beginStageActivity()
            try check(receipt.actual.isHUDVisible && receipt.actual.receipt?.id == id && receipt.actual.lifetime?.event == event
                      && receipt.actual.lifetime?.remaining(at: receipt.clock.now) == duration - 1,
                      "Stage start preserves the actual receipt and its remaining time")
            receipt.clock.now += duration
            receipt.actual.expireHUD(event)
            try check(!receipt.actual.isHUDVisible, "the preserved receipt still ends at its own deadline")
        }
        independent.clipboardReceipt.record(outcome: TextDelivery.Outcome(clipboardChangeCount: nil, wasPasted: true), wordCount: 3)
        stageShell.beginStageActivity()
        try check(!independent.clipboardReceipt.actual.isHUDVisible && independent.clipboardReceipt.actual.lifetime == nil,
                  "Stage start does not resurrect a popup after confirmed insertion")
        independent.dismissCaptureFailure()
        try check(independent.captureFailure == nil && (try Data(contentsOf: retainedAudio)) == wav,
                  "explicit Dismiss still clears the result without deleting retained audio")

        let meetingBusy = CaptureHarness(directory: folder("meeting-busy"))
        meetingBusy.meetings.isBusy = true
        meetingBusy.importAudio(folder("unread.wav"))
        try check(meetingBusy.error?.contains("meeting") == true && meetingBusy.engine.calls == 0,
                  "audio import cannot race the meeting recognizer")
        func finish(_ model: CaptureHarness) async { let task = model.transcriptionTask; await task?.value }
        func waitUntil(_ name: String, _ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CheckFailure(description: "Timed out waiting for " + name) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        func waitForEngine(_ model: CaptureHarness) async throws {
            try await waitUntil("fixture engine") { model.engine.continuation != nil }
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
        try check(quitting.meetings.shutdownCount == 1 && quitting.handoffJobs.shutdownCount == 1,
                  "ordinary shutdown forwards cancellation to independent work")
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
        let recoveredID = audioRecovery.captureRecovery.pending!.id
        let extraFile = folder("interrupted").appendingPathComponent("user-note.txt")
        try Data("Keep this sibling".utf8).write(to: extraFile)
        try check(audioRecovery.canRecordAgain && audioRecovery.admitsCapture(), "A fresh recording safely releases failed audio instead of trapping dictation")
        let kept = audioRecovery.captureRecovery.savedRecordingsDirectory.appendingPathComponent(recoveredID.uuidString)
        try check(try Data(contentsOf: kept.appendingPathComponent(interruptedURL.lastPathComponent)) == wav, "Saved recording retains exact audio bytes")
        try check(FileManager.default.fileExists(atPath: kept.appendingPathComponent("pending.json").path)
                  && FileManager.default.fileExists(atPath: kept.appendingPathComponent("user-note.txt").path), "The complete prior journal and unrelated sibling survive")
        try check(audioRecovery.transcript == "Old draft" && audioRecovery.history.isEmpty && !audioRecovery.canRetry && audioRecovery.recordURL == nil, "Keeping failed audio does not change the draft or manufacture a transcript")
        let freshURL = try audioRecovery.makeRecording(wav)
        try check(freshURL != interruptedURL && audioRecovery.captureRecovery.pending?.id != recoveredID, "Next capture owns a fresh journal and audio identity")
        let racing = CaptureHarness(directory: folder("racing-archive")); _ = try racing.makeRecording(wav)
        let altered = Data("changed externally".utf8)
        try altered.write(to: folder("racing-archive").appendingPathComponent("pending.json"))
        try check(!racing.admitsCapture() && racing.hasCaptureRecovery, "Changed metadata refuses archival and remains recoverable")
        try check(try Data(contentsOf: folder("racing-archive").appendingPathComponent("pending.json")) == altered, "Failed archival preserves external metadata")
        let markerOnly = CaptureHarness(directory: folder("marker-only"))
        _ = try markerOnly.captureRecovery.beginRecording()
        let markerID = markerOnly.captureRecovery.pending!.id
        try check(markerOnly.canRecordAgain && markerOnly.admitsCapture(), "A crash before WAV creation can archive its journal and record again")
        try check(FileManager.default.fileExists(atPath: markerOnly.captureRecovery.savedRecordingsDirectory.appendingPathComponent(markerID.uuidString).appendingPathComponent("pending.json").path), "A missing WAV never causes deletion of its recovery marker")
        let collision = CaptureHarness(directory: folder("archive-collision")); let collisionURL = try collision.makeRecording(wav)
        let collisionDestination = collision.captureRecovery.savedRecordingsDirectory.appendingPathComponent(collision.captureRecovery.pending!.id.uuidString)
        try FileManager.default.createDirectory(at: collisionDestination, withIntermediateDirectories: true)
        try check(!collision.admitsCapture() && collision.hasCaptureRecovery && FileManager.default.fileExists(atPath: collisionURL.path), "An existing saved-recording destination is never overwritten")
        let importing = CaptureHarness(directory: folder("import-validation")); let importRecoveryURL = try importing.makeRecording(wav)
        let importRecoveryID = importing.captureRecovery.pending!.id
        let invalidImport = root.appendingPathComponent("invalid.wav"); try Data("not audio".utf8).write(to: invalidImport)
        importing.importAudio(invalidImport)
        try check(importing.captureRecovery.pending?.id == importRecoveryID && FileManager.default.fileExists(atPath: importRecoveryURL.path), "Invalid audio import leaves current retry audio in place")
        importing.importAudio(importRecoveryURL); await finish(importing)
        try check(importing.history.count == 1 && importing.history.first?.id == importRecoveryID && !importing.hasCaptureRecovery, "Importing the current recovery transcribes with its owned identity and never moves the URL first")
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
        TextDelivery.calls = 0
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
        try await waitUntil("delayed delivery") { TextDelivery.continuation != nil }
        try check(TextDelivery.continuation != nil && delivering.store.saved?.history.count == 1, "Delayed delivery begins only after the capture commit")
        delivering.shutdown(); let stoppedStatus = delivering.status
        TextDelivery.release(); await finish(delivering); TextDelivery.delayed = false
        try check(delivering.clipboardReceipt.receipts == 0 && delivering.status == stoppedStatus, "An invalidated delivery cannot publish a late receipt or replace shutdown state")

        FixtureAccessibility.trusted = false
        let untrustedDrawing = CaptureHarness(directory: folder("drawing-untrusted"))
        untrustedDrawing.shouldDeferDelivery = { true }; untrustedDrawing.captureOptions.preferences.delivery = .paste
        let untrustedCalls = TextDelivery.calls
        untrustedDrawing.run(try untrustedDrawing.makeRecording(wav), owned: true); await finish(untrustedDrawing)
        try check(!untrustedDrawing.accessibilityGranted && !untrustedDrawing.waitingForDrawing
                  && !untrustedDrawing.drawingDelivery.isWaiting && TextDelivery.calls == untrustedCalls + 1,
                  "without Accessibility trust, drawing does not defer the copied delivery")
        try check(untrustedDrawing.history.count == 1 && untrustedDrawing.phase == .idle,
                  "untrusted drawing still retains the committed transcript")
        FixtureAccessibility.trusted = true

        // Drawing defers only delivery: the exact production method saves the
        // transcript first and retains its original target, without holding audio.
        TextDelivery.calls = 0; TextDelivery.beforeDelivery = nil
        let drawing = CaptureHarness(directory: folder("drawing"))
        var isDrawing = true
        drawing.shouldDeferDelivery = { isDrawing }
        drawing.captureOptions.preferences.delivery = .paste
        drawing.run(try drawing.makeRecording(wav), owned: true)
        try await waitUntil("drawing delivery") { drawing.drawingDelivery.isWaiting }
        try check(drawing.waitingForDrawing && drawing.drawingDelivery.isWaiting && TextDelivery.calls == 0, "Drawing defers text delivery")
        try check(drawing.history.count == 1 && drawing.store.saved?.history.count == 1 && !drawing.captureRecovery.hasRecovery, "Waiting text is durably saved and owned audio is released")
        drawing.resumeWaitingDelivery()
        try check(drawing.drawingDelivery.isWaiting && TextDelivery.calls == 0, "A stale callback cannot resume while drawing still owns input")
        isDrawing = false; drawing.resumeWaitingDelivery(); await finish(drawing)
        try check(TextDelivery.calls == 1 && TextDelivery.lastMode == .paste && TextDelivery.lastTarget == "Original app target", "Resume checks the original target once through TextDelivery")
        try check(!drawing.waitingForDrawing && drawing.phase == .idle && drawing.history.count == 1, "Deferred success returns idle without another history item")

        let copyDrawing = CaptureHarness(directory: folder("drawing-copy"))
        copyDrawing.shouldDeferDelivery = { true }; copyDrawing.captureOptions.preferences.delivery = .paste
        copyDrawing.run(try copyDrawing.makeRecording(wav), owned: true)
        try await waitUntil("copy while drawing") { copyDrawing.drawingDelivery.isWaiting }
        copyDrawing.copyWaitingDelivery(); await finish(copyDrawing)
        try check(TextDelivery.calls == 2 && TextDelivery.lastMode == .clipboard && !copyDrawing.waitingForDrawing, "Copy now completes without asking drawing to stop")

        let quitDrawing = CaptureHarness(directory: folder("drawing-quit"))
        quitDrawing.shouldDeferDelivery = { true }; quitDrawing.captureOptions.preferences.delivery = .paste
        quitDrawing.run(try quitDrawing.makeRecording(wav), owned: true)
        try await waitUntil("quit while drawing") { quitDrawing.drawingDelivery.isWaiting }
        let waitingTask = quitDrawing.transcriptionTask
        quitDrawing.shutdown(); await waitingTask?.value
        try check(TextDelivery.calls == 2 && !quitDrawing.waitingForDrawing && !quitDrawing.drawingDelivery.isWaiting, "Quit cancels a waiting insertion without delivering or retaining its continuation")
        try check(quitDrawing.store.saved?.history.count == 1, "Quit preserves text already saved before the drawing wait")

        // No speech is routine (#156): a brief cue with the same words for
        // VoiceOver, no failure panel or error, and any recording of ours kept.
        // Failures keep the explicit recovery panel.
        func recording(_ model: CaptureHarness, seconds: Double, peak: Float) throws -> URL {
            let url = try model.makeRecording(wav)
            model.phase = .recording; model.elapsed = seconds; model.peakPower = peak
            return url
        }
        let liveModel = CaptureHarness(directory: folder("live-complete"))
        _ = try recording(liveModel, seconds: 1, peak: -20)
        let liveRecorder = FixtureLiveCapture()
        liveRecorder.checkpoint = LiveVoiceCheckpoint(sessionID: UUID(),
            segments: [.init(source: .microphone, start: 0, end: 1, text: "Live words", isFinal: true)], complete: true)
        liveModel.liveCapture = liveRecorder
        TextDelivery.calls = 0
        liveModel.stopRecording()
        try check(liveModel.phase == .transcribing && TextDelivery.calls == 0, "Stop holds admission and never pastes provisional words")
        try await waitUntil("live completion") { liveModel.phase == .idle }
        try check(liveModel.engine.calls == 0 && liveModel.history.count == 1 && liveModel.rawTranscript == "Live words", "Complete live capture skips batch inference and commits the same original words")
        try check(TextDelivery.calls == 1 && !liveModel.captureRecovery.hasRecovery, "Live capture preserves one final delivery and durable recovery cleanup")

        let fieldModel = CaptureHarness(directory: folder("live-field-complete"))
        let fieldURL = try recording(fieldModel, seconds: 1, peak: -20)
        let fieldRecorder = FixtureLiveCapture(); fieldRecorder.checkpoint = liveRecorder.checkpoint
        let fieldOwner = LiveDictationDelivery(); fieldOwner.attempted = true
        fieldModel.liveCapture = fieldRecorder; fieldModel.liveDictation = fieldOwner
        var fieldCommittedBeforeDelivery = false
        fieldOwner.beforeFinish = {
            fieldCommittedBeforeDelivery = fieldModel.store.saved?.history.count == 1 && FileManager.default.fileExists(atPath: fieldURL.path)
        }
        let pasteCallsBeforeField = TextDelivery.calls
        fieldModel.stopRecording(); try await waitUntil("live field completion") { fieldModel.phase == .idle }
        try check(fieldCommittedBeforeDelivery && fieldOwner.finishCalls == 1 && TextDelivery.calls == pasteCallsBeforeField,
                  "Final live span replacement follows History commit and never calls final paste")
        try check(!fieldModel.captureRecovery.hasRecovery && !FileManager.default.fileExists(atPath: fieldURL.path),
                  "Confirmed live field insertion releases original audio after delivery")

        let fieldFailed = CaptureHarness(directory: folder("live-field-uncertain"))
        let fieldFailedURL = try recording(fieldFailed, seconds: 1, peak: -20)
        let fieldFailedRecorder = FixtureLiveCapture(); fieldFailedRecorder.checkpoint = liveRecorder.checkpoint
        let fieldFailedOwner = LiveDictationDelivery(); fieldFailedOwner.attempted = true
        fieldFailedOwner.outcome = .init(message: "Review the field.", clipboardChangeCount: nil, failure: .pasteUnconfirmed, pasteWasAttempted: true)
        fieldFailed.liveCapture = fieldFailedRecorder; fieldFailed.liveDictation = fieldFailedOwner
        let failedFieldID = fieldFailed.captureRecovery.pending!.id
        fieldFailed.stopRecording(); try await waitUntil("uncertain live field") { fieldFailed.phase == .idle }
        let savedFieldAudio = fieldFailed.captureRecovery.savedRecordingsDirectory.appendingPathComponent(failedFieldID.uuidString).appendingPathComponent(fieldFailedURL.lastPathComponent)
        try check(fieldFailed.history.count == 1 && fieldFailed.unresolvedDelivery?.kind == .pasteUnconfirmed && TextDelivery.calls == pasteCallsBeforeField,
                  "Uncertain live write is saved as review outcome without duplicate paste")
        try check((try Data(contentsOf: savedFieldAudio)) == wav && !fieldFailed.captureRecovery.hasRecovery,
                  "Uncertain live insertion preserves its exact original audio in existing Saved recordings")

        let fieldCancel = CaptureHarness(directory: folder("live-field-cancel-changed"))
        let fieldCancelURL = try recording(fieldCancel, seconds: 1, peak: -20)
        let fieldCancelOwner = LiveDictationDelivery(); fieldCancelOwner.attempted = true
        fieldCancelOwner.cancellationProblem = "Field changed; live text left in place and recording kept."
        fieldCancel.liveDictation = fieldCancelOwner
        fieldCancel.cancelRecording()
        try check(fieldCancelOwner.cancelCalls == 1 && fieldCancel.canRetry && fieldCancel.status == fieldCancelOwner.cancellationProblem
                  && (try Data(contentsOf: fieldCancelURL)) == wav, "Cancel with changed field keeps audio and reports that text remains")

        let partialModel = CaptureHarness(directory: folder("live-partial"))
        _ = try recording(partialModel, seconds: 1, peak: -20)
        let partialRecorder = FixtureLiveCapture()
        partialRecorder.checkpoint = LiveVoiceCheckpoint(sessionID: UUID(), complete: false)
        partialModel.liveCapture = partialRecorder; partialModel.stopRecording()
        try await waitUntil("live fallback") { partialModel.phase == .idle }
        try check(partialModel.engine.calls == 1 && partialModel.history.count == 1, "Incomplete live capture uses the original file instead of publishing partial text")

        let failedLive = CaptureHarness(directory: folder("live-device-failure"))
        let failedLiveURL = try recording(failedLive, seconds: 1, peak: -20)
        let failedRecorder = FixtureLiveCapture(); failedRecorder.failure = "Synthetic microphone unavailable"
        failedLive.liveCapture = failedRecorder
        let deliveredBeforeFailure = TextDelivery.calls
        failedLive.stopRecording()
        try await waitUntil("live device failure") { failedLive.phase == .idle }
        try check(failedLive.canRetry && failedLive.hasCaptureRecovery && failedLive.history.isEmpty && TextDelivery.calls == deliveredBeforeFailure
                  && (try Data(contentsOf: failedLiveURL)) == wav, "Unrecoverable device loss preserves original audio and cannot silently deliver a partial dictation")

        let cancelLive = CaptureHarness(directory: folder("live-cancel-finishing"))
        _ = try recording(cancelLive, seconds: 1, peak: -20)
        let heldRecorder = FixtureLiveCapture(); heldRecorder.hold = true
        cancelLive.liveCapture = heldRecorder; cancelLive.stopRecording()
        try await waitUntil("live finish held") { heldRecorder.continuation != nil }
        let previousDeliveries = TextDelivery.calls
        cancelLive.cancelCurrentCapture()
        heldRecorder.continuation?.resume(); heldRecorder.continuation = nil
        try await waitUntil("cancel live finish") { cancelLive.phase == .idle }
        try check(cancelLive.history.isEmpty && TextDelivery.calls == previousDeliveries && !cancelLive.captureRecovery.hasRecovery,
                  "Cancellation during the final window cannot save or deliver late words")
        var announced: [String] = []
        let tap = CaptureHarness(directory: folder("no-speech-tap")); tap.announceForAccessibility = { announced.append($0) }
        let tapURL = try recording(tap, seconds: 0.2, peak: -20)
        tap.stopRecording()
        try check(tap.captureCue?.reason == .tooShort && tap.captureFailure == nil && tap.error == nil && tap.phase == .idle
                  && !tap.canRetry && tap.engine.calls == 0, "An accidental tap is a routine cue, not a failure")
        try check(announced == ["No speech heard"] && tap.captureCue?.message == "No speech heard", "VoiceOver hears the cue's own words, once")
        try check(!FileManager.default.fileExists(atPath: tapURL.path) && !tap.captureRecovery.hasRecovery, "A tap keeps nothing, as before")
        let hush = CaptureHarness(directory: folder("no-speech-quiet")); hush.announceForAccessibility = { _ in }
        _ = try recording(hush, seconds: 3, peak: -70)
        hush.stopRecording()
        try check(hush.captureCue?.reason == .tooQuiet && hush.captureFailure == nil && hush.error == nil && hush.status.contains("Sound"),
                  "Silence is a routine cue, with the microphone hint in the status")
        // A second silent capture in a row points at the microphone, not a pause.
        _ = try recording(hush, seconds: 3, peak: -70)
        hush.stopRecording()
        try check(hush.captureCue == nil && hush.captureFailure?.contains("twice in a row") == true && hush.error != nil,
                  "A second silent capture in a row gets the explicit panel with where to look")
        _ = try recording(hush, seconds: 3, peak: -70)
        hush.stopRecording()
        try check(hush.captureCue?.reason == .tooQuiet && hush.captureFailure == nil,
                  "After that panel the count starts again, so the next silence is a cue")

        let nothing = CaptureHarness(directory: folder("no-speech-recognised")); nothing.announceForAccessibility = { _ in }
        nothing.engine.result = ""
        let nothingURL = try nothing.makeRecording(wav)
        nothing.run(nothingURL, owned: true); await finish(nothing)
        try check(nothing.captureCue?.reason == .nothingRecognised(keptAudio: true) && nothing.captureFailure == nil && nothing.error == nil
                  && nothing.phase == .idle && nothing.history.isEmpty, "Sound that came back as no words is a routine cue, not a failure")
        try check(nothing.canRetry && nothing.retryCaptureLabel == "Retry transcription" && (try Data(contentsOf: nothingURL)) == wav,
                  "Its recording is kept exactly, with Retry on the Dictate page")
        nothing.dismissCaptureCue()
        try check(nothing.captureCue == nil && nothing.canRetry && FileManager.default.fileExists(atPath: nothingURL.path),
                  "Dismissing the cue keeps the recording and its Retry")
        nothing.engine.result = "um synthetic captured words"
        nothing.destination = "An old paste destination"
        TextDelivery.lastTarget = "unset"
        nothing.retryTranscription(); await finish(nothing)
        try check(nothing.history.count == 1 && TextDelivery.lastTarget == nil, "Retry after no speech never reuses an old paste destination")

        let again = CaptureHarness(directory: folder("no-speech-again")); again.announceForAccessibility = { _ in }
        again.engine.result = ""
        let againURL = try again.makeRecording(wav)
        again.run(againURL, owned: true); await finish(again)
        let keptID = again.captureRecovery.pending!.id
        try check(again.canRecordAgain && again.admitsCapture(), "A new capture after no speech is admitted")
        let keptFolder = again.captureRecovery.savedRecordingsDirectory.appendingPathComponent(keptID.uuidString)
        try check((try Data(contentsOf: keptFolder.appendingPathComponent(againURL.lastPathComponent))) == wav,
                  "The kept recording moves to Saved recordings instead of being discarded")

        let expiring = CaptureHarness(directory: folder("no-speech-expiry")); expiring.announceForAccessibility = { _ in }
        _ = try recording(expiring, seconds: 0.1, peak: -20); expiring.stopRecording()
        let held = CaptureHarness(directory: folder("no-speech-held")); held.announceForAccessibility = { _ in }
        _ = try recording(held, seconds: 0.1, peak: -20); held.stopRecording()
        held.holdCaptureCue(true)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try check(expiring.captureCue == nil, "The cue goes by itself within two seconds")
        try check(held.captureCue != nil, "A hovered cue stays")
        held.holdCaptureCue(false)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try check(held.captureCue == nil, "Letting go of the cue lets it go")

        let replaced = CaptureHarness(directory: folder("no-speech-replaced")); replaced.announceForAccessibility = { _ in }
        _ = try recording(replaced, seconds: 0.1, peak: -20); replaced.stopRecording()
        replaced.run(try replaced.makeRecording(wav), owned: true)
        try check(replaced.captureCue == nil, "A new transcription takes the surface from a cue still showing")
        await finish(replaced)

        let broken = CaptureHarness(directory: folder("engine-failed")); broken.announceForAccessibility = { _ in }
        broken.engine.failure = FixtureFailure.write
        let brokenURL = try broken.makeRecording(wav)
        broken.run(brokenURL, owned: true); await finish(broken)
        try check(broken.captureFailure?.hasPrefix("Transcription failed") == true && broken.captureCue == nil && broken.canRetry
                  && FileManager.default.fileExists(atPath: brokenURL.path), "An engine failure keeps the explicit recovery panel with Retry")

        let shortcutSilence = CaptureHarness(directory: folder("no-speech-shortcut")); shortcutSilence.announceForAccessibility = { _ in }
        shortcutSilence.engine.result = ""
        var silenceReplies: [String] = []
        try shortcutSilence.shortcutRequest.begin(id: UUID()) { result in
            if case .failure(let error) = result { silenceReplies.append(error.localizedDescription) } else { silenceReplies.append("success") }
        }
        shortcutSilence.run(importedURL, owned: false); await finish(shortcutSilence)
        try check(silenceReplies == ["No speech heard."] && shortcutSilence.captureCue == nil && shortcutSilence.captureFailure == nil
                  && !shortcutSilence.canRetry, "Shortcuts get one No speech heard reply and no floating cue; an imported file is never kept")

        // The hold lesson (#134 T5): only a press of the Dictate shortcut in Hold,
        // whose recorder started, let go before the shortest speech and ending
        // too short, asks for the coach, which replaces that attempt's cue. The
        // lesson is spent only when a host shows it. Everything else keeps #156.
        func tips(_ name: String) -> CoachTips { CoachTips(defaults: UserDefaults(suiteName: folder("tips-" + name).path)!) }
        func holdTap(_ model: CaptureHarness, down: TimeInterval = 50, up: TimeInterval = 50.2, audio: Double = 0.15, peak: Float = -20) throws {
            model.shortcutChanged(down: true, at: down)
            try model.recorderStarted(audio: audio, peak: peak, wav: wav)
            model.shortcutChanged(down: false, at: up)
        }
        let lessons = tips("lesson")
        let taught = CaptureHarness(directory: folder("hold-lesson"), tips: lessons)
        taught.coach.canPresent = { true }
        try holdTap(taught)
        let lesson = taught.coach.card
        try check(lesson?.title == "Hold ⌥V to dictate." && lesson?.body == "Keep holding while you speak. Release to finish."
                  && taught.captureCue == nil && taught.captureFailure == nil && taught.phase == .idle,
                  "a too-short press of the shortcut in Hold asks for the lesson in place of the cue")
        try check(!lessons.isRetired(HoldLesson.tip), "asking is not showing: the lesson is not spent yet")
        taught.coach.didPresent(lesson!.id)
        try check(lessons.isRetired(HoldLesson.tip) && taught.coach.isPresented, "shown by the host, the lesson is spent")
        try holdTap(taught, down: 60, up: 60.1)
        try check(taught.coach.card == nil && taught.captureCue?.reason == .tooShort, "a new capture removes it; the next short press gets #156's cue, not the lesson again")
        let relaunched = CaptureHarness(directory: folder("hold-lesson-relaunch"), tips: tips("lesson"))
        relaunched.coach.canPresent = { true }
        relaunched.preferences.dictationShortcut.label = "⌃⌥Space"
        try holdTap(relaunched)
        try check(relaunched.coach.card == nil && relaunched.captureCue?.reason == .tooShort, "relaunch and a new binding keep the lesson taught")

        let rebound = CaptureHarness(directory: folder("hold-lesson-rebound"), tips: tips("rebound"))
        rebound.coach.canPresent = { true }
        rebound.preferences.dictationShortcut.label = "⌃⌥Space"
        try holdTap(rebound)
        try check(rebound.coach.card?.title == "Hold ⌃⌥Space to dictate.", "the lesson names the shortcut as it is saved now")

        let noHost = tips("no-host")
        let hostless = CaptureHarness(directory: folder("hold-lesson-no-host"), tips: noHost)
        try holdTap(hostless)
        try check(hostless.coach.card == nil && hostless.captureCue?.reason == .tooShort && !noHost.isRetired(HoldLesson.tip),
                  "with no host to show it, the cue shows and the lesson waits")
        hostless.coach.canPresent = { true }
        try holdTap(hostless, down: 70, up: 70.1)
        try check(hostless.coach.card != nil, "the next qualifying press can be taught")
        hostless.coach.drop(hostless.coach.card!.id)
        try check(!noHost.isRetired(HoldLesson.tip), "a blocked presentation does not spend it")

        func neverTeaches(_ name: String, _ description: String, _ act: (CaptureHarness) throws -> Void) throws {
            let unspent = tips(name)
            let model = CaptureHarness(directory: folder("never-" + name), tips: unspent)
            model.coach.canPresent = { true }
            try act(model)
            try check(model.coach.card == nil && !unspent.isRetired(HoldLesson.tip), description + " never teaches the hold")
        }
        try neverTeaches("toggle", "Toggle") { model in
            model.preferences.capture = .toggle
            model.shortcutChanged(down: true, at: 1)
            try model.recorderStarted(audio: 0.1, peak: -20, wav: wav)
            model.shortcutChanged(down: false, at: 1.05)
            model.shortcutChanged(down: true, at: 1.1)
            try check(model.captureCue?.reason == .tooShort, "a short Toggle press keeps #156's cue")
        }
        try neverTeaches("click", "a click on the recording button") { model in
            model.toggleRecording()
            try model.recorderStarted(audio: 0.1, peak: -20, wav: wav)
            model.stopRecording()
            try check(model.captureCue?.reason == .tooShort, "a short click-started capture keeps #156's cue")
        }
        try neverTeaches("denied", "a permission or start failure") { model in
            model.shortcutChanged(down: true, at: 1)
            model.fail("Microphone access is off.")
            model.shortcutChanged(down: false, at: 1.1)
            try check(model.captureCue == nil && model.error == "Microphone access is off.", "a failed start keeps its own explanation")
        }
        try neverTeaches("cancel-requesting", "a release before the recorder started") { model in
            model.shortcutChanged(down: true, at: 1)
            model.shortcutChanged(down: false, at: 1.1)
            try check(model.phase == .idle && model.captureCue == nil, "releasing while the recorder starts cancels quietly")
        }
        try neverTeaches("cancel-recording", "an explicit cancel") { model in
            model.shortcutChanged(down: true, at: 1)
            try model.recorderStarted(audio: 0.1, peak: -20, wav: wav)
            model.cancelCurrentCapture()
            model.shortcutChanged(down: false, at: 1.1)
            try check(model.phase == .idle && model.captureCue == nil && model.status == "Recording discarded.", "Cancel discards and teaches nothing")
        }
        try neverTeaches("silent", "a genuine hold that heard only silence") { model in
            try holdTap(model, down: 1, up: 4, audio: 3, peak: -70)
            try check(model.captureCue?.reason == .tooQuiet, "a silent hold keeps #156's cue")
        }
        try neverTeaches("slow-start", "a long hold whose recorder started late") { model in
            try holdTap(model, down: 1, up: 2, audio: 0.2)
            try check(model.captureCue?.reason == .tooShort, "a slow start is judged by the key, and keeps #156's cue")
        }

        let learned = tips("learned")
        let fluent = CaptureHarness(directory: folder("hold-success"), tips: learned)
        fluent.coach.canPresent = { true }
        fluent.shortcutChanged(down: true, at: 1)
        try fluent.recorderStarted(audio: 1.2, peak: -20, wav: wav)
        fluent.shortcutChanged(down: false, at: 2.2); await finish(fluent)
        try check(fluent.history.count == 1 && learned.isRetired(HoldLesson.tip), "a hold that produced words retires the lesson")
        try holdTap(fluent, down: 10, up: 10.1)
        try check(fluent.coach.card == nil && fluent.captureCue?.reason == .tooShort, "after a successful hold a later tap is never taught")

        // An undelivered result stays with its owner (#134 T5). The receipt going,
        // its clear() on a new or retried capture, and teardown cannot resolve it;
        // the same words delivered again, or Dismiss, does. The inventories are
        // read from AppModel.swift: every member that clears or hides the receipt,
        // and every member that changes the undelivered result.
        let clearCallSites: Set<String> = __CLEAR_CALL_SITES__
        try check(clearCallSites == ["receiveReadingSelection", "toggleRecording", "transcribe", "cleanCurrentDraft", "shutdown"],
                  "every member that clears or hides the receipt is known: \(clearCallSites.sorted())")
        let writers: Set<String> = __UNDELIVERED_WRITERS__
        try check(writers == ["init", "transcribe", "copyTextWithReceipt", "dismissUnresolvedDelivery", "removeTranscript"],
                  "only delivery, a copy, Dismiss, removing its transcript and launch change the undelivered result: \(writers.sorted())")
        try check(clearCallSites.intersection(writers) == ["transcribe"],
                  "of those that clear the receipt, only transcribe also changes the result, and only by its own delivery (checked below)")
        let undelivered = CaptureHarness(directory: folder("undelivered"))
        TextDelivery.nextOutcome = TextDelivery.Outcome(message: "Could not copy.", clipboardChangeCount: nil, failure: .copyFailed)
        undelivered.run(try undelivered.makeRecording(wav), owned: true); await finish(undelivered)
        let failedID = undelivered.history.first?.id
        try check(undelivered.unresolvedDelivery?.kind == .copyFailed && undelivered.unresolvedDelivery?.reference == failedID.map { .transcript($0) }
                  && undelivered.unresolvedDelivery?.offersCopy == true, "a failed copy is kept with its transcript in History")
        TextDelivery.nextOutcome = TextDelivery.Outcome()
        undelivered.toggleRecording()
        try check(undelivered.unresolvedDelivery?.kind == .copyFailed, "a new capture (toggleRecording's clear) does not resolve it")
        undelivered.cancelRecording()
        undelivered.engine.result = "um different words entirely"
        undelivered.run(try undelivered.makeRecording(wav), owned: true); await finish(undelivered)
        undelivered.engine.result = "um synthetic captured words"
        try check(undelivered.history.count == 2 && undelivered.unresolvedDelivery?.reference == failedID.map { .transcript($0) },
                  "a later transcription (transcribe's clear) and its successful delivery of other words do not resolve an older result")
        undelivered.shutdown()
        try check(undelivered.unresolvedDelivery?.kind == .copyFailed, "teardown (shutdown's clear) leaves it for its canonical record")
        let quitState = undelivered.store.saved
        try check(quitState?.undelivered?.kind == .copyFailed && quitState?.undelivered?.reference == failedID.map { .transcript($0) },
                  "quit saves it with the session, naming its transcript")
        let afterQuit = CaptureHarness(directory: folder("undelivered-relaunch"), state: quitState)
        try check(afterQuit.unresolvedDelivery?.kind == .copyFailed && afterQuit.unresolvedDelivery?.offersCopy == true,
                  "relaunch shows it on the shelf, with Copy again")
        let beforeReview = afterQuit.transcript
        afterQuit.reviewUnresolvedDelivery()
        try check(afterQuit.page == "history" && afterQuit.historyDoor?.transcript == failedID
                  && afterQuit.historyDoor?.filter == .all && afterQuit.transcript == beforeReview
                  && afterQuit.unresolvedDelivery != nil, "durable Review opens the exact failed result without replacing the draft or resolving delivery")
        let copiesBefore = TextDelivery.copies.count
        afterQuit.copyUnresolvedDelivery()
        try check(TextDelivery.copies.count == copiesBefore + 1 && TextDelivery.copies.last == afterQuit.history.first(where: { $0.id == failedID })?.text
                  && afterQuit.unresolvedDelivery == nil, "Copy again copies those exact words, and only then is it resolved")
        afterQuit.saveNow()
        try check(afterQuit.store.saved?.undelivered == nil && afterQuit.store.saved?.history.count == 2, "once resolved, the next save carries nothing undelivered")

        // The words decide: the same words copied from the draft resolve a transcript's unconfirmed paste.
        let uncertain = CaptureHarness(directory: folder("uncertain"))
        TextDelivery.nextOutcome = TextDelivery.Outcome(message: "Paste sent · insertion could not be confirmed.", failure: .pasteUnconfirmed, pasteWasAttempted: true)
        uncertain.run(try uncertain.makeRecording(wav), owned: true); await finish(uncertain)
        TextDelivery.nextOutcome = TextDelivery.Outcome()
        let uncertainCopies = TextDelivery.copies.count
        uncertain.copyUnresolvedDelivery()
        try check(uncertain.unresolvedDelivery?.kind == .pasteUnconfirmed && TextDelivery.copies.count == uncertainCopies,
                  "an unconfirmed paste offers no second copy to paste, and stays until the person decides")
        try check(uncertain.transcript == uncertain.history.first?.text, "the dictation left the same words in the draft")
        uncertain.copyTranscript()
        try check(uncertain.unresolvedDelivery == nil, "copying those same words from the draft resolves it")
        TextDelivery.nextOutcome = TextDelivery.Outcome(message: "Paste sent · insertion could not be confirmed.", failure: .pasteUnconfirmed, pasteWasAttempted: true)
        uncertain.run(try uncertain.makeRecording(wav), owned: true); await finish(uncertain)
        TextDelivery.nextOutcome = TextDelivery.Outcome()
        uncertain.dismissUnresolvedDelivery()
        try check(uncertain.unresolvedDelivery == nil && uncertain.history.count == 2, "Dismiss sets it aside; the transcript stays in History")

        // Removing its transcript is the person's choice: the result goes with it, and is not saved.
        let removing = CaptureHarness(directory: folder("undelivered-removed"))
        TextDelivery.nextOutcome = TextDelivery.Outcome(message: "Could not copy.", clipboardChangeCount: nil, failure: .copyFailed)
        removing.run(try removing.makeRecording(wav), owned: true); await finish(removing)
        TextDelivery.nextOutcome = TextDelivery.Outcome()
        let removed = removing.history.first!
        removing.store.fails = true
        removing.removeTranscript(removed)
        try check(removing.history.first?.id == removed.id && removing.meetings.removedTranscripts.isEmpty,
                  "failed transcript-only removal keeps History and the meeting completion link")
        removing.store.fails = false
        removing.removeTranscript(removed)
        try check(removing.history.isEmpty && removing.unresolvedDelivery == nil && removing.undelivered.entry == nil
                  && removing.store.saved?.undelivered == nil && removing.store.saved?.history.isEmpty == true,
                  "removing its transcript drops it, from memory and from the saved session")
        try check(removing.meetings.removedTranscripts == [removed.id],
                  "successful transcript-only removal invalidates exactly its meeting completion link")

        // A draft entry acts only while the draft is the one that failed.
        let draft = CaptureHarness(directory: folder("draft-copy"))
        TextDelivery.copyFails = true
        draft.copyTranscript()
        TextDelivery.copyFails = false
        try check(draft.unresolvedDelivery?.kind == .copyFailed && draft.unresolvedDelivery?.isDraft == true, "a failed copy of the draft is kept too")
        draft.saveNow()
        try check(draft.store.saved?.undelivered?.isDraft == true && draft.store.saved?.draft == "Old draft", "a save carries a draft entry with the draft it names")
        draft.run(try draft.makeRecording(wav), owned: true); await finish(draft)
        let changedDraft = draft.unresolvedDelivery
        try check(draft.transcript == "Synthetic captured words." && changedDraft?.draftChanged == true && changedDraft?.offersCopy == false,
                  "a new dictation replaced the draft: the shelf says the draft changed and offers Review, not Copy again")
        draft.reviewUnresolvedDelivery()
        try check(draft.page == "dictate" && draft.transcript == "Synthetic captured words."
                  && draft.unresolvedDelivery == changedDraft, "Review of a changed draft opens Dictate without replacing or copying it")
        let copiesAfterChange = TextDelivery.copies.count
        draft.copyUnresolvedDelivery()
        try check(TextDelivery.copies.count == copiesAfterChange && draft.unresolvedDelivery != nil, "Copy again never copies whatever the draft became")
        draft.saveNow()
        try check(draft.store.saved?.undelivered == nil, "a save after the draft changed carries nothing undelivered, so relaunch drops it")
        draft.dismissUnresolvedDelivery()
        TextDelivery.copyFails = true
        draft.copyTranscript()
        TextDelivery.copyFails = false
        draft.copyTranscript()
        try check(draft.unresolvedDelivery == nil, "copying the unchanged draft again resolves it")

        // T4's fallback: a lesson the host drops after asking gives this attempt's cue after all.
        let dropped = CaptureHarness(directory: folder("hold-lesson-dropped"), tips: tips("dropped"))
        dropped.coach.canPresent = { true }
        try holdTap(dropped)
        let pending = dropped.coach.card
        try check(pending != nil && dropped.captureCue == nil, "the lesson was asked for in place of the cue")
        dropped.coach.drop(pending!.id)
        try check(dropped.coach.card == nil && dropped.captureCue?.reason == .tooShort && dropped.status == "No speech heard. Nothing was added."
                  && !dropped.coach.tips.isRetired(HoldLesson.tip), "a card the host drops gives the cue after all; the attempt never shows neither")
        dropped.dismissCaptureCue()
        try holdTap(dropped, down: 80, up: 80.1)
        dropped.coach.didPresent(dropped.coach.card!.id)
        dropped.coach.drop(dropped.coach.card!.id)
        try check(dropped.captureCue == nil && dropped.coach.card != nil, "a card the host showed is never followed by the cue")
        let superseded = CaptureHarness(directory: folder("hold-lesson-superseded"), tips: tips("superseded"))
        superseded.coach.canPresent = { true }
        try holdTap(superseded)
        let stalePending = superseded.coach.card!.id
        superseded.toggleRecording()
        superseded.coach.drop(stalePending)
        try check(superseded.captureCue == nil && superseded.phase != .idle, "a newer capture removes the pending card; a late drop shows no cue over it")
        superseded.cancelRecording()
        // A speech model that could not be prepared is Home's problem, beside its Retry model: the
        // page is recorded where it is raised, so the menu-bar panel opens Home. Guessing from the
        // words opened Dictate (#134 review).
        let unprepared = CaptureHarness(directory: folder("model-preparation"))
        unprepared.ready = false
        unprepared.engine.prepareFailure = CheckFailure(description: "Synthetic model download failure")
        await unprepared.prepare()
        try check(unprepared.attention?.page == .home && unprepared.error?.hasPrefix("Could not prepare the speech model.") == true
                  && unprepared.modelMessage == "The speech model couldn’t be prepared" && !unprepared.ready && !unprepared.preparing,
                  "A model that could not be prepared is Home's problem, where Retry model is")
        try check(unprepared.modelFailure != nil, "Settings › Models keeps the reason beside Try download again")
        unprepared.engine.prepareFailure = nil
        await unprepared.prepare()
        try check(unprepared.ready && unprepared.modelMessage == "Fixture model ready" && unprepared.modelFailure == nil,
                  "Retry model prepares it and clears the reason")

        // A refusal is shown where the person acted (1 October audit, finding 7). The Dictate page's
        // mic: the reason is Dictate's, whose banner is beside that mic, and the capture HUD's.
        let refusedStart = CaptureHarness(directory: folder("start-refused"))
        let meetingWait = "Finish the meeting recording or transcription before starting Dictate."
        refusedStart.microphoneStartFailure = { _ in meetingWait }
        refusedStart.page = "dictate"
        refusedStart.toggleRecording()
        try check(refusedStart.phase == .idle && refusedStart.recordingAttempt == nil && refusedStart.startedAttempts.isEmpty
                  && refusedStart.captureFailure == meetingWait && refusedStart.attention == Attention(message: meetingWait, page: .dictate),
                  "A start the Dictate page's mic cannot make is reported on Dictate: \(String(describing: refusedStart.attention))")
        // History's Open while Dictate is busy says why on History and changes nothing; once Dictate
        // is idle, Open goes ahead and takes that wait away, since History's notice has no Dismiss.
        let busyOpen = CaptureHarness(directory: folder("history-open-busy"))
        let saved = Transcript(text: "Saved words from History", seconds: 2)
        busyOpen.openHistory()
        busyOpen.toggleRecording()
        try check(busyOpen.phase == .requesting, "Dictate is busy")
        busyOpen.openTranscript(saved)
        try check(busyOpen.page == "history" && busyOpen.pendingTranscript == nil && busyOpen.transcript == "Old draft"
                  && busyOpen.attention == Attention(message: "Finish the current dictation or processing before replacing its draft.", page: .history),
                  "History's Open while Dictate is busy is refused on History: \(String(describing: busyOpen.attention))")
        busyOpen.cancelRecording()
        busyOpen.openTranscript(saved)
        try check(busyOpen.page == "dictate" && busyOpen.pendingTranscript?.id == saved.id && busyOpen.transcript == "Old draft" && busyOpen.attention == nil,
                  "Open goes ahead once Dictate is idle, behind Keep or Replace, and History's wait goes")

        print("CAPTURE_PERSISTENCE_CHECKS_OK: \(assertions) checks; exact AppModel capture methods, real recovery files, synthetic audio, injected recognition/delivery/state writes")
    }
}
'''
values = '\n'.join([core.imports(), core.extract(['VoiceError', 'SavedState', 'extension SavedState']),
                    SwiftFile(PROJECT / 'Sources/LocalVoice/HistoryView.swift').extract(['HistoryFilter', 'HistoryDoor'])])
fixture = fixture.replace('__CLEAR_CALL_SITES__', '[' + ', '.join('"%s"' % site for site in sorted(clear_sites)) + ']')
fixture = fixture.replace('__UNDELIVERED_WRITERS__', '[' + ', '.join('"%s"' % site for site in sorted(writers)) + ']')
fixture = fixture.replace('__STAGE_START__', stage_start)
# Expose only the destination's access level to the fixture; keep its actual observer body.
fixture = fixture.replace('__LIFECYCLE_PROPERTIES__', model.extract(['phase', 'destination', 'insertionContext']).replace('private var destination', 'var destination'))
fixture = fixture.replace('__VALUES__', values).replace('__REQUEST__', request).replace('__LABELS__', labels).replace('__METHODS__', methods)
with tempfile.TemporaryDirectory(prefix='workbench-capture-persistence-') as temporary:
    directory = Path(temporary)
    swift = directory / 'CapturePersistenceChecks.swift'; swift.write_text(fixture)
    executable = directory / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(directory / 'ModuleCache'),
                    str(swift), str(PROJECT / 'Sources/LocalVoice/TextPrimitives.swift'), str(PROJECT / 'Sources/LocalVoice/CaptureRecovery.swift'), str(PROJECT / 'Sources/LocalVoice/DrawingDeliveryGate.swift'),
                    str(PROJECT / 'Sources/LocalVoice/CaptureCue.swift'), str(PROJECT / 'Sources/LocalVoice/Attention.swift'), str(PROJECT / 'Sources/LocalVoice/LiveVoiceSession.swift'),
                    str(PROJECT / 'Sources/LocalVoice/NoticeLifetime.swift'), str(PROJECT / 'Sources/LocalVoice/FeedbackCoach.swift'),
                    str(PROJECT / 'Sources/LocalVoice/DeliveryOutcome.swift'), str(PROJECT / 'Sources/LocalVoice/ClipboardReceipt.swift'),
                    str(PROJECT / 'Sources/LocalVoice/InsertionBoundary.swift'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(directory / 'data')], check=True)
print('AppModel.swift SHA256:', hashlib.sha256(app_model.source.encode()).hexdigest())
