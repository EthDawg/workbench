import AppKit
import Combine
import Foundation

enum TranscriptHandoffError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

/// Bounds for one explicitly selected handoff. They exist so a malformed skill,
/// an enormous session or a runaway selection fails before anything is published.
enum TranscriptHandoffLimits {
    static let maxTranscripts = 200
    static let maxTranscriptCharacters = 2_000_000
    static let maxSkillFiles = 200
    static let maxSkillFileBytes = 16_000_000
    static let maxEvidenceFiles = 2_000
    static let maxEvidenceFileBytes = 512_000_000
    static let maxEvidenceBytes = 2_000_000_000
}

/// One selectable skill for a transcript handoff. The built-in follow-up skill
/// is a static string in this file; a host can add installed pack entries by
/// supplying `load`, so this view layer never learns about pack distribution.
struct TranscriptHandoffSkill: Identifiable {
    let id: String
    let title: String
    let detail: String
    let load: () throws -> ReadbackSkillPackSnapshot

    static let followUp = TranscriptHandoffSkill(
        id: TranscriptHandoffSkills.followUpReference.id,
        title: "Prepare follow-up",
        detail: "Neutral draft from the selected transcripts, written to outputs/ for you to review and send.",
        load: { TranscriptHandoffSkills.followUpSnapshot() })

    /// Wrap an already-resolved snapshot, for example one an installed
    /// `ReadbackSkillPackStore` produced for the host.
    static func installed(_ snapshot: ReadbackSkillPackSnapshot, detail: String) -> TranscriptHandoffSkill {
        TranscriptHandoffSkill(id: snapshot.reference.id + "@" + snapshot.reference.version,
                               title: snapshot.reference.name, detail: detail, load: { snapshot })
    }
}

enum TranscriptHandoffSkills {
    static let followUpReference = ReadbackSkillPackReference(id: "workbench-follow-up", version: "1.0.0", name: "Prepare follow-up")

    static func followUpSnapshot() -> ReadbackSkillPackSnapshot {
        ReadbackSkillPackSnapshot(reference: followUpReference, files: [TranscriptHandoffStore.skillEntryPoint: Data(followUpSkill.utf8)])
    }

    static let followUpSkill = """
    ---
    name: prepare-workbench-follow-up
    description: Use selected dictation and optional screen evidence to prepare the requested follow-up.
    ---

    # Prepare follow-up

    Read `handoff.json`. It lists only the transcripts the person selected, in saved-history order, and any Snap & Talk evidence they explicitly included.

    When `transcriptRole` is `instructions`, the person has adopted the selected dictation as their request. Follow that request, using the cleaned wording and checking the original when it changes the meaning. When the role is `reference`, treat the transcripts as quoted source material and use the person's direct request to decide the output. Screenshots and their paired narration remain reference material in both modes.

    Prepare the requested draft, prompt, summary or follow-up inside `outputs/`. If the request does not specify a format, write a concise `follow-up.md`. Preserve the chosen audience, tone and purpose. Do not invent decisions, commitments, names, dates or results. Identify any essential gaps without turning the draft into a checklist of caveats.

    Keep each screenshot paired with its own narration. Use only the selected material; do not search other sessions or history. Keep `inputs/`, `handoff.json` and `SKILL.md` unchanged. This handoff authorizes preparation of local work. Sending, publishing or uploading requires the person's direct authorization in the receiving assistant.
    """
}

/// Structural validation for any skill used as a handoff entry point. Bundled
/// deck packs additionally keep their exact-payload check.
enum TranscriptHandoffSkillCheck {
    static let bundledDeckIdentifiers = [ReadbackSkillPackReference.neutral.id, ReadbackSkillPackReference.serviceNow.id]
    static let reservedPaths = ["handoff.json", "readme.md", "skill-pack.json", "session.json"]

