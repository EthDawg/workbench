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

/// Guidance and ordinary app launching only. No account, policy, audio route,
/// screen-sharing or third-party application settings are changed here.
struct NativePresentationApps: View {
    var onEndAndOpen: ((NativePresentationApp) -> Void)? = nil
    var onError: (String) -> Void
    @State private var showingGuide = false
    @State private var pendingApp: NativePresentationApp?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showingGuide = true } label: {
                Label("Connection & audio…", systemImage: "cable.connector")
            }.help("Choose a route for phone screens, voice conversations or Mac control")
            if onEndAndOpen != nil {
                ForEach(NativePresentationApp.allCases, id: \.self) { app in launchButton(app) }
            } else {
                HStack(spacing: 10) {
                    ForEach(NativePresentationApp.allCases, id: \.self) { app in launchButton(app) }
                }
            }
            Text("Workbench shows USB video only. For voice demos, choose a separate phone-audio route.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingGuide, onDismiss: {
            guard let app = pendingApp else { return }
            pendingApp = nil
            launch(app)
        }) {
            PhonePresentationGuide(endsPreview: onEndAndOpen != nil, openApp: { app in
                pendingApp = app
                showingGuide = false
            })
        }
    }
    private func launchButton(_ app: NativePresentationApp) -> some View {
        Button(onEndAndOpen == nil ? app.title : "End preview & open \(app.title)") { launch(app) }
            .disabled(!app.isAvailable)
            .help(app.isAvailable ? "Open \(app.title) in its own window" : "Not installed on this Mac")
    }
    private func launch(_ app: NativePresentationApp) {
        guard app.isAvailable else { onError("\(app.title) is not installed on this Mac."); return }
        if let onEndAndOpen { onEndAndOpen(app) }
        else { app.open(onError: onError) }
    }
}

enum PhonePresentationJob: String, CaseIterable, Identifiable {
    case screen, voice, control
    var id: String { rawValue }
    var title: String {
        switch self { case .screen: return "Show a phone"; case .voice: return "Voice conversation"; case .control: return "Control from Mac" }
    }
    var suggestedRoute: PhonePresentationRoute {
        switch self { case .screen: return .workbench; case .voice: return .quickTime; case .control: return .mirroring }
    }
}

enum PhonePresentationRoute: String, CaseIterable, Identifiable {
    case workbench, quickTime, zoomCable, mirroring, airPlay, phoneMeeting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .workbench: return "Workbench · USB"
        case .quickTime: return "QuickTime · USB"
        case .zoomCable: return "Zoom · iPhone/iPad via Cable"
        case .mirroring: return "Apple iPhone Mirroring"
        case .airPlay: return "AirPlay to Mac"
        case .phoneMeeting: return "Share directly from iPhone"
        }
    }
    var app: NativePresentationApp? {
        switch self { case .quickTime: return .quickTime; case .mirroring: return .iPhoneMirroring; default: return nil }
    }
    var summary: String {
        switch self {
        case .workbench: return "Your phone inside a saved backdrop. Operate the physical phone; Workbench displays its picture."
        case .quickTime: return "A plain phone preview with separate audio choices. A useful built-in route to rehearse a voice demo."
        case .zoomCable: return "Zoom can share the connected phone and its audio directly. This uses Zoom’s presentation, without a Workbench backdrop."
        case .mirroring: return "Use your Mac mouse and keyboard while the iPhone stays locked. This is Apple’s separate window."
        case .airPlay: return "Operate the phone and show it wirelessly on an allowed Mac receiver. This does not give the Mac control."
        case .phoneMeeting: return "Use the meeting app on the phone to share its screen. Useful when the Mac cannot receive the device."
        }
    }
    var steps: [String] {
        switch self {
        case .workbench: return ["Connect a data-capable USB cable. Unlock the phone and trust this approved Mac when asked.", "In the presentation, choose Source and select the phone. If you have not started, choose Present from your scene first. Workbench remembers that exact device.", "Use the phone for taps, typing and its own voice features. Share the Workbench presentation window or display."]
        case .quickTime: return ["End other previews using the phone. Connect and unlock it, and complete approved trust prompts.", "In QuickTime, choose File → New Movie Recording. Open the source menu and choose the iPhone as Camera.", "Choose the intended audio source separately and raise QuickTime’s monitor volume if needed. You do not need to record to show the preview.", "Share that window in your meeting. Enable computer sound only after the phone’s reply actually plays on the Mac."]
        case .zoomCable: return ["End the Workbench device presentation or other USB preview first.", "In the Zoom desktop meeting on Mac, choose Share Screen → iPhone/iPad via Cable.", "Enable Share computer sound for phone audio, then Share. Follow the cable and trust instructions.", "Operate and speak to the phone. Ask a participant to confirm the picture, your voice and the agent’s reply."]
        case .mirroring: return ["Use a supported Mac and iPhone with the same Apple Account and two-factor authentication, where your organisation permits it.", "Keep Wi-Fi and Bluetooth on, the phone nearby and locked. Open iPhone Mirroring.", "Share Apple’s window in your meeting. Opening the app does not establish that the meeting receives its picture or audio."]
        case .airPlay: return ["Use an approved AirPlay receiver configuration. Apple’s normal setup uses the same Wi-Fi network.", "On the phone, open Control Centre → Screen Mirroring and choose the Mac.", "Rehearse the meeting’s capture of the receiver and actual playback. End Screen Mirroring on the phone when finished."]
        case .phoneMeeting: return ["Join the same meeting on the phone with the appropriate sharing permission. Keep only one meeting microphone and speaker active to avoid echo.", "In Teams on iPhone, choose Share → Share screen with audio → Start Broadcast. Zoom offers device-screen sharing with Share Device Audio.", "Open the demo app and test its microphone and reply audio. Stop the phone’s broadcast explicitly; ending Workbench does not stop it."]
        }
    }
    var limitation: String {
        switch self {
        case .workbench: return "Video only: Workbench does not play or forward the phone’s audio. A meeting’s sound toggle cannot add audio missing from this route."
        case .quickTime: return "The phone app owns its microphone. QuickTime’s audio selector does not forward a Mac microphone into that app; simultaneous listening and reply playback need a real rehearsal."
        case .zoomCable: return "Zoom documents phone-audio sharing, but not every voice agent’s simultaneous microphone use. Confirm the actual app can still listen, respond and be interrupted."
        case .mirroring: return "The iPhone microphone and camera are unavailable in iPhone Mirroring. Choose USB for a live microphone-based voice demo. Hardware, region, account and workplace restrictions also apply."
        case .airPlay: return "Some phone conversation audio modes disable AirPlay mirroring. A wireless receiver is not a universal fallback for voice agents or restricted workplace networks."
        case .phoneMeeting: return "Two apps may compete for phone audio. Muting the meeting is not proof the agent keeps its microphone. This route also shares the entire phone screen."
        }
    }
    var supportURL: URL {
        let value: String
        switch self {
        case .workbench: value = "https://workbench-mac.vercel.app/phone-presenting/"
        case .quickTime: value = "https://support.apple.com/en-au/guide/quicktime-player/qtp356b55534/mac"
        case .zoomCable: value = "https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0066704"
        case .mirroring: value = "https://support.apple.com/en-au/120421"
        case .airPlay: value = "https://support.apple.com/en-nz/guide/mac-help/mchld7e543a0/mac"
        case .phoneMeeting: value = "https://workbench-mac.vercel.app/phone-presenting/#phone-share"
        }
        return URL(string: value)!
    }
}

