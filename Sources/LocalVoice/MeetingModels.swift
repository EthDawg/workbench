import Darwin
import Foundation

/// One audio-producing application the person can explicitly choose. A browser
/// entry covers that browser's whole audio output, including every tab in it.
struct MeetingAudioApp: Identifiable, Hashable {
    /// The process identifier. It is stable only while the app keeps running.
    var id: Int32
    var name: String
    var bundleID: String
}

enum MeetingAppKind: String, Codable {
    case communication, browser
}

/// Only apps in this catalogue are considered by detection. Nothing
/// here inspects window titles, page contents or the browser's automation API.
struct MeetingKnownApp {
    let bundleID: String
    let name: String
    let kind: MeetingAppKind
    /// False until remote-stream capture from this app has been checked on real
    /// hardware. Nothing in this module may claim a verified two-sided recording.
    let remoteAudioVerified: Bool
}

enum MeetingAppCatalogue {
    static let supported: [MeetingKnownApp] = [
        MeetingKnownApp(bundleID: "us.zoom.xos", name: "Zoom", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.webex.meetingmanager", name: "Webex Meetings", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.hnc.Discord", name: "Discord", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.skype.skype", name: "Skype", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.ringcentral.glip", name: "RingCentral", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.gotomeeting.GoToMeeting", name: "GoTo Meeting", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.apple.FaceTime", name: "FaceTime", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.apple.mobilephone", name: "Phone", kind: .communication, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.google.Chrome", name: "Google Chrome", kind: .browser, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.apple.Safari", name: "Safari", kind: .browser, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", kind: .browser, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "company.thebrowser.Browser", name: "Arc", kind: .browser, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "org.mozilla.firefox", name: "Firefox", kind: .browser, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.brave.Browser", name: "Brave", kind: .browser, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", kind: .browser, remoteAudioVerified: false),
        MeetingKnownApp(bundleID: "com.operasoftware.Opera", name: "Opera", kind: .browser, remoteAudioVerified: false)
    ]

    /// Never list, tap or detect Workbench itself, in any edition.
    static let excludedBundleIDs: Set<String> = [
        "com.ethdawg.workbench", "com.ethdawg.workbench.preview",
        "com.ethdawg.localvoice", "com.ethdawg.stagemark"
    ]

    /// Existing Mac audio-service sources stay manually selectable by their own
    /// PID and bundle. These labels neither enable detection nor merge their
    /// capture scope into FaceTime/Phone/Safari. Receiver support needs testing.
    static let manualServiceNames = [
        "com.apple.avconferenced": "Mac calling service",
        "com.apple.TelephonyUtilities": "Mac telephony service",
        "com.apple.WebKit.GPU": "WebKit audio service (shared)"
    ]

    /// Observed call activity on this Mac ran through this exact service.
    /// Two-way activity can offer a possible call, not prove its type or that
    /// both sides are recordable. Its capture scope stays separate from apps.
    static let callServiceBundleIDs: Set<String> = ["com.apple.avconferenced"]

    static func known(_ bundleID: String) -> MeetingKnownApp? {
        supported.first { bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".helper") }
    }

    static func isExcluded(_ bundleID: String) -> Bool {
        if excludedBundleIDs.contains(bundleID) { return true }
        return bundleID == Bundle.main.bundleIdentifier || excludedBundleIDs.contains(where: { bundleID.hasPrefix($0 + ".") })
    }

    /// The single sentence the surface shows next to a chosen source. It names
    /// the limits instead of implying a proven two-sided recording.
    static func sourceCaution(for app: MeetingAudioApp) -> String? {
        guard let known = known(app.bundleID) else { return nil }
        if known.kind == .browser {
            return "\(known.name) records everything that browser plays, including other tabs."
        }
        if !known.remoteAudioVerified {
            return "Recording other people from \(known.name) has not been checked on this Mac yet. Play back the result before relying on it."
        }
        return nil
    }
}

enum MeetingError: LocalizedError {
    case message(String)
    case futureFormat(Int)
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .futureFormat(let version):
            return "This meeting recording uses format \(version); this Workbench supports format \(MeetingManifest.currentFormat). Its folder was left unchanged."
        case .unsafePath:
            return "The meeting folder contains an unsafe path or a symbolic link. It was left unchanged."
        }
    }
}

enum MeetingTrackSource: String, Codable, Hashable, Sendable {
    case remote, local
}

