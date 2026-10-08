import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import Darwin.membership

/// Home's Permissions panel (docs/desktop.md § Home). It shows what macOS lets Workbench use on
/// this Mac, what each approval is for and what still works without it. Looking never asks:
/// every status is read passively, and macOS's own request appears only when the person presses
/// Set up… on that one row. Nothing here is a gate; every tool keeps its own contextual request
/// and its useful remainder (mac-foundation.md § Permissions follow the action).
enum MacPermission: String, CaseIterable, Identifiable {
    case microphone, accessibility, screenRecording, camera, callAudio
    var id: String { rawValue }

    /// macOS's own name for the list in Privacy & Security, so the person finds the same words
    /// there. macOS 15 renamed Screen Recording.
    var name: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording:
            if #available(macOS 15, *) { return "Screen & System Audio Recording" } else { return "Screen Recording" }
        case .camera: return "Camera"
        case .callAudio: return "Call audio"
        }
    }
    /// What the approval lets Workbench do, in the person's words. Accessibility leads with the
    /// feature's own name, so someone looking for automatic paste finds it here.
    var purpose: String {
        switch self {
        case .microphone: return "Dictate, Meetings and Snap & Talk hear you."
        case .accessibility: return "Automatic paste: dictated words go straight into the app you’re typing in."
        case .screenRecording: return "Snap and Snap & Talk capture windows and screens."
        case .camera: return "Present shows your phone; Persona shows your camera."
        case .callAudio: return "Meetings hears the other side of a call."
        }
    }
    /// What keeps working while it is not allowed, so nothing here reads as a wall.
    var withoutIt: String {
        switch self {
        case .microphone: return "Without it: import audio files and keep using saved transcripts."
        case .accessibility: return "Without it: your words are copied. Paste with ⌘V."
        case .screenRecording: return "Without it: paste or import images instead."
        case .camera: return "Without it: scenes without a phone, and saved artwork, work as before."
        case .callAudio: return "Without it: Meetings records your microphone only."
        }
    }
    var symbol: String {
        switch self {
        case .microphone: return "mic"
        case .accessibility: return "keyboard"
        case .screenRecording: return "rectangle.dashed"
        case .camera: return "video"
        case .callAudio: return "speaker.wave.2"
        }
    }
    /// Privacy & Security, at this approval's own list.
    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .camera: pane = "Privacy_Camera"
        case .callAudio: pane = "Privacy_AudioCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!
    }
    /// macOS keeps these two for the whole Mac, so switching either on in System Settings asks for
    /// an administrator's name and password. A standard account can't do it alone.
    var asksForAdministrator: Bool { self == .accessibility || self == .screenRecording }
    /// The lists that have a + button, for an entry a reset or a − removed.
    var listHasAddButton: Bool { asksForAdministrator }
    /// Where the switch is in Privacy & Security, in macOS's words. Call audio has no list of its
    /// own name: from macOS 15 it sits inside Screen & System Audio Recording.
    var settingsPath: String {
        guard self == .callAudio else { return "Privacy & Security › \(name)" }
        if #available(macOS 15, *) { return "Privacy & Security › Screen & System Audio Recording › System Audio Recording Only" }
        return "Privacy & Security"
    }
}

/// Only the distinctions macOS actually reports, plus the one fact about this account that
/// decides whether the person can change a Mac-wide approval. A yes/no check that says no can't
/// tell "never asked" from "turned off", so without Workbench's own record of asking it reads as
/// not set up, never as a refusal.
enum MacPermissionState: Equatable {
    case allowed
    /// macOS reports it has not asked yet (Microphone, Camera); Set up… shows its request.
    case notAsked
    /// A yes/no check that is not true, with no record that this edition asked. It may never have
    /// been asked, or have been refused before Workbench kept count; Set up… handles both.
    case notSetUp
    /// Turned off, or a yes/no check that is not true after Workbench asked.
    case notAllowed
    /// Not on, on an account that is not an administrator, for an approval macOS keeps for the
    /// whole Mac. `listed` records that Workbench already asked, so the list shows it.
    case needsAdministrator(listed: Bool)
    /// Restricted: an organisation or Screen Time controls it.
    case managed
    /// Call audio, which has no passive check: unknown until Meetings next records a call.
    case checkedOnUse
    /// Call audio as Meetings found it on its last call: real sound from the app, or macOS's
    /// refusal. Evidence from then, not a reading now.
    case lastCall(allowed: Bool)
    /// This Mac cannot provide it at all.
    case unsupported(String)
}

