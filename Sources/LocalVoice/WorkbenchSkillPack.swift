import Foundation
import PrivatePackKit

/// Workbench keys a skill may declare in its SKILL.md frontmatter, inside the
/// Agent Skills spec's optional `metadata` map. They travel with the skill when
/// one file is shared, and keep it valid for Claude Code and Codex:
///
/// ```
/// metadata:
///   workbench-reply: inline
///   workbench-task: "Turn this meeting into notes and a follow-up."
/// ```
///
/// Without them a skill keeps the file-producing handoff and suggests no task.
/// Unknown keys are ignored.
struct SkillMetadata: Equatable {
    var description: String?
    /// The skill returns its document as the answer, so it can run as a
    /// connected task instead of needing the assistant's full workspace.
    var repliesInline = false
    /// What the task field suggests for this skill until the person edits it.
    var suggestedTask: String?

    init(description: String? = nil, repliesInline: Bool = false, suggestedTask: String? = nil) {
        self.description = description; self.repliesInline = repliesInline; self.suggestedTask = suggestedTask
    }

    init(skill text: String) {
        guard let frontmatter = Self.frontmatter(text) else { return }
        var inMetadata = false
        for line in frontmatter {
            guard line.first == " " || line.first == "\t" else {
                inMetadata = line.trimmingCharacters(in: .whitespaces) == "metadata:"
                if let value = Self.value(of: "description", in: line), !value.isEmpty { description = value }
                continue
            }
            guard inMetadata else { continue }
            let entry = line.trimmingCharacters(in: .whitespaces)
            if let value = Self.value(of: "workbench-reply", in: entry) { repliesInline = value == "inline" }
            if let value = Self.value(of: "workbench-task", in: entry), !value.isEmpty { suggestedTask = value }
        }
    }

    init(snapshot: ReadbackSkillPackSnapshot) {
        self.init(skill: snapshot.files[TranscriptHandoffStore.skillEntryPoint].flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    /// The lines between the opening and closing `---`, or nil without frontmatter.
    private static func frontmatter(_ text: String) -> [String]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.hasSuffix("\r") ? $0.dropLast() : $0) }
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        return Array(lines[1..<end])
    }

    /// `key: value`, `key: "value"` or `key: 'value'`.
    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return value }
        let inner = String(value.dropFirst().dropLast())
        return quote == "'" ? inner.replacingOccurrences(of: "''", with: "'")
            : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

/// Workbench's own skills ship in the app as a pack in the private pack format,
/// so built-in and installed skills are read, checked and offered the same way.
enum WorkbenchSkillPack {
    static let directory = "workbench-pack"

    static func payload(in application: Bundle = .main) throws -> PackPayload {
        for location in ReadbackResources.bundleLocations(in: application) {
            guard let root = Bundle(url: location)?.resourceURL?.appendingPathComponent(directory),
                  let data = try? Data(contentsOf: root.appendingPathComponent("pack.json")) else { continue }
            let manifest = try JSONDecoder().decode(PackManifest.self, from: data)
            var files: [String: Data] = [:]
            for record in manifest.files { files[record.path] = try Data(contentsOf: PackPath.url(record.path, in: root)) }
            return try PackPayload(manifest: manifest, files: files)
        }
        throw TranscriptHandoffError.message("This Workbench installation is missing its built-in skills. Reinstall Workbench.")
    }

    /// Transcript skills in the order the pack lists them.
    static func transcriptSkills(from payload: PackPayload) throws -> [TranscriptHandoffSkill] {
        try payload.manifest.entries.filter { $0.kind == .skill && $0.inputKinds?.contains(.transcripts) == true }.map { entry in
            let reference = ReadbackSkillPackReference(id: entry.id, version: payload.manifest.version.description, name: entry.name)
            let snapshot = ReadbackSkillPackSnapshot(reference: reference, files: try payload.snapshot(entryID: entry.id).files)
            try TranscriptHandoffSkillCheck.validate(snapshot)
            return TranscriptHandoffSkill(snapshot, title: entry.name, detail: SkillMetadata(snapshot: snapshot).description ?? entry.name)
        }
    }

    static let loaded = Result { try transcriptSkills(from: payload()) }
}
