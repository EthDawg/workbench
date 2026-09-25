import Foundation
import Carbon
import StageKit

/// Uses disposable preferences and the production migration/registration plans. No hotkeys or UI.
enum ShortcutMigrationChecks {
    static func run() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            guard condition() else { throw VoiceError.message("Shortcut migration: \(message)") }
        }
        func option(_ key: Int, enabled: Bool = true) -> VoiceShortcut {
            VoiceShortcut(keyCode: UInt32(key), modifiers: UInt32(optionKey), enabled: enabled)
        }
        func legacyVoice() -> VoicePreferences {
            var value = VoicePreferences()
            for id in UInt32(1)...7 { value.setShortcut(VoicePreferences.legacyDefaults[id]!, for: id) }
            return value
        }
        func entries(_ voice: VoicePreferences, _ stage: [StageShortcutDescriptor]) -> [ShortcutEntry] {
            (UInt32(1)...7).map { ShortcutEntry(id: "voice.\($0)", title: $0 == 6 ? "Read" : "Voice \($0)", shortcut: voice.shortcut($0)) }
                + stage.map { ShortcutEntry(id: "stage.\($0.id)", title: $0.label,
                    shortcut: VoiceShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers, enabled: $0.enabled)) }
        }
        func stageKey(_ id: String, in entries: [StageShortcutDescriptor]) -> VoiceShortcut {
            let entry = entries.first { $0.id == id }!
            return VoiceShortcut(keyCode: entry.keyCode, modifiers: entry.modifiers, enabled: entry.enabled)
        }
        func fixture(_ body: (UserDefaults, UserDefaults) throws -> Void) throws {
            let suite = "WorkbenchShortcutMigration.\(UUID().uuidString)"
            let voice = UserDefaults(suiteName: suite + ".voice")!, stage = UserDefaults(suiteName: suite + ".stage")!
            defer { voice.removePersistentDomain(forName: suite + ".voice"); stage.removePersistentDomain(forName: suite + ".stage") }
            try body(voice, stage)
        }
        func saveStage(_ shortcuts: [String: VoiceShortcut], to defaults: UserDefaults, revision: Int = 3) throws {
            // Seed non-shortcut fields from the real store, then import an older shortcut catalogue.
            _ = StageShortcutSettings.load(defaults: defaults)
            var saved = try JSONSerialization.jsonObject(with: defaults.data(forKey: "preferences.v1")!) as! [String: Any]
            saved["shortcuts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shortcuts))
            defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: "preferences.v1")
            defaults.set(revision, forKey: "preferences.schema")
        }
        func load(_ voice: UserDefaults, _ stage: UserDefaults) -> (VoicePreferences, [StageShortcutDescriptor]) {
            // Same ordering as AppDelegate: chosen Stage keys first, then Voice, then Stage.
            let value = VoicePreferences.load(from: voice, reserving: StageShortcutSettings.migrationReservations(defaults: stage))
            return (value, StageShortcutSettings.load(defaults: stage, reserving: value.enabledCombinations))
        }

        try fixture { voice, stage in
            legacyVoice().save(to: voice)
            try saveStage(["timer": option(kVK_ANSI_V)], to: stage)
            let (v, s) = load(voice, stage)
            try check(stageKey("timer", in: s) == option(kVK_ANSI_V), "Stage's chosen Option-V remains enabled")
            try check(v.shortcut(1) == VoicePreferences.legacyDefaults[1], "Dictate falls back instead of claiming Stage's choice")
            try check(ShortcutConflict.duplicateFailures(in: entries(v, s)).isEmpty, "the complete migrated catalogues have no duplicates")
            let stageFailures = StageShortcutSettings.registrationFailures(in: s) { code, modifiers in
                v.enabledCombinations.contains(.init(keyCode: code, modifiers: modifiers)) ? "Used by Voice" : nil
            }
            try check(stageFailures["timer"] == nil, "Stage's chosen Option-V is available after Voice yields it")
            let beforeVoice = voice.data(forKey: VoicePreferences.key), beforeStage = stage.data(forKey: "preferences.v1")
            _ = load(voice, stage)
            try check(beforeVoice == voice.data(forKey: VoicePreferences.key) && beforeStage == stage.data(forKey: "preferences.v1"), "relaunch does not rewrite saved migrations")
            var edited = v; edited.libraryShortcut = VoicePreferences.legacyDefaults[3]; edited.save(to: voice)
            try check(load(voice, stage).0.shortcut(3).enabled, "a later choice of an old Voice key is not migrated again")
            try saveStage(["timer": VoiceShortcut(keyCode: UInt32(kVK_ANSI_K))], to: stage, revision: 4)
            try check(stageKey("timer", in: load(voice, stage).1).enabled, "a later choice of an old Stage key is not migrated again")
        }
        try fixture { voice, stage in
            var previous = legacyVoice(); previous.readingShortcut = option(kVK_ANSI_D); previous.save(to: voice)
            try saveStage(["pen": VoiceShortcut(keyCode: UInt32(kVK_ANSI_D))], to: stage)
            let (v, s) = load(voice, stage)
            try check(v.shortcut(6) == option(kVK_ANSI_D), "Voice's chosen Option-D remains enabled")
            try check(stageKey("pen", in: s) == VoiceShortcut(keyCode: UInt32(kVK_ANSI_D)), "Draw falls back instead of claiming Voice's choice")
            try check(ShortcutConflict.duplicateFailures(in: entries(v, s)).isEmpty, "reverse migration preserves one owner per combination")
        }
        try fixture { voice, stage in
            try saveStage(["timer": option(kVK_ANSI_V)], to: stage, revision: 4)
            let (v, s) = load(voice, stage)
            try check(v.shortcut(1) == VoicePreferences.legacyDefaults[1] && stageKey("timer", in: s).enabled, "fresh Voice respects an already migrated Stage catalogue")
        }
        try fixture { voice, stage in
            var previous = legacyVoice(); previous.readingShortcut = option(kVK_ANSI_D); previous.save(to: voice)
            voice.set(1, forKey: VoicePreferences.shortcutRevisionKey)
            // The Stage data may be absent even when its old revision marker survives.
            stage.set(4, forKey: "preferences.schema")
            let (v, s) = load(voice, stage)
            try check(stageKey("pen", in: s) == VoiceShortcut(keyCode: UInt32(kVK_ANSI_D)) && v.shortcut(6).enabled, "fresh Stage respects an already migrated Voice catalogue")
        }
        try fixture { voice, stage in
            legacyVoice().save(to: voice)
            try saveStage(["timer": option(kVK_ANSI_V), "pointer": VoiceShortcut()], to: stage)
            let (v, s) = load(voice, stage)
            try check(!v.shortcut(1).enabled, "Dictate stays off when both new and fallback keys are chosen elsewhere")
            try check(stageKey("timer", in: s).enabled && stageKey("pointer", in: s).enabled, "both Stage choices survive fallback exhaustion")
            try check(ShortcutConflict.duplicateFailures(in: entries(v, s)).isEmpty, "fallback exhaustion adds no collision")
        }
        try fixture { voice, stage in
            var previous = legacyVoice(); previous.readingShortcut = option(kVK_ANSI_D)
            previous.dictationShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_D)); previous.save(to: voice)
            try saveStage([:], to: stage)
            let (v, s) = load(voice, stage)
            try check(!stageKey("pen", in: s).enabled, "Draw stays off when both new and fallback keys are Voice choices")
            try check(v.shortcut(1).enabled && v.shortcut(6).enabled, "both Voice choices survive fallback exhaustion")
        }
        try fixture { voice, stage in
            var previous = legacyVoice(); previous.readingShortcut = option(kVK_ANSI_D, enabled: false); previous.save(to: voice)
            try saveStage(["timer": option(kVK_ANSI_V, enabled: false)], to: stage)
            let (v, s) = load(voice, stage)
            try check(v.shortcut(1) == VoicePreferences.defaultDictationShortcut && stageKey("pen", in: s) == option(kVK_ANSI_D), "disabled choices release keys in both directions")
            try check(!v.shortcut(6).enabled && !stageKey("timer", in: s).enabled, "the disabled choices themselves stay off")
        }
        try fixture { voice, stage in
            var previous = legacyVoice(); previous.readbackShortcut = VoicePreferences.legacyReadbackShortcut; previous.save(to: voice)
            try saveStage(["timer": option(kVK_ANSI_C)], to: stage)
            let (v, s) = load(voice, stage)
            try check(v.shortcut(5) == VoicePreferences.legacyDefaults[5] && stageKey("timer", in: s) == option(kVK_ANSI_C), "earliest Snap shortcut migration also respects Stage choices")
        }
        try fixture { voice, stage in
            var previous = legacyVoice(); previous.readingShortcut = option(kVK_ANSI_Y); previous.save(to: voice)
            try saveStage(["timer": option(kVK_ANSI_Y)], to: stage)
            let (v, s) = load(voice, stage), catalogue = entries(v, s)
            let failures = ShortcutConflict.duplicateFailures(in: catalogue)
            try check(failures["voice.6"]?.contains("Break timer") == true && failures["stage.timer"]?.contains("Read") == true, "both duplicate rows name the other saved action")
            try check(failures.values.allSatisfy { $0.contains("paused") && $0.contains("Keyboard shortcuts") }, "collision errors explain the pause and repair route")
            let registration = ShortcutConflict.voiceRegistrationPreferences(v, failures: failures)
            try check(!registration.shortcut(6).enabled && v.shortcut(6).enabled && stageKey("timer", in: s).enabled, "registration pauses Voice without changing either saved choice")
            let stageFailures = StageShortcutSettings.registrationFailures(in: s) { code, modifiers in
                catalogue.first { $0.id.hasPrefix("voice.") && $0.shortcut.enabled && $0.shortcut.keyCode == code && $0.shortcut.modifiers == modifiers }
                    .map { "Also assigned to \($0.title). Both shortcuts are paused." }
            }
            try check(stageFailures["timer"]?.contains("Read") == true, "Stage's production registration plan also pauses its duplicate")
            var repaired = v; repaired.readingShortcut?.enabled = false; repaired.save(to: voice)
            let (v2, s2) = load(voice, stage)
            try check(ShortcutConflict.duplicateFailures(in: entries(v2, s2)).isEmpty, "turning off either duplicate clears the collision on reload")
            try check(stageKey("timer", in: s2) == option(kVK_ANSI_Y), "repair leaves the remaining chosen key available")
            try check(StageShortcutSettings.registrationFailures(in: s2, validateExternal: { _, _ in nil }).isEmpty, "an authoritative host approval does not reserve historical Voice defaults")
            v.save(to: voice)
            try saveStage(["timer": option(kVK_ANSI_Y, enabled: false)], to: stage, revision: 4)
            let (v3, s3) = load(voice, stage)
            let repairedFailures = ShortcutConflict.duplicateFailures(in: entries(v3, s3))
            try check(repairedFailures.isEmpty && ShortcutConflict.voiceRegistrationPreferences(v3, failures: repairedFailures).shortcut(6).enabled, "turning off Stage's duplicate also releases Voice's chosen key")
        }
        try fixture { voice, stage in
            let corrupt = Data("preserve unreadable preferences".utf8)
            voice.set(corrupt, forKey: VoicePreferences.key); stage.set(corrupt, forKey: "preferences.v1")
            _ = load(voice, stage)
            try check(voice.data(forKey: VoicePreferences.key) == corrupt, "unreadable Voice preferences are never replaced during migration")
            try check(stage.data(forKey: "preferences.v1") == corrupt, "unreadable Stage preferences are never replaced during migration")
        }
        print("SHORTCUT_MIGRATION_CHECKS_OK: \(checks) checks; cross-module choices, fallback exhaustion, fresh settings, persistence and visible duplicate repair; no global registration")
    }
}
