import Darwin
import Foundation

// Report a problem (#296): the edition's private report folder. One unfinished draft, and an
// outbox of frozen reports with their delivery state. It is a deliberate exception to History:
// neither the draft nor the outbox is a user library, and nothing here is captured work.
//
//   Application Support/Workbench[ Preview]/Reports/        0700
//     draft/      draft.json, screenshot.png, voice.wav     the one unfinished draft
//     outbox/<report id>/  report.envelope, delivery.json   frozen before any network
//     staging/    a report being frozen; never sent from here
//
// Files are 0600 and written durably (temporary file, F_FULLFSYNC, rename). Nothing here is
// logged. Unsent reports are never evicted to make room.

/// The one unfinished report, kept while the composer is closed and across launches.
struct BugReportDraft: Codable, Equatable {
    var explanation = ""
    var replyEmail = ""
    var origin: BugReportOrigin
    var context: BugReportContext
    var build: BugReportBuild
    /// When reporting was invoked. Evidence only; the receiver keeps its own clock.
    var createdAt: Date?
    var screenshot: BugReportImageInfo?
    var voiceSeconds: Double?

    var isEmpty: Bool { explanation.isEmpty && replyEmail.isEmpty && screenshot == nil && voiceSeconds == nil }
    var contents: [String] {
        [BugReportText.hasVisibleText(explanation) ? "text" : nil, screenshot != nil ? "screenshot" : nil, voiceSeconds != nil ? "voice" : nil].compactMap { $0 }
    }
}

/// One attachment as the verifier compares it with what Sentry stored.
struct BugReportVerifiedFile: Codable, Equatable {
    var name: String
    var size: Int
    var sha256: String
    var object: [String: Any] { ["name": name, "size": size, "sha256": sha256] }
}

/// A frozen report's delivery, the only file in its folder that changes.
struct BugReportDelivery: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        /// Not yet accepted, waiting for a connection.
        case waiting
        /// Being sent, or trying again after the service asked it to wait.
        case sending
        /// Sentry accepted it. Received needs the verifier.
        case sent
        /// The verifier found the event and every attachment.
        case received
        /// The verifier could not find it, or found different bytes, within its window.
        case unconfirmed
        /// Refused in a way that retrying the same bytes cannot fix by itself.
        case failed
    }
    enum Problem: String, Codable {
        case offline, busy, rateLimited, tooLarge, rejected, unauthorized, secureConnection, unreadable, mismatch, notFound
        /// An earlier attempt may have reached Sentry more than 55 minutes ago, past its
        /// one-hour duplicate filter, so the same event ID is not sent again by itself.
        case uncertain
    }
    /// The report ID, also the folder's name.
    var id: String
    /// The current attempt's Sentry event ID; Sentry drops a repeated one.
    var eventID: String
    var previousEventIDs: [String] = []
    var destination: BugReportDestination
    var envelopeSHA256: String
    var envelopeBytes: Int
    /// The attachments' names, sizes and SHA-256, kept here so checking never depends on the envelope.
    var files: [BugReportVerifiedFile]
    /// `text`, `screenshot` and `voice`, for the receipt's line.
    var contents: [String]
    var state: State
    var problem: Problem?
    var status: Int?
    var attempts = 0
    var nextAttemptAt: Date?
    /// The first attempt for this event ID that may have reached Sentry (a lost reply, a time-out or a
    /// server error). Attempts that never connected do not count.
    var mayHaveArrivedAt: Date?
    var createdAt: Date
    var sentAt: Date?
    var verifyAttempts = 0
    var verifyUntil: Date?
    var verifierState: String?
    /// The window ended without an answer: ask the verifier once more at the next launch.
    var verifyAtLaunch = false
    /// That launch check has been made for the current event ID.
    var launchCheckUsed = false
    var receivedAt: Date?
    var evidenceRemoved = false

    var shortID: String { BugReportText.shortID(id) }
    var isUnsent: Bool { [.waiting, .sending, .failed, .unconfirmed].contains(state) }
    /// Delivered, and nothing more will be asked about it: its local copy may go to make room.
    var isSettled: Bool {
        state == .received || (state == .sent && nextAttemptAt == nil && !verifyAtLaunch)
    }
}

