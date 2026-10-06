import Foundation

// Report a problem (#296), transport v2: one Sentry envelope per report attempt, sent straight
// to the team's private Sentry project with the public client key (no SDK). Checked against
// Sentry's developer documentation on 7 October 2026: Envelopes (header/item grammar, `dsn`
// and `sent_at` headers, the `/api/<project>/envelope/` endpoint and X-Sentry-Auth), Feedback
// 1.5.0 (a `feedback` item holding an event with `contexts.feedback`, attachments in the same
// envelope, the 8,192-byte feedback context budget) and Attachments 1.7.0 (`attachment` items
// with `length`, `filename`, `content_type`, `attachment_type`), and Rate Limiting
// (X-Sentry-Rate-Limits on any status, the `feedback` category, empty categories meaning all).

/// Where a report goes: the edition's Sentry DSN and optional delivery verifier, frozen with each
/// report so a later configuration change never sends it somewhere else.
struct BugReportDestination: Codable, Equatable {
    var dsn: String
    var verifier: String?
    /// `production` for the Stable release configuration; `preview` for the developer override.
    var environment: String
    var isOverride: Bool
}

/// The edition's reporting configuration. Only the Stable release's Info.plist carries a DSN
/// (stamped by scripts/release/build_info.py from scripts/release/reporting.json). Preview and
/// local builds have none unless a developer sets the override, which those builds alone honour:
///
///     defaults write com.ethdawg.workbench.preview WorkbenchReportDSNOverride 'https://KEY@HOST/PROJECT'
///     defaults write com.ethdawg.workbench.preview WorkbenchReportVerifierOverride 'http://127.0.0.1:8787'
///
/// or the same keys as launch arguments (`-WorkbenchReportDSNOverride …`). Override reports carry
/// the `preview` environment, so they never mix with production triage.
enum BugReportConfiguration {
    static let dsnKey = "WorkbenchReportDSN"
    static let verifierKey = "WorkbenchReportVerifierURL"
    static let dsnOverrideKey = "WorkbenchReportDSNOverride"
    static let verifierOverrideKey = "WorkbenchReportVerifierOverride"

    static func destination(build: WorkbenchBuild = WorkbenchBuild(), defaults: UserDefaults = .standard) -> BugReportDestination? {
        if build.preview || !build.released, let raw = defaults.string(forKey: dsnOverrideKey),
           BugReportDSN(raw, allowLoopbackHTTP: true) != nil {
            let verifier = defaults.string(forKey: verifierOverrideKey).flatMap { verifierURL($0, allowLoopbackHTTP: true) }
            return BugReportDestination(dsn: raw.trimmingCharacters(in: .whitespacesAndNewlines), verifier: verifier?.absoluteString,
                                        environment: "preview", isOverride: true)
        }
        guard !build.preview, let raw = build.info[dsnKey] as? String, BugReportDSN(raw, allowLoopbackHTTP: false) != nil else { return nil }
        let verifier = (build.info[verifierKey] as? String).flatMap { verifierURL($0, allowLoopbackHTTP: false) }
        return BugReportDestination(dsn: raw, verifier: verifier?.absoluteString, environment: "production", isOverride: false)
    }

    /// HTTPS, or plain HTTP to this Mac for a developer's local verifier. No credentials, query or fragment.
    static func verifierURL(_ raw: String, allowLoopbackHTTP: Bool) -> URL? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              scheme == "https" || (allowLoopbackHTTP && scheme == "http" && BugReportDSN.isLoopback(host)),
              let url = components.url else { return nil }
        return url
    }
}

/// A Sentry DSN: `https://PUBLIC_KEY@HOST[:PORT][/PATH]/PROJECT_ID`.
struct BugReportDSN: Equatable {
    let raw: String
    let publicKey: String
    let projectID: String
    let envelopeURL: URL

    init?(_ text: String, allowLoopbackHTTP: Bool) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, let key = components.user, !key.isEmpty,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), components.query == nil, components.fragment == nil,
              scheme == "https" || (allowLoopbackHTTP && scheme == "http" && Self.isLoopback(host)) else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        guard let project = parts.popLast(), !project.isEmpty, project.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        var endpoint = URLComponents()
        endpoint.scheme = scheme; endpoint.host = host; endpoint.port = components.port
        endpoint.path = "/" + (parts + ["api", project, "envelope"]).joined(separator: "/") + "/"
        guard let url = endpoint.url else { return nil }
        self.raw = raw; publicKey = key; projectID = project; envelopeURL = url
    }

    static func isLoopback(_ host: String) -> Bool { ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()) }

    func authorization(client: String) -> String {
        "Sentry sentry_version=7, sentry_key=\(publicKey), sentry_client=\(client)"
    }
}