/// One row of the panel, derived from the permission, its state and a few facts about this run,
/// so checks can hold every combination without a Mac to ask.
struct MacPermissionRow: Equatable, Identifiable {
    enum Action: Equatable {
        /// Shows macOS's request for this one approval. Labelled Set up…, not Allow: the person
        /// allows it in macOS's own request (Apple's Privacy guidance).
        case request
        /// Opens Privacy & Security at this approval's list.
        case openSettings
        /// An allowed approval: opens its list, where the person can turn it off. macOS doesn't
        /// let an app switch off its own approval, so this is the honest way to remove one.
        case change
        var title: String {
            switch self {
            case .request: return "Set up…"
            case .openSettings: return "Open System Settings…"
            case .change: return "Change…"
            }
        }
    }
    let permission: MacPermission
    let state: MacPermissionState
    /// Whether this account is an administrator; nil when macOS couldn't say.
    var administrator: Bool? = true
    /// Why the last automatic paste didn't land, while Accessibility reads Allowed.
    var pasteProblem: String? = nil
    var id: MacPermission { permission }

    var status: String {
        switch state {
        case .allowed: return "Allowed"
        case .notAsked: return "Not asked yet"
        case .notSetUp: return "Not set up"
        case .notAllowed: return "Off"
        case .needsAdministrator: return permission == .accessibility ? "Needs an administrator" : "May need an administrator"
        case .managed: return "Managed"
        case .checkedOnUse: return "Checked on your next call"
        case .lastCall(let allowed): return allowed ? "Allowed on your last call" : "Off on your last call"
        case .unsupported(let reason): return reason
        }
    }
    /// Orange only when an approval is off and the person can turn it on, which is when a tool
    /// that needs it would fail. Not asked yet, not set up and needing an administrator are plain
    /// information: the tool asks when first used, or someone else has to switch it on. Green only
    /// for what macOS reports allowed now.
    var tone: WorkbenchTone {
        switch state {
        case .allowed: return .done
        case .notAllowed, .lastCall(allowed: false): return .attention
        case .notAsked, .notSetUp, .needsAdministrator, .managed, .checkedOnUse, .lastCall(allowed: true), .unsupported: return .neutral
        }
    }
    var action: Action? {
        switch state {
        case .notAsked, .notSetUp: return .request
        // macOS's request is what puts Workbench in the list an administrator will switch on.
        case .needsAdministrator(let listed): return listed ? .openSettings : .request
        // A restricted approval can still be read in Settings; there is nothing to request.
        case .notAllowed, .managed, .lastCall(allowed: false): return .openSettings
        case .allowed, .lastCall(allowed: true): return .change
        // Someone who updated Workbench may already have been asked about call audio, so its
        // switch is one quiet click away even before Meetings knows.
        case .checkedOnUse: return .openSettings
        case .unsupported: return nil
        }
    }
    /// Whether the button is a quiet link: nothing needs doing, but the switch is there.
    var actionIsQuiet: Bool { action == .change || state == .checkedOnUse }
    /// The lines under the purpose, only where the person needs them: what works meanwhile, why
    /// it is managed or needs someone else, and how to bring back an entry missing from the list.
    var details: [String] {
        let reopen = "If it’s already on there, quit and reopen \(Self.appName)."
        switch state {
        case .allowed:
            return [pasteProblem].compactMap { $0 }
        case .lastCall(allowed: false):
            return [permission.withoutIt, "Changed it? Meetings checks again on your next call."]
        case .unsupported, .notAsked, .notSetUp, .lastCall:
            return [permission.withoutIt]
        case .managed:
            return ["Your organisation or Screen Time sets this. " + permission.withoutIt]
        case .checkedOnUse:
            return ["Meetings learns this when it records a call. " + permission.withoutIt]
        case .needsAdministrator(let listed):
            guard permission == .accessibility else {
                return ["Switching this on may need an administrator’s name and password.", permission.withoutIt]
            }
            return ["Switching this on needs an administrator’s name and password. Ask your IT team, or anyone with an admin account on this Mac; Copy permission details tells IT how."]
                + (listed ? [reopen] : []) + [permission.withoutIt]
        case .notAllowed:
            var lines = [permission.withoutIt]
            if permission.listHasAddButton { lines.append("If \(Self.appName) isn’t in the list, click + and choose it.") }
            // A switch already on that macOS doesn't report yet: a stale entry, or the macOS 27 cache.
            if permission == .accessibility { lines.append(reopen) }
            return lines
        }
    }
    /// macOS keeps Screen Recording off for a running app until it reopens.
    var afterAllowing: String? {
        guard permission == .screenRecording else { return nil }
        switch state {
        case .notAllowed, .needsAdministrator(listed: true): return Self.reopenAfterAllowing
        default: return nil
        }
    }
    /// The button's help, saying where it goes and what macOS does there.
    var actionHelp: String? {
        guard let action else { return nil }
        switch action {
        case .request: return "Shows macOS’s request for \(permission.name)."
        case .openSettings:
            if permission.asksForAdministrator { return "Asks macOS to list \(Self.appName), then opens \(permission.settingsPath) in System Settings." }
            return "Opens \(permission.settingsPath) in System Settings."
        case .change:
            var help = "Opens \(permission.settingsPath), where its switch is."
            switch permission {
            case .microphone, .camera, .callAudio: help += " macOS may let \(Self.appName) keep it until it quits."
            case .screenRecording: help += " macOS applies a change when \(Self.appName) reopens."
            case .accessibility: break
            }
            if permission.asksForAdministrator {
                help += " If your organisation approved it, it may not be listed there."
                if administrator == false { help += " Switching it off also needs an administrator." }
            }
            return help
        }
    }
    static let reopenAfterAllowing = "Once it’s on, quit and reopen \(appName)."
    /// The name macOS lists this edition under: Workbench, or Workbench Preview.
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String).flatMap { $0 == "LocalVoice" ? nil : $0 }
            ?? "Workbench"
    }
}

