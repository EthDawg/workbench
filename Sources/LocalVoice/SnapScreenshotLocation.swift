import Foundation

/// Where macOS saves screenshots. Nil means its default, the Desktop.
protocol ScreenshotLocationStore: AnyObject {
    var location: String? { get set }
}

/// The person's own macOS screenshot setting, read and changed only through
/// the explicit Keep new screenshots off the Desktop choice.
final class SystemScreenshotLocation: ScreenshotLocationStore {
    private let domain = "com.apple.screencapture" as CFString
    var location: String? {
        get { CFPreferencesCopyAppValue("location" as CFString, domain) as? String }
        set {
            CFPreferencesSetAppValue("location" as CFString, newValue as CFString?, domain)
            CFPreferencesAppSynchronize(domain)
        }
    }

    /// macOS applies a changed screenshot location only after its screenshot
    /// service restarts (macos-defaults.com pairs the setting with
    /// `killall SystemUIServer`). launchd relaunches it at once; the menu bar
    /// redraws. Called only after an explicit change of the location.
    static func restartScreenshotService() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["SystemUIServer"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
