import AppKit
import SwiftUI

enum NativePresentationApp: String, CaseIterable {
    case quickTime, iPhoneMirroring
    var title: String { self == .quickTime ? "QuickTime Player" : "iPhone Mirroring" }
    var bundleIdentifier: String { self == .quickTime ? "com.apple.QuickTimePlayerX" : "com.apple.ScreenContinuity" }
    var applicationURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) }
    var isAvailable: Bool { applicationURL != nil }

    func open(onError: @escaping (String) -> Void) {
        guard let url = applicationURL else { onError("\(title) is not installed on this Mac."); return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { DispatchQueue.main.async { onError("\(title) could not open: \(error.localizedDescription)") } }
        }
    }
}

enum PhoneConnectionSupport {
    static let guideURL = URL(string: "https://workbench-mac.vercel.app/guide/#phone-share")!
    static let cameraSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
    /// The three things that happen away from Workbench, in the order they fail.
    static let checks = [
        "The cable carries data. Some cables only charge; the cable that came with the phone does both.",
        "The phone is unlocked and you tapped Trust This Computer. A reset phone or a new Mac asks again.",
        "This Mac allowed the accessory. Approve its prompt, or look under System Settings › Privacy & Security › Allow accessories to connect. A managed Mac may block phones over USB; that is IT’s setting, not yours."
    ]

    /// Copies the connection details and reports whether the pasteboard took them.
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
    /// What the button and VoiceOver say after a copy, from the pasteboard's own answer:
    /// success is never claimed for a write that did not happen.
    static func copyOutcome(_ wrote: Bool) -> (label: String, announcement: String) {
        wrote ? ("Copied", "Connection details copied")
              : ("Couldn’t copy", "Connection details were not copied. Try again.")
    }
}

/// One compact answer to "Can’t see your phone?": the live status, the three
/// checks that happen away from Workbench, a QuickTime check while the picture is
/// missing for a reason the Mac might explain, and the honest ways to show a phone
/// in a call when this Mac cannot receive it. No route picker, no policy detection,
/// no setting changed.
struct PhoneConnectionHelp: View {
    let status: PhoneLinkStatus
    let diagnostic: () -> String
    /// A presentation is running: opening an Apple app releases its capture first.
    var endsPresentation = false
    let openApp: (NativePresentationApp) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The last copy's words, nil until a copy is tried or after they fade.
    @State private var copyLabel: String?
    @State private var copiedLifetime: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Can’t see your phone?").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.symbol).font(.title3).foregroundStyle(status.isLive ? Workbench.accent : .secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title).font(.headline)
                    if let detail = status.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                }.fixedSize(horizontal: false, vertical: true)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Three checks, on the phone and this Mac").font(.headline)
                        ForEach(Array(PhoneConnectionSupport.checks.enumerated()), id: \.offset) { index, check in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 16)
                                Text(check).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if status.suggestsQuickTimeCheck {
                        VStack(alignment: .leading, spacing: 6) {
                            Button(endsPresentation ? "End presentation & check in QuickTime Player" : "Check in QuickTime Player") { openApp(.quickTime) }
                                .disabled(!NativePresentationApp.quickTime.isAvailable)
                            Text("File › New Movie Recording, then the source menu beside the record button. Whether QuickTime sees the phone is one more observation for your report; it doesn’t say why.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("In a call, without the stage").font(.headline)
                        Text("Zoom on this Mac: Share Screen › iPhone/iPad via Cable, with Share computer sound for the phone’s audio.")
                        Text("Teams or Zoom on the phone: share the phone’s screen from the phone itself. Keep one microphone and speaker live so nothing echoes.")
                        HStack(alignment: .top, spacing: 10) {
                            Text("Apple’s iPhone Mirroring controls the phone from this Mac. It needs the same Apple Account signed in on both devices, and keeps the phone’s microphone and camera off.")
                            if NativePresentationApp.iPhoneMirroring.isAvailable {
                                Button(endsPresentation ? "End & open" : "Open") { openApp(.iPhoneMirroring) }.fixedSize()
                            }
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }
            Divider()
            HStack {
                Button(copyLabel ?? "Copy connection details") {
                    let outcome = PhoneConnectionSupport.copyOutcome(PhoneConnectionSupport.copy(diagnostic()))
                    // One owner-held lifetime per copy (Fit rule 7): a rerender cannot restart it and
                    // a stale one cannot end a newer one. VoiceOver hears what actually happened, once.
                    copiedLifetime?.cancel()
                    copyLabel = outcome.label
                    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                         userInfo: [.announcement: outcome.announcement, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                    let lifetime = DispatchWorkItem { copyLabel = nil }
                    copiedLifetime = lifetime
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: lifetime)
                }.help("Facts about the USB bus, screen sources and permissions, with no identifiers or device names, for IT or a report")
                Spacer()
                Link("Help online ↗", destination: PhoneConnectionSupport.guideURL)
            }
            if endsPresentation {
                Text("Opening an Apple app ends this presentation’s capture first. Saved scenes stay as they are.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(width: 520, height: 560)
            .onExitCommand { dismiss() }
    }
}