/// The panel's whole state. Its summary names what it can know, never a count over rows it
/// cannot check: “2 off”, “Needs an administrator”, “2 to set up”, “All set” or, only when
/// call audio doesn't apply, “All allowed”.
struct MacPermissionSnapshot: Equatable {
    var rows: [MacPermissionRow]
    /// A few words for the summary and folded line when the last automatic paste didn't land.
    var pasteNote: String?
    init(_ states: [MacPermission: MacPermissionState], administrator: Bool? = true,
         pasteProblem: String? = nil, pasteNote: String? = nil) {
        rows = MacPermission.allCases.compactMap { permission in
            states[permission].map { state in
                MacPermissionRow(permission: permission, state: state, administrator: administrator,
                                 pasteProblem: permission == .accessibility && state == .allowed ? pasteProblem : nil)
            }
        }
        self.pasteNote = rows.contains { $0.pasteProblem != nil } ? (pasteNote ?? "Last paste only copied") : nil
    }
    private func count(_ matches: (MacPermissionState) -> Bool) -> Int { rows.filter { matches($0.state) }.count }
    var offCount: Int { count { $0 == .notAllowed || $0 == .lastCall(allowed: false) } }
    var toSetUpCount: Int { count { $0 == .notAsked || $0 == .notSetUp } }
    /// What is off now; Done for now remembers it, so only something newly off opens the panel.
    var offPermissions: Set<MacPermission> {
        Set(rows.filter { $0.state == .notAllowed || $0.state == .lastCall(allowed: false) }.map(\.permission))
    }
    var allowedPermissions: Set<MacPermission> { Set(rows.filter { $0.state == .allowed }.map(\.permission)) }
    /// Something a tool needs is off, and the person can turn it on.
    var needsAttention: Bool { offCount > 0 }
    /// Every approval that can be checked now is allowed. Managed or needing an administrator
    /// keeps this false; call audio, known only from a call, doesn't.
    var isComplete: Bool {
        !rows.contains {
            switch $0.state {
            case .allowed, .checkedOnUse, .lastCall(allowed: true), .unsupported: return false
            default: return true
            }
        }
    }
    /// Call audio applies to this Mac, so a complete panel says All set: nobody can check it now.
    private var callAudioApplies: Bool {
        rows.contains { if $0.permission == .callAudio, case .unsupported = $0.state { return false }; return $0.permission == .callAudio }
    }
    var summary: String {
        if offCount > 0 { return "\(offCount) off" }
        let administrator = rows.filter { if case .needsAdministrator = $0.state { return true } else { return false } }
        if !administrator.isEmpty {
            return administrator.contains { $0.permission == .accessibility } ? "Needs an administrator" : "May need an administrator"
        }
        if let pasteNote { return pasteNote }
        if isComplete { return callAudioApplies ? "All set" : "All allowed" }
        if toSetUpCount > 0 { return "\(toSetUpCount) to set up" }
        return "\(count { $0 == .managed }) managed"
    }
    var tone: WorkbenchTone { needsAttention ? .attention : isComplete && pasteNote == nil ? .done : .neutral }
    /// Before Done for now, the panel shows every row until everything is allowed. After it, it
    /// stays one line until something turns off that was not off when the person folded it, so
    /// an approval only IT can change, or one the person chose to leave off, never nags.
    func expanded(dismissed: Bool, offWhenDismissed: Set<MacPermission> = []) -> Bool {
        guard dismissed else { return !isComplete }
        return !offPermissions.subtracting(offWhenDismissed).isEmpty
    }
    /// The folded panel's one line: each row's status by name, in the rows' order, and the last
    /// paste if it didn't land.
    var foldedLine: String {
        var parts: [String]
        if isComplete {
            parts = [callAudioApplies ? "All set. Meetings checks call audio when it records a call." : "Everything Workbench uses on this Mac is allowed."]
        } else {
            var groups: [(status: String, names: [String])] = []
            for row in rows {
                if case .unsupported = row.state { continue }
                if let index = groups.firstIndex(where: { $0.status == row.status }) { groups[index].names.append(row.permission.name) }
                else { groups.append((row.status, [row.permission.name])) }
            }
            parts = groups.map { "\($0.status): \(ListFormatter.localizedString(byJoining: $0.names))." }
        }
        if let pasteNote { parts.append(pasteNote + ".") }
        return parts.joined(separator: " ")
    }
}

