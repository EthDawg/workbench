import AppKit
import Foundation

/// What the detector is allowed to see: a process identifier, a bundle
/// identifier and whether that process is running audio input or output. No
/// samples, window titles, page contents or browser automation are involved.
struct MeetingProcessSnapshot: Equatable {
    var pid: Int32
    var bundleID: String
    var isRunningInput: Bool
    var isRunningOutput: Bool
    var name: String? = nil
    /// AppKit metadata only; no windows or their contents are inspected.
    var isUserFacingApp: Bool = true
}

protocol MeetingProcessSource: AnyObject {
    var isAvailable: Bool { get }
    var unavailableReason: String { get }
    func snapshot() throws -> [MeetingProcessSnapshot]
}

/// The real source. Every value comes from CoreAudio process metadata, which
/// macOS exposes from 14.2. Older systems report honestly that this is
/// unavailable instead of guessing from running applications.
final class MeetingSystemProcessSource: MeetingProcessSource {
    var isAvailable: Bool { MeetingCoreAudio.isProcessMetadataAvailable }
    var unavailableReason: String { MeetingCoreAudio.unavailableReason }

    func snapshot() throws -> [MeetingProcessSnapshot] {
        guard isAvailable else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        var result: [MeetingProcessSnapshot] = []
        for object in try MeetingCoreAudio.processObjectsChecked() {
            guard let pid = MeetingCoreAudio.processID(of: object), pid != own,
                  let bundleID = MeetingCoreAudio.bundleID(of: object),
                  !MeetingAppCatalogue.isExcluded(bundleID) else { continue }
            let application = NSRunningApplication(processIdentifier: pid)
            result.append(MeetingProcessSnapshot(pid: Int32(pid), bundleID: bundleID,
                                                 isRunningInput: try MeetingCoreAudio.activity(object, input: true),
                                                 isRunningOutput: try MeetingCoreAudio.activity(object, input: false),
                                                 name: application?.localizedName,
                                                 isUserFacingApp: application?.bundleURL?.pathExtension.lowercased() == "app"
                                                    && application?.activationPolicy != .prohibited))
        }
        return result
    }
}

/// Default-off metadata detection. It can only ever say that a call *may* be
/// running, because nothing it reads proves one. It never starts a recording,
/// and while it is switched off it does not read anything at all.
final class MeetingDetector {
    struct Options {
        /// Consecutive observations before an app is offered. One launch, or a
        /// single momentary input check, is never enough.
        var confirmations = 3
        var dismissCooldown: TimeInterval = 20 * 60
        var snoozeDuration: TimeInterval = 2 * 60 * 60
    }

    let source: MeetingProcessSource
    let options: Options
    /// Persisted per-app opt-outs. The model owns loading and saving them.
    var disabledBundleIDs: Set<String> = []
    var snoozedUntil: Date?
    /// Detection stays off until the person turns it on.
    var isEnabled = false { didSet { if !isEnabled { forgetObservations() } } }
    /// Suppresses offers while a recording or transcription is already running.
    var isSuppressed = false { didSet { if isSuppressed { forgetObservations() } } }
    private(set) var lastError: String?

    private var streaks: [String: Int] = [:]
    private var cooldowns: [String: Date] = [:]

    init(source: MeetingProcessSource, options: Options = Options()) {
        self.source = source
        self.options = options
    }

    var isAvailable: Bool { source.isAvailable }
    var unavailableReason: String { source.unavailableReason }

    /// The picker list: audio apps Workbench recognises that exist right now.
    /// This is an explicit person-facing action, not detection.
    func availableApps() -> [MeetingAudioApp] {
        guard source.isAvailable else { return [] }
        return availableApps(in: read())
    }

