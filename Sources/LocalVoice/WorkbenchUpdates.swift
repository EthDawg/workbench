import AppKit
import SwiftUI
import Combine
#if !APP_STORE
import Sparkle
#endif

struct WorkbenchBuild {
    let info: [String: Any]
    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) { self.info = info }
    var preview: Bool { info["WorkbenchChannel"] as? String == "preview" }
    var edition: String { preview ? "Preview" : "Stable" }
    var version: String { info["CFBundleShortVersionString"] as? String ?? "Development" }
    var number: String { info["CFBundleVersion"] as? String ?? "unpackaged" }
    var revision: String { info["WorkbenchSourceRevision"] as? String ?? "unknown" }
    var released: Bool { info["WorkbenchBuildKind"] as? String == "release" }
    var label: String { "\(edition) · \(version)" + (released ? "" : " · Local build") }
    var details: String {
        "Workbench \(edition)\nVersion: \(version) (\(number))\nSource: \(revision)\nBuild: \(released ? "Release" : "Local development")\nModified source: \(info["WorkbenchSourceDirty"] as? Bool == true ? "yes" : "no")\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

/// One admission check for manual checks and the final update restart.
struct WorkbenchUpdateActivity {
    var voice = false, insertion = false, capture = false, presentation = false
    var drawing = false, timer = false, interaction = false
    var busy: Bool { voice || insertion || capture || presentation || drawing || timer || interaction }
}

@MainActor
final class WorkbenchUpdates: NSObject, ObservableObject {
    static let shared = WorkbenchUpdates()
    let build: WorkbenchBuild
    init(build: WorkbenchBuild = WorkbenchBuild()) { self.build = build; super.init() }
    @Published var status = ""
    @Published private(set) var checkedCurrent = false
    @Published private(set) var checking = false
    @Published var availableVersion: String?
    @Published var enabled = false
    @Published var automaticChecks = false
    @Published var automaticDownloads = false
    @Published var restartWaiting = false
    @Published private(set) var releaseSummary: String?
    @Published private(set) var actionNotice: String?
    @Published private(set) var installRequested = false
    @Published private(set) var downloaded = false
    @Published private(set) var requiresReview = false
    var showUpdate: () -> Void = {}
    var activity: () -> WorkbenchUpdateActivity = { WorkbenchUpdateActivity() }
    private var deferredInstall: (() -> Void)?
    private(set) var installing = false
    #if !APP_STORE
    private var updater: SPUUpdater?
    private var driver: WorkbenchUpdateDriver?
    private var requestedVersion: String?
    private var requestedBuildNumber: String?
    private var availableBuildNumber: String?
    private var offerReply: ((SPUUserUpdateChoice) -> Void)?
    #endif

    func start() {
        #if APP_STORE
        status = "Updates are managed by the App Store."
        #else
        guard updater == nil else { return }
        guard build.released else {
            status = "Local development build. Install a published release to receive updates."
            return
        }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else {
            status = "Updates are unavailable in this package. Download the latest release."
            return
        }
        let driver = WorkbenchUpdateDriver(owner: self, hostBundle: .main)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.driver = driver; self.updater = updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$enabled)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticDownloads)
        // No hardware profile, unique identifier or extra feed parameters.
        updater.sendsSystemProfile = false
        do {
            try updater.start()
            status = "Updates stay on the \(build.edition) edition."
            // Sparkle permits an immediate launch check here. Honour the existing
            // preference and leave every subsequent check to its own scheduler.
            if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        } catch { status = "Could not start updates: \(error.localizedDescription)" }
        #endif
    }
    func setAutomaticChecks(_ value: Bool) {
        #if !APP_STORE
        updater?.automaticallyChecksForUpdates = value
        #endif
    }
    func setAutomaticDownloads(_ value: Bool) {
        #if !APP_STORE
        updater?.automaticallyDownloadsUpdates = value
        #endif
    }
    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard !activity().busy else {
            status = "Finish recording, inserting, presenting or editing before updating."
            actionNotice = "Finish your current activity, then update."
            return
        }
        guard canCheck else { return }
        checkedCurrent = false; actionNotice = nil
        if let resume = deferredInstall {
            deferredInstall = nil; restartWaiting = false; installing = true
            resume(); return
        }
        #if !APP_STORE
        if let reply = offerReply {
            offerReply = nil; installRequested = true; installing = true
            status = "Updating Workbench. It will restart when ready."
            reply(.install)
        } else {
            // An automatic download can finish before Sparkle offers its reply.
            // Carry this click through that resume, for this exact version only.
            requestedVersion = requiresReview ? nil : availableVersion
            requestedBuildNumber = availableBuildNumber
            installRequested = requestedVersion != nil
            checking = true
            updater?.checkForUpdates()
        }
        #endif
    }
    func copyDetails() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(build.details, forType: .string)
    }
    var panelTitle: String {
        if !build.released { return "Update · Local Build" }
        if restartWaiting { return "Update · Restart Ready" }
        if installRequested { return "Updating…" }
        if availableVersion != nil { return "Update Ready" }
        if checking { return "Checking for Updates…" }
        if checkedCurrent { return "Update · Current" }
        return canCheck ? "Check for Updates…" : "Update Status Unavailable"
    }
    var buttonTitle: String {
        if restartWaiting { return "Restart to update" }
        if installRequested { return "Updating…" }
        if let version = availableVersion { return requiresReview ? "Review \(version)…" : "Update to \(version)" }
        return checking ? "Checking for Updates…" : "Check for Updates…"
    }
    var sidebarDetail: String {
        if let actionNotice { return actionNotice }
        if restartWaiting { return "Ready when your current work is finished." }
        if installRequested { return "Restarts when ready. Your work is saved first." }
        if !canCheck { return "Preparing the update in the background…" }
        return releaseSummary ?? "A new version is ready."
    }
    var sidebarHint: String { requiresReview ? buttonTitle : "\(buttonTitle) · Restarts Workbench" }
    var canCheck: Bool {
        if restartWaiting { return true }
        if installRequested { return false }
        #if !APP_STORE
        return offerReply != nil || enabled
        #else
        return enabled
        #endif
    }
    func finishUpdateSession() {
        let wasUpdating = installRequested || checking
        checking = false; installRequested = false
        #if !APP_STORE
        offerReply = nil; requestedVersion = nil; requestedBuildNumber = nil; availableBuildNumber = nil
        #endif
        if !restartWaiting {
            availableVersion = nil; releaseSummary = nil; downloaded = false; installing = false
            if wasUpdating { status = "Update paused. Check again when you’re ready." }
        }
    }
    func canTerminate(saveSession: () -> Bool) -> Bool {
        // A postponed update must not intercept an ordinary user Quit. Once
        // Sparkle resumes, recheck activity and save at the final restart gate.
        guard installing else { return true }
        guard !activity().busy else {
            status = "Finish your current activity before restarting to update."
            return false
        }
        guard saveSession() else {
            status = "Update paused because your current session could not be saved."
            return false
        }
        return true
    }
}