struct BugReportEnvelopeItem {
    var header: [String: Any]
    var payload: Data
    var type: String? { header["type"] as? String }
    var filename: String? { header["filename"] as? String }
}

enum BugReportEnvelope {
    static let feedbackSource = "workbench-mac"

    /// A random UUIDv4 as 32 lowercase hexadecimal characters, the form Sentry recommends.
    static func newEventID() -> String { UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
    static func isEventID(_ text: String) -> Bool { text.range(of: "^[a-f0-9]{12}4[a-f0-9]{3}[89ab][a-f0-9]{15}$", options: .regularExpression) != nil }

    /// The envelope frozen in the outbox before any network. Its header holds `dsn` and
    /// `event_id`; `sent_at` is added only when it is actually sent, as Sentry asks of SDKs that
    /// store envelopes, so every item byte stays identical on every retry.
    static func frozen(manifest: Data, screenshot: Data?, voice: Data?, eventID: String,
                       destination: BugReportDestination, timestamp: Date) throws -> Data {
        guard isEventID(eventID) else { throw BugReportError.message("The report's event ID is not valid.") }
        guard let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any] else {
            throw BugReportError.message("The report's details could not be read.")
        }
        let event = try feedbackEvent(manifest: object, eventID: eventID, destination: destination, timestamp: timestamp,
                                      screenshot: screenshot != nil, voice: voice != nil)
        let eventData = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
        // The feedback item's compact JSON has no newline, so its length is implicit, as in
        // Sentry's own feedback example and the live probe of 7 October 2026.
        var items = [BugReportEnvelopeItem(header: ["type": "feedback"], payload: eventData),
                     attachment("context.json", contentType: "application/json", manifest)]
        if let screenshot { items.append(attachment(BugReportAttachment.screenshot, contentType: "image/png", screenshot)) }
        if let voice { items.append(attachment(BugReportAttachment.voice, contentType: "audio/wav", voice)) }
        let total = items.reduce(0) { $0 + $1.payload.count }
        guard total <= BugReportLimits.payloadBytes + BugReportLimits.manifestBytes + 64 * 1_024 else {
            throw BugReportError.message("This report is too large to send. Remove the voice note or choose a smaller image.")
        }
        return try serialize(header: ["dsn": destination.dsn, "event_id": eventID], items: items)
    }

    static func attachment(_ name: String, contentType: String, _ data: Data) -> BugReportEnvelopeItem {
        BugReportEnvelopeItem(header: ["type": "attachment", "length": data.count, "filename": name,
                                       "content_type": contentType, "attachment_type": "event.attachment"], payload: data)
    }

