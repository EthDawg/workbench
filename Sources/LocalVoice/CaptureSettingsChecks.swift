import Foundation

enum CaptureSettingsChecks {
    static func run() throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw VoiceError.message("Capture settings: " + message) }
        }
        var preferences = VoicePreferences()
        var cleanup = CleanupConfiguration()
        let original = CaptureSettings(preferences: preferences, cleanup: cleanup, replacements: [])
        // Editing settings while permission/transcription is pending must not
        // rewrite the current operation's cleanup, destination or model choice.
        preferences.cleanup = .natural
        preferences.delivery = .clipboard
        preferences.restoreClipboard = false
        cleanup.naturalProvider = .ollama
        cleanup.model = "different-model"
        let next = CaptureSettings(preferences: preferences, cleanup: cleanup, replacements: [])
        try check(original.preferences.cleanup == .light && original.preferences.delivery == .paste && original.preferences.restoreClipboard,
                  "an in-flight operation changed with edited preferences")
        try check(original.cleanup.naturalProvider == .apple && original.cleanup.model != next.cleanup.model,
                  "a model edit changed the captured configuration")
        try check(next.outputLabel == "Natural · local model" && original.outputLabel == "Light cleanup", "capture labels do not describe their own settings")
        try check(!CaptureInputPolicy.canStart(isPresenting: true, hasExternalMacTarget: false), "phone presentation accepted Mac capture as phone input")
        try check(CaptureInputPolicy.canStart(isPresenting: true, hasExternalMacTarget: true), "an explicit Mac field was blocked by a separate presentation")
        try check(CaptureInputPolicy.canStart(isPresenting: false, hasExternalMacTarget: false), "ordinary in-app capture was blocked")
        try check(CaptureInputPolicy.canStart(isPresenting: true, hasExternalMacTarget: false, delivery: .clipboard), "explicit clipboard capture was blocked during a presentation")
        print("CAPTURE_SETTINGS_CHECKS_OK: 6 checks")
    }
}
