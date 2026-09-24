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
        for state in [WorkbenchUpdateActivity(voice: true), WorkbenchUpdateActivity(reading: true), WorkbenchUpdateActivity(capture: true), WorkbenchUpdateActivity(presentation: true), WorkbenchUpdateActivity(drawing: true), WorkbenchUpdateActivity(timer: true), WorkbenchUpdateActivity(interaction: true)] {
            try require(state.busy, "independent live activities defer restart")
        }
        #if !APP_STORE
        // Invoke the actual delegates without starting Sparkle, networking or
        // replacing an app. Native old-to-new acceptance remains separate.
        let policy = WorkbenchUpdates(build: release)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        let item = SUAppcastItem.empty()
        try require(!policy.checkedCurrent && !policy.panelTitle.contains("Current"), "an unchecked build does not claim current")
        policy.updaterDidNotFindUpdate(updater)
        try require(policy.panelTitle == "Update · Current", "only a successful no-update response says current")
        policy.updater(updater, didAbortWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        try require(!policy.checkedCurrent && !policy.panelTitle.contains("Current"), "a failed check clears stale current status")
        var busy = true, resumed = 0
        policy.activity = { WorkbenchUpdateActivity(voice: busy) }
        try require(policy.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { resumed += 1 }), "busy restart defers")
        try require(policy.restartWaiting && policy.installing && policy.canCheck, "deferred restart remains accessible")
        policy.checkForUpdates()
        try require(resumed == 0 && policy.restartWaiting, "busy action cannot resume installation")
        busy = false
        policy.checkForUpdates()
        try require(resumed == 1 && !policy.restartWaiting && policy.installing, "idle resume retains final termination guard")
        policy.checkForUpdates()
        try require(resumed == 1, "consumed handler cannot run twice")
        policy.standardUserDriverWillFinishUpdateSession()
        try require(!policy.installing, "finished session clears guard")
        busy = true
        _ = policy.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { resumed += 1 })
        policy.updater(updater, didAbortWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        busy = false
        policy.checkForUpdates()
        try require(resumed == 1 && !policy.restartWaiting && !policy.installing, "abort clears stale handler")
        try require(!policy.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: false), "scheduled update stays quiet")
        try require(!policy.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: true), "foreground app still uses quiet reminder")
        try policy.updater(updater, mayPerform: .updates)
        busy = true
        do {
            try policy.updater(updater, mayPerform: .updates)
            try require(false, "busy check must be refused")
        } catch let error as NSError {
            try require(error.domain == "WorkbenchUpdates", "busy check refusal comes from policy")
        }
        #endif
        print("WORKBENCH_UPDATE_CHECKS_OK: identity, seven activity gates and restart delegate policy")
    }
}