/// A bounded preparation aid, available without starting capture or requesting
/// permissions. No checklist is persisted or represented as automatic readiness.
struct PhonePresentationGuide: View {
    var endsPreview = false
    var openApp: (NativePresentationApp) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var job = PhonePresentationJob.screen
    @State private var route = PhonePresentationRoute.workbench
    @State private var showingWorkplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connection & audio").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Picker("What are you demonstrating?", selection: $job) {
                ForEach(PhonePresentationJob.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
                .onChange(of: job) { _, value in route = value.suggestedRoute }
            Picker("Route", selection: $route) {
                ForEach(PhonePresentationRoute.allCases) { Text($0.title).tag($0) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(route.summary).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if job == .voice && route == .quickTime {
                        Button("Using Zoom? See its built-in cable route") { route = .zoomCable }
                            .buttonStyle(.link)
                    }
                    ForEach(Array(route.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 16)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Label { Text(route.limitation).fixedSize(horizontal: false, vertical: true) }
                        icon: { Image(systemName: "info.circle") }
                        .font(.callout).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    if job == .voice {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Rehearse both sides").font(.headline)
                            Text("Ask the agent a question, interrupt its reply and ask another. Have a participant confirm they can hear you and the agent without doubled sound. Repeat after reconnecting.")
                            Text("The phone microphone, the agent’s reply and the meeting microphone are three separate paths. Hearing sound beside your Mac is not an audience check.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("Using a workplace-managed Mac?", isExpanded: $showingWorkplace) {
                        Text("USB avoids a matching Apple Account and a wireless receiver, but still needs allowed device pairing and video access. A Managed Apple Account can support Mirroring when both devices use that account and policy permits it. Workbench cannot inspect every workplace restriction. If access is restricted, use a route your organisation allows or ask IT. Teams computer-audio setup may also need IT’s help. This guide changes no policy, account, driver or audio setting.")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.id(route) // Every route starts at its own first instruction.
            Divider()
            HStack {
                Link("Route instructions ↗", destination: route.supportURL)
                Spacer()
                if let app = route.app {
                    Button(endsPreview ? "End preview & open \(app.title)" : "Open \(app.title)") { openApp(app) }
                        .disabled(!app.isAvailable)
                        .help(app.isAvailable ? "Opens Apple’s separate app" : "Not installed on this Mac")
                }
            }
            if endsPreview {
                Text("Opening an Apple app ends this Workbench device presentation first. Other apps and saved scenes stay intact.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(width: 580, height: 610)
            .onExitCommand { dismiss() }
    }
}
