import CryptoKit
import Foundation

enum ReadbackDeckStyle: String, CaseIterable, Identifiable {
    case neutral
    case serviceNow
    var id: String { rawValue }
    var title: String { self == .neutral ? "Neutral" : "ServiceNow" }
}

struct ReadbackSkillPackReference: Codable, Equatable {
    var id: String
    var version: String
    var name: String

    static let neutral = Self(id: "workbench-neutral", version: "1.0.0", name: "Neutral")
    static let serviceNow = Self(id: "servicenow-employee-experience", version: "1.0.0", name: "ServiceNow")
}

struct ReadbackSkillPackProvenance: Codable {
    var formatVersion = 1
    var pack: ReadbackSkillPackReference
}

struct ReadbackSkillPackSnapshot {
    let reference: ReadbackSkillPackReference
    let files: [String: Data]

    func validate() throws {
        let paths: [String]
        switch reference.id {
        case ReadbackSkillPackReference.neutral.id: paths = ReadbackResources.deckFiles
        case ReadbackSkillPackReference.serviceNow.id: paths = ReadbackResources.serviceNowFiles
        default: throw ReadbackError.message("The selected skill pack is unsupported. No session was created.")
        }
        guard Set(files.keys) == Set(paths), files.values.allSatisfy({ !$0.isEmpty && $0.count < 16_000_000 }),
              let skill = files["SKILL.md"], String(data: skill, encoding: .utf8) != nil else {
            throw ReadbackError.message("The selected skill pack is incomplete. No session was created.")
        }
    }
}

enum ReadbackResources {
    static let deckFiles = ["SKILL.md"]
    // Explicit payload: no private examples, caches or unrelated bundle files travel.
    static let serviceNowFiles = [
        "SKILL.md", "requirements.txt", "brand/brand.json",
        "brand/assets/bg_purple.jpg", "brand/assets/bg_thankyou.jpg",
        "brand/assets/deco_hex.png", "brand/assets/logo_wordmark.png",
        "brand/assets/logo_wordmark_closing.png",
        "scripts/session_outline.py", "scripts/session_io.py", "scripts/build_deck.py"
    ]

    /// Avoid SwiftPM's trapping Bundle.module accessor. Optional branding is
    /// resolved separately, so a missing pack cannot break neutral sessions.
    static func deckPayload(in application: Bundle = .main) throws -> [String: Data] {
        try bundledSnapshot(.neutral, in: application).files
    }

    static func bundledSnapshot(_ style: ReadbackDeckStyle, in application: Bundle = .main) throws -> ReadbackSkillPackSnapshot {
        let reference: ReadbackSkillPackReference = style == .neutral ? .neutral : .serviceNow
        let relative = "build-snap-and-talk-deck" + (style == .neutral ? "" : "/packs/\(reference.id)/\(reference.version)")
        let paths = style == .neutral ? deckFiles : serviceNowFiles
        let name = "Workbench_LocalVoice.bundle"
        var locations = [application.resourceURL?.appendingPathComponent(name)].compactMap { $0 }
        if application.bundleURL.pathExtension != "app" {
            locations.append(application.bundleURL.appendingPathComponent(name))
            if let executable = application.executableURL {
                locations.append(executable.deletingLastPathComponent().appendingPathComponent(name))
            }
        }
        for location in locations {
            guard let resources = Bundle(url: location), let root = resources.resourceURL?.appendingPathComponent(relative),
                  let payload = try? readPayload(at: root, paths: paths) else { continue }
            return ReadbackSkillPackSnapshot(reference: reference, files: payload)
        }
        if style == .serviceNow {
            throw ReadbackError.message("This Workbench installation is missing the complete ServiceNow skill pack. Reinstall Workbench to install that pack, or choose Neutral for a new session.")
        }
        throw ReadbackError.message("This Workbench installation is missing its readable Snap & Talk deck skill. Reinstall a complete Workbench app. No session was created.")
    }

