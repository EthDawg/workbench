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
    var origin: ReadbackSkillOrigin? = nil

    static let neutral = Self(id: "workbench-neutral", version: "1.0.0", name: "Neutral")
    static let serviceNow = Self(id: "servicenow-employee-experience", version: "1.0.0", name: "ServiceNow")
}

struct ReadbackSkillOrigin: Codable, Equatable {
    var repository: String
    var revision: String
    var packID: String
    var entryID: String
}

struct ReadbackSkillPackProvenance: Codable {
    var formatVersion = 1
    var pack: ReadbackSkillPackReference
}

struct ReadbackSkillPackSnapshot {
    let reference: ReadbackSkillPackReference
    let files: [String: Data]

    func validate() throws {
        if reference.id == ReadbackSkillPackReference.neutral.id, Set(files.keys) != Set(ReadbackResources.deckFiles) {
            throw ReadbackError.message("The bundled neutral skill is incomplete.")
        }
        if reference.id == ReadbackSkillPackReference.serviceNow.id, Set(files.keys) != Set(ReadbackResources.serviceNowFiles) {
            throw ReadbackError.message("The previously installed company skill is incomplete.")
        }
        guard reference.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil,
              reference.version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              !reference.name.isEmpty, reference.name.count <= 160,
              (1...512).contains(files.count),
              let skill = files["SKILL.md"], !skill.isEmpty, skill.count <= 4_194_304,
              String(data: skill, encoding: .utf8) != nil else {
            throw ReadbackError.message("The selected skill is incomplete or unsupported. No session was created.")
        }
        var folded = Set<String>(); var bytes = 0
        let reserved = ["session.json", "skill-pack.json", "handoff.json", "readme.md", "items", "inputs", "outputs"]
        for (path, data) in files {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.utf8.count <= 400, !parts.isEmpty, parts.count <= 12,
                  parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains(":") && !$0.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) }),
                  !reserved.contains(String(parts[0]).lowercased()),
                  folded.insert(path.lowercased().precomposedStringWithCanonicalMapping).inserted,
                  !data.isEmpty, data.count <= 104_857_600 else {
                throw ReadbackError.message("The selected skill contains an unsafe, duplicated or oversized file. No session was created.")
            }
            bytes += data.count
            guard bytes <= 268_435_456 else { throw ReadbackError.message("The selected skill is too large.") }
        }
        for path in folded {
            let parts = path.split(separator: "/")
            for count in 1..<parts.count where folded.contains(parts.prefix(count).joined(separator: "/")) {
                throw ReadbackError.message("The selected skill contains conflicting file and folder names.")
            }
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
        guard style == .neutral else { throw ReadbackError.message("Company packs are installed from Packs. Existing local copies remain available.") }
        let reference: ReadbackSkillPackReference = .neutral
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
        throw ReadbackError.message("Open Packs to install the current company pack from its private repository. Existing sessions remain available.")
    }

    func uninstallServiceNow() throws {
        // Only this app-owned pack directory is removed. Sessions hold independent copies.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