    static func validate(_ snapshot: ReadbackSkillPackSnapshot) throws {
        try snapshot.validate()
        let reference = snapshot.reference
        guard reference.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil,
              reference.version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              !reference.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptHandoffError.message("The chosen skill has no usable id, version and name. No handoff folder was created.")
        }
        guard let entry = snapshot.files[TranscriptHandoffStore.skillEntryPoint], !entry.isEmpty,
              String(data: entry, encoding: .utf8) != nil else {
            throw TranscriptHandoffError.message("The chosen skill has no readable \(TranscriptHandoffStore.skillEntryPoint) entry point. No handoff folder was created.")
        }
        guard (1...TranscriptHandoffLimits.maxSkillFiles).contains(snapshot.files.count) else {
            throw TranscriptHandoffError.message("The chosen skill has an unsupported number of files. No handoff folder was created.")
        }
        for path in snapshot.files.keys.sorted() {
            guard isSafeRelativePath(path) else {
                throw TranscriptHandoffError.message("The chosen skill contains an unsafe file path (\(path)). No handoff folder was created.")
            }
            guard !reservedPaths.contains(path.lowercased()), !path.lowercased().hasPrefix("inputs/"), !path.lowercased().hasPrefix("outputs/") else {
                throw TranscriptHandoffError.message("The chosen skill cannot supply \(path); that name belongs to the handoff folder. No handoff folder was created.")
            }
            let data = snapshot.files[path]!
            guard !data.isEmpty, data.count <= TranscriptHandoffLimits.maxSkillFileBytes else {
                throw TranscriptHandoffError.message("The chosen skill file \(path) is empty or too large. No handoff folder was created.")
            }
        }
        // A bundled deck pack must still be its exact complete payload.

    }

    /// A portable relative path: no absolute root, traversal, empty or hidden
    /// component, and no Windows-style separator smuggled into one component.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.count <= 512 else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 16 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && !component.hasPrefix(".") && !component.contains("\\") && !component.contains(":")
                && component.count <= 96
        }
    }
}

enum TranscriptHandoffSelection {
    /// Resolve selected identifiers against the saved history. Order follows the
    /// history, a removed transcript simply stops being selected, and a search
    /// can never add an item the person did not choose.
    static func resolve(_ selection: Set<UUID>, in history: [Transcript]) -> [Transcript] {
        history.filter { selection.contains($0.id) }
    }
}

struct TranscriptHandoffTranscript: Codable, Equatable {
    /// The saved Workbench transcript identifier, so a draft can be traced back.
    var id: UUID
    var index: Int
    var capturedAt: Date
    var seconds: Double
    var words: Int
    var cleanup: String?
    var hasSeparateOriginal: Bool
    var cleanedFile: String
    var originalFile: String
    var cleanedText: String
    var originalText: String
}

struct TranscriptHandoffEvidenceSection: Codable, Equatable {
    var id: UUID
    var index: Int
    var capturedAt: Date
    var displayName: String
    var status: String
    var screenshot: String
    var audio: String?
    var originalTranscript: String?
    var editedTranscript: String?
}

/// One explicitly selected Snap & Talk session, copied as evidence. Only the
/// live referenced files travel: Recently Deleted sections, replaced-file
/// archives and unreferenced files in the source folder stay behind.
struct TranscriptHandoffEvidence: Codable, Equatable {
    var kind = "snap-and-talk-session"
    var sessionID: UUID
    var sessionTitle: String
    /// Folder name only. A handoff never records where the source lives.
    var sourceFolderName: String
    var createdAt: Date
    var updatedAt: Date
    /// The session's own recorded skill, kept as provenance. Its skill files are
    /// not copied, so this handoff keeps one SKILL.md entry point.
    var sessionSkill: ReadbackSkillPackReference?
    var directory: String
    var sections: [TranscriptHandoffEvidenceSection]
}

enum TranscriptHandoffRole: String, Codable, CaseIterable {
    case instructions, reference
    var title: String { self == .instructions ? "My instructions" : "Reference material" }
}

struct TranscriptHandoffManifest: Codable, Equatable {
    static let currentFormat = 1
    var formatVersion = currentFormat
    var transcriptRole: TranscriptHandoffRole = .instructions
    var id: UUID
    var title: String
    var createdAt: Date
    var source = "Workbench Recent transcriptions"
    var skill: ReadbackSkillPackReference
    var skillEntryPoint = TranscriptHandoffStore.skillEntryPoint
    var skillFiles: [String]
    var outputs = TranscriptHandoffStore.outputsDirectory
    var transcripts: [TranscriptHandoffTranscript]
    var evidence: TranscriptHandoffEvidence?
}

struct TranscriptHandoffRequest {
    var title: String
    /// The transcripts the person selected, in the order shown.
    var transcripts: [Transcript]
    var skill: ReadbackSkillPackSnapshot
    /// An explicitly chosen existing Snap & Talk session folder, or nil.
    var evidenceSession: URL? = nil
    var transcriptRole: TranscriptHandoffRole = .instructions
    var id = UUID()
    var createdAt = Date()
}