/// One preserved original track, written straight through during capture.
struct MeetingTrack: Codable, Equatable, Sendable {
    var source: MeetingTrackSource
    var file: String
    /// Seconds between the session's host-clock reference and this track's first
    /// sample. Mixing uses it so neither side is shifted onto the other.
    var startSeconds: Double
    var seconds: Double
    var sampleRate: Double
    var peak: Double
    /// Audio the bounded capture buffer could not keep. Reported, never hidden.
    var droppedSeconds: Double
}

/// One bounded chunk of the mixed timeline, sized for the shared engine.
struct MeetingSegment: Codable, Equatable, Sendable {
    var index: Int
    var file: String
    var startSeconds: Double
    var seconds: Double
    var bytes: Int
    /// Filled once this chunk is recognised. A retry resumes at the first nil.
    var text: String?
}

enum MeetingState: String, Codable, Sendable {
    /// Capture is in progress, or the app stopped before it could finish.
    case recording
    /// Originals are complete; segments are not planned yet.
    case stopped
    /// Segments exist; some may already carry text.
    case segmented
    /// Every segment has text; the transcript is not in history yet.
    case recognized
    /// The transcript is in history under this same identifier.
    case committed
}

struct MeetingManifest: Codable, Equatable, Sendable {
    static let currentFormat = 1
    var formatVersion = currentFormat
    /// Also the saved transcript's identifier, so a retry can never duplicate it.
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var purpose: String
    var appName: String?
    var appBundleID: String?
    var includesMicrophone: Bool
    var includesRemote: Bool
    var state: MeetingState
    var seconds: Double
    var tracks: [MeetingTrack] = []
    var segments: [MeetingSegment] = []
    /// Plain sentences about missing, quiet or interrupted audio.
    var gaps: [String] = []
    var failure: String?

    var orderedSegments: [MeetingSegment] { segments.sorted { $0.index < $1.index } }
    var recognizedText: String {
        orderedSegments.compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    var isFullyRecognized: Bool {
        !segments.isEmpty && segments.allSatisfy { $0.text != nil }
    }
    /// Anything that still holds audio the person has not received text for.
    var needsRecovery: Bool { state != .committed && (state == .recording || seconds > 0 || !tracks.isEmpty || !segments.isEmpty) }
}

/// Sizes for the shared recognition engine. A meeting is chunked so no request
/// approaches the 30-minute or 64 MB limits the ordinary Dictate path enforces.
enum MeetingSegmentPlan {
    static let sampleRate = 16_000.0
    static let bytesPerSecond = 32_000
    static let maximumSegmentSeconds = 600.0
    static let maximumSegmentBytes = 64 * 1024 * 1024
    static let maximumMeetingSeconds = 7_200.0
    static let minimumSegmentSeconds = 0.5

    struct Window: Equatable {
        var index: Int
        var start: Double
        var seconds: Double
        var bytes: Int { Int((seconds * Double(bytesPerSecond)).rounded()) }
    }

    /// The longest chunk that satisfies both the duration and the byte bound.
    static var segmentSeconds: Double {
        min(maximumSegmentSeconds, Double(maximumSegmentBytes) / Double(bytesPerSecond))
    }

    static func plan(totalSeconds: Double) -> [Window] {
        guard totalSeconds.isFinite, totalSeconds >= minimumSegmentSeconds else { return [] }
        let total = min(totalSeconds, maximumMeetingSeconds)
        let chunk = segmentSeconds
        var windows: [Window] = []
        var start = 0.0
        while start < total {
            let seconds = min(chunk, total - start)
            // Borrow from the previous window so even a short tail stays
            // transcribable without exceeding the ten-minute request bound.
            if seconds < minimumSegmentSeconds, var last = windows.popLast() {
                let borrowed = minimumSegmentSeconds - seconds
                last.seconds -= borrowed
                windows.append(last)
                windows.append(Window(index: windows.count, start: start - borrowed,
                                      seconds: minimumSegmentSeconds))
            } else {
                windows.append(Window(index: windows.count, start: start, seconds: seconds))
            }
            start += chunk
        }
        return windows
    }

    static func filename(index: Int) -> String {
        MeetingStore.segmentsDirectory + "/" + String(format: "segment-%04d.wav", index)
    }
}

/// Space checks are deliberately blunt: they refuse to start a long recording on
/// a nearly full disk and stop safely rather than corrupt an original track.
enum MeetingDiskBudget {
    static let requiredStartBytes: Int64 = 512 * 1024 * 1024
    static let stopFloorBytes: Int64 = 192 * 1024 * 1024
    /// The bounded live buffer each track keeps before it reports dropped audio.
    static let captureBufferSeconds = 8.0

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage { return capacity }
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let free = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }

