import Foundation

/// A read-only recovery snapshot, deliberately separate from portable Library exchange.
/// Read raw saved fields: loading/migrating VoicePreferences here could change the assignment.
struct SavedBrowserSettings {
    private let connection: [String: Any]
    private let shortcut: Any?
    private let unreadableShortcut: Bool
    private let links: [DemoResource]
    let hasSavedSettings: Bool

    init(resources: [DemoResource], defaults: UserDefaults = .standard) {
        connection = ["browser.enabled", "browser.machineID"].reduce(into: [:]) { fields, key in
            fields[key] = defaults.object(forKey: key)
        }
        links = resources.filter { $0.kind == .link && $0.browserTarget != nil }
        let saved = defaults.object(forKey: VoicePreferences.key)
        let fields = (saved as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        shortcut = fields?["presenterShortcut"]
        unreadableShortcut = saved != nil && fields == nil
        let originalDefault = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(VoicePreferences.defaultPresenterShortcut))
        let customShortcut = shortcut.map { raw in
            guard !(raw is NSNull), let originalDefault else { return false }
            return !NSDictionary(dictionary: ["value": raw]).isEqual(to: ["value": originalDefault])
        } ?? false
        // Older startup could create a machine ID even with no connection. That alone,
        // or the fresh disabled shortcut, must not promote browser UI to a new person.
        hasSavedSettings = connection["browser.enabled"] != nil || !links.isEmpty || customShortcut
    }

    var shortcutSummary: String? {
        guard let shortcut, !(shortcut is NSNull) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: shortcut, options: [.fragmentsAllowed]),
              var saved = try? JSONDecoder().decode(VoiceShortcut.self, from: data) else {
            return "Saved Switch to shortcut: unrecognized assignment · inactive"
        }
        saved.enabled = true // Inspect the stored combination even if it was already disabled.
        return "Saved Switch to shortcut: \(saved.label) · inactive"
    }

    func encoded() throws -> Data {
        guard !unreadableShortcut else {
            throw VoiceError.message("The saved shortcut preferences could not be read. No browser settings were exported or changed.")
        }
        let boundLinks = try links.map { link -> [String: Any] in
            let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(link)) as! [String: Any]
            return record.filter { ["id", "title", "content", "browserTarget"].contains($0.key) }
        }
        var snapshot: [String: Any] = ["format": "workbench-saved-browser-settings", "version": 1,
            "connection": connection, "boundLinks": boundLinks, "shortcutID": 4]
        if let shortcut { snapshot["presenterShortcut"] = shortcut }
        return try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