/// What Meetings found the last time it recorded a call's audio: real sound from the app, or
/// macOS's refusal. macOS has no passive check for call audio, and a refused tap delivers silence
/// rather than an error, so a start alone proves nothing. Written by Meetings; Home forgets it
/// when it opens the switch, because the person may be about to change it.
enum CallAudioRecord: String {
    case allowed, refused
    static let key = "workbench.permissions.callAudio.v1"
    static var saved: CallAudioRecord? { UserDefaults.standard.string(forKey: key).flatMap(Self.init) }
    static func forget() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Facts about the person's account that macOS reports without asking anything.
enum MacAccount {
    /// Membership of the admin group (gid 80), nested directory groups included, which is what
    /// macOS checks before it lets someone change a Mac-wide approval. Nil if macOS can't say.
    /// Read each time (about 0.2 ms), so a temporary-admin tool is seen without relaunching.
    static var administrator: Bool? { isAdministrator() }
    /// The one sentence every surface uses for who can switch on automatic paste.
    static var automaticPasteApproval: String {
        switch administrator {
        case false?: return "On this account, switching Accessibility on needs an administrator’s name and password; ask your IT team, or anyone with an admin account on this Mac."
        case true?: return "macOS asks for your Mac’s password to switch Accessibility on."
        case nil: return "On a work Mac, IT may need to allow Accessibility."
        }
    }
    static func isAdministrator() -> Bool? {
        var user = [UInt8](repeating: 0, count: 16), group = [UInt8](repeating: 0, count: 16), member: Int32 = 0
        guard mbr_uid_to_uuid(getuid(), &user) == 0, mbr_gid_to_uuid(80, &group) == 0,
              mbr_check_membership(user, group, &member) == 0 else { return nil }
        return member != 0
    }
}

/// Where the panel reads macOS. Every read is passive; the gallery replaces it with fixed answers.
@MainActor
struct MacPermissionReader {
    var microphone: () -> AVAuthorizationStatus
    var camera: () -> AVAuthorizationStatus
    var accessibility: () -> Bool
    var screenRecording: () -> Bool
    var callAudioSupported: () -> Bool
    /// Whether Workbench already asked for Screen Recording, from Home, Snap or Snap & Talk.
    var screenRecordingAsked: () -> Bool
    var callAudio: () -> CallAudioRecord? = { nil }
    var administrator: () -> Bool? = { true }
    /// Accessibility and Screen Recording seen allowed earlier in this run: switched off since,
    /// they read Off, not Not set up, even without Workbench's record of asking.
    var allowedEarlier: () -> Set<MacPermission> = { [] }

