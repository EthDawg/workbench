import Foundation
#if !APP_STORE
import Sparkle
#endif

enum WorkbenchUpdateChecks {
    @MainActor static func run() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw VoiceError.message("Updates: " + message) }
        }
        let release = WorkbenchBuild(info: ["WorkbenchChannel": "preview", "WorkbenchBuildKind": "release", "CFBundleVersion": "20260924120000", "CFBundleShortVersionString": "2.0.0", "WorkbenchSourceRevision": String(repeating: "a", count: 40)])
        try require(release.preview && release.released && !release.label.contains("Local"), "published Preview identity")
        let local = WorkbenchBuild(info: ["WorkbenchChannel": "preview"])
        try require(!local.released && local.label.contains("Local"), "missing provenance cannot turn on updates")
        try require(!WorkbenchBuild(info: [:]).preview, "stable has no Preview badge")
        try require(release.details.contains("20260924120000") && release.details.contains("Source:"), "feedback has exact build and source")
        try require(!WorkbenchUpdateActivity().busy, "idle can update")
        let busyActivities = [WorkbenchUpdateActivity(voice: true), WorkbenchUpdateActivity(reading: true), WorkbenchUpdateActivity(capture: true), WorkbenchUpdateActivity(presentation: true), WorkbenchUpdateActivity(drawing: true), WorkbenchUpdateActivity(timer: true), WorkbenchUpdateActivity(interaction: true)]
        for state in busyActivities {
            try require(state.busy, "independent live activities defer restart")
        }
        #if !APP_STORE
        // Invoke the actual delegates without starting Sparkle, networking or
        // replacing an app. Native old-to-new acceptance remains separate.
        let policy = WorkbenchUpdates(build: release)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        let delegate: any SPUUpdaterDelegate = policy
        let item = SUAppcastItem.empty()
        try require(!policy.checkedCurrent && !policy.panelTitle.contains("Current"), "an unchecked build does not claim current")
        policy.updaterDidNotFindUpdate(updater)
        try require(!policy.checkedCurrent, "no eligible update alone cannot claim current")
        let currentError = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
            userInfo: [SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.onLatestVersion.rawValue])
        policy.updater(updater, didAbortWithError: currentError)
        try require(policy.panelTitle == "Update · Current", "Sparkle's latest-version reason confirms current")
        policy.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
            userInfo: [SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.systemIsTooOld.rawValue,
                       NSLocalizedRecoverySuggestionErrorKey: "This update needs a newer macOS."]))
        try require(!policy.checkedCurrent && policy.status.contains("newer macOS"), "ineligible update explains the requirement")
        policy.updater(updater, didAbortWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        try require(!policy.checkedCurrent && !policy.panelTitle.contains("Current"), "a failed check clears stale current status")
        var busy = true, resumed = 0, saves = 0
        func save() -> Bool { saves += 1; return true }
        policy.activity = { WorkbenchUpdateActivity(voice: busy) }
        try require(policy.canTerminate(saveSession: save) && saves == 0, "ordinary busy Quit is not an update restart")
        var guardedOnResume = false
        try require(policy.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: {
            resumed += 1; guardedOnResume = policy.installing
        }), "busy restart defers")
        try require(policy.restartWaiting && !policy.installing && policy.canCheck, "deferred restart remains accessible without intercepting Quit")
        try require(policy.canTerminate(saveSession: save) && saves == 0, "postponement preserves ordinary busy Quit")
        policy.checkForUpdates()
        try require(resumed == 0 && policy.restartWaiting, "busy action cannot resume installation")
        busy = false
        policy.checkForUpdates()
        try require(resumed == 1 && !policy.restartWaiting && policy.installing && guardedOnResume, "idle resume arms final termination guard before invoking Sparkle")
        busy = true
        try require(!policy.canTerminate(saveSession: save) && saves == 0, "activity beginning after resume refuses the final restart")
        busy = false
        try require(!policy.canTerminate(saveSession: { false }), "failed session save refuses restart")
        try require(policy.canTerminate(saveSession: save) && saves == 1, "idle restart saves the session before termination")
        policy.checkForUpdates()
        try require(resumed == 1, "consumed handler cannot run twice")
        policy.finishUpdateSession()
        try require(!policy.installing, "finished session clears guard")
        busy = true
        _ = policy.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { resumed += 1 })
        policy.updater(updater, didAbortWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        busy = false
        policy.checkForUpdates()
        try require(resumed == 1 && !policy.restartWaiting && !policy.installing, "abort clears stale handler")
        // Install is a one-shot choice. Completion continues without a second
        // confirmation only after that explicit choice, and restart still gates.
        var choices: [SPUUserUpdateChoice] = []
        policy.receiveOffer(version: "9.0.1", summary: "Keep your place while you work.", downloaded: true, reply: { choices.append($0) })
        try require(policy.canCheck && policy.buttonTitle == "Update to 9.0.1" && policy.downloaded && choices.isEmpty,
                    "downloaded offers stay passive and show their exact version")
        try require(!policy.continueInstallation(reply: { choices.append($0) }), "no restart choice without user intent")
        busy = true
        policy.checkForUpdates()
        try require(choices.isEmpty && policy.actionNotice != nil, "busy click keeps the one-shot offer for later")
        busy = false
        policy.checkForUpdates()
        policy.checkForUpdates()
        try require(choices == [.install] && policy.installRequested && !policy.canCheck, "one sidebar click consumes one install choice")
        try require(policy.continueInstallation(reply: { choices.append($0) }) && choices == [.install, .install],
                    "download completion continues the already-authorised install")
        policy.finishUpdateSession()
        try require(!policy.continueInstallation(reply: { choices.append($0) }) && !policy.installRequested && policy.availableVersion == nil,
                    "cancel or completion clears stale install intent")
        policy.receiveOffer(version: "9.0.2", summary: nil, downloaded: false, reply: { choices.append($0) })
        policy.updater(updater, didAbortWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        policy.checkForUpdates()
        try require(choices.count == 2 && policy.availableVersion == nil, "abort cannot leave a callable stale offer")
        try require(WorkbenchUpdateDriver.canOfferInline(item), "ordinary updates use the sidebar")
        policy.enabled = true; policy.availableVersion = "9.0.3"
        policy.checkForUpdates()
        policy.receiveOffer(version: "9.0.3", summary: nil, downloaded: true, reply: { choices.append($0) })
        try require(choices.count == 3 && policy.installRequested, "click before automatic-download resume still installs once")
        policy.finishUpdateSession()
        policy.availableVersion = "9.0.4"; policy.checkForUpdates()
        policy.receiveOffer(version: "9.0.5", summary: nil, downloaded: false, reply: { choices.append($0) })
        try require(choices.count == 3 && !policy.installRequested, "a different release needs its own update choice")
        policy.finishUpdateSession()
        policy.updater(updater, didFindValidUpdate: item); policy.checkForUpdates()
        policy.receiveOffer(version: item.displayVersionString, buildNumber: "different-build", summary: nil, downloaded: true, reply: { choices.append($0) })
        try require(choices.count == 3 && !policy.installRequested, "same marketing version with a different build needs fresh consent")
        policy.finishUpdateSession(); policy.enabled = false
        // Match Sparkle's optional-delegate dispatch without starting a network
        // session: an absent callback admits background and information checks.
        let admission = NSSelectorFromString("updater:mayPerformUpdateCheck:error:")
        for state in busyActivities {
            policy.activity = { state }
            policy.status = ""
            try require(!delegate.responds(to: admission), "busy background checks and probes have no activity veto")
            policy.checkForUpdates()
            try require(!policy.checking && policy.status == "Finish recording, reading, presenting or editing before updating.",
                        "the manual update action still refuses every busy activity")
        }
        try driverChecks()
        #endif
        try require(WorkbenchUpdateSummary.text(from: "<h2>9.0.1</h2><p>Keep <strong>your place</strong> &amp; save time.</p><p>More detail.</p>", format: "html") == "Keep your place & save time.", "benefit uses the first paragraph, without markup")
        try require(WorkbenchUpdateSummary.text(from: "<p>Fast<script>ignore this</script> updates.</p>", format: "html") == "Fast updates.", "script content cannot appear in benefit")
        try require(WorkbenchUpdateSummary.text(from: "<p>Unfinished", format: "html") == nil, "malformed notes have no invented benefit")
        try require(WorkbenchUpdateSummary.text(from: String(repeating: "a", count: 65_000), format: "html") == nil, "oversized notes stay bounded")
        try require(WorkbenchUpdateSummary.text(from: "First benefit.\n\nDetails.", format: "plain-text") == "First benefit.", "plain text keeps the short opening")
        print("WORKBENCH_UPDATE_CHECKS_OK: identity, one-click choices, failure cleanup, release summary, seven activity gates and restart policy")
    }
}

