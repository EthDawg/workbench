import Foundation

enum WorkbenchUpdateChecks {
    static func run() throws {
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
        print("WORKBENCH_UPDATE_CHECKS_OK: identity and seven independent activity gates")
    }
}