    static let live = MacPermissionReader(
        microphone: { AVCaptureDevice.authorizationStatus(for: .audio) },
        camera: { AVCaptureDevice.authorizationStatus(for: .video) },
        accessibility: { AXIsProcessTrusted() },
        screenRecording: { ScreenCaptureAccess.system.isGranted() },
        callAudioSupported: { if #available(macOS 14.2, *) { return true } else { return false } },
        screenRecordingAsked: { ScreenCaptureAccess.wasRequested },
        callAudio: { CallAudioRecord.saved },
        administrator: { MacAccount.administrator },
        allowedEarlier: { allowedThisRun })
    /// The surface gallery's fixed answers replace this; the app always reads macOS.
    static var current = live
    /// What Home has seen allowed in this run; only Home's live reads add to it.
    static var allowedThisRun: Set<MacPermission> = []

    nonisolated static func state(_ status: AVAuthorizationStatus) -> MacPermissionState {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        case .restricted: return .managed
        default: return .notAllowed
        }
    }

    /// A yes/no approval that macOS keeps for the whole Mac: allowed, or not on with whether
    /// Workbench asked, and whether this account could switch it on.
    nonisolated static func state(granted: Bool, asked: Bool, administrator: Bool?) -> MacPermissionState {
        if granted { return .allowed }
        if administrator == false { return .needsAdministrator(listed: asked) }
        return asked ? .notAllowed : .notSetUp
    }

    nonisolated static func state(callAudio record: CallAudioRecord?, supported: Bool) -> MacPermissionState {
        guard supported else { return .unsupported("Needs macOS 14.2 or later") }
        return record.map { .lastCall(allowed: $0 == .allowed) } ?? .checkedOnUse
    }

    /// `accessibilityAsked` comes from Dictate's own saved preference, the one its Set up
    /// automatic paste… already keeps. `paste` is why the last automatic paste didn't land.
    func snapshot(accessibilityAsked: Bool, paste: AutomaticPasteProblem? = nil) -> MacPermissionSnapshot {
        let administrator = administrator(), earlier = allowedEarlier()
        return MacPermissionSnapshot([
            .microphone: Self.state(microphone()),
            .accessibility: Self.state(granted: accessibility(), asked: accessibilityAsked || earlier.contains(.accessibility), administrator: administrator),
            .screenRecording: Self.state(granted: screenRecording(), asked: screenRecordingAsked() || earlier.contains(.screenRecording), administrator: administrator),
            .camera: Self.state(camera()),
            .callAudio: Self.state(callAudio: callAudio(), supported: callAudioSupported()),
        ], administrator: administrator, pasteProblem: paste?.line, pasteNote: paste?.note)
    }
}

/// What pressing a row's button does, as data, so checks can hold every route without asking
/// macOS anything. The panel performs it through the owner each tool already uses.
enum MacPermissionStep: Equatable {
    case requestMicrophone, requestCamera
    /// Dictate's own setup: asks macOS first, then opens Settings when no request comes forward.
    case setUpAccessibility
    /// The same route for Screen Recording, through the request Snap and Snap & Talk use.
    case setUpScreenRecording
    case openSettings(URL)

