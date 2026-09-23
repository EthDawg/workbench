// StageKit's internal presentation style and isolated data location.
import AppKit
import SwiftUI

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
    static var stageDefaults: UserDefaults { UserDefaults(suiteName: suiteDomain + ".stage")! }

    /// Copy complete legacy presentation state once; never move or rewrite it.
    /// A staging directory keeps interrupted migrations from appearing complete.
    static func prepareStageData(applicationSupport: URL? = nil, defaults: UserDefaults? = nil, preview: Bool? = nil) -> String? {
        if fixtureRoot != nil, applicationSupport == nil { return nil }
        let root = applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let preview = preview ?? isPreview
        let defaults = defaults ?? stageDefaults
        let manager = FileManager.default
        let destination = root.appendingPathComponent(preview ? "Workbench Preview" : "Workbench").appendingPathComponent("StageMark")
        // These are presentation preferences only. Credentials and unrelated defaults stay put.
        if !defaults.bool(forKey: "legacyStagePreferencesSeeded.v1") {
            let domains = preview ? ["local.ethan.StageMark.preview", "local.ethan.StageMark"] : ["local.ethan.StageMark"]
            if let values = domains.compactMap({ UserDefaults.standard.persistentDomain(forName: $0) }).first(where: { $0["preferences.v1"] != nil }) {
                for key in ["preferences.v1", "preferences.schema", "preferences.recovery"] where defaults.object(forKey: key) == nil {
                    if let value = values[key] { defaults.set(value, forKey: key) }
                }
            }
            defaults.set(true, forKey: "legacyStagePreferencesSeeded.v1")
        }
        guard !manager.fileExists(atPath: destination.path) else { return nil }
        let candidates = preview ? ["StageMark Preview", "StageMark"] : ["StageMark"]
        let source = candidates.map { root.appendingPathComponent($0, isDirectory: true) }.first { manager.fileExists(atPath: $0.path) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".StageMark-migration-" + UUID().uuidString)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let source {
                let sourceValues = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard sourceValues.isSymbolicLink != true, sourceValues.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                for name in ["boards.json", "Scenes"] {
                    let from = source.appendingPathComponent(name)
                    if manager.fileExists(atPath: from.path) {
                        try copyMigrationItem(from, to: staging.appendingPathComponent(name), manager: manager)
                    }
                }
            }
            try manager.moveItem(at: staging, to: destination)
            return nil
        } catch {
            try? manager.removeItem(at: staging)
            return "Your existing presentation files are unchanged. Workbench could not finish copying them: \(error.localizedDescription)"
        }
    }
    private static func copyMigrationItem(_ source: URL, to destination: URL, manager: FileManager) throws {
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        if values.isDirectory == true {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                // An old desktop recovery manifest refers to the user's current Spaces.
                // Preserve it in the original app; never activate it in the new app.
                guard child.lastPathComponent != "desktop-restore.json" else { continue }
                try copyMigrationItem(child, to: destination.appendingPathComponent(child.lastPathComponent), manager: manager)
            }
        } else if values.isRegularFile == true {
            try manager.copyItem(at: source, to: destination)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } else { throw CocoaError(.fileReadUnsupportedScheme) }
    }
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let accent = WorkbenchPalette.accent
    static let border = Color.primary.opacity(0.08)
    static let controlWidth: CGFloat = 370
}

final class WorkbenchSettings: ObservableObject {
    enum Appearance: String, CaseIterable { case system = "System", light = "Light", dark = "Dark" }
    static let shared = WorkbenchSettings()
    #if APP_STORE
    // Store editions keep preferences within their own sandbox container.
    private let defaults = UserDefaults.standard
    #else
    private let defaults = UserDefaults.standard
    #endif
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
