#!/usr/bin/env python3
"""Exercise the exact correction transactions with production rules and value types.

Only StateStore is replaced: an in-memory fixture can fail before saving. No
AppModel initialization, user state, clipboard, models or UI are accessed.
"""

import hashlib
from pathlib import Path
import subprocess
import tempfile
import time


PROJECT = Path(__file__).resolve().parents[1]
source = (PROJECT / "Sources/LocalVoice/AppModel.swift").read_text()
core = (PROJECT / "Sources/LocalVoice/Core.swift").read_text()


def extract(start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin)].rstrip()


methods = "\n".join([
    extract("    func rememberCorrection(", "\n    func removeTranscript("),
    extract("    func persist()", "\n    func shutdown()"),
])
names = ["rawTranscript", "cleanupMethod", "phase", "status", "error", "transcript",
         "speechText", "history", "replacements", "rememberedCorrection", "voice", "rate"]
properties = "\n".join(next(line for line in source.splitlines()
                             if "@Published" in line and f" var {name}" in line
                             and line.split(f" var {name}", 1)[1][:1] in [" ", ":"])
                       for name in names)
values = core[:core.index("struct StateStore {")]

fixture = r'''
import Foundation
import Combine

enum StoreFailure: Error { case simulated }
@MainActor final class StateStore {
    var saved: SavedState?
    var attempts = 0
    var fails = false
    var beforeSave: ((SavedState) throws -> Void)?
    func save(_ state: SavedState) throws {
        attempts += 1
        try beforeSave?(state)
        if fails { throw StoreFailure.simulated }
        saved = state
    }
}
@MainActor final class AppModelCorrectionHarness {
    enum Phase: String { case idle, requesting, recording, transcribing, cleaning, delivering, cancelling }
    var loaded = false
    var draftRevision: UInt64 = 0
    var persistWork: DispatchWorkItem?
    let store = StateStore()
    /// History's observer records the first dictation for Home (#15); corrections never depend on it.
    func recordFirstDictation() {}
    __EXACT_PROPERTIES__
    init(draft: String = " \ngit hub and cat.\t ", rules: [Replacement] = []) {
        transcript = draft
        rawTranscript = "Untouched recognition original"
        cleanupMethod = "Prior cleanup method"
        speechText = "Separate reading text"
        history = [Transcript(text: "Earlier capture", seconds: 2.5, rawText: "Earlier original", cleanupMethod: "Original")]
        replacements = rules
        voice = "Fixture voice"; rate = 195
        status = "Before correction"
        loaded = true
    }
    __EXACT_METHODS__
}

struct ReceiptSnapshot: Equatable {
    let written: String
    let beforeRules: [Replacement]
    let afterRules: [Replacement]
    let beforeDraft: String
    let afterDraft: String
    let revision: UInt64
    init(_ receipt: RememberedCorrection) {
        written = receipt.written; beforeRules = receipt.beforeRules; afterRules = receipt.afterRules
        beforeDraft = receipt.beforeDraft; afterDraft = receipt.afterDraft; revision = receipt.appliedRevision
    }
}
struct Snapshot: Equatable {
    let session: Data
    let method: String
    let status: String
    let error: String?
    let phase: String
    let revision: UInt64
    let receipt: ReceiptSnapshot?
    @MainActor init(_ model: AppModelCorrectionHarness) throws {
        session = try encoded(SavedState(draft: model.transcript, speechText: model.speechText, history: model.history,
            replacements: model.replacements, voice: model.voice, rate: model.rate, rawDraft: model.rawTranscript))
        method = model.cleanupMethod; status = model.status; error = model.error; phase = model.phase.rawValue
        revision = model.draftRevision; receipt = model.rememberedCorrection.map(ReceiptSnapshot.init)
    }
}
func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
struct CheckFailure: Error, CustomStringConvertible { let description: String }

@main struct Checks {
    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("REMEMBER_CORRECTION_CHECK_FAILED: \(error)\n".utf8))
            exit(1)
        }
    }
    @MainActor static func run() throws {
        let start = Date()
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw CheckFailure(description: name) }
            count += 1
        }
        func rejects(_ name: String, _ action: () throws -> Void) throws {
            var rejected = false
            do { try action() } catch { rejected = true }
            try check(rejected, name)
        }
        func remember(_ model: AppModelCorrectionHarness, heard: String = "git hub", written: String = "GitHub") throws {
            try model.rememberCorrection(heard: heard, written: written, expectedDraft: model.transcript)
        }

        let unrelated = Replacement(heard: "alpha", written: "A")
        let success = AppModelCorrectionHarness(rules: [unrelated])
        let before = try Snapshot(success)
        let history = try encoded(success.history)
        success.store.beforeSave = { _ in
            try check(try Snapshot(success) == before, "Save must happen before any draft, dictionary or receipt mutation")
        }
        try remember(success)
        success.store.beforeSave = nil
        try check(success.transcript == " \nGitHub and cat.\t ", "Successful correction must preserve surrounding draft whitespace")
        try check(success.rawTranscript == "Untouched recognition original" && success.cleanupMethod == "Prior cleanup method"
                  && (try encoded(success.history)) == history && (try encoded(success.store.saved?.history ?? [])) == history,
                  "Correction must retain recognition original, method and historical captures in memory and storage")
        try check(success.replacements.count == 2 && success.replacements[0] == unrelated, "Transaction must add exactly one rule without changing unrelated rules")
        try check(success.store.saved?.draft == success.transcript && success.store.saved?.replacements == success.replacements
                  && success.store.saved?.rawDraft == success.rawTranscript, "Persisted session must match the published correction")
        try check(success.store.saved?.speechText == success.speechText && success.store.saved?.voice == success.voice
                  && success.store.saved?.rate == success.rate, "Correction save must retain separate reading settings")
        try check(success.rememberedCorrection?.beforeDraft == " \ngit hub and cat.\t "
                  && success.rememberedCorrection?.afterDraft == success.transcript, "Undo receipt must contain the actual before and after draft")
        try check(TextRules.apply("Next GIT HUB capture", replacements: success.store.saved!.replacements) == "Next GitHub capture",
                  "Subsequent transcription must observe the saved correction")

        // A failed second correction must retain the previous usable undo receipt.
        let failedBefore = try Snapshot(success)
        let savedBefore = try encoded(success.store.saved)
        let pendingBefore = success.persistWork
        success.store.fails = true
        try rejects("A failed correction save must be reported") { try remember(success, heard: "cat", written: "kitten") }
        try check(try Snapshot(success) == failedBefore && encoded(success.store.saved) == savedBefore,
                  "Failed save must leave all published and stored state unchanged, including the existing receipt")
        try check(success.persistWork === pendingBefore && pendingBefore?.isCancelled == false, "Failed save must not cancel pending autosave")
        success.store.fails = false
        try remember(success, heard: "cat", written: "kitten")
        try check(success.transcript == " \nGitHub and kitten.\t " && success.replacements.count == 3,
                  "Retry after save failure must succeed once without adding duplicates")

        let noOpBefore = try Snapshot(success)
        let noOpWrites = success.store.attempts
        try remember(success, heard: "cat", written: "kitten")
        try check(try Snapshot(success) == noOpBefore && success.store.attempts == noOpWrites,
                  "Already-remembered rule with an unchanged draft must be a complete no-op")
        try rejects("Stale sheet draft must be rejected") {
            try success.rememberCorrection(heard: "cat", written: "kitten", expectedDraft: "Older draft")
        }
        try check(try Snapshot(success) == noOpBefore && success.store.attempts == noOpWrites, "Stale sheet rejection must not save or mutate")

        for phase in [AppModelCorrectionHarness.Phase.requesting, .recording, .transcribing, .cleaning, .delivering, .cancelling] {
            let busy = AppModelCorrectionHarness(); busy.phase = phase
            let snapshot = try Snapshot(busy)
            try rejects("Remember correction must reject \(phase.rawValue)") { try remember(busy) }
            try check(try Snapshot(busy) == snapshot && busy.store.attempts == 0, "Busy rejection must not mutate the session")
        }
        let unavailable = AppModelCorrectionHarness(); unavailable.loaded = false
        try rejects("Unavailable session store must prevent remembering") { try remember(unavailable) }
        try check(unavailable.store.attempts == 0 && unavailable.rememberedCorrection == nil, "Unavailable session must not publish success")

        let oldRule = Replacement(heard: "GIT HUB", written: "Github")
        let existing = AppModelCorrectionHarness(rules: [unrelated, oldRule])
        let originalDraft = existing.transcript
        try remember(existing)
        try check(existing.replacements[1].id == oldRule.id && existing.replacements[1].written == "GitHub", "Updating a rule must retain its identity")
        let corrected = try Snapshot(existing)
        let correctedStore = try encoded(existing.store.saved)
        let correctedWork = existing.persistWork
        existing.store.fails = true
        try rejects("Undo save failure must be reported") { try existing.undoRememberedCorrection() }
        try check(try Snapshot(existing) == corrected && encoded(existing.store.saved) == correctedStore,
                  "Failed undo must retain draft, corrected dictionary and receipt for retry")
        try check(existing.persistWork === correctedWork && correctedWork?.isCancelled == false, "Failed undo must preserve pending autosave")
        existing.store.fails = false
        try existing.undoRememberedCorrection()
        try check(existing.replacements == [unrelated, oldRule] && existing.transcript == originalDraft,
                  "Undo retry must restore the previous existing-rule value, identity, order and draft")
        try check(existing.rememberedCorrection == nil && existing.store.saved?.draft == originalDraft
                  && existing.store.saved?.replacements == [unrelated, oldRule], "Successful undo must persist before clearing the receipt")
        try check(existing.rawTranscript == "Untouched recognition original" && existing.history.first?.text == "Earlier capture"
                  && existing.store.saved?.history.first?.rawText == "Earlier original",
                  "Undo must retain recognition originals and historical captures")

        let edited = AppModelCorrectionHarness()
        try remember(edited)
        edited.transcript = "Newer handwritten draft"
        try edited.undoRememberedCorrection()
        try check(edited.transcript == "Newer handwritten draft" && edited.store.saved?.draft == edited.transcript
                  && edited.replacements.isEmpty, "Undo must remove the dictionary change while preserving newer draft edits")
        let returned = AppModelCorrectionHarness()
        try remember(returned)
        let afterDraft = returned.transcript
        returned.transcript = "Temporary edit"
        returned.transcript = afterDraft
        try returned.undoRememberedCorrection()
        try check(returned.transcript == afterDraft && returned.store.saved?.draft == afterDraft && returned.replacements.isEmpty,
                  "Revision guard must preserve later edits even when text returns to the same string")

        let changedDictionary = AppModelCorrectionHarness()
        try remember(changedDictionary)
        changedDictionary.replacements.append(unrelated)
        let dictionarySnapshot = try Snapshot(changedDictionary)
        let dictionaryWrites = changedDictionary.store.attempts
        try rejects("Undo must reject a dictionary changed after the correction") { try changedDictionary.undoRememberedCorrection() }
        try check(try Snapshot(changedDictionary) == dictionarySnapshot && changedDictionary.store.attempts == dictionaryWrites,
                  "Undo must not delete a later dictionary change or its receipt")
        let busyUndo = AppModelCorrectionHarness()
        try remember(busyUndo); busyUndo.phase = .cleaning
        let busyUndoBefore = try Snapshot(busyUndo)
        let busyUndoWrites = busyUndo.store.attempts
        try rejects("Undo must reject an active operation") { try busyUndo.undoRememberedCorrection() }
        try check(try Snapshot(busyUndo) == busyUndoBefore && busyUndo.store.attempts == busyUndoWrites,
                  "Busy undo must not mutate or save")
        let absent = AppModelCorrectionHarness()
        let absentBefore = try Snapshot(absent)
        try absent.undoRememberedCorrection()
        try check(try Snapshot(absent) == absentBefore && absent.store.attempts == 0, "Undo without a receipt must be a no-op")
        print(String(format: "REMEMBER_CORRECTION_CHECKS_OK: %d checks in %.3fs", count, Date().timeIntervalSince(start)))
    }
}
'''.replace("__EXACT_PROPERTIES__", properties).replace("__EXACT_METHODS__", methods)

started = time.monotonic()
with tempfile.TemporaryDirectory(prefix="workbench-remember-correction-", dir="/private/tmp") as directory:
    directory = Path(directory)
    (directory / "CoreValues.swift").write_text(values)
    (directory / "Checks.swift").write_text(fixture)
    binary = directory / "checks"
    subprocess.run([
        "swiftc", "-parse-as-library", "-swift-version", "5", "-module-cache-path", str(directory / "ModuleCache"),
        str(directory / "CoreValues.swift"), str(PROJECT / "Sources/LocalVoice/TextPrimitives.swift"), str(PROJECT / "Sources/LocalVoice/CorrectionRule.swift"),
        str(directory / "Checks.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
print(f"Exact application methods/properties SHA-256: {hashlib.sha256((methods + properties).encode()).hexdigest()}")
print(f"Compilation and checks: {time.monotonic() - started:.3f}s")