    static func of(_ action: MacPermissionRow.Action, for permission: MacPermission) -> MacPermissionStep {
        switch (action, permission) {
        // Change… only opens the list: nothing is asked when someone wants to turn something off.
        case (.change, _): return .openSettings(permission.settingsURL)
        case (.request, .microphone): return .requestMicrophone
        case (.request, .camera): return .requestCamera
        // Asking again before Settings lets a list cleared by a reset or a − show Workbench again.
        case (.request, .accessibility), (.openSettings, .accessibility): return .setUpAccessibility
        case (.request, .screenRecording), (.openSettings, .screenRecording): return .setUpScreenRecording
        case (.openSettings, _), (.request, .callAudio): return .openSettings(permission.settingsURL)
        }
    }
}

/// Copy permission details: one plain text for an IT team, and for a problem report from a Mac
/// nobody else can see. It names what to allow by macOS version, this edition's identity, and
/// what this Mac reports. It holds no words or files; it names the app the last paste went to.
struct MacPermissionDetails {
    struct Facts: Equatable {
        var appName = "Workbench", bundleID = "com.ethdawg.workbench", version = "", build = ""
        var teamID = "GHVAAH9P5Z", codeRequirement: String? = nil
        var macOS = "", installedIn = "", administrator: Bool? = nil, enrolled: Bool? = nil
        var postEvent: Bool? = nil, accessibilityAsked = false, screenRecordingAsked = false
        var callAudio: CallAudioRecord? = nil, delivery = "Paste automatically"
        var keyboardLayout = "", pasteKeyCode: Int? = nil, lastPasteProblem: String? = nil
    }
    static let itPage = "https://github.com/Ship-Work/workbench/tree/main/docs/it"

    static func text(_ snapshot: MacPermissionSnapshot, _ facts: Facts) -> String {
        func yesNo(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "unknown" }
        let callAudio: String
        switch facts.callAudio {
        case .allowed?: callAudio = "sound heard on the last call"
        case .refused?: callAudio = "refused on the last call"
        case nil: callAudio = "not known yet"
        }
        var lines = ["\(facts.appName) \(facts.version) (\(facts.build)): permission details", "",
            "For IT: what to allow",
            "• Accessibility (automatic paste). macOS 14–26: PPPC Accessibility = Allow and PostEvent = Allow. macOS 27: keep that PPPC profile (Apple says its Accessibility grant still applies, with a notice); supervised Macs can also use App Settings › Privacy › PermissionDefaults on the user channel, which the person accepts once and which doesn't apply to an approval macOS already asked about.",
            "• Screen & System Audio Recording (Snap). A profile can't switch it on. PPPC ScreenCapture = AllowStandardUserToSetSystemService lets a standard user switch it on.",
            "• Microphone and Camera. The person allows them when macOS asks (PPPC can only deny them). On supervised macOS 27 Macs, PermissionDefaults can suggest Allow.",
            "• Call audio (System Audio Recording Only). macOS asks the first time Meetings records a call; after that it's in Privacy & Security › Screen & System Audio Recording › System Audio Recording Only. No profile key exists.",
            "PPPC profiles go through MDM on the device channel; one installed by hand grants nothing.",
            "Identifier: \(facts.bundleID)", "Team ID: \(facts.teamID)"]
        if let requirement = facts.codeRequirement { lines.append("Code requirement: \(requirement)") }
        lines += ["Ready-made profiles and a table: \(itPage)", "", "This Mac",
            "\(facts.macOS) · administrator: \(yesNo(facts.administrator)) · MDM enrolled: \(yesNo(facts.enrolled)) · installed in \(facts.installedIn)"]
        lines.append(snapshot.rows.map { "\($0.permission.name): \($0.status)" }.joined(separator: " · "))
        lines.append("Post Event: \(yesNo(facts.postEvent)) · asked from Workbench: Accessibility \(yesNo(facts.accessibilityAsked)), Screen Recording \(yesNo(facts.screenRecordingAsked)) · call audio: \(callAudio)")
        lines.append("Delivery: \(facts.delivery) · keyboard layout \(facts.keyboardLayout), ⌘V key \(facts.pasteKeyCode.map(String.init) ?? "none")")
        lines.append("Last automatic paste: \(facts.lastPasteProblem ?? "no problem this run")")
        if facts.postEvent == false || snapshot.rows.contains(where: { $0.permission == .accessibility && $0.state != .allowed }) {
            lines.append("These can show what they were when Workbench opened. After a change, quit and reopen Workbench, then copy again.")
        }
        return lines.joined(separator: "\n")
    }

