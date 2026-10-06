import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

/// Home's Permissions panel (docs/desktop.md § Home). It shows what macOS lets Workbench use on
/// this Mac, what each approval is for and what still works without it. Looking never asks:
/// every status is read passively, and macOS's own request appears only when the person presses
/// Allow… on that one row. Nothing here is a gate; every tool keeps its own contextual request
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
    /// What the approval lets Workbench do, in the person's words.
    var purpose: String {
        switch self {
        case .microphone: return "Dictate, Meetings and Snap & Talk hear you."
        case .accessibility: return "Dictated words go straight into the app you’re typing in."
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
}

/// Only the distinctions macOS actually reports. A yes/no check that says no cannot tell
/// "never asked" from "turned off", so it reads as not allowed, never as denied by policy.
enum MacPermissionState: Equatable {
    case allowed
    /// macOS has not asked yet; Allow… shows its request.
    case notAsked
    /// Turned off, or a yes/no check that is not yet true after Workbench asked.
    case notAllowed
    /// Restricted: an organisation or Screen Time controls it.
    case managed
    /// No passive check exists; macOS asks the first time the feature runs.
    case checkedOnUse
    /// This Mac cannot provide it at all.
    case unsupported(String)
}

/// One row of the panel, derived from the permission and its state alone, so checks can hold
/// every combination without a Mac to ask.
struct MacPermissionRow: Equatable, Identifiable {
    enum Action: Equatable {
        /// Shows macOS's request for this one approval.
        case request
        /// Opens Privacy & Security at this approval's list.
        case openSettings
        var title: String { self == .request ? "Allow…" : "Open Settings…" }
    }
    let permission: MacPermission
    let state: MacPermissionState
    var id: MacPermission { permission }

    var status: String {
        switch state {
        case .allowed: return "Allowed"
        case .notAsked: return "Not asked yet"
        case .notAllowed: return "Off"
        case .managed: return "Managed"
        case .checkedOnUse: return "Asked on first call"
        case .unsupported(let reason): return reason
        }
    }
    /// Orange only when an approval is off, which is when a tool that needs it would fail. One
    /// macOS has not asked about yet is plain information: the tool asks when it is first used.
    var tone: WorkbenchTone {
        switch state {
        case .allowed: return .done
        case .notAllowed: return .attention
        case .notAsked, .managed, .checkedOnUse, .unsupported: return .neutral
        }
    }
    var action: Action? {
        switch state {
        case .notAsked: return .request
        // A restricted approval can still be read in Settings; there is nothing to request.
        case .notAllowed, .managed: return .openSettings
        // Call audio's list is empty until Meetings first records a call, and a refusal there is
        // explained, with its own Settings door, on Meetings itself.
        case .allowed, .unsupported, .checkedOnUse: return nil
        }
    }
    /// A second line only where the person needs it: what works meanwhile, or why it is managed.
    var detail: String? {
        switch state {
        case .allowed, .unsupported: return nil
        case .managed: return "Your organisation or Screen Time sets this. " + permission.withoutIt
        case .notAsked, .notAllowed: return permission.withoutIt
        case .checkedOnUse: return "macOS asks the first time Meetings records a call. " + permission.withoutIt
        }
    }
    /// macOS keeps Screen Recording off for a running app until it reopens.
    var afterAllowing: String? {
        permission == .screenRecording && state == .notAllowed ? Self.reopenAfterAllowing : nil
    }
    static let reopenAfterAllowing = "Once it’s on, quit and reopen Workbench."
    /// Where macOS lists call audio once it has asked, for the row's help: its own list from macOS 15.
    static var callAudioList: String {
        if #available(macOS 15, *) { return "Once asked, macOS lists it in Privacy & Security › Screen & System Audio Recording › System Audio Recording Only." }
        return "Once asked, macOS lists it in Privacy & Security."
    }
}

/// The panel's whole state. Its summary names what it can know, never a count over rows it
/// cannot check: “2 off”, “2 not asked yet” or, only when true, “All allowed”.
struct MacPermissionSnapshot: Equatable {
    var rows: [MacPermissionRow]
    init(_ states: [MacPermission: MacPermissionState]) {
        rows = MacPermission.allCases.compactMap { permission in states[permission].map { MacPermissionRow(permission: permission, state: $0) } }
    }
    private func count(_ state: MacPermissionState) -> Int { rows.filter { $0.state == state }.count }
    var offCount: Int { count(.notAllowed) }
    var notAskedCount: Int { count(.notAsked) }
    /// Something a tool needs is off: the panel opens and asks for attention.
    var needsAttention: Bool { offCount > 0 }
    /// Every approval that can be checked is allowed. A managed one keeps this false.
    var isComplete: Bool { !rows.contains { [.notAsked, .notAllowed, .managed].contains($0.state) } }
    var summary: String {
        if offCount > 0 { return "\(offCount) off" }
        if isComplete { return "All allowed" }
        if notAskedCount > 0 { return "\(notAskedCount) not asked yet" }
        return "\(count(.managed)) managed"
    }
    var tone: WorkbenchTone { needsAttention ? .attention : isComplete ? .done : .neutral }
    /// The panel shows every row while something is off, or while something is still to set up
    /// and the person has not chosen Done for now. Otherwise it is one line.
    func expanded(dismissed: Bool) -> Bool { needsAttention || (!isComplete && !dismissed) }
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

    static let live = MacPermissionReader(
        microphone: { AVCaptureDevice.authorizationStatus(for: .audio) },
        camera: { AVCaptureDevice.authorizationStatus(for: .video) },
        accessibility: { AXIsProcessTrusted() },
        screenRecording: { ScreenCaptureAccess.system.isGranted() },
        callAudioSupported: { if #available(macOS 14.2, *) { return true } else { return false } },
        screenRecordingAsked: { ScreenCaptureAccess.wasRequested })
    /// The surface gallery's fixed answers replace this; the app always reads macOS.
    static var current = live

    nonisolated static func state(_ status: AVAuthorizationStatus) -> MacPermissionState {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        case .restricted: return .managed
        default: return .notAllowed
        }
    }

    /// `accessibilityAsked` comes from Dictate's own saved preference, the one its Set up
    /// automatic paste… already keeps.
    func snapshot(accessibilityAsked: Bool) -> MacPermissionSnapshot {
        MacPermissionSnapshot([
            .microphone: Self.state(microphone()),
            .accessibility: accessibility() ? .allowed : accessibilityAsked ? .notAllowed : .notAsked,
            .screenRecording: screenRecording() ? .allowed : screenRecordingAsked() ? .notAllowed : .notAsked,
            .camera: Self.state(camera()),
            .callAudio: callAudioSupported() ? .checkedOnUse : .unsupported("Needs macOS 14.2 or later"),
        ])
    }
}

/// The panel. Home owns its snapshot and rereads macOS when Home appears and whenever Workbench
/// comes back to the front, which is when someone returns from System Settings.
struct HomePermissionsPanel: View {
    @ObservedObject var model: AppModel
    let snapshot: MacPermissionSnapshot
    /// Done for now, saved with Home: the panel stays one line until something turns off.
    @Binding var dismissed: Bool
    /// Rereads macOS after an Allow… or Open Settings… returns.
    var refresh: () -> Void
    @State private var showingDetails = false
    @State private var problem: String?

    var body: some View {
        let expanded = snapshot.expanded(dismissed: dismissed) || showingDetails
        WorkbenchTile("Permissions", symbol: "lock.shield", accessory: {
            WorkbenchStatusBadge(text: snapshot.summary, tone: snapshot.tone)
                .accessibilityIdentifier("home.permissions.summary")
        }) {
            if expanded {
                Text("What Workbench can use on this Mac. Nothing is asked until you press Allow…, and each row says what still works without it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.rows) { row in
                        if row.id != snapshot.rows.first?.id { Divider().padding(.leading, 34) }
                        rowView(row)
                    }
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Workbench.attention).fixedSize(horizontal: false, vertical: true)
                }
                if !snapshot.needsAttention {
                    Button(snapshot.isComplete ? "Hide details" : "Done for now") { dismissed = true; showingDetails = false }
                        .buttonStyle(.link).font(.callout)
                        .help(snapshot.isComplete ? "Fold the panel to one line." : "Fold the panel to one line. Each tool still asks when it first needs something.")
                        .accessibilityIdentifier("home.permissions.fold")
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.isComplete ? "All set. macOS asks about call audio the first time you record a call."
                         : "Each tool asks when it first needs something. Allowed: " + allowedNames + ".")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Show details") { showingDetails = true }.buttonStyle(.link).font(.callout)
                        .accessibilityIdentifier("home.permissions.details")
                }
            }
        }
        .accessibilityIdentifier("home.permissions")
    }

    private var allowedNames: String {
        let names = snapshot.rows.filter { $0.state == .allowed }.map(\.permission.name)
        return names.isEmpty ? "none yet" : ListFormatter.localizedString(byJoining: names)
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
                ForEach([row.detail, row.afterAllowing].compactMap { $0 }, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .help(row.permission == .callAudio ? MacPermissionRow.callAudioList : "")
            if let action = row.action {
                Button(action.title) { perform(action, for: row.permission) }
                    .controlSize(.small)
                    .fixedSize()
                    .help(action == .request ? "Shows macOS’s request for \(row.permission.name)." : "Opens Privacy & Security › \(row.permission.name) in System Settings.")
                    .accessibilityLabel("\(action.title.replacingOccurrences(of: "…", with: "")) \(row.permission.name)")
                    .accessibilityIdentifier("home.permissions.\(row.permission.rawValue)")
            }
        }.padding(.vertical, 10)
            .accessibilityElement(children: .contain)
    }

    /// Each Allow… reaches the same owner its tool uses: Dictate's microphone and automatic-paste
    /// setup, Snap's Screen Recording request, and macOS's camera request. None starts a recording.
    private func perform(_ action: MacPermissionRow.Action, for permission: MacPermission) {
        problem = nil
        switch (action, permission) {
        case (.request, .microphone):
            Task { _ = await model.requestMicrophoneAuthorization(); model.refreshMicrophoneAuthorization(); refresh() }
        case (.request, .accessibility), (.openSettings, .accessibility):
            // Dictate's own setup: the first press asks macOS, later presses open Settings (#165).
            model.requestAccessibility(); refresh()
        case (.request, .screenRecording):
            // macOS shows its request once per app. If it asked before Workbench kept count, no
            // request comes forward; Workbench is still in front after a moment, so Settings opens
            // instead, as Set up automatic paste… does. The press is never a dead click.
            _ = ScreenCaptureAccess.system.request(); refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + AccessibilitySetup.requestWait) {
                guard NSApp.isActive, !ScreenCaptureAccess.system.isGranted() else { return }
                open(permission)
            }
        case (.request, .camera):
            Task { _ = await AVCaptureDevice.requestAccess(for: .video); refresh() }
        case (.openSettings, _), (.request, .callAudio):
            open(permission)
        }
    }

    private func open(_ permission: MacPermission) {
        if !NSWorkspace.shared.open(permission.settingsURL) {
            problem = "System Settings could not be opened. Open Privacy & Security › \(permission.name) there."
        }
    }
}
