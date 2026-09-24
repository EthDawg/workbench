import Foundation

@MainActor
enum PromptInsertionChecks {
    private final class Field {
        var value = "before TARGET after"
        var selection = NSRange(location: 7, length: 6)
        var readable = true, permitted = true, cancelled = false, progressive = true, refuses = false
        var writes: [String] = [], pastes = 0
        var onCapability: (() -> Void)?
        var afterWrite: (() -> Void)?
        var snapshot: PromptInsertionRunner.Snapshot { .init(value: value, selection: selection) }
        var driver: PromptInsertionRunner.Driver {
            .init(cancelled: { self.cancelled || Task.isCancelled }, permitted: { self.permitted },
                  snapshot: { self.readable ? self.snapshot : nil },
                  supportsProgressive: { self.onCapability?(); return self.progressive },
                  insert: { chunk in
                      self.writes.append(chunk)
                      guard !self.refuses, let range = Range(self.selection, in: self.value) else { return false }
                      self.value.replaceSubrange(range, with: chunk)
                      self.selection = NSRange(location: self.selection.location + chunk.utf16.count, length: 0)
                      return true
                  }, waitForConfirmation: { self.afterWrite?(); try Task.checkCancellation() },
                  paste: { _, expected in self.pastes += 1; self.value = expected.value; self.selection = expected.selection; return "pasted" })
        }
        func run(_ text: String = "hello") async -> String {
            await PromptInsertionRunner.run(text: text, destination: snapshot, driver: driver)
        }
    }
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("Prompt insertion: " + name) }
            count += 1
        }
        let unicode = "👨‍👩‍👧‍👦 café e\u{301}\n第二行"
        let field = Field()
        let result = await field.run(unicode)
        try check(field.value == "before \(unicode) after" && result == "Prompt inserted. Nothing was submitted.", "literal Unicode, newlines and selected-range replacement")
        try check(field.writes.joined() == unicode && field.writes.allSatisfy { $0.count <= 2 } && field.pastes == 0, "progressive writes use whole Characters with no fallback replay")
        let fallback = Field(); fallback.progressive = false
        let fallbackResult = await fallback.run(unicode)
        try check(fallbackResult == "pasted" && fallback.pastes == 1 && fallback.writes.isEmpty && fallback.value == field.value, "unsupported progressive write uses exactly one validated paste")
        let invalid = Field(); invalid.progressive = false
        _ = await invalid.run(String(repeating: "x", count: 50_001))
        try check(invalid.pastes == 0 && invalid.writes.isEmpty, "oversized prompt cannot bypass bounds through fallback")
        invalid.selection = NSRange(location: 500, length: 1)
        _ = await invalid.run()
        try check(invalid.pastes == 0 && invalid.writes.isEmpty, "invalid selection cannot fall back to paste")
        let boundary = Field(); boundary.progressive = false
        boundary.onCapability = { boundary.selection.location = 0 }
        _ = await boundary.run()
        try check(boundary.pastes == 0, "selection changes at the capability boundary stop fallback")
        let editing = Field(); editing.progressive = false
        editing.onCapability = { editing.permitted = false }
        _ = await editing.run()
        try check(editing.pastes == 0, "shortcut editing begins before fallback and blocks delivery")
        let cancelledFallback = Field(); cancelledFallback.progressive = false
        cancelledFallback.onCapability = { cancelledFallback.cancelled = true }
        _ = await cancelledFallback.run()
        try check(cancelledFallback.pastes == 0, "cancellation before fallback prevents any delivery")
        let unreadable = Field(); unreadable.readable = false
        _ = await unreadable.run()
        try check(unreadable.writes.isEmpty && unreadable.pastes == 0, "lost focus, permission, secure or unreadable field cannot receive text")
        let lost = Field(); lost.afterWrite = { lost.readable = false }
        let lostResult = await lost.run()
        try check(lost.writes.count == 1 && lost.pastes == 0 && lostResult.contains("could not be confirmed"), "focus loss after a write stops without replay")
        let changed = Field(); changed.afterWrite = { changed.value += "manual edit" }
        _ = await changed.run()
        try check(changed.writes.count == 1 && changed.pastes == 0, "manual field changes stop after the first unconfirmed write")
        let partial = Field(); partial.afterWrite = { partial.cancelled = true }
        _ = await partial.run()
        try check(partial.writes.count == 1 && partial.pastes == 0, "Escape after a chunk does not replay the full prompt")
        let practice = Field(); practice.afterWrite = { practice.permitted = false }
        _ = await practice.run()
        try check(practice.writes.count == 1 && practice.pastes == 0, "shortcut practice stops progressive insertion")
        let refused = Field(); refused.refuses = true
        _ = await refused.run()
        try check(refused.writes.count == 1 && refused.pastes == 0 && refused.value == "before TARGET after", "failed write never triggers a full paste")
        let queued = Field(); queued.progressive = false
        let task = Task { await queued.run() }; task.cancel()
        _ = await task.value
        try check(queued.writes.isEmpty && queued.pastes == 0, "cancelling a queued delivery Task prevents its first write")
        print("PROMPT_INSERTION_CHECKS_OK: \(count) checks passed")
    }
}