    /// This edition and this Mac, read without asking anything. MDM enrolment comes from
    /// `profiles status`, which needs no administrator; it is skipped if it doesn't answer in 2 s.
    @MainActor static func liveFacts(accessibilityAsked: Bool, delivery: String, paste: AutomaticPasteProblem?) async -> Facts {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundle = Bundle.main.bundleURL.path
        var facts = Facts(appName: MacPermissionRow.appName, bundleID: Bundle.main.bundleIdentifier ?? "unknown",
                          version: info["CFBundleShortVersionString"] as? String ?? "Development",
                          build: info["CFBundleVersion"] as? String ?? "unpackaged")
        facts.codeRequirement = designatedRequirement()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        facts.macOS = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        facts.installedIn = bundle.hasPrefix("/Applications/") ? "/Applications"
            : bundle.hasPrefix(NSHomeDirectory() + "/Applications/") ? "~/Applications"
            : bundle.contains("/AppTranslocation/") ? "a translocated copy (open it from Applications)" : "another folder"
        facts.administrator = MacAccount.administrator
        facts.postEvent = CGPreflightPostEventAccess()
        facts.accessibilityAsked = accessibilityAsked
        facts.screenRecordingAsked = ScreenCaptureAccess.wasRequested
        facts.callAudio = CallAudioRecord.saved
        facts.delivery = delivery
        // The layout the last paste used, when there was one: this app's own input source may differ.
        facts.keyboardLayout = paste?.layout ?? PasteKey.currentLayoutID() ?? "unknown"
        facts.pasteKeyCode = paste.map { $0.pasteKey.map(Int.init) } ?? PasteKey.current().map(Int.init)
        facts.lastPasteProblem = paste?.summary
        facts.enrolled = await enrolled()
        return facts
    }

    /// The running app's designated requirement, so Preview copies its own, never a hard-coded one.
    static func designatedRequirement() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    private static func enrolled() async -> Bool? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
                process.arguments = ["status", "-type", "enrollment"]
                process.standardOutput = output; process.standardError = Pipe()
                guard (try? process.run()) != nil else { continuation.resume(returning: nil); return }
                let deadline = DispatchTime.now() + 2
                DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
                process.waitUntilExit()
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guard process.terminationStatus == 0, text.contains("MDM enrollment:") else { continuation.resume(returning: nil); return }
                continuation.resume(returning: text.contains("MDM enrollment: Yes"))
            }
        }
    }
}

/// The panel. Home owns its snapshot and rereads macOS when Home appears and whenever Workbench
/// comes back to the front, which is when someone returns from System Settings.
struct HomePermissionsPanel: View {
    @ObservedObject var model: AppModel
    let snapshot: MacPermissionSnapshot
    /// Done for now, saved with Home.
    @Binding var dismissed: Bool
    /// What was off when the person chose Done for now; only something newly off reopens the panel.
    @Binding var offWhenDismissed: Set<MacPermission>
    /// Rereads macOS after a Set up…, Open System Settings… or Change… returns.
    var refresh: () -> Void
    @State private var showingDetails = false
    @State private var problem: String?
    @State private var copiedDetails = false

