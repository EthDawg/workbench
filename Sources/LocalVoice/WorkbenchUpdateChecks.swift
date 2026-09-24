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
        try require(policy.panelTitle == "Update · Current", "only a successful no-update response says current")
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
        #endif
        print("WORKBENCH_UPDATE_CHECKS_OK: identity, quiet automatic checks, seven activity gates and restart delegate policy")
    }
}