#if !APP_STORE
extension WorkbenchUpdates: SPUUpdaterDelegate {
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    // Quiet checks have no activity veto; actions and the final restart have gates.
    func receiveOffer(version: String, buildNumber: String? = nil, summary: String?, downloaded: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let continueRequested = requestedVersion == version && requestedBuildNumber == buildNumber
        requestedVersion = nil; requestedBuildNumber = nil; installRequested = false
        checking = false; checkedCurrent = false; actionNotice = nil
        availableVersion = version; releaseSummary = summary; self.downloaded = downloaded; requiresReview = false
        availableBuildNumber = buildNumber; offerReply = reply
        status = "\(build.edition) \(version) is ready. Updating will restart Workbench."
        if continueRequested { checkForUpdates() }
    }
    func needsNativeReview() {
        requestedVersion = nil; requestedBuildNumber = nil; installRequested = false
    }
    func continueInstallation(reply: @escaping (SPUUserUpdateChoice) -> Void) -> Bool {
        guard installRequested else { return false }
        // The user's Update action already authorised this restart. Sparkle still
        // calls shouldPostponeRelaunch and AppDelegate still saves before quitting.
        reply(.install)
        return true
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        checking = false; checkedCurrent = false; actionNotice = nil
        availableVersion = item.displayVersionString; availableBuildNumber = item.versionString
        requiresReview = !WorkbenchUpdateDriver.canOfferInline(item)
        releaseSummary = requiresReview ? nil : WorkbenchUpdateSummary.text(from: item.itemDescription, format: item.itemDescriptionFormat)
    }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { downloaded = true }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil; releaseSummary = nil; checking = false; checkedCurrent = false
        // didAbortWithError supplies Sparkle's reason. No eligible update is not
        // necessarily the same as having the latest published version.
        status = "No compatible update was found."
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        deferredInstall = nil; restartWaiting = false
        finishUpdateSession()
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
            let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
            checkedCurrent = reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
            status = checkedCurrent ? "You have the latest published \(build.edition.lowercased()) version." :
                (error.localizedRecoverySuggestion ?? error.localizedDescription)
        } else {
            checkedCurrent = false
            status = "Update check: \(error.localizedDescription)"
        }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard activity().busy else { installing = true; return false }
        installing = false
        deferredInstall = installHandler; restartWaiting = true
        status = "Update ready. Finish your current activity, then choose Restart to update."
        return true
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { installing = true }
}

#endif

struct WorkbenchUpdateSettings: View {
    @ObservedObject private var updates = WorkbenchUpdates.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(updates.build.label)
            Text("Build \(updates.build.number) · Source \(updates.build.revision.prefix(8))")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let summary = updates.releaseSummary { Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Text(updates.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if updates.build.released {
                Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticChecks }, set: updates.setAutomaticChecks)).toggleStyle(.switch)
                Toggle("Download updates automatically", isOn: Binding(get: { updates.automaticDownloads }, set: updates.setAutomaticDownloads)).toggleStyle(.switch)
                Text("Updates wait for your recording or presentation to finish. You can restart when ready or let a downloaded update install when you quit.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(updates.buttonTitle) { updates.checkForUpdates() }.disabled(!updates.canCheck)
                Button("Copy build details") { updates.copyDetails() }
                Link("Release notes and downloads", destination: URL(string: "https://github.com/Ship-Work/workbench/releases")!)
            }
        }
    }
}