    var body: some View {
        let expanded = snapshot.expanded(dismissed: dismissed, offWhenDismissed: offWhenDismissed) || showingDetails
        WorkbenchTile("Permissions", symbol: "lock.shield", accessory: {
            WorkbenchStatusBadge(text: snapshot.summary, tone: snapshot.tone)
                .accessibilityIdentifier("home.permissions.summary")
        }) {
            if expanded {
                Text("What Workbench can use on this Mac, and what still works without each. Nothing is asked until you press Set up…; Change… opens a switch in System Settings.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.rows) { row in
                        if row.id != snapshot.rows.first?.id { Divider().padding(.leading, 34) }
                        rowView(row)
                    }
                }
                if let problem {
                    WorkbenchNote(problem, font: .caption)
                }
                HStack(spacing: 16) {
                    Button(snapshot.isComplete ? "Hide details" : "Done for now") {
                        dismissed = true; offWhenDismissed = snapshot.offPermissions; showingDetails = false
                    }
                    .buttonStyle(.workbenchLink).font(.callout)
                    .help(snapshot.isComplete ? "Fold the panel to one line." : "Fold the panel to one line. It opens again only if something else turns off.")
                    .accessibilityIdentifier("home.permissions.fold")
                    Button(copiedDetails ? "Copied" : "Copy permission details") { copyDetails() }
                        .buttonStyle(.workbenchLink).font(.callout)
                        .help("Copies what Workbench needs and what this Mac reports, for your IT team. It holds none of your words or files.")
                        .accessibilityIdentifier("home.permissions.copyDetails")
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.foldedLine)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Show details") { showingDetails = true }.buttonStyle(.workbenchLink).font(.callout)
                        .accessibilityIdentifier("home.permissions.details")
                }
            }
        }
        .accessibilityIdentifier("home.permissions")
    }

    private func rowView(_ row: MacPermissionRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.permission.symbol).font(.system(size: 15)).foregroundStyle(row.tone == .done ? Workbench.accent : .secondary)
                .frame(width: 22, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.permission.name).font(.callout.weight(.semibold)).lineLimit(2).layoutPriority(1)
                    WorkbenchStatusBadge(text: row.status, tone: row.tone)
                }
                Text(row.permission.purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(row.details + [row.afterAllowing].compactMap { $0 }, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let action = row.action {
                Button(action.title) { perform(action, for: row.permission) }
                .modifier(PermissionActionStyle(quiet: row.actionIsQuiet))
                .fixedSize()
                .help(row.actionHelp ?? "")
                .accessibilityLabel("\(action.title.replacingOccurrences(of: "…", with: "")) \(row.permission.name)")
                .accessibilityIdentifier("home.permissions.\(row.permission.rawValue)")
            }
        }.padding(.vertical, 10)
            .accessibilityElement(children: .contain)
    }

    /// Each Set up… reaches the same owner its tool uses: Dictate's microphone and automatic-paste
    /// setup, Snap's Screen Recording request, and macOS's camera request. None starts a recording.
    /// Accessibility and Screen Recording reread when Workbench comes back to the front, so the row
    /// doesn't turn orange while macOS's own request is still on screen.
    private func perform(_ action: MacPermissionRow.Action, for permission: MacPermission) {
        problem = nil
        // A change to Accessibility starts automatic paste afresh.
        if permission == .accessibility { model.forgetPasteProblem() }
        let unavailable = { problem = "System Settings could not be opened. Open \(permission.settingsPath) there."; refresh() }
        switch MacPermissionStep.of(action, for: permission) {
        case .requestMicrophone:
            Task { _ = await model.requestMicrophoneAuthorization(); model.refreshMicrophoneAuthorization(); refresh() }
        case .requestCamera:
            Task { _ = await AVCaptureDevice.requestAccess(for: .video); refresh() }
        case .setUpAccessibility:
            model.requestAccessibility(unavailable: unavailable)
        case .setUpScreenRecording:
            var asked: Bool? = ScreenCaptureAccess.wasRequested ? true : nil
            if AccessibilitySetup.screenRecording.run(asked: &asked, unavailable: unavailable) == .approved { refresh() }
        case .openSettings(let url):
            // Change… on an allowed call audio may switch it off, so it reads unknown until the
            // next call. A refusal stays, with its line, until Meetings hears otherwise.
            if permission == .callAudio, action == .change { CallAudioRecord.forget(); refresh() }
            if !NSWorkspace.shared.open(url) { unavailable() }
        }
    }

    /// Change…, and call audio's switch before Meetings knows, are quiet: nothing needs doing.
    private struct PermissionActionStyle: ViewModifier {
        let quiet: Bool
        func body(content: Content) -> some View {
            if quiet { content.buttonStyle(.workbenchLink).font(.caption) } else { content.controlSize(.small) }
        }
    }

    private func copyDetails() {
        let snapshot = snapshot
        let asked = model.preferences.accessibilityRequested == true
        let delivery = model.preferences.delivery.rawValue, paste = model.lastPasteProblem
        Task {
            let facts = await MacPermissionDetails.liveFacts(accessibilityAsked: asked, delivery: delivery, paste: paste)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(MacPermissionDetails.text(snapshot, facts), forType: .string)
            copiedDetails = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copiedDetails = false
        }
    }
}
