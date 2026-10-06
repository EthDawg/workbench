import AppKit
import SwiftUI

/// Deliberately static: no transcript, device details or usage history enter this draft.
enum FounderIntroductionDraft {
    static let recipients = ["ethanharley77@gmail.com", "matty.white.au@gmail.com"]
    static let subject = "Hello from a Workbench user"
    static let body = """
    Hi Ethan and Matt,

    I'm trying Workbench and wanted to say hello.

    """
    static var addresses: String { recipients.joined(separator: ", ") }
    static var copyable: String { "To: \(addresses)\nSubject: \(subject)\n\n\(body)" }
    static var url: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipients.joined(separator: ",")
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }
}

@MainActor
final class FounderIntroductionModel: ObservableObject {
    private static let dismissalKey = "workbench.founderIntroduction.dismissed.v1"
    private let defaults: UserDefaults
    @Published private(set) var isDismissed: Bool
    @Published private(set) var isOpening = false
    @Published private(set) var message: String?
    @Published private(set) var hasError = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isDismissed = defaults.bool(forKey: Self.dismissalKey)
    }
    func dismiss() {
        defaults.set(true, forKey: Self.dismissalKey)
        isDismissed = true
    }
    func openDraft() {
        guard !isOpening else { return }
        message = nil; hasError = false
        guard let url = FounderIntroductionDraft.url else {
            hasError = true; message = "The email draft could not be prepared. Use Copy instead."; return
        }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            hasError = true; message = "No email app is configured. Copy the addresses or draft instead."; return
        }
        isOpening = true
        NSWorkspace.shared.open(url, configuration: .init()) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isOpening = false
                self.hasError = error != nil
                self.message = error == nil
                    ? "Your email app was asked to open a draft. If it needs setup, you can use Copy instead."
                    : "The email app could not open the draft. Copy the addresses or draft instead."
            }
        }
    }
    func copy(addressesOnly: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(addressesOnly ? FounderIntroductionDraft.addresses : FounderIntroductionDraft.copyable, forType: .string)
        hasError = !copied
        message = copied ? (addressesOnly ? "Addresses copied." : "Email draft copied. Paste it into your email app and edit before sending.") : "Could not copy to the clipboard. Try again."
    }
}

struct FounderIntroductionCard: View {
    @ObservedObject var model: FounderIntroductionModel
    var canDismiss = true
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "envelope").font(.system(size: 25)).foregroundStyle(Workbench.accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 9) {
                Text("Say hello to Ethan and Matt").font(.headline)
                Text("Open an editable draft in your email app. You choose whether to send.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button(model.isOpening ? "Opening email app…" : "Open email draft") { model.openDraft() }
                        .disabled(model.isOpening)
                    Menu("Copy") {
                        Button("Copy addresses") { model.copy(addressesOnly: true) }
                        Button("Copy email draft") { model.copy(addressesOnly: false) }
                    }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Copy founder email addresses or draft")
                    if canDismiss { Button("Not now") { model.dismiss() }.buttonStyle(.workbenchLink) }
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(model.hasError ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(20)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}
