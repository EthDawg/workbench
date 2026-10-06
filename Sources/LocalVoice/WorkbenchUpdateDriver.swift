import Foundation
#if !APP_STORE
import Sparkle

/// Sparkle owns selection, signatures, downloads and replacement. This adapter
/// puts an ordinary release's single Install choice in the existing sidebar;
/// Sparkle's native UI still handles progress, cancellation, errors and any
/// informational/major upgrade which needs its full review.
@MainActor
final class WorkbenchUpdateDriver: NSObject, SPUUserDriver, @preconcurrency SPUStandardUserDriverDelegate {
    private weak var owner: WorkbenchUpdates?
    private var standard: (any SPUUserDriver)!
    private var inlineOffer = false

    init(owner: WorkbenchUpdates, hostBundle: Bundle, standard: (any SPUUserDriver)? = nil) {
        self.owner = owner
        super.init()
        self.standard = standard ?? SPUStandardUserDriver(hostBundle: hostBundle, delegate: self)
    }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Exceptional scheduled releases also stay quiet until Review is chosen.
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }
    static func canOfferInline(_ item: SUAppcastItem) -> Bool {
        !item.isInformationOnlyUpdate && !item.isMajorUpgrade && item.signingValidationStatus != .failed
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner, Self.canOfferInline(appcastItem) else {
            inlineOffer = false
            owner?.needsNativeReview()
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
            return
        }
        inlineOffer = true
        standard.dismissUpdateInstallation() // Close the manual checking window, if present.
        owner.receiveOffer(version: appcastItem.displayVersionString, buildNumber: appcastItem.versionString,
            summary: WorkbenchUpdateSummary.text(from: appcastItem.itemDescription, format: appcastItem.itemDescriptionFormat),
            downloaded: state.stage != .notDownloaded, reply: reply)
        if state.userInitiated { owner.showUpdate() }
    }
    func showUpdateInFocus() {
        if inlineOffer { owner?.showUpdate() }
        else { standard.showUpdateInFocus?() }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if !inlineOffer { standard.showUpdateReleaseNotes(with: downloadData) }
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        if !inlineOffer { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        inlineOffer = false
        standard.showDownloadInitiated(cancellation: cancellation)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standard.showDownloadDidReceiveData(ofLength: length)
    }
    func showDownloadDidStartExtractingUpdate() {
        inlineOffer = false
        standard.showDownloadDidStartExtractingUpdate()
    }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if owner?.continueInstallation(reply: reply) != true {
            standard.showReady(toInstallAndRelaunch: reply)
        }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        inlineOffer = false
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }
    func dismissUpdateInstallation() {
        inlineOffer = false
        owner?.finishUpdateSession()
        standard.dismissUpdateInstallation()
    }
}
#endif

/// A short benefit from the release's first paragraph, with no WebKit, remote
/// resources or executable HTML. Missing/malformed notes simply omit the benefit.
enum WorkbenchUpdateSummary {
    static func text(from description: String?, format: String?) -> String? {
        guard let description, description.utf8.count <= 64_000 else { return nil }
        if format == "plain-text" || format == "markdown" {
            return compact(description.components(separatedBy: "\n\n").first ?? "")
        }
        let parser = XMLParser(data: Data(("<release>" + description + "</release>").utf8))
        let paragraph = Paragraph()
        parser.delegate = paragraph
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return paragraph.completed ? compact(paragraph.text) : nil
    }
    private static func compact(_ text: String) -> String? {
        let text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > 200 ? String(text.prefix(197)) + "…" : text
    }
    private final class Paragraph: NSObject, XMLParserDelegate {
        var text = "", depth = 0, ignored = 0, completed = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            guard !completed else { return }
            if depth > 0 {
                depth += 1
                if ignored > 0 || ["script", "style"].contains(elementName.lowercased()) { ignored += 1 }
            } else if elementName.lowercased() == "p" { depth = 1 }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if depth > 0 && ignored == 0 { text += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard depth > 0 else { return }
            depth -= 1
            if ignored > 0 { ignored -= 1 }
            if depth == 0 { completed = true }
        }
    }
}