@MainActor
final class BugReportStore {
    struct Limits {
        var entries = BugReportLimits.outboxEntries
        var bytes = BugReportLimits.outboxBytes
        /// A sent report's local copy is kept as long as the team keeps it, for Save a copy.
        var sentEvidence: TimeInterval = 30 * 86_400
        /// Receipts outlive the evidence, then go too.
        var receipts: TimeInterval = 90 * 86_400
        var receiptCount = 50
    }
    let root: URL
    let limits: Limits
    var now: () -> Date
    /// Free space for a new report; nil when unknown.
    var availableCapacity: () -> Int64?

    init(root: URL, limits: Limits = Limits(), now: @escaping () -> Date = Date.init, availableCapacity: (() -> Int64?)? = nil) {
        self.root = root; self.limits = limits; self.now = now
        self.availableCapacity = availableCapacity ?? {
            let values = try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
    }

    var draftFolder: URL { root.appendingPathComponent("draft", isDirectory: true) }
    var outboxFolder: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    var stagingFolder: URL { root.appendingPathComponent("staging", isDirectory: true) }
    /// Where a voice note records before it becomes the draft's voice.wav.
    var recordingURL: URL { draftFolder.appendingPathComponent("recording.wav") }
    private var draftFile: URL { draftFolder.appendingPathComponent("draft.json") }

    // MARK: Draft

    func loadDraft() -> BugReportDraft? {
        guard let data = try? BugReportFiles.read(draftFile, maximum: 256 * 1_024) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard var draft = try? decoder.decode(BugReportDraft.self, from: data) else { return nil }
        // A file that went missing drops its description rather than pointing at nothing.
        if draft.screenshot != nil, draftScreenshot() == nil { draft.screenshot = nil }
        if draft.voiceSeconds != nil, draftVoice() == nil { draft.voiceSeconds = nil }
        return draft
    }

    func saveDraft(_ draft: BugReportDraft) throws {
        try BugReportFiles.directory(root); try BugReportFiles.directory(draftFolder)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try BugReportFiles.writeDurably(try encoder.encode(draft), to: draftFile)
    }

    func draftScreenshot() -> Data? { try? BugReportFiles.read(draftFolder.appendingPathComponent(BugReportAttachment.screenshot), maximum: BugReportLimits.screenshotBytes) }
    func draftVoice() -> Data? { try? BugReportFiles.read(draftFolder.appendingPathComponent(BugReportAttachment.voice), maximum: BugReportLimits.voiceBytes) }

    func setDraftScreenshot(_ data: Data?) throws { try setDraftFile(BugReportAttachment.screenshot, data) }
    func setDraftVoice(_ data: Data?) throws { try setDraftFile(BugReportAttachment.voice, data) }

    private func setDraftFile(_ name: String, _ data: Data?) throws {
        let url = draftFolder.appendingPathComponent(name)
        if let data {
            try BugReportFiles.directory(root); try BugReportFiles.directory(draftFolder)
            try BugReportFiles.writeDurably(data, to: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Prepares the folder a recording is written into.
    func prepareRecording() throws -> URL {
        try BugReportFiles.directory(root); try BugReportFiles.directory(draftFolder)
        try? FileManager.default.removeItem(at: recordingURL)
        return recordingURL
    }

    func clearDraft() throws {
        guard FileManager.default.fileExists(atPath: draftFolder.path) else { return }
        try FileManager.default.removeItem(at: draftFolder)
    }

    // MARK: Outbox

    /// Freezes one report: reserves room, then writes its envelope and delivery to staging and
    /// moves the folder into the outbox in one rename. Any failure leaves no outbox entry, so
    /// Send has not started; the caller keeps the draft.
    func freeze(envelope: Data, delivery: BugReportDelivery) throws {
        guard delivery.id.range(of: "^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$", options: .regularExpression) != nil else {
            throw BugReportError.message("The report could not be saved.")
        }
        try BugReportFiles.directory(root); try BugReportFiles.directory(outboxFolder); try BugReportFiles.directory(stagingFolder)
        try reserve(Int64(envelope.count))
        let staging = stagingFolder.appendingPathComponent(delivery.id, isDirectory: true)
        let destination = outboxFolder.appendingPathComponent(delivery.id, isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: staging)
            try BugReportFiles.directory(staging)
            try BugReportFiles.writeDurably(envelope, to: staging.appendingPathComponent("report.envelope"))
            try BugReportFiles.writeDurably(try Self.encode(delivery), to: staging.appendingPathComponent("delivery.json"))
            guard rename(staging.path, destination.path) == 0 else { throw BugReportError.message("") }
            BugReportFiles.syncDirectory(outboxFolder)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw BugReportError.message("The report could not be saved on this Mac, so nothing was sent. Your draft is kept.")
        }
    }

    /// Room for a new report, made only by dropping delivered reports' local copies, oldest first.
    private func reserve(_ bytes: Int64) throws {
        func fits() -> Bool {
            let use = usage()
            return use.entries + 1 <= limits.entries && use.bytes + bytes <= limits.bytes
        }
        if !fits() {
            for delivery in deliveries().reversed() where !delivery.evidenceRemoved && delivery.isSettled {
                removeEvidence(delivery.id)
                if fits() { break }
            }
        }
        guard fits() else {
            throw BugReportError.full("Workbench is still holding \(usage().entries) unsent reports, so this one can't be added. Save a copy instead; your draft is kept.")
        }
        if let free = availableCapacity(), free < bytes + 8 * 1_024 * 1_024 {
            throw BugReportError.full("This Mac doesn't have room to keep the report for sending. Save a copy somewhere with space; your draft is kept.")
        }
    }

    /// Reports holding evidence, and their bytes including anything in staging.
    func usage() -> (entries: Int, bytes: Int64) {
        let holding = deliveries().filter { !$0.evidenceRemoved }
        let staged = BugReportFiles.size(stagingFolder)
        return (holding.count, holding.reduce(staged) { $0 + BugReportFiles.size(outboxFolder.appendingPathComponent($1.id, isDirectory: true)) })
    }

    /// Every report in the outbox, newest first.
    func deliveries() -> [BugReportDelivery] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: outboxFolder.path) else { return [] }
        return names.compactMap(delivery).sorted { $0.createdAt > $1.createdAt }
    }

    func delivery(_ id: String) -> BugReportDelivery? {
        guard !id.contains("/"), !id.hasPrefix("."),
              let data = try? BugReportFiles.read(outboxFolder.appendingPathComponent(id).appendingPathComponent("delivery.json"), maximum: 64 * 1_024) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let delivery = try? decoder.decode(BugReportDelivery.self, from: data), delivery.id == id else { return nil }
        return delivery
    }

    /// Saves a delivery only while its report is still in the outbox, so a late result can never
    /// bring back a report removed from this Mac.
    func save(_ delivery: BugReportDelivery) throws {
        let folder = outboxFolder.appendingPathComponent(delivery.id, isDirectory: true)
        guard self.delivery(delivery.id) != nil else { return }
        try BugReportFiles.writeDurably(try Self.encode(delivery), to: folder.appendingPathComponent("delivery.json"))
    }

    func envelope(_ id: String) throws -> Data {
        try BugReportFiles.read(outboxFolder.appendingPathComponent(id).appendingPathComponent("report.envelope"),
                                maximum: BugReportLimits.payloadBytes + 1_024 * 1_024)
    }

    /// Send again: a new envelope for the same report, with a new event ID.
    func replaceEnvelope(_ id: String, with data: Data, delivery: BugReportDelivery) throws {
        guard self.delivery(id) != nil else { throw BugReportError.message("This report is no longer on this Mac.") }
        let folder = outboxFolder.appendingPathComponent(id, isDirectory: true)
        try BugReportFiles.writeDurably(data, to: folder.appendingPathComponent("report.envelope"))
        try save(delivery)
    }

    /// After delivery: drop the envelope and keep the receipt.
    func removeEvidence(_ id: String) {
        guard var delivery = delivery(id), !delivery.evidenceRemoved else { return }
        try? FileManager.default.removeItem(at: outboxFolder.appendingPathComponent(id).appendingPathComponent("report.envelope"))
        delivery.evidenceRemoved = true
        try? save(delivery)
    }

    /// Remove from this Mac: the report's folder, evidence and receipt.
    func remove(_ id: String) throws {
        guard !id.contains("/"), !id.hasPrefix(".") else { return }
        let folder = outboxFolder.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Delivered copies past the team's retention and receipts past theirs. Unsent reports stay.
    func prune() {
        let now = now()
        var receipts = 0
        for delivery in deliveries() {
            let delivered = delivery.receivedAt ?? delivery.sentAt
            if delivery.isSettled, !delivery.evidenceRemoved, let delivered, now.timeIntervalSince(delivered) > limits.sentEvidence {
                removeEvidence(delivery.id)
            }
            guard delivery.isSettled else { continue }
            receipts += 1
            if receipts > limits.receiptCount || now.timeIntervalSince(delivered ?? delivery.createdAt) > limits.receipts { try? remove(delivery.id) }
        }
        if let staged = try? FileManager.default.contentsOfDirectory(atPath: stagingFolder.path) {
            for name in staged { try? FileManager.default.removeItem(at: stagingFolder.appendingPathComponent(name)) }
        }
    }

    // MARK: Save a copy

    /// A new folder in `parent` with fixed names, context.json and any screenshot.png and
    /// voice.wav. It never writes into an existing folder or over a file.
    func export(manifest: Data, screenshot: Data?, voice: Data?, shortID: String, to parent: URL) throws -> URL {
        let base = "Workbench report \(shortID)"
        var folder: URL?
        for index in 1...500 {
            let candidate = parent.appendingPathComponent(index == 1 ? base : "\(base) \(index)", isDirectory: true)
            if mkdir(candidate.path, 0o700) == 0 { folder = candidate; break }
            guard errno == EEXIST else { break }
        }
        guard let folder else { throw BugReportError.message("A copy could not be saved there. Choose another folder.") }
        do {
            try manifest.write(to: folder.appendingPathComponent("context.json"), options: .withoutOverwriting)
            if let screenshot { try screenshot.write(to: folder.appendingPathComponent(BugReportAttachment.screenshot), options: .withoutOverwriting) }
            if let voice { try voice.write(to: folder.appendingPathComponent(BugReportAttachment.voice), options: .withoutOverwriting) }
            for name in ["context.json", BugReportAttachment.screenshot, BugReportAttachment.voice] {
                let url = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw BugReportError.message("A copy could not be saved there. Choose another folder.")
        }
        return folder
    }

    /// Save a copy of a frozen report, read back from its envelope.
    func export(_ id: String, to parent: URL) throws -> URL {
        let items = try BugReportEnvelope.parse(try envelope(id)).items
        func payload(_ name: String) -> Data? { items.first { $0.type == "attachment" && $0.filename == name }?.payload }
        guard let manifest = payload("context.json") else { throw BugReportError.message("The saved report could not be read.") }
        return try export(manifest: manifest, screenshot: payload(BugReportAttachment.screenshot), voice: payload(BugReportAttachment.voice),
                          shortID: BugReportText.shortID(id), to: parent)
    }

    private static func encode(_ delivery: BugReportDelivery) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(delivery)
    }
}

/// Private, durable file operations for reports.
enum BugReportFiles {
    /// A 0700 directory that is not a symbolic link. Missing parents (the edition's Application
    /// Support folder on a fresh Mac) are created too.
    static func directory(_ url: URL) throws {
        var info = stat()
        let parent = url.deletingLastPathComponent()
        if lstat(parent.path, &info) != 0 {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw BugReportError.message("The report folder is not usable.") }
            if info.st_mode & 0o777 != 0o700 { chmod(url.path, 0o700) }
            return
        }
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw BugReportError.message("The report folder could not be created.") }
    }

    /// Writes a 0600 temporary file, flushes it to the disk and renames it into place.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BugReportError.message("The report could not be saved.") }
        var ok = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 { if errno == EINTR { continue }; return false }
                offset += written
            }
            return true
        }
        if ok, fcntl(descriptor, F_FULLFSYNC) != 0 { ok = fsync(descriptor) == 0 }
        close(descriptor)
        guard ok, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw BugReportError.message("The report could not be saved.")
        }
        syncDirectory(url.deletingLastPathComponent())
    }

    static func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        fsync(descriptor); close(descriptor)
    }

    /// Reads a regular file without following a symbolic link, up to `maximum` bytes.
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BugReportError.message("The file could not be read.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximum else {
            throw BugReportError.message("The file could not be read.")
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let got = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if got < 0 { if errno == EINTR { continue }; return -1 }
                if got == 0 { break }
                offset += got
            }
            return offset
        }
        guard count == data.count else { throw BugReportError.message("The file could not be read.") }
        return data
    }

    /// Bytes in a folder, without following links.
    static func size(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
