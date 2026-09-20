import AppKit
import SwiftUI

/// Opt-in UI inspection with real guide views and a fake app-opening boundary.
/// This fixture never starts capture, launches a fallback, or writes user data.
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
        let panel = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 400),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Workbench · Phone route QA"
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
    @State private var result = "No app launch requested."
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Phone presentation guide").font(.title2.bold())
            Text("Synthetic QA · no device capture, account changes or app launches.")
                .foregroundStyle(.secondary)
            Toggle("Simulate an active Workbench presentation", isOn: $isPresenting)
            NativePresentationApps(onEndAndOpen: isPresenting ? { app in
                result = "Requested end and open: \(app.title). Guide dismissed first."
            } : nil) { result = $0 }
                .disabled(!isPresenting)
            Text("Enable the simulated presentation to inspect the guide safely.")
                .font(.caption).foregroundStyle(.secondary)
            Text(result).accessibilityIdentifier("handoff-result")
            Button("Quit fixture") { NSApp.terminate(nil) }
        }.padding(28).frame(width: 660, height: 400, alignment: .topLeading)
    }
}