#if !APP_STORE
/// A protocol-level fixture exercises the adapter without a network request,
/// updater window, install helper or application replacement.
@MainActor private final class UpdateDriverSpy: NSObject, SPUUserDriver {
    var found = 0, ready = 0, dismissed = 0, focused = 0, errors = 0
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {}
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) { found += 1 }
    func showUpdateInFocus() { focused += 1 }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { errors += 1; acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { ready += 1 }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { dismissed += 1 }
}

extension WorkbenchUpdateChecks {
    @MainActor private static func driverChecks() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw VoiceError.message("Update driver: " + message) }
        }
        func state(userInitiated: Bool) throws -> SPUUserUpdateState {
            // Sparkle 2.10's secure archive format; no private constructor or updater.
            let archive = NSKeyedArchiver(requiringSecureCoding: true)
            archive.encode(SPUUserUpdateStage.downloaded.rawValue, forKey: "SPUUserUpdateStateStage")
            archive.encode(userInitiated, forKey: "SPUUserUpdateStateUserInitiated")
            archive.finishEncoding()
            let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
            defer { decoder.finishDecoding() }
            guard let value = SPUUserUpdateState(coder: decoder) else { throw VoiceError.message("Missing update state fixture") }
            return value
        }
        let owner = WorkbenchUpdates(), spy = UpdateDriverSpy()
        let driver = WorkbenchUpdateDriver(owner: owner, hostBundle: .main, standard: spy)
        var focus = 0, choices: [SPUUserUpdateChoice] = []
        owner.showUpdate = { focus += 1 }
        try require(driver.supportsGentleScheduledUpdateReminders && !driver.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: true), "exceptional scheduled updates are also quiet")
        driver.showUpdateFound(with: .empty(), state: try state(userInitiated: false), reply: { choices.append($0) })
        try require(focus == 0 && spy.found == 0 && spy.dismissed == 1 && owner.canCheck,
                    "automatic offers stay inline without stealing focus")
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        try require(spy.ready == 1 && choices.isEmpty, "unexpected readiness still needs native consent")
        owner.checkForUpdates()
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        try require(choices == [.install, .install] && spy.ready == 1, "one explicit click continues through ready without another prompt")
        driver.dismissUpdateInstallation()
        try require(!owner.installRequested && owner.availableVersion == nil, "teardown removes intent and the sidebar offer")
        driver.showUpdateFound(with: .empty(), state: try state(userInitiated: true), reply: { choices.append($0) })
        try require(focus == 1 && spy.found == 0, "manual checks bring the inline update into view")
        driver.showUpdateInFocus()
        try require(focus == 2, "repeat check focuses the existing offer")
        driver.dismissUpdateInstallation()
        driver.showUpdateInFocus()
        try require(spy.focused == 1, "other update progress retains native focus handling")
        var acknowledged = false
        driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), acknowledgement: { acknowledged = true })
        try require(spy.errors == 1 && acknowledged, "native errors retain their acknowledgement")
    }
}
#endif