    static func readPayload(at root: URL, paths: [String]) throws -> [String: Data] {
        var payload: [String: Data] = [:]
        for path in paths {
            let file = root.appendingPathComponent(path)
            guard file.resolvingSymlinksInPath().standardizedFileURL.path == file.standardizedFileURL.path,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size > 0, size < 16_000_000,
                  let data = try? Data(contentsOf: file), !data.isEmpty else {
                throw ReadbackError.message("The skill pack is incomplete or unreadable (\(path)). Reinstall the pack before creating a session with it.")
            }
            payload[path] = data
        }
        guard let skill = payload["SKILL.md"], String(data: skill, encoding: .utf8) != nil else {
            throw ReadbackError.message("The skill pack has no readable SKILL.md. No session was created.")
        }
        return payload
    }
}

/// One optional local pack, installed only through an explicit app action.
/// Snapshots travel with sessions; no global agent skill registration is made.
struct ReadbackSkillPackStore {
    let root: URL
    var resources: Bundle = .main
    private var destination: URL { root.appendingPathComponent(ReadbackSkillPackReference.serviceNow.id, isDirectory: true) }

    private struct Receipt: Codable {
        var formatVersion = 1
        var pack: ReadbackSkillPackReference
        var files: [String: String]
    }

    func snapshot(for style: ReadbackDeckStyle) throws -> ReadbackSkillPackSnapshot {
        if style == .neutral { return try ReadbackResources.bundledSnapshot(.neutral, in: resources) }
        do {
            let receiptURL = destination.appendingPathComponent("pack.json")
            guard receiptURL.resolvingSymlinksInPath().standardizedFileURL.path == receiptURL.standardizedFileURL.path else {
                throw ReadbackError.message("The installed pack cannot be a symbolic link.")
            }
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.formatVersion == 1, receipt.pack.id == ReadbackSkillPackReference.serviceNow.id,
                  receipt.pack.name == "ServiceNow", receipt.pack.version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
                  Set(receipt.files.keys) == Set(ReadbackResources.serviceNowFiles) else {
                throw ReadbackError.message("The installed pack record is unsupported.")
            }
            let files = try ReadbackResources.readPayload(at: destination, paths: ReadbackResources.serviceNowFiles)
            guard files.allSatisfy({ digest($0.value) == receipt.files[$0.key] }) else {
                throw ReadbackError.message("The installed pack files have changed.")
            }
            return ReadbackSkillPackSnapshot(reference: receipt.pack, files: files)
        } catch {
            throw ReadbackError.message("ServiceNow is selected but its installed skill pack is unavailable. Install the pack again or choose Neutral. Existing sessions are unchanged.")
        }
    }

    @discardableResult
    func installServiceNow() throws -> ReadbackSkillPackReference {
        let snapshot = try ReadbackResources.bundledSnapshot(.serviceNow, in: resources)
        let fm = FileManager.default
        try ReadbackStore.createPrivateDirectory(root)
        let staged = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let backup = root.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        try ReadbackStore.createPrivateDirectory(staged, includingParents: false)
        defer { try? fm.removeItem(at: staged) }
        for (path, data) in snapshot.files {
            let file = staged.appendingPathComponent(path)
            try ReadbackStore.createPrivateDirectory(file.deletingLastPathComponent())
            try ReadbackStore.writePrivate(data, to: file)
        }
        let receipt = Receipt(pack: snapshot.reference, files: snapshot.files.mapValues(digest))
        try ReadbackStore.writePrivate(JSONEncoder().encode(receipt), to: staged.appendingPathComponent("pack.json"))
        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staged, to: destination) }
        catch {
            if hadPrevious { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadPrevious { try? fm.removeItem(at: backup) }
        return snapshot.reference
    }

    func uninstallServiceNow() throws {
        // Only this app-owned pack directory is removed. Sessions hold independent copies.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