/// Builds one clean portable handoff folder from selected transcripts, a
/// complete chosen skill and optional explicitly selected screen evidence.
/// Everything is staged privately and committed with a single move, so an
/// invalid input can never leave a published half-folder behind.
enum TranscriptHandoffStore {
    static let manifestName = "handoff.json"
    static let skillEntryPoint = "SKILL.md"
    static let transcriptsDirectory = "inputs/transcripts"
    static let evidenceDirectory = "inputs/evidence"
    static let outputsDirectory = "outputs"
    static let outputsPlaceholder = "PLACE-RESULTS-HERE.md"
    static let stagingPrefix = ".workbench-handoff-"

    struct Result {
        let folder: URL
        let manifest: TranscriptHandoffManifest
    }

    /// Check everything that does not depend on the destination, so the person
    /// is not asked to name a folder for a handoff that cannot be produced.
    static func validate(_ request: TranscriptHandoffRequest) throws {
        try TranscriptHandoffSkillCheck.validate(request.skill)
        _ = try records(for: request.transcripts)
        if let session = request.evidenceSession { _ = try evidence(at: session) }
    }

    @discardableResult
    static func create(_ request: TranscriptHandoffRequest, at destination: URL) throws -> Result {
        let fm = FileManager.default
        try TranscriptHandoffSkillCheck.validate(request.skill)
        let transcripts = try records(for: request.transcripts)
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else {
            throw TranscriptHandoffError.message("Choose a folder name for this handoff. Nothing was created.")
        }
        if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw TranscriptHandoffError.message("A handoff folder cannot be a symbolic link. Choose another name; nothing was created or replaced.")
        }
        var destinationExisted = false
        if fm.fileExists(atPath: destination.path) {
            guard (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw TranscriptHandoffError.message("A file already exists with that name. Choose another name; nothing was created or replaced.")
            }
            guard try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty else {
                throw TranscriptHandoffError.message("Choose a new or empty folder so existing files are never replaced. Nothing was created.")
            }
            destinationExisted = true
        }
        var parentIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw TranscriptHandoffError.message("The folder you chose is no longer available. Nothing was created.")
        }
        // Read the optional evidence before writing anything, so a moved or
        // malformed session fails while the destination is still untouched.
        let evidenceSource = try request.evidenceSession.map { try evidence(at: $0) }

        let staging = parent.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        var committed = false
        // Only this staging folder is ever removed by Workbench.
        defer { if !committed { try? fm.removeItem(at: staging) } }
        try ReadbackStore.createPrivateDirectory(staging, includingParents: false)

        for path in request.skill.files.keys.sorted() {
            let url = try safeURL(root: staging, relative: path)
            try ReadbackStore.createPrivateDirectory(url.deletingLastPathComponent())
            try ReadbackStore.writePrivate(request.skill.files[path]!, to: url)
        }
        try ReadbackStore.createPrivateDirectory(try safeURL(root: staging, relative: transcriptsDirectory))
        for record in transcripts {
            try ReadbackStore.writePrivate(Data(record.cleanedText.utf8), to: try safeURL(root: staging, relative: record.cleanedFile))
            try ReadbackStore.writePrivate(Data(record.originalText.utf8), to: try safeURL(root: staging, relative: record.originalFile))
        }
        if let evidenceSource {
            for file in evidenceSource.files {
                let url = try safeURL(root: staging, relative: file.relative)
                try ReadbackStore.createPrivateDirectory(url.deletingLastPathComponent())
                // Copy: the source session is never moved or modified.
                try fm.copyItem(at: file.source, to: url)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        let outputs = try safeURL(root: staging, relative: outputsDirectory)
        try ReadbackStore.createPrivateDirectory(outputs)
        // Only this marker, so an empty results folder survives copying or zipping.
        try ReadbackStore.writePrivate(Data("Results belong in this folder. Workbench created it with nothing else in it.\n".utf8), to: outputs.appendingPathComponent(outputsPlaceholder))

        let manifest = TranscriptHandoffManifest(
            transcriptRole: request.transcriptRole, id: request.id, title: request.title, createdAt: request.createdAt,
            skill: request.skill.reference, skillFiles: request.skill.files.keys.sorted(),
            transcripts: transcripts, evidence: evidenceSource?.record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try ReadbackStore.writePrivate(try encoder.encode(manifest), to: staging.appendingPathComponent(manifestName))
        try ReadbackStore.writePrivate(Data(readme(for: manifest).utf8), to: staging.appendingPathComponent("README.md"))

        if destinationExisted { try fm.removeItem(at: destination) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch {
            if destinationExisted { try? ReadbackStore.createPrivateDirectory(destination) }
            throw TranscriptHandoffError.message("The handoff folder could not be created. \(error.localizedDescription) Your transcripts and any selected session are unchanged, and nothing was sent anywhere.")
        }
        committed = true
        return Result(folder: destination, manifest: manifest)
    }

    static func records(for transcripts: [Transcript]) throws -> [TranscriptHandoffTranscript] {
        guard !transcripts.isEmpty else {
            throw TranscriptHandoffError.message("Select at least one transcript before handing off. Nothing was created.")
        }
        guard transcripts.count <= TranscriptHandoffLimits.maxTranscripts else {
            throw TranscriptHandoffError.message("Select at most \(TranscriptHandoffLimits.maxTranscripts) transcripts for one handoff. Nothing was created.")
        }
        var seen = Set<UUID>()
        return try transcripts.enumerated().map { offset, item in
            guard seen.insert(item.id).inserted else {
                throw TranscriptHandoffError.message("The same transcript was selected twice. Nothing was created.")
            }
            let cleaned = item.text
            let original = item.rawText ?? item.text
            guard cleaned.count <= TranscriptHandoffLimits.maxTranscriptCharacters,
                  original.count <= TranscriptHandoffLimits.maxTranscriptCharacters else {
                throw TranscriptHandoffError.message("One selected transcript is too large to copy into a handoff folder. Nothing was created.")
            }
            let index = offset + 1
            let stem = String(format: "%03d", index) + "-" + item.id.uuidString.lowercased()
            return TranscriptHandoffTranscript(
                id: item.id, index: index, capturedAt: item.date, seconds: item.seconds,
                words: TextRules.wordCount(cleaned), cleanup: item.cleanupMethod,
                hasSeparateOriginal: original != cleaned,
                cleanedFile: transcriptsDirectory + "/" + stem + "-cleaned.txt",
                originalFile: transcriptsDirectory + "/" + stem + "-original.txt",
                cleanedText: cleaned, originalText: original)
        }
    }

    struct EvidenceFile {
        let relative: String
        let source: URL
    }

    struct EvidenceSource {
        let record: TranscriptHandoffEvidence
        let files: [EvidenceFile]
    }

    /// Read one explicitly selected Snap & Talk session and list exactly the
    /// live files that will travel. Nothing in the source is written or moved.
    static func evidence(at url: URL) throws -> EvidenceSource {
        let fm = FileManager.default
        let root = url.standardizedFileURL
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw TranscriptHandoffError.message("The selected Snap & Talk folder is a symbolic link. Choose the real session folder; nothing was created.")
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TranscriptHandoffError.message("The selected Snap & Talk session folder is not available. Nothing was created.")
        }
        let session: ReadbackManifest
        do { session = try ReadbackStore.load(from: root) }
        catch {
            throw TranscriptHandoffError.message("That folder is not a readable Snap & Talk session. \(error.localizedDescription) No handoff folder was created.")
        }
        let active = session.sections.filter { $0.deletedAt == nil }
        guard !active.isEmpty else {
            throw TranscriptHandoffError.message("That Snap & Talk session has no current sections to include. Items in Recently Deleted are never copied. Nothing was created.")
        }
        let directory = evidenceDirectory + "/session-" + session.id.uuidString.lowercased()
        var files: [EvidenceFile] = []
        var totalBytes = 0
        var sections: [TranscriptHandoffEvidenceSection] = []
        for (offset, section) in active.enumerated() {
            func include(_ relative: String?, label: String) throws -> String? {
                guard let relative else { return nil }
                // safeURL rejects traversal and any symbolic-link component.
                let source = try ReadbackStore.safeURL(root: root, relative: relative)
                guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, let size = values.fileSize, size > 0,
                      size <= TranscriptHandoffLimits.maxEvidenceFileBytes else {
                    throw TranscriptHandoffError.message("Section \(offset + 1) of the selected session is missing or cannot read its \(label). Nothing was created, and the session was not changed.")
                }
                totalBytes += size
                let target = directory + "/" + relative
                guard TranscriptHandoffSkillCheck.isSafeRelativePath(target) else {
                    throw TranscriptHandoffError.message("Section \(offset + 1) of the selected session uses an unsupported file path. Nothing was created.")
                }
                files.append(EvidenceFile(relative: target, source: source))
                return target
            }
            guard let screenshot = try include(section.screenshot, label: "screenshot") else {
                throw TranscriptHandoffError.message("Section \(offset + 1) of the selected session has no screenshot. Nothing was created.")
            }
            sections.append(TranscriptHandoffEvidenceSection(
                id: section.id, index: offset + 1, capturedAt: section.capturedAt,
                displayName: section.displayName, status: section.status.rawValue, screenshot: screenshot,
                audio: try include(section.audio, label: "narration audio"),
                originalTranscript: try include(section.originalTranscript, label: "original narration"),
                editedTranscript: try include(section.transcript, label: "edited narration")))
        }
        guard files.count <= TranscriptHandoffLimits.maxEvidenceFiles, totalBytes <= TranscriptHandoffLimits.maxEvidenceBytes else {
            throw TranscriptHandoffError.message("The selected session is too large to copy into a handoff folder. Nothing was created.")
        }
        let record = TranscriptHandoffEvidence(
            sessionID: session.id, sessionTitle: session.title, sourceFolderName: root.lastPathComponent,
            createdAt: session.createdAt, updatedAt: session.updatedAt, sessionSkill: session.skillPack,
            directory: directory, sections: sections)
        return EvidenceSource(record: record, files: files)
    }

    /// Relative paths inside the handoff folder stay portable and real.
    static func safeURL(root: URL, relative: String) throws -> URL {
        guard TranscriptHandoffSkillCheck.isSafeRelativePath(relative) else {
            throw TranscriptHandoffError.message("The handoff folder cannot use the path \(relative). Nothing was created.")
        }
        var candidate = root.standardizedFileURL
        for component in relative.split(separator: "/") {
            candidate.appendPathComponent(String(component))
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw TranscriptHandoffError.message("The handoff folder cannot follow a symbolic link. Nothing was created.")
            }
        }
        return candidate
    }

    static func readme(for manifest: TranscriptHandoffManifest) -> String {
        let evidence = manifest.evidence.map {
            "`\($0.directory)/` holds one Snap & Talk session you chose: \($0.sections.count) current section(s), each screenshot beside the narration recorded for it. Items in that session's Recently Deleted, its replaced-file history and its own deck skill were not copied. The original session folder is unchanged."
        } ?? "No screen evidence was included in this handoff."
        return """
        # \(manifest.title)

        This is a portable Workbench handoff folder, created from transcripts you selected in Recent transcriptions.

        - `\(manifest.skillEntryPoint)` is the single task entry point: the \(manifest.skill.name) skill, pack \(manifest.skill.id) version \(manifest.skill.version).
        - `\(TranscriptHandoffStore.manifestName)` is the authoritative typed record of this handoff: the selected transcripts with their original Workbench ids and capture times, both wordings, the skill and any included evidence.
        - `\(TranscriptHandoffStore.transcriptsDirectory)/` holds plain-text copies of each selected transcript: `-cleaned.txt` is the wording you kept and `-original.txt` is the original recognised wording.
        - \(evidence)
        - `\(manifest.outputs)/` is where results belong. It holds nothing but a short placeholder note.

        Only the \(manifest.transcripts.count) transcript(s) you selected are here. Your other saved transcripts, your history file and unselected sessions were not copied or referenced.

        Workbench copied these files on this Mac. It did not send, upload or submit anything, and the assistant you choose has no authority to send anything for you. Review any draft in `\(manifest.outputs)/` before you send it.

        Keep this folder private when its transcripts or screenshots contain sensitive information.
        """
    }
}