    static func checkStartSpace(at url: URL) throws {
        guard let available = availableBytes(at: url) else { return }
        guard available >= requiredStartBytes else {
            throw MeetingError.message("There is not enough free disk space to record a meeting safely. Free about 500 MB and try again.")
        }
    }
}

/// One app-managed Meetings root. Each session owns a UUID directory holding a
/// versioned manifest, its original tracks and its bounded segments. Nothing
/// here deletes a session: only an explicit person-facing action may do that,
/// and this module never offers one.
enum MeetingStore {
    static let manifestName = "meeting.json"
    static let tracksDirectory = "tracks"
    static let segmentsDirectory = "segments"
    static let maximumManifestBytes = 4 * 1024 * 1024

    static func sessionURL(root: URL, id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    @discardableResult
    static func create(root: URL, manifest: MeetingManifest) throws -> URL {
        try createPrivateDirectory(root)
        let session = sessionURL(root: root, id: manifest.id)
        guard !FileManager.default.fileExists(atPath: session.path) else {
            throw MeetingError.message("A meeting folder with this identifier already exists. It was left unchanged.")
        }
        try createPrivateDirectory(session)
        try createPrivateDirectory(session.appendingPathComponent(tracksDirectory, isDirectory: true))
        try createPrivateDirectory(session.appendingPathComponent(segmentsDirectory, isDirectory: true))
        try save(manifest, at: session)
        return session
    }

    static func load(from session: URL) throws -> MeetingManifest {
        let url = try safeURL(session: session, relative: manifestName)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maximumManifestBytes else {
            throw MeetingError.message("The meeting record could not be read safely. Its folder was left unchanged.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest: MeetingManifest
        do { manifest = try decoder.decode(MeetingManifest.self, from: Data(contentsOf: url)) }
        catch {
            throw MeetingError.message("The meeting record could not be read. Its folder and audio were left unchanged. \(error.localizedDescription)")
        }
        // A newer Workbench may have written this. Read nothing else from it.
        guard manifest.formatVersion == MeetingManifest.currentFormat else {
            throw MeetingError.futureFormat(manifest.formatVersion)
        }
        guard manifest.id.uuidString == session.lastPathComponent else {
            throw MeetingError.message("The meeting record does not match its folder. It was left unchanged.")
        }
        try validate(manifest, at: session)
        return manifest
    }

    /// A staged sibling plus one atomic rename: a failed write leaves the
    /// previous durable record intact rather than a truncated one.
    static func save(_ manifest: MeetingManifest, at session: URL, replacing previous: MeetingManifest? = nil) throws {
        try validate(manifest, at: session)
        guard manifest.formatVersion == MeetingManifest.currentFormat else {
            throw MeetingError.futureFormat(manifest.formatVersion)
        }
        let url = try safeURL(session: session, relative: manifestName)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let previous, try Data(contentsOf: url) == encoded(previous) else {
                throw MeetingError.message("The meeting record changed outside this operation. It was left unchanged; retry after checking its folder.")
            }
        } else if previous != nil {
            throw MeetingError.message("The meeting record was moved or removed. Its audio was left unchanged.")
        }
        let data = try encoded(manifest)
        try writePrivate(data, to: url)
    }

    private static func encoded(_ value: MeetingManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= maximumManifestBytes else {
            throw MeetingError.message("The meeting record grew beyond its safe size and was not written.")
        }
        return data
    }

    private static func validate(_ manifest: MeetingManifest, at session: URL) throws {
        guard manifest.id.uuidString == session.lastPathComponent,
              ["meeting", "call"].contains(manifest.purpose),
              manifest.seconds.isFinite, manifest.seconds >= 0,
              manifest.seconds <= MeetingSegmentPlan.maximumMeetingSeconds + 60,
              manifest.tracks.count <= 2, manifest.segments.count <= 13 else {
            throw MeetingError.message("The meeting record has an out-of-range duration and was not written.")
        }
        var sources = Set<MeetingTrackSource>()
        for track in manifest.tracks {
            guard sources.insert(track.source).inserted,
                  track.file == "\(tracksDirectory)/\(track.source.rawValue).caf",
                  track.startSeconds.isFinite, track.startSeconds >= 0,
                  track.seconds.isFinite, track.seconds >= 0,
                  track.startSeconds + track.seconds <= MeetingSegmentPlan.maximumMeetingSeconds + 60,
                  track.sampleRate.isFinite, (8_000...192_000).contains(track.sampleRate),
                  track.peak.isFinite, track.peak >= -1, track.peak <= 1,
                  track.droppedSeconds.isFinite, track.droppedSeconds >= 0 else {
                throw MeetingError.message("The meeting record links an unexpected track and was not written.")
            }
            _ = try safeURL(session: session, relative: track.file)
        }
        var indexes = Set<Int>()
        for segment in manifest.segments {
            guard indexes.insert(segment.index).inserted, segment.index >= 0,
                  segment.file == MeetingSegmentPlan.filename(index: segment.index),
                  segment.startSeconds.isFinite, segment.startSeconds >= 0,
                  segment.seconds.isFinite, segment.seconds >= MeetingSegmentPlan.minimumSegmentSeconds,
                  segment.seconds <= MeetingSegmentPlan.maximumSegmentSeconds,
                  segment.startSeconds + segment.seconds <= MeetingSegmentPlan.maximumMeetingSeconds,
                  segment.bytes > 0, segment.bytes <= MeetingSegmentPlan.maximumSegmentBytes else {
                throw MeetingError.message("The meeting record links an unexpected segment and was not written.")
            }
            _ = try safeURL(session: session, relative: segment.file)
        }
        var end = 0.0
        for (index, segment) in manifest.orderedSegments.enumerated() {
            guard segment.index == index, abs(segment.startSeconds - end) < 0.001 else {
                throw MeetingError.message("The meeting segments have an invalid order. The record was left unchanged.")
            }
            end = segment.startSeconds + segment.seconds
        }
        if [.recognized, .committed].contains(manifest.state), !manifest.isFullyRecognized {
            throw MeetingError.message("The meeting record is missing recognised segments. It was left unchanged.")
        }
    }

    /// Relative paths only, no traversal, and no symbolic link on any component.
    static func safeURL(session: URL, relative: String) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw MeetingError.unsafePath
        }
        try rejectSymbolicLinks(in: session)
        var candidate = session
        for component in components {
            candidate.appendPathComponent(String(component))
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw MeetingError.unsafePath
            }
        }
        guard candidate.path.hasPrefix(session.path + "/") else { throw MeetingError.unsafePath }
        return candidate
    }

    /// Session directories only, newest first. Anything that is not a UUID
    /// directory is ignored and left in place.
    static func sessions(in root: URL) -> [URL] {
        guard (try? rejectSymbolicLinks(in: root)) != nil,
              let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let sessions = entries.filter { url in
            guard UUID(uuidString: url.lastPathComponent) != nil else { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        return sessions.sorted { left, right in
            let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l > r
        }
    }

    static func createPrivateDirectory(_ url: URL) throws {
        try rejectSymbolicLinks(in: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw MeetingError.unsafePath }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func rejectSymbolicLinks(in url: URL) throws {
        guard url.isFileURL, !url.pathComponents.contains("..") else { throw MeetingError.unsafePath }
        var part = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            part.appendPathComponent(component)
            if (try? part.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw MeetingError.unsafePath
            }
        }
    }

    /// Stage with private permissions before replacement, then synchronise and
    /// atomically rename. A chmod or staging failure never replaces old bytes.
    static func writePrivate(_ data: Data, to url: URL) throws {
        try rejectSymbolicLinks(in: url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".meeting-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// A person-readable summary of what a finished session actually contains. It
/// never implies both sides were captured when one of them is missing or silent.
enum MeetingSummary {
    static let quietPeak = 0.01

    static func gaps(for manifest: MeetingManifest) -> [String] {
        var notes: [String] = []
        let remote = manifest.tracks.first { $0.source == .remote }
        let local = manifest.tracks.first { $0.source == .local }
        if manifest.includesRemote {
            let name = manifest.appName ?? "the selected app"
            if remote == nil || remote?.seconds ?? 0 <= 0 {
                notes.append("No audio was received from \(name). Other people may be missing from the transcript.")
            } else if let peak = remote?.peak, peak >= 0, peak <= quietPeak {
                notes.append("\(name) produced no audible sound. Check that other people were unmuted and that the app plays through this Mac.")
            }
        }
        if manifest.includesMicrophone {
            if local == nil || local?.seconds ?? 0 <= 0 {
                notes.append("No microphone audio was recorded. Your voice may be missing from the transcript.")
            } else if let peak = local?.peak, peak >= 0, peak <= quietPeak {
                notes.append("Your microphone stayed quiet for the whole recording.")
            }
        }
        for track in manifest.tracks where track.droppedSeconds > 0.05 {
            let side = track.source == .remote ? (manifest.appName ?? "the app") : "your microphone"
            notes.append(String(format: "About %.1f seconds from %@ could not be written and are missing.", track.droppedSeconds, side))
        }
        return notes
    }
}
