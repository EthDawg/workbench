import Foundation

/// Delivery policy shared by the native adapter and synthetic orchestration
/// checks. Every write requires the exact field value and UTF-16 selection.
@MainActor
enum PromptInsertionRunner {
    struct Snapshot: Equatable {
        var value: String
        var selection: NSRange
    }
    struct Driver {
        var cancelled: () -> Bool
        var permitted: () -> Bool
        /// nil means focus, permission, security or readable ownership was lost.
        var snapshot: () -> Snapshot?
        var supportsProgressive: () -> Bool
        var insert: (String) -> Bool
        var waitForConfirmation: () async throws -> Void
        var paste: (String, Snapshot) async -> String
    }
    static func run(text: String, destination: Snapshot, driver: Driver) async -> String {
        guard var plan = PromptInsertionPlan(value: destination.value, selection: destination.selection, text: text) else {
            return "The prompt or selected range is invalid. Nothing was inserted."
        }
        func owns(_ plan: PromptInsertionPlan) -> Bool {
            guard !driver.cancelled(), driver.permitted(), let current = driver.snapshot() else { return false }
            return plan.matches(value: current.value, selection: current.selection)
        }
        guard owns(plan) else { return "Insertion stopped before delivery. Nothing was inserted." }
        if !driver.supportsProgressive() {
            // A capability query may run arbitrary adapter code. Recheck at the
            // fallback boundary; never bypass validation with a full paste.
            guard owns(plan) else { return "Insertion stopped before delivery. Nothing was inserted." }
            var complete = plan; complete.acknowledge(text)
            return await driver.paste(text, Snapshot(value: complete.expectedValue, selection: complete.selection))
        }
        while !plan.remaining.isEmpty {
            guard owns(plan) else {
                return "Insertion stopped. \(plan.insertedCharacters) characters confirmed; nothing was replayed."
            }
            let chunk = plan.nextChunk
            guard driver.insert(chunk) else {
                return "The field refused insertion. Check it before trying again; nothing was replayed."
            }
            var expected = plan; expected.acknowledge(chunk)
            do { try await driver.waitForConfirmation() }
            catch { return "Insertion stopped after sending text. Check the destination; nothing was replayed." }
            guard owns(expected) else {
                return "Insertion could not be confirmed. Check the destination; nothing was replayed."
            }
            plan = expected
        }
        return "Prompt inserted. Nothing was submitted."
    }
}
