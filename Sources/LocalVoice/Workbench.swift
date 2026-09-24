// Unified Workbench identity and non-destructive legacy data import.
import AppKit
import SwiftUI
import StageKit

enum Workbench {
    static let name = "Workbench"
    static var isPreview: Bool { Bundle.main.object(forInfoDictionaryKey: "WorkbenchChannel") as? String == "preview" }
    static var productionIsRunning: Bool {
        guard isPreview, let identifier = Bundle.main.bundleIdentifier, identifier.hasSuffix(".preview") else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: String(identifier.dropLast(".preview".count))).isEmpty
    }
    static var displayName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? name }
    // Only debug QA bundles opt into disposable storage. Release builds ignore
    // the marker, and normal Preview/production data and migration stay intact.
    static var fixtureRoot: URL? {
        #if DEBUG
        if let path = Bundle.main.object(forInfoDictionaryKey: "WorkbenchFixtureRoot") as? String,
           path.hasPrefix("/private/tmp/workbench-usability-"), !path.contains("..") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return nil
    }
    static var suiteDomain: String {
        if fixtureRoot != nil { return Bundle.main.bundleIdentifier ?? "local.workbench.usability-qa" }
        return "com.ethdawg.workbench" + (isPreview ? ".preview" : "")
    }
    static func supportDirectory(component: String) -> URL {
        if let fixtureRoot { return fixtureRoot.appendingPathComponent(component, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isPreview ? "Workbench Preview" : "Workbench", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
    }
    static func preparePreviewData(component: String, files: [String]) {
        guard fixtureRoot == nil else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destination = supportDirectory(component: component)
        // A complete component directory is the import boundary: never merge a later
        // legacy snapshot into an existing unified session.
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let choices = [base.appendingPathComponent(component + " Preview"), base.appendingPathComponent(component)]
        let source = choices.first { FileManager.default.fileExists(atPath: $0.path) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".import-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            if let source {
                for file in files where !file.contains("/") && file != ".." {
                    let from = source.appendingPathComponent(file)
                    if FileManager.default.fileExists(atPath: from.path) {
                        try FileManager.default.copyItem(at: from, to: staging.appendingPathComponent(file))
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent(file).path)
                    }
                }
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            let defaults = UserDefaults.standard
            if defaults.object(forKey: VoicePreferences.key) == nil {
                let legacyIDs = ["com.ethdawg.localvoice.preview", "com.ethdawg.localvoice"]
                for id in legacyIDs {
                    if let value = defaults.persistentDomain(forName: id)?[VoicePreferences.key] {
                        defaults.set(value, forKey: VoicePreferences.key); break
                    }
                }
            }
        } catch { NSLog("Workbench could not import the previous session: %@", error.localizedDescription) }
    }
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let accent = WorkbenchPalette.accent
    static let border = Color.primary.opacity(0.08)
    static let controlWidth: CGFloat = 370
    static func open(_ app: String) {
        NotificationCenter.default.post(name: .workbenchNavigate, object: app == "Voice" ? "dictate" : "annotate")
    }

}

final class WorkbenchSettings: ObservableObject {
    enum Appearance: String, CaseIterable { case system = "System", light = "Light", dark = "Dark" }
    static let shared = WorkbenchSettings()
    // Both modules now live in this application's domain. Opening that same
    // domain as a separate suite can return nil in a signed installed app.
    private let defaults = UserDefaults.standard
    private let notification = Notification.Name(Workbench.suiteDomain + ".appearance")
    private var observer: NSObjectProtocol?
    private var systemObserver: NSObjectProtocol?
    @Published private(set) var systemIsDark = false
    var colorScheme: ColorScheme { appearance == .dark || (appearance == .system && systemIsDark) ? .dark : .light }
    @Published private(set) var appearance: Appearance = .system
    init() {
        refresh()
        systemObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        observer = DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    func setAppearance(_ value: Appearance) {
        defaults.set(value.rawValue, forKey: "appearance"); defaults.synchronize()
        refresh(); DistributedNotificationCenter.default().postNotificationName(notification, object: nil, userInfo: nil, deliverImmediately: true)
    }
    private func refresh() {
        defaults.synchronize(); UserDefaults.standard.synchronize()
        #if APP_STORE
        // Use AppKit appearance rather than reading a system-owned defaults key.
        NSApp?.appearance = nil
        systemIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
        systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        #endif
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        NSApp?.appearance = appearance == .system ? nil : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) }; if let systemObserver { DistributedNotificationCenter.default().removeObserver(systemObserver) } }
}

struct WorkbenchHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(Workbench.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(Workbench.isPreview ? "WORKBENCH · PREVIEW" : "WORKBENCH").font(.system(size: 8, weight: .semibold)).tracking(1.7).foregroundStyle(.secondary)
                Text(title).font(.system(size: 14, weight: .semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
                if Workbench.productionIsRunning {
                    Text("Quit production to use the same shortcuts here.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
struct WorkbenchSwitcher: View {
    var beforeOpen: () -> Void = {}
    var body: some View {
        Menu {
            Button("Voice · dictate and read") { beforeOpen(); Workbench.open("Voice") }
            Button("Annotate · draw and present") { beforeOpen(); Workbench.open("StageMark") }
        } label: { Label(Workbench.isPreview ? "Workbench Preview" : "Workbench", systemImage: "square.grid.2x2") }
        .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).accessibilityLabel("Workbench tools")
    }
}
struct WorkbenchAppearancePicker: View {
    @ObservedObject private var suite = WorkbenchSettings.shared
    var body: some View {
        Picker("Suite appearance", selection: Binding(get: { suite.appearance }, set: { suite.setAppearance($0) })) {
            ForEach(WorkbenchSettings.Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }
}

struct WorkbenchTheme: ViewModifier {
    @ObservedObject private var suite = WorkbenchSettings.shared
    func body(content: Content) -> some View {
        content.preferredColorScheme(suite.colorScheme)
    }
}
extension View {
    func workbenchTheme() -> some View { modifier(WorkbenchTheme()) }
}

extension Notification.Name { static let workbenchNavigate = Notification.Name("com.ethdawg.workbench.navigate") }