    private func availableApps(in processes: [MeetingProcessSnapshot]) -> [MeetingAudioApp] {
        var seen = Set<String>()
        var apps: [MeetingAudioApp] = []
        // A selected app's tap already includes its recognised helper processes.
        // Show one choice for that same scope, preferring its stable main process.
        let ordered = processes.sorted { left, right in
            if left.isUserFacingApp != right.isUserFacingApp { return left.isUserFacingApp }
            let leftMain = MeetingAppCatalogue.known(left.bundleID)?.bundleID == left.bundleID
            let rightMain = MeetingAppCatalogue.known(right.bundleID)?.bundleID == right.bundleID
            if leftMain != rightMain { return leftMain }
            return left.pid < right.pid
        }
        for process in ordered {
            let known = MeetingAppCatalogue.known(process.bundleID)
            let serviceName = MeetingAppCatalogue.manualServiceNames[process.bundleID]
            let bundleID = known?.bundleID ?? process.bundleID
            guard process.pid != ProcessInfo.processInfo.processIdentifier,
                  !MeetingAppCatalogue.isExcluded(process.bundleID),
                  process.isUserFacingApp || known != nil || serviceName != nil,
                  seen.insert(bundleID).inserted else { continue }
            apps.append(MeetingAudioApp(id: process.pid, name: known?.name ?? serviceName ?? process.name ?? process.bundleID,
                                        bundleID: bundleID))
        }
        return apps.sorted { left, right in
            let leftKind = MeetingAppCatalogue.known(left.bundleID)?.kind ?? .browser
            let rightKind = MeetingAppCatalogue.known(right.bundleID)?.kind ?? .browser
            if leftKind != rightKind { return leftKind == .communication }
            if left.name != right.name { return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending }
            return left.id < right.id
        }
    }

    /// One detection step. Returns an app only when the same supported app has
    /// been running audio input for several consecutive steps.
    func evaluate(now: Date = Date()) -> MeetingAudioApp? {
        guard isEnabled, !isSuppressed, source.isAvailable else { return nil }
        if let snoozedUntil, snoozedUntil > now { streaks.removeAll(); return nil }
        var candidates: [String: MeetingAudioApp] = [:]
        let processes = read()
        let choices = Dictionary(uniqueKeysWithValues: availableApps(in: processes).map { ($0.bundleID, $0) })
        for process in processes {
            guard process.pid != ProcessInfo.processInfo.processIdentifier,
                  !MeetingAppCatalogue.isExcluded(process.bundleID),
                  let known = MeetingAppCatalogue.known(process.bundleID),
                  !disabledBundleIDs.contains(known.bundleID),
                  // Playing sound alone is not a call. Something must be using
                  // the microphone through that app.
                  process.isRunningInput else { continue }
            candidates[known.bundleID] = choices[known.bundleID]
        }
        for bundleID in Array(streaks.keys) where candidates[bundleID] == nil { streaks[bundleID] = 0 }
        for bundleID in candidates.keys { streaks[bundleID, default: 0] += 1 }
        let ready = candidates.values.filter { app in
            guard streaks[app.bundleID, default: 0] >= options.confirmations else { return false }
            if let until = cooldowns[app.bundleID], until > now { return false }
            return true
        }
        return ready.sorted { left, right in
            let leftKind = MeetingAppCatalogue.known(left.bundleID)?.kind ?? .browser
            let rightKind = MeetingAppCatalogue.known(right.bundleID)?.kind ?? .browser
            if leftKind != rightKind { return leftKind == .communication }
            return left.bundleID < right.bundleID
        }.first
    }

    private func read() -> [MeetingProcessSnapshot] {
        do { let value = try source.snapshot(); lastError = nil; return value }
        catch {
            lastError = "Audio activity could not be checked. \(error.localizedDescription)"
            forgetObservations()
            return []
        }
    }

    /// "Not now" for this app: no further offer until the cooldown passes.
    func dismiss(_ app: MeetingAudioApp, now: Date = Date()) {
        cooldowns[app.bundleID] = now.addingTimeInterval(options.dismissCooldown)
        streaks[app.bundleID] = 0
    }

    func snooze(now: Date = Date()) {
        snoozedUntil = now.addingTimeInterval(options.snoozeDuration)
        streaks.removeAll()
    }

    func disable(_ app: MeetingAudioApp) {
        disabledBundleIDs.insert(app.bundleID)
        streaks[app.bundleID] = 0
        cooldowns[app.bundleID] = nil
    }

    /// Turning detection off forgets every observation immediately.
    func forgetObservations() {
        streaks.removeAll()
    }

    /// The wording the surface shows. It claims a possibility, never a fact.
    static func offerText(for app: MeetingAudioApp) -> String {
        "\(app.name) is using the microphone, so a call may be running. Record this meeting?"
    }
}