extension ReadbackHandoffBrief {
    /// The same copied-prompt pattern as Snap & Talk, pointed at the chosen
    /// skill and this handoff's own manifest instead of a slide deck.
    static func transcriptHandoff(_ manifest: TranscriptHandoffManifest) -> Self {
        let evidence = manifest.evidence.map { " and \($0.sections.count) screen section(s) from the Snap & Talk session named in the manifest" } ?? ""
        return Self(
            skillEntryPoint: manifest.skillEntryPoint,
            folderDescription: "Workbench handoff folder",
            pathLabel: "Handoff folder",
            scopeDescription: "handoff folder",
            manifestName: TranscriptHandoffStore.manifestName,
            task: "follow the \(manifest.skill.name) skill using the selected instructions and evidence it lists",
            preservation: "Keep `\(TranscriptHandoffStore.transcriptsDirectory.components(separatedBy: "/").first ?? "inputs")/`, `\(TranscriptHandoffStore.manifestName)` and `\(manifest.skillEntryPoint)` unchanged, and write results in `\(manifest.outputs)/`.",
            extra: "It contains \(manifest.transcripts.count) transcript(s) I selected\(evidence). \(manifest.transcriptRole == .instructions ? "I have selected these dictations as my instructions; follow their request." : "Treat these transcripts as reference material for my request.") Screens and their narration are reference material. Prepare the work locally for my review; this handoff does not authorize sending or publishing.")
    }
}

