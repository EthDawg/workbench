#!/usr/bin/env python3
"""Check the production preference owner using disposable absolute-path suites.

No app launch, global shortcuts, real preferences, microphone, or network.
The production types are extracted by name, without replacing their persistence.
"""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from swift_extract import SwiftFile

PROJECT = Path(__file__).resolve().parents[1]
sources = [
    SwiftFile(PROJECT / "Sources/PresenterKit/PresenterProtocol.swift").extract(["BrowserIntegration"]),
    SwiftFile(PROJECT / "Sources/LocalVoice/VoicePreferences.swift").extract([
        "CaptureMode", "DeliveryMode", "FirstDictationGuide", "VoiceShortcut", "VoicePreferences"]),
    SwiftFile(PROJECT / "Sources/LocalVoice/DictationCleanup.swift").extract(["CleanupStyle"]),
    SwiftFile(PROJECT / "Sources/StageKit/Hotkeys.swift").extract([
        "GlobalShortcutCombination", "GlobalShortcutRule"]),
    SwiftFile(PROJECT / "Sources/LocalVoice/WorkbenchHome.swift").extract(["HomeJourney"]),
]

fixture = r'''
import AppKit
import Carbon

__PRODUCTION__

enum CheckFailure: Error { case failed(String) }

/// Refuse only the recovery write; the original remains writable. This proves
/// preservation is a prerequisite, not an ignored best-effort side effect.
final class RefusingRecoveryDefaults: UserDefaults {
    override func set(_ value: Any?, forKey key: String) {
        if key.hasPrefix(VoicePreferences.recoveryKeyPrefix) { return }
        super.set(value, forKey: key)
    }
}

final class RefusingReplacementDefaults: UserDefaults {
    var refuseReplacement = false
    override func set(_ value: Any?, forKey key: String) {
        if refuseReplacement && key == VoicePreferences.key { return }
        super.set(value, forKey: key)
    }
}

@main struct Checks {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw CheckFailure.failed(message) }
            count += 1
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func fixture(refusing: Bool = false, _ body: (UserDefaults, String) throws -> Void) throws {
            let name = root.appendingPathComponent(UUID().uuidString).path
            let defaults = refusing ? RefusingRecoveryDefaults(suiteName: name)! : UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            try body(defaults, name)
        }
        func recoveries(_ defaults: UserDefaults, _ name: String) -> [String: Any] {
            (defaults.persistentDomain(forName: name) ?? [:]).filter { $0.key.hasPrefix(VoicePreferences.recoveryKeyPrefix) }
        }
        func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
            guard let lhs, let rhs else { return lhs == nil && rhs == nil }
            return NSDictionary(dictionary: ["value": lhs]).isEqual(to: ["value": rhs])
        }
        func altered(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var chosen = VoicePreferences()
            chosen.dictationShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(optionKey))
            chosen.delivery = .clipboard
            var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chosen)) as! [String: Any]
            edit(&fields)
            return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        }

        let unreadable: [Any] = [
            Data("{incomplete JSON".utf8),
            try altered { $0["cleanup"] = "A future cleanup mode" },
            try altered { $0.removeValue(forKey: "capture") },
            try altered { $0["dictationShortcut"] = "invalid shortcut" },
            "a stored string instead of data",
            ["unexpected": ["nested", "property list"]],
            42,
        ]
        for original in unreadable {
            try fixture { defaults, name in
                defaults.set(original, forKey: VoicePreferences.key)
                defaults.set(0, forKey: VoicePreferences.shortcutRevisionKey)
                let before = defaults.persistentDomain(forName: name)!
                var fallback = VoicePreferences.load(from: defaults)
                try check(same(before, defaults.persistentDomain(forName: name)), "failed load preserves all original preferences and migration state")
                _ = VoicePreferences.load(from: defaults)
                try check(same(before, defaults.persistentDomain(forName: name)), "repeated failed loads do not write or multiply recovery copies")
                // The existing startup path records the guide as complete when
                // state.json has History, then the preference observer saves.
                fallback.firstDictationGuide = HomeJourney(transcripts: 1, guide: fallback.firstDictationGuide).guideToSave
                try check(fallback.firstDictationGuide == .completed && fallback.save(to: defaults), "ordinary startup preference save succeeds")
                let copies = recoveries(defaults, name)
                try check(copies.count == 1, "first replacement preserves exactly one recovery copy")
                let copy = copies.values.first as! [String: Any]
                try check(same(copy["value"], original), "recovery retains the exact original bytes or plist value")
                try check((copy["shortcutRevision"] as? Int) == 0, "recovery retains the original migration marker")
                try check(defaults.integer(forKey: VoicePreferences.shortcutRevisionKey) == 1, "replacement uses the current shortcut migration marker")
                try check(VoicePreferences.load(from: defaults) == fallback, "new settings and guide completion round trip")
                fallback.delivery = .clipboard
                try check(fallback.save(to: defaults), "later normal edits remain saveable")
                try check(same(recoveries(defaults, name), copies), "later edits never rewrite or duplicate recovery")
                let reopened = UserDefaults(suiteName: name)!
                try check(same(recoveries(reopened, name), copies), "same-domain recovery remains available when reopening preferences")
            }
        }

        try fixture { defaults, name in
            let fresh = VoicePreferences.load(from: defaults)
            try check(defaults.data(forKey: VoicePreferences.key) != nil, "fresh preferences are created")
            try check(defaults.integer(forKey: VoicePreferences.shortcutRevisionKey) == 1, "fresh catalogue gets its marker")
            try check(recoveries(defaults, name).isEmpty, "fresh launch has nothing to recover")
            try check(VoicePreferences.load(from: defaults) == fresh, "fresh choices round trip")
        }
        try fixture { defaults, name in
            var chosen = VoicePreferences()
            chosen.dictationShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(optionKey))
            chosen.capture = .hold; chosen.delivery = .clipboard; chosen.restoreClipboard = false
            try check(chosen.save(to: defaults), "valid chosen preferences save")
            let loaded = VoicePreferences.load(from: defaults)
            try check(loaded.dictationShortcut == chosen.dictationShortcut && loaded.capture == .hold
                      && loaded.delivery == .clipboard && !loaded.restoreClipboard, "valid migration keeps custom choices")
            try check(recoveries(defaults, name).isEmpty, "valid preferences need no recovery copy")
            let before = defaults.persistentDomain(forName: name)!
            _ = VoicePreferences.load(from: defaults)
            try check(same(before, defaults.persistentDomain(forName: name)), "completed migration does not rewrite on relaunch")
        }
        try fixture { defaults, name in
            let original = Data("first unreadable value".utf8)
            defaults.set(original, forKey: VoicePreferences.key)
            let fallback = VoicePreferences.load(from: defaults)
            try check(defaults.object(forKey: VoicePreferences.shortcutRevisionKey) == nil, "failed load preserves an absent marker")
            try check(fallback.save(to: defaults), "unreadable value without marker can be preserved")
            let first = recoveries(defaults, name)
            let copy = first.values.first as! [String: Any]
            try check(copy["shortcutRevision"] == nil, "recovery distinguishes absent marker from zero")
            defaults.set(Data("second unreadable value".utf8), forKey: VoicePreferences.key)
            try check(fallback.save(to: defaults), "a later independent failure can also recover")
            let both = recoveries(defaults, name)
            try check(both.count == 2 && first.allSatisfy { same(both[$0.key], $0.value) }, "a second failure leaves the first recovery untouched")
        }
        try fixture(refusing: true) { defaults, name in
            let original = Data("must survive a failed recovery write".utf8)
            defaults.set(original, forKey: VoicePreferences.key)
            defaults.set(0, forKey: VoicePreferences.shortcutRevisionKey)
            let fallback = VoicePreferences.load(from: defaults)
            let before = defaults.persistentDomain(forName: name)!
            try check(!fallback.save(to: defaults), "refused recovery reports an unsuccessful save")
            try check(same(before, defaults.persistentDomain(forName: name)), "refused recovery preserves original and migration marker")
        }
        let refusedName = root.appendingPathComponent(UUID().uuidString).path
        let refusingReplacement = RefusingReplacementDefaults(suiteName: refusedName)!
        defer { refusingReplacement.removePersistentDomain(forName: refusedName) }
        let original = Data("original survives refused replacement".utf8)
        refusingReplacement.set(original, forKey: VoicePreferences.key)
        refusingReplacement.set(0, forKey: VoicePreferences.shortcutRevisionKey)
        refusingReplacement.refuseReplacement = true
        try check(!VoicePreferences().save(to: refusingReplacement), "refused primary write reports failure")
        try check(refusingReplacement.data(forKey: VoicePreferences.key) == original, "refused primary write leaves original present")
        try check(refusingReplacement.integer(forKey: VoicePreferences.shortcutRevisionKey) == 0, "refused primary write cannot advance migration")
        try check(recoveries(refusingReplacement, refusedName).count == 1, "completed recovery remains after a refused primary write")
        print("VOICE_PREFERENCES_CHECKS_OK: \(count) checks; synthetic temporary preferences only")
    }
}
'''.replace("__PRODUCTION__", "\n".join(sources))

with tempfile.TemporaryDirectory(prefix="workbench-voice-preferences-", dir="/private/tmp") as directory:
    directory = Path(directory)
    harness = directory / "Checks.swift"
    harness.write_text(fixture)
    binary = directory / "checks"
    subprocess.run([
        "swiftc", "-parse-as-library", "-swift-version", "5", "-module-cache-path", str(directory / "ModuleCache"),
        str(harness), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), str(directory)], check=True, timeout=30)
print("Production declarations SHA-256: " + hashlib.sha256("\n".join(sources).encode()).hexdigest())
