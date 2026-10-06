import AppKit
import SwiftUI

/// Opt-in UI inspection of the help sheet with a synthetic status and a fake
/// app-opening boundary. This fixture never starts capture, launches a fallback
/// or writes user data.
@MainActor
final class PhonePresentationFixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func run() {
        NSApp.delegate = self
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(title: "Fixture")
        let quit = NSMenuItem(title: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; appMenu.addItem(quit); item.submenu = appMenu
        NSApp.mainMenu = menu
        let panel = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Workbench · Phone help QA"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PhonePresentationFixtureView())
        window = panel
        panel.center(); panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
    }
}

private struct PhonePresentationFixtureView: View {
    @State private var isPresenting = false
    @State private var showingHelp = false
    @State private var phase = 0
    @State private var result = "No app launch requested."
    private var signals: PhoneLinkSignals {
        var value = PhoneLinkSignals()
        switch phase {
        case 1: value.usb = [.init(name: "iPhone", kind: .iPhone, productID: 0x12A8)]
        case 2: value.sources = [.init(id: "one", name: "QA capture card", isScreen: false)]
        case 3: value.access = .restricted
        default: break
        }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Phone connection help").font(.title2.bold())
            Text("Synthetic QA · no device capture, account changes or app launches.")
                .foregroundStyle(.secondary)
            Toggle("Simulate an active Workbench presentation", isOn: $isPresenting)
            Picker("Synthetic state", selection: $phase) {
                Text("Nothing on USB").tag(0); Text("Phone on USB").tag(1); Text("Video device found").tag(2); Text("Video restricted").tag(3)
            }
            Button("Can’t see your phone?") { showingHelp = true }
            Text(result).accessibilityIdentifier("handoff-result")
            Button("Quit fixture") { NSApp.terminate(nil) }
        }.padding(28).frame(width: 660, height: 420, alignment: .topLeading)
            .sheet(isPresented: $showingHelp) {
                PhoneConnectionHelp(status: PhoneLink.status(signals), diagnostic: {
                    PhoneLink.diagnostic(signals, build: "fixture")
                }, endsPresentation: isPresenting) { app in
                    result = "Requested \(isPresenting ? "end and open" : "open"): \(app.title). Help dismissed first."
                    showingHelp = false
                }
            }
    }
}
