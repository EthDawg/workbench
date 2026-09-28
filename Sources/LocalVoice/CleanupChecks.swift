import Foundation

enum CleanupChecks {
    static let example = "Okay, so to Hello, this is Sam. The time is 2pm and I'm looking at a rock melon. I'd like to catch the train at 6pm. Oh wait, not 6pm, 7pm. I'd like to make a grocery list. I'll need apples, bananas, cucumbers."
    static func run() throws {
        var passed = 0
        func check(_ valid: Bool, _ label: String) throws {
            guard valid else { throw VoiceError.message("Cleanup check failed: \(label)") }
            passed += 1; print("PASS: \(label)")
        }
        // The Dictate page's examples are the cleanup's own results (#134).
        let original = CleanupStyle.original.example, light = CleanupStyle.light.example, natural = CleanupStyle.natural.example
        try check(original.result == original.heard, "Original's example keeps the words as heard")
        try check(DictationCleanup.light(light.heard) == light.result, "Light's example is Light's own result")
        try check(DictationCleanup.isFaithful(natural.result, to: DictationCleanup.light(natural.heard)) && natural.result != DictationCleanup.light(natural.heard),
                  "Natural's example changes only what its meaning check allows")
        let clean = DictationCleanup.light(example)
        try check(clean == "Hello, this is Sam. The time is 2pm and I'm looking at a rockmelon. I'd like to catch the train at 7pm. I'd like to make a grocery list:\n• Apples\n• Bananas\n• Cucumbers", "false start, corrected time, requested grocery list")
        try check(DictationCleanup.light("Meet at 2 p.m. Bring the book.") == "Meet at 2pm. Bring the book.", "time punctuation preserved")
        try check(DictationCleanup.light("Um, I, I think we should go. Uh, bring a coat.") == "I think we should go. Bring a coat.", "filler sounds and accidental repetitions")
        try check(DictationCleanup.light("I like apples, bananas, and pears.") == "I like apples, bananas, and pears.", "ordinary prose is not turned into a list")
        try check(DictationCleanup.light("The meeting is at 9am. Oh wait, not 9am, 10am.") == "The meeting is at 10am.", "explicit correction outside example")
        try check(DictationCleanup.light("Meet at 6pm, actually 7pm.") == "Meet at 7pm.", "adjacent time correction")
        try check(DictationCleanup.light("Um, meet at 3pm, no actually 4pm.") == "Meet at 4pm.", "explicit no actually time correction")
        try check(DictationCleanup.light("Meet at 3:30 p.m., no, actually 4:15 p.m.") == "Meet at 4:15pm.", "minute precision and punctuated correction")
        try check(DictationCleanup.light("Meet at 3pm, no actually 4pm, sorry 5pm.") == "Meet at 5pm.", "successive explicit time corrections")
        try check(DictationCleanup.light("Meet at 3pm. No, actually I leave at 4pm.") == "Meet at 3pm. No, actually I leave at 4pm.", "another clause and its negation are retained")
        try check(DictationCleanup.light("Meet at 3pm.\n\nActually 4pm is when I leave.") == "Meet at 3pm.\n\nActually 4pm is when I leave.", "no correction inferred across paragraphs")
        try check(DictationCleanup.light("The label says 13pm, actually 14pm.") == "The label says 13pm, actually 14pm.", "invalid clock values are not interpreted")
        try check(DictationCleanup.light("I do not want tea. I want coffee.") == "I do not want tea. I want coffee.", "meaningful negation preserved")
        try check(DictationCleanup.light("Shopping list: 2 apples, 3 bananas, and 4 pears. Bring a bag.") == "Shopping list:\n• 2 apples\n• 3 bananas\n• 4 pears\n\nBring a bag.", "quantities and text after list preserved")
        try check(DictationCleanup.light("The shopping list was lost, but we found it.") == "The shopping list was lost, but we found it.", "mention of a list is not a list instruction")
        try check(DictationCleanup.light("Shopping list: 1,000g flour, salt and pepper, and milk.") == "Shopping list:\n• 1,000g flour\n• Salt and pepper\n• Milk", "thousands separators and compound items preserved")
        try check(!DictationCleanup.isFaithful("Catch the train at 8pm.", to: "Catch the train at 7pm."), "invented time rejected")
        try check(!DictationCleanup.isFaithful("I want pears.", to: "I don't want pears."), "removed negation rejected")
        try check(!DictationCleanup.isFaithful("Call Jane at 7pm and Sam at 6pm.", to: "Call Jane at 6pm and Sam at 7pm."), "swapped facts rejected")
        try check(DictationCleanup.isFaithful("Hello, Sam. Bring apples!", to: "Hello Sam, bring apples."), "punctuation edits accepted")
        try check(DictationCleanup.chunks(clean) == [clean], "list line breaks retained during natural editing")
        let oldState = Data(#"{"draft":"old draft","speechText":"old reading","history":[],"replacements":[],"voice":"Karen","rate":180}"#.utf8)
        let decoded = try JSONDecoder().decode(SavedState.self, from: oldState)
        try check(decoded.draft == "old draft" && decoded.rawDraft == nil, "version one state migrates without loss")
        print("CLEANUP_CHECKS_OK: \(passed)"); print("EXAMPLE_OUTPUT:\n\(clean)")
    }
}
