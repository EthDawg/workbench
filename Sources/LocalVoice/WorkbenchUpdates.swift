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
    var voice = false, reading = false, capture = false, presentation = false
    var drawing = false, timer = false, interaction = false
    var busy: Bool { voice || reading || capture || presentation || drawing || timer || interaction }
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
    var activity: () -> WorkbenchUpdateActivity = { WorkbenchUpdateActivity() }
    private var deferredInstall: (() -> Void)?
    private(set) var installing = false
    #if !APP_STORE
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()
    #endif

    func start() {
        #if APP_STORE
        status = "Updates are managed by the App Store."
        #else
        guard controller == nil else { return }
        guard build.released else {
            status = "Local development build. Install a published release to receive updates."
            return
        }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else {
            status = "Updates are unavailable in this package. Download the latest release."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$enabled)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticDownloads)
        // No hardware profile, unique identifier or extra feed parameters.
        controller.updater.sendsSystemProfile = false
        do { try controller.updater.start(); status = "Updates stay on the \(build.edition) edition." }
        catch { status = "Could not start updates: \(error.localizedDescription)" }
        #endif
    }
    func setAutomaticChecks(_ value: Bool) {
        #if !APP_STORE
        controller?.updater.automaticallyChecksForUpdates = value
        #endif
    }
    func setAutomaticDownloads(_ value: Bool) {
        #if !APP_STORE
        controller?.updater.automaticallyDownloadsUpdates = value
        #endif
    }
    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard !activity().busy else {
            status = "Finish recording, reading, presenting or editing before updating."
            return
        }
        checkedCurrent = false
        if let resume = deferredInstall {
            deferredInstall = nil; restartWaiting = false; installing = true
            resume(); return
        }
        #if !APP_STORE
        if let controller { checking = true; controller.checkForUpdates(sender) }
        #endif
    }
    func copyDetails() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(build.details, forType: .string)
    }
    var panelTitle: String {
        if !build.released { return "Update · Local Build" }
        if restartWaiting { return "Update · Restart Ready" }
        if availableVersion != nil { return "Update Ready" }
        if checking { return "Checking for Updates…" }
        if checkedCurrent { return "Update · Current" }
        return canCheck ? "Check for Updates…" : "Update Status Unavailable"
    }
    var buttonTitle: String {
        restartWaiting ? "Restart to update…" : availableVersion != nil ? "Review update…" : "Check for Updates…"
    }
    var canCheck: Bool { enabled || availableVersion != nil || restartWaiting }
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
extension WorkbenchUpdates: SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if activity().busy {
            throw NSError(domain: "WorkbenchUpdates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Updates will wait until your current activity is finished."])
        }
    }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        status = "\(build.edition) \(update.displayVersionString) is available. Update when you are ready."
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        checking = false; checkedCurrent = false
        availableVersion = item.displayVersionString
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil; checking = false; checkedCurrent = true
        status = "You have the latest published \(build.edition.lowercased()) version."
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        checking = false; installing = false
        deferredInstall = nil; restartWaiting = false
        // Sparkle reports no-update through this callback too.
        if (error as NSError).code != SUError.noUpdateError.rawValue { checkedCurrent = false; status = "Update check: \(error.localizedDescription)" }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard activity().busy else { installing = true; return false }
        installing = false
        deferredInstall = installHandler; restartWaiting = true
        status = "Update ready. Finish your current activity, then choose Restart to update."
        return true
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { installing = true }
    func standardUserDriverWillFinishUpdateSession() {
        checking = false
        if !restartWaiting { availableVersion = nil; installing = false }
    }
}
#endif

struct WorkbenchUpdateSettings: View {
    @ObservedObject private var updates = WorkbenchUpdates.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workbench updates").font(.headline)
            Text(updates.build.label)
            Text("Build \(updates.build.number) · Source \(updates.build.revision.prefix(8))")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text(updates.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if updates.build.released {
                Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticChecks }, set: updates.setAutomaticChecks))
                Toggle("Download updates automatically", isOn: Binding(get: { updates.automaticDownloads }, set: updates.setAutomaticDownloads))
                Text("Updates wait for your recording or presentation to finish. You can restart when ready or let a downloaded update install when you quit.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(updates.buttonTitle) { updates.checkForUpdates() }.disabled(!updates.canCheck)
                Button("Copy build details") { updates.copyDetails() }
                Link("Release notes and downloads", destination: URL(string: "https://github.com/EthDawg/workbench/releases")!)
            }
        }
    }
}