/// Panel, folder creation, prompt copying and app opening for a transcript
/// handoff. It reuses the existing Snap & Talk delivery behaviour and owns no
/// persisted state, so it is not a second store or selection owner.
@MainActor
final class TranscriptHandoffRunner: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published var status: String?
    @Published var failure: String?
    @Published private(set) var lastFolder: URL?

    /// Overridable for checks and previews; the default is the native panel.
    var chooseDestination: (String) -> URL? = { message in
        let panel = NSSavePanel()
        panel.title = "Create Handoff Folder"
        panel.prompt = "Create Folder"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = "Workbench Handoff"
        panel.message = message
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Overridable for checks; the default is the native session chooser.
    var chooseEvidenceSession: () -> URL? = {
        let panel = NSOpenPanel()
        panel.title = "Choose Snap & Talk Session"
        panel.prompt = "Use Session"
        panel.message = "The whole current session is copied as evidence: every current screenshot with the narration recorded for it. Recently Deleted sections and replaced files are not copied, and the original session is not changed."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func reset() { status = nil; failure = nil }

    func chooseEvidence() -> URL? {
        guard let url = chooseEvidenceSession() else { return nil }
        return useEvidence(url)
    }

    /// Accept a session the host already selected, without a panel. It is read
    /// and checked here so an unreadable folder is refused before any handoff.
    func useEvidence(_ url: URL) -> URL? {
        do {
            _ = try TranscriptHandoffStore.evidence(at: url)
            failure = nil
            return url.standardizedFileURL
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    func handOff(to target: ReadbackHandoffTarget, transcripts: [Transcript], skill: TranscriptHandoffSkill,
                 evidence: URL?, title: String = "Workbench handoff", role: TranscriptHandoffRole = .instructions) {
        guard !isPreparing else { return }
        status = nil; failure = nil
        isPreparing = true
        do {
            let snapshot = try skill.load()
            let request = TranscriptHandoffRequest(title: title, transcripts: transcripts, skill: snapshot, evidenceSession: evidence, transcriptRole: role)
            try TranscriptHandoffStore.validate(request)
            let summary = "\(transcripts.count) selected transcript(s) · \(skill.title)"
                + (evidence == nil ? " · no screen evidence" : " · one Snap & Talk session copied as evidence")
                + ". Workbench copies them into this new folder on your Mac and sends nothing."
            guard let destination = chooseDestination(summary) else { isPreparing = false; return }
            Task {
                defer { isPreparing = false }
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try TranscriptHandoffStore.create(request, at: destination)
                    }.value
                    lastFolder = result.folder
                    deliver(result, to: target)
                } catch { failure = error.localizedDescription }
            }
        } catch {
            isPreparing = false
            failure = error.localizedDescription
        }
    }

    private func deliver(_ result: TranscriptHandoffStore.Result, to target: ReadbackHandoffTarget) {
        let prompt = target.prompt(for: result.folder, brief: .transcriptHandoff(result.manifest))
        NSWorkspace.shared.activateFileViewerSelecting([result.folder])
        guard TextDelivery.copy(prompt) != nil else {
            failure = "The handoff folder “\(result.folder.lastPathComponent)” was created and shown in Finder, but its prompt could not be copied. Open \(target.title) and describe the folder yourself. Nothing was sent anywhere."
            return
        }
        guard let applicationURL = target.bundleIdentifiers.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            status = "Handoff folder created and shown in Finder, and its prompt copied. Open \(target.title), add this folder, then paste the prompt. Nothing was uploaded."
            return
        }
        status = "Handoff folder created and its prompt copied. \(target.title) is opening. Give it access to this folder, then paste the prompt. Nothing was uploaded."
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.failure = "\(target.title) could not open: \(error.localizedDescription) The prompt is copied and the handoff folder is shown in Finder. Nothing was uploaded."
            }
        }
    }
}
