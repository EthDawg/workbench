import AppKit
import SwiftUI
import WebKit

struct LogoBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = LogoBrowserModel()
    @State private var query = ""
    @State private var imageAddress = ""
    @State private var name = "Web logo"
    let useLogo: (LogoImport.Image) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Find a logo").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { browser.close(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Company or logo to find", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit { browser.search(query) }
                    .accessibilityLabel("Google Images search")
                Button("Search Google Images") { browser.search(query) }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack).accessibilityLabel("Back")
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward).accessibilityLabel("Forward")
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(browser.webView.url == nil).accessibilityLabel("Reload page")
                Text(browser.pageHost).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if browser.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button(browser.selecting ? "Cancel selection" : "Select image") { browser.selecting.toggle() }
                    .disabled(browser.webView.url == nil)
            }
            ZStack {
                LogoBrowserWebView(browser: browser)
                if browser.webView.url == nil && !browser.loading {
                    ContentUnavailableView("Search for a logo", systemImage: "photo.on.rectangle.angled",
                        description: Text("Browse public Google Images here, then select the image you want to use."))
                        .allowsHitTesting(false)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
            Text(browser.selecting ? "Click the logo image to preview it below." : "Open a larger preview, then choose Select image and click it.")
                .font(.caption).foregroundStyle(browser.selecting ? Workbench.accent : .secondary)
            HStack {
                TextField("Or paste a direct image URL", text: $imageAddress).textFieldStyle(.roundedBorder)
                    .onSubmit { browser.preview(imageAddress, name: "Web logo") }
                    .accessibilityLabel("Direct logo image URL")
                Button("Preview image") { browser.preview(imageAddress, name: "Web logo") }
                    .disabled(imageAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if browser.importing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading logo preview…").font(.caption)
                    Button("Cancel download") { browser.cancelImport() }
                }
            } else if let candidate = browser.candidate, let image = NSImage(data: candidate.png) {
                HStack(spacing: 14) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 110, height: 65)
                        .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Selected logo preview")
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Logo name", text: $name).textFieldStyle(.roundedBorder)
                        Text("Saved to this scene and your reusable logos.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Use logo") {
                        do {
                            try useLogo(LogoImport.Image(png: candidate.png, name: name))
                            browser.close(); dismiss()
                        } catch { browser.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                }
            }
            if let error = browser.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(20).frame(width: 880, height: 670).workbenchTheme()
        .onChange(of: browser.candidate?.name) { _, value in if let value { name = value } }
        .onDisappear { browser.close() }
    }
}

private struct LogoBrowserWebView: NSViewRepresentable {
    @ObservedObject var browser: LogoBrowserModel
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}

@MainActor
final class LogoBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var pageHost = "Public image search"
    @Published var selecting = false { didSet { setSelectionMode() } }
    @Published var importing = false
    @Published var candidate: LogoImport.Image?
    @Published var error: String?
    private var importTask: Task<Void, Never>?
    private var importID = UUID()
    private var closed = false

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        let bridge = LogoBrowserBridge(owner: self)
        configuration.userContentController.add(bridge, contentWorld: .defaultClient, name: "logoImage")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.selectionScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()

    func search(_ query: String) {
        guard !closed, let url = LogoWebImport.searchURL(query) else { return }
        error = nil; selecting = false
        webView.load(URLRequest(url: url))
    }

    func reload() { error = nil; webView.reload() }

    func preview(_ address: String, name: String) {
        guard !closed else { return }
        cancelImport(); candidate = nil; error = nil; selecting = false; importing = true
        let id = importID
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        importTask = Task { [weak self] in
            do {
                let image = try await LogoWebImport.load(address, name: name.isEmpty ? "Web logo" : name)
                guard let self, self.importID == id, !Task.isCancelled, !self.closed else { return }
                self.candidate = image; self.importing = false; self.importTask = nil
            } catch {
                guard let self, self.importID == id, !Task.isCancelled, !self.closed else { return }
                self.error = error.localizedDescription; self.importing = false; self.importTask = nil
            }
        }
    }

    func cancelImport() {
        importID = UUID(); importTask?.cancel(); importTask = nil; importing = false
    }

    func close() {
        guard !closed else { return }
        closed = true; cancelImport(); webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "logoImage", contentWorld: .defaultClient)
        webView.navigationDelegate = nil; webView.uiDelegate = nil
    }

    fileprivate func selected(_ body: Any) {
        guard selecting, let value = body as? [String: String], let source = value["source"] else { return }
        preview(source, name: String((value["name"] ?? "Web logo").prefix(160)))
    }

    private func setSelectionMode() {
        guard !closed else { return }
        webView.evaluateJavaScript("window.workbenchSelectLogo = \(selecting ? "true" : "false"); document.documentElement.classList.toggle('workbench-logo-selection', window.workbenchSelectLogo);",
                                  in: nil, in: .defaultClient, completionHandler: nil)
    }

    private func refreshNavigation() {
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        pageHost = webView.url?.host ?? "Public image search"
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; selecting = false; refreshNavigation()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; refreshNavigation(); setSelectionMode()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ failure: Error) {
        loading = false; refreshNavigation()
        if (failure as NSError).code != NSURLErrorCancelled { error = "This page could not load. Reload it, search again, or use a direct image URL." }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false; error = "The image browser stopped. Reload the page to continue."
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let address = navigationAction.request.url?.absoluteString, LogoWebImport.remoteURL(address) != nil else {
            if navigationAction.targetFrame?.isMainFrame != false { error = "This link cannot open in the logo picker. Choose an image or another web page." }
            decisionHandler(.cancel); return
        }
        if navigationAction.targetFrame == nil {
            if navigationAction.navigationType == .linkActivated { webView.load(navigationAction.request) }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.canShowMIMEType else {
            error = "This page starts a download. Use a direct image URL to preview a logo here."
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }

    // The isolated client world prevents a page from calling the native bridge.
    // Selecting only previews bytes; the native Use logo button owns the save.
    static let selectionScript = """
    window.workbenchSelectLogo = false;
    const style = document.createElement('style');
    style.textContent = '.workbench-logo-selection img:hover { outline: 3px solid #13a886 !important; cursor: crosshair !important; }';
    document.documentElement.appendChild(style);
    document.addEventListener('click', event => {
      if (!window.workbenchSelectLogo || !event.isTrusted) return;
      const img = event.target.closest('img');
      if (!img) return;
      event.preventDefault(); event.stopImmediatePropagation();
      let source = img.currentSrc || img.src;
      const anchor = img.closest('a[href]');
      if (anchor) {
        try { source = new URL(anchor.href).searchParams.get('imgurl') || source; } catch (_) {}
      }
      if (!source || source.length > \(LogoWebImport.maximumDataURLLength)) return;
      window.webkit.messageHandlers.logoImage.postMessage({source, name: (img.alt || 'Web logo').slice(0, 160)});
    }, true);
    """
}

@MainActor
private final class LogoBrowserBridge: NSObject, WKScriptMessageHandler {
    weak var owner: LogoBrowserModel?
    init(owner: LogoBrowserModel) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        owner?.selected(message.body)
    }
}