    /// The bytes sent: the frozen envelope with `sent_at` added to its header line. Everything
    /// after the first newline is the frozen bytes, unchanged.
    static func transmission(_ frozen: Data, sentAt: Date) throws -> Data {
        guard let newline = frozen.firstIndex(of: 0x0A),
              var header = try JSONSerialization.jsonObject(with: frozen[frozen.startIndex..<newline]) as? [String: Any] else {
            throw BugReportError.message("The saved report could not be read.")
        }
        header["sent_at"] = BugReportText.preciseTimestamp(sentAt)
        return try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes]) + frozen[newline...]
    }

    static func serialize(header: [String: Any], items: [BugReportEnvelopeItem]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
        for item in items {
            data.append(0x0A)
            data.append(try JSONSerialization.data(withJSONObject: item.header, options: [.sortedKeys, .withoutEscapingSlashes]))
            data.append(0x0A)
            data.append(item.payload)
        }
        data.append(0x0A)
        return data
    }

    /// Reads an envelope: a declared length, or else the payload runs to the next newline.
    static func parse(_ data: Data) throws -> (header: [String: Any], items: [BugReportEnvelopeItem]) {
        let malformed = BugReportError.message("The saved report could not be read.")
        let bytes = [UInt8](data)
        func line(from start: Int) throws -> (Data, Int) {
            guard let end = bytes[start...].firstIndex(of: 0x0A) else { throw malformed }
            return (Data(bytes[start..<end]), end + 1)
        }
        let (headerData, afterHeader) = try line(from: 0)
        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else { throw malformed }
        var items: [BugReportEnvelopeItem] = []
        var offset = afterHeader
        while offset < bytes.count {
            let (itemHeaderData, payloadStart) = try line(from: offset)
            guard let itemHeader = try JSONSerialization.jsonObject(with: itemHeaderData) as? [String: Any] else { throw malformed }
            let length: Int
            if let declared = itemHeader["length"] {
                guard let declared = declared as? Int, declared >= 0, payloadStart + declared <= bytes.count else { throw malformed }
                length = declared
            } else {
                length = (bytes[payloadStart...].firstIndex(of: 0x0A) ?? bytes.count) - payloadStart
            }
            items.append(BugReportEnvelopeItem(header: itemHeader, payload: Data(bytes[payloadStart..<payloadStart + length])))
            offset = payloadStart + length
            if offset < bytes.count {
                guard bytes[offset] == 0x0A else { throw malformed }
                offset += 1
            }
        }
        return (header, items)
    }

    /// The feedback event, built only from the frozen manifest: the reviewed words (or a fixed
    /// placeholder when there are none), the optional reply address, and the manifest's safe build,
    /// OS and tool facts. No user, IP, device name, server name, breadcrumbs or stack.
    static func feedbackEvent(manifest: [String: Any], eventID: String, destination: BugReportDestination,
                              timestamp: Date, screenshot: Bool, voice: Bool) throws -> [String: Any] {
        guard let reportID = manifest["report_id"] as? String, let explanation = manifest["explanation"] as? String,
              let build = manifest["build"] as? [String: Any], let context = manifest["context"] as? [String: Any] else {
            throw BugReportError.message("The report's details could not be read.")
        }
        func value(_ key: String) -> String { (build[key] as? String).map { BugReportText.safe($0, limit: 64) } ?? "unknown" }
        let message: String
        if BugReportText.hasVisibleText(explanation) { message = explanation }
        else if screenshot && voice { message = "Screenshot and voice note attached" }
        else if screenshot { message = "Screenshot attached" }
        else if voice { message = "Voice note attached" }
        else { throw BugReportError.message("Describe the problem, or add a screenshot or voice note.") }
        var feedback: [String: Any] = ["message": message, "source": feedbackSource]
        if let email = manifest["reply_email"] as? String, !email.isEmpty { feedback["contact_email"] = email }
        let feedbackBytes = try JSONSerialization.data(withJSONObject: feedback, options: [.sortedKeys, .withoutEscapingSlashes]).count
        guard feedbackBytes <= BugReportLimits.feedbackContextBytes else {
            throw BugReportError.message("Shorten your description so the team receives all of it.")
        }
        let version = value("version"), number = value("build")
        let release = "workbench@\(version)+\(number)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        let tool = context["surface"] as? String ?? "unknown"
        var workbench: [String: Any] = ["report_id": reportID, "edition": value("edition"), "revision": value("revision"),
                                        "kind": value("kind"), "dirty": build["dirty"] ?? NSNull(), "surface": tool]
        if let code = context["error_code"] as? String { workbench["error_code"] = code }
        let attached = [screenshot ? "screenshot" : nil, voice ? "voice note" : nil].compactMap { $0 }
        workbench["attachments"] = attached.isEmpty ? "none" : attached.joined(separator: ", ")
        return [
            "event_id": eventID, "timestamp": (timestamp.timeIntervalSince1970 * 1_000).rounded() / 1_000,
            "platform": "other", "level": "info", "type": "feedback",
            "environment": destination.environment, "release": String(release.prefix(200)), "dist": number,
            "tags": ["report_id": reportID, "edition": value("edition"), "tool": tool, "schema": "1", "build": number],
            "contexts": ["feedback": feedback,
                         "os": ["name": "macOS", "version": value("os_version"), "build": value("os_build")],
                         "app": ["app_name": "Workbench", "app_version": version, "app_build": number, "build_type": value("kind")],
                         "workbench": workbench],
            "sdk": ["name": feedbackSource, "version": version]]
    }

    /// What the verifier compares with the attachments Sentry stored.
    static func verifierAttachments(_ items: [BugReportEnvelopeItem]) -> [[String: Any]] {
        items.filter { $0.type == "attachment" }.compactMap { item in
            item.filename.map { ["name": $0, "size": item.payload.count, "sha256": BugReportText.sha256(item.payload)] }
        }
    }

    // MARK: Rate limits

    /// Seconds before feedback or its attachments may be sent again, from X-Sentry-Rate-Limits
    /// (any status) or, on 429, Retry-After. Nil when nothing limits this report.
    static func rateLimit(status: Int, rateLimits: String?, retryAfter: String?, now: Date) -> TimeInterval? {
        var longest: TimeInterval?
        for quota in (rateLimits ?? "").split(separator: ",") {
            let fields = quota.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
            guard let first = fields.first, let seconds = Double(first.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0 else { continue }
            let categories = fields.count > 1 ? fields[1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } : []
            guard categories.isEmpty || categories.contains("feedback") || categories.contains("attachment") else { continue }
            longest = max(longest ?? 0, seconds)
        }
        if let longest { return min(86_400, max(1, longest)) }
        guard status == 429 else { return nil }
        if let retryAfter = retryAfter?.trimmingCharacters(in: .whitespaces) {
            if let seconds = Double(retryAfter), seconds.isFinite { return min(86_400, max(1, seconds)) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: retryAfter) { return min(86_400, max(1, date.timeIntervalSince(now))) }
        }
        return 60
    }
}
