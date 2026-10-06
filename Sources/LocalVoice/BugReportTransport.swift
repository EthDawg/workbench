import Foundation
import Network

// Report a problem (#296): delivery of frozen reports to Sentry and, when configured, the
// delivery verifier. State lives in each report's delivery.json, so a relaunch resumes the same
// report, event ID and bytes. Nothing here blocks Quit or an update: an interrupted request is
// simply tried again later.
//
//   waiting / sending  --POST envelope, 200 without a feedback or attachment limit-->  sent
//   sent  --verifier: received-->  received   (local copy dropped, receipt kept)
//   sent  --verifier: mismatch or not_found-->  unconfirmed  (Send again: new event ID, only when chosen)
//   sent  --pending, any other status, no answer-->  stays sent, never downgraded; checked for about
//          16 minutes after Sent, then once more at the next launch
//   400, 401, 403, 404, 413, TLS  -->  failed  (Retry is the person's choice; no loop)

@MainActor
final class BugReportTransport: ObservableObject {
    @Published private(set) var deliveries: [BugReportDelivery] = []
    /// Reports with a request in flight now. The surface gallery sets it to draw Sending….
    @Published var active: Set<String> = []
    let store: BugReportStore
    let session: URLSession
    /// `workbench-mac/<version>`, sent as the Sentry client.
    let client: String
    var now: () -> Date
    var random: () -> Double
    /// The verifier answers pending for 900 s of elapsed time; checks continue a little past it.
    static let verifyWindow: TimeInterval = 16 * 60
    static let firstCheck: TimeInterval = 15
    /// Verifier checks back off to at most five minutes apart.
    static let verifyBackoffCap: TimeInterval = 300
    /// Sentry filters a repeated event ID for about an hour, so the same event ID is never sent
    /// again by itself once an attempt that may have arrived is older than this.
    static let sameEventLimit: TimeInterval = 55 * 60
    nonisolated static let uploadLimit: TimeInterval = 30 * 60
    private var wake: Task<Void, Never>?
    private var running = false
    private var monitor: NWPathMonitor?
    private var online = true

    init(store: BugReportStore, session: URLSession = BugReportTransport.session(), client: String,
         now: @escaping () -> Date = Date.init, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.store = store; self.session = session; self.client = client; self.now = now; self.random = random
        deliveries = store.deliveries()
    }

    /// An ephemeral session: no cookies, cache or credentials, and no waiting for a network.
    nonisolated static func session(protocols: [AnyClass] = []) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        // A request may idle for a minute; a whole upload of up to 16 MiB on a slow uplink may take 30.
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = Self.uploadLimit
        if !protocols.isEmpty { configuration.protocolClasses = protocols + (configuration.protocolClasses ?? []) }
        return URLSession(configuration: configuration)
    }

    /// Resumes every report at its saved time and keeps them moving while the app runs.
    func start(watchConnectivity: Bool = true) {
        guard !running else { return }
        running = true
        store.prune()
        // One more check at launch for reports whose window ended without an answer.
        for var delivery in store.deliveries() where delivery.state == .sent && delivery.verifyAtLaunch {
            delivery.verifyAtLaunch = false; delivery.launchCheckUsed = true
            delivery.nextAttemptAt = now()
            try? store.save(delivery)
        }
        reload()
        if watchConnectivity {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let satisfied = path.status == .satisfied
                Task { @MainActor in self?.connectivity(satisfied) }
            }
            monitor.start(queue: DispatchQueue(label: "Workbench.BugReportNetwork", qos: .utility))
            self.monitor = monitor
        }
        kick()
    }

    func stop() {
        running = false; wake?.cancel(); wake = nil
        monitor?.cancel(); monitor = nil
    }

    func reload() { deliveries = store.deliveries() }

    /// A report waiting for a connection goes, and a Sent report is checked, as soon as one returns.
    func connectivity(_ satisfied: Bool) {
        defer { online = satisfied }
        guard satisfied, !online else { return }
        for var delivery in store.deliveries() where delivery.state == .waiting
            || (delivery.state == .sent && delivery.destination.verifier != nil && (delivery.nextAttemptAt != nil || delivery.verifyAtLaunch)) {
            delivery.nextAttemptAt = now()
            try? store.save(delivery)
        }
        kick()
    }

    func kick() {
        reload()
        guard running else { return }
        Task { await runDue(); scheduleWake() }
    }

    private func scheduleWake() {
        wake?.cancel(); wake = nil
        guard running, let next = store.deliveries().filter(isScheduled).compactMap(\.nextAttemptAt).min() else { return }
        let delay = max(0.5, next.timeIntervalSince(now()))
        wake = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 3_600) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.runDue()
            self.scheduleWake()
        }
    }

    private func isScheduled(_ delivery: BugReportDelivery) -> Bool {
        guard delivery.nextAttemptAt != nil else { return false }
        return [.waiting, .sending].contains(delivery.state) || (delivery.state == .sent && delivery.destination.verifier != nil)
    }

    /// Every report whose time has come, one request each, oldest due first.
    func runDue() async {
        let due = store.deliveries().filter { isScheduled($0) && ($0.nextAttemptAt ?? .distantFuture) <= now() }
            .sorted { ($0.nextAttemptAt ?? .distantPast) < ($1.nextAttemptAt ?? .distantPast) }
        for delivery in due { await attempt(delivery.id) }
        reload()
    }

    func attempt(_ id: String) async {
        guard !active.contains(id), let delivery = store.delivery(id) else { return }
        active.insert(id)
        defer { active.remove(id); reload() }
        switch delivery.state {
        case .waiting, .sending: await send(delivery)
        case .sent: await verify(delivery)
        case .received, .unconfirmed, .failed: break
        }
    }

    // MARK: Commands

    /// A frozen report joined the outbox.
    func added() { kick() }

    /// Retry: the same bytes and event ID, now, with the attempt count reset.
    func retry(_ id: String) {
        guard var delivery = store.delivery(id), [.failed, .waiting, .sending].contains(delivery.state) else { return }
        delivery.state = .waiting; delivery.problem = nil; delivery.status = nil
        delivery.attempts = 0; delivery.nextAttemptAt = now()
        try? store.save(delivery)
        kick()
    }

    /// Send again after an unconfirmed delivery: the same report and files under a new event ID,
    /// only when the person asks.
    func sendAgain(_ id: String) throws {
        guard var delivery = store.delivery(id), delivery.state == .unconfirmed else { return }
        let items = try BugReportEnvelope.parse(try store.envelope(id)).items
        func payload(_ name: String) -> Data? { items.first { $0.type == "attachment" && $0.filename == name }?.payload }
        guard let manifest = payload("context.json") else { throw BugReportError.message("The saved report could not be read.") }
        let eventID = BugReportEnvelope.newEventID()
        let envelope = try BugReportEnvelope.frozen(manifest: manifest, screenshot: payload(BugReportAttachment.screenshot),
            voice: payload(BugReportAttachment.voice), eventID: eventID, destination: delivery.destination, timestamp: now())
        delivery.previousEventIDs.append(delivery.eventID)
        delivery.eventID = eventID
        delivery.envelopeSHA256 = BugReportText.sha256(envelope); delivery.envelopeBytes = envelope.count
        delivery.files = BugReportEnvelope.verifierFiles(try BugReportEnvelope.parse(envelope).items)
        delivery.mayHaveArrivedAt = nil
        delivery.state = .waiting; delivery.problem = nil; delivery.status = nil
        delivery.attempts = 0; delivery.nextAttemptAt = now(); delivery.sentAt = nil
        delivery.verifyAttempts = 0; delivery.verifyUntil = nil; delivery.verifierState = nil
        delivery.verifyAtLaunch = false; delivery.launchCheckUsed = false
        try store.replaceEnvelope(id, with: envelope, delivery: delivery)
        kick()
    }

    /// Remove from this Mac. A request already in flight may still arrive; its result is ignored.
    func remove(_ id: String) throws {
        try store.remove(id)
        reload()
    }

    /// 5 seconds, doubling to 15 minutes (or a lower cap), with jitter over the upper half.
    static func backoff(_ attempt: Int, random: Double, cap: TimeInterval = 900) -> TimeInterval {
        let base = min(cap, 5 * pow(2, Double(max(0, attempt - 1))))
        return min(cap, max(5, base / 2 + base / 2 * min(max(random, 0), 1)))
    }

    // MARK: Sentry

    private func send(_ delivery: BugReportDelivery) async {
        var sending = delivery
        // Past Sentry's one-hour duplicate filter, an attempt that may have arrived makes another
        // send of the same event ID a possible second report: only the person's Send again may go on.
        if let arrived = sending.mayHaveArrivedAt, now().timeIntervalSince(arrived) > Self.sameEventLimit {
            sending.state = .unconfirmed; sending.problem = .uncertain; sending.nextAttemptAt = nil
            try? store.save(sending); return
        }
        guard let dsn = BugReportDSN(sending.destination.dsn, allowLoopbackHTTP: sending.destination.isOverride) else {
            sending.state = .failed; sending.problem = .rejected; sending.nextAttemptAt = nil
            try? store.save(sending); return
        }
        let body: Data
        do {
            let frozen = try store.envelope(sending.id)
            guard BugReportText.sha256(frozen) == sending.envelopeSHA256 else { throw BugReportError.message("changed") }
            body = try BugReportEnvelope.transmission(frozen, sentAt: now())
        } catch {
            // Never send changed bytes under the same report and event ID.
            sending.state = .failed; sending.problem = .unreadable; sending.nextAttemptAt = nil
            try? store.save(sending); return
        }
        var request = URLRequest(url: dsn.envelopeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue(dsn.authorization(client: client), forHTTPHeaderField: "X-Sentry-Auth")
        request.httpBody = body
        let started = now()
        let outcome = await perform(request)
        // A report removed, or sent again, while this request was in flight keeps its newer state.
        guard var current = store.delivery(sending.id), current.eventID == sending.eventID, [.waiting, .sending].contains(current.state) else { return }
        current.attempts += 1
        let time = now()
        switch outcome {
        case .response(let response, _):
            let status = response.statusCode
            let limit = BugReportEnvelope.rateLimit(status: status, rateLimits: response.value(forHTTPHeaderField: "X-Sentry-Rate-Limits"),
                                                    retryAfter: response.value(forHTTPHeaderField: "Retry-After"), now: time)
            current.status = status
            switch status {
            case 200..<300 where limit == nil || limit?.attachmentsOnly == true:
                // Sent. With only attachments limited, the verifier decides whether the files arrived.
                current.state = .sent; current.problem = nil; current.status = nil; current.sentAt = time
                current.verifyAtLaunch = false; current.launchCheckUsed = false
                if current.destination.verifier != nil {
                    current.verifyUntil = time.addingTimeInterval(Self.verifyWindow); current.verifyAttempts = 0
                    // Sentry takes roughly 10 to 40 seconds to store an event and its attachments.
                    current.nextAttemptAt = time.addingTimeInterval(Self.firstCheck)
                } else { current.nextAttemptAt = nil }
            case 200..<300, 429:
                // Refused for now, before Sentry kept anything: the same event ID may go again later.
                current.state = .sending; current.problem = .rateLimited
                current.nextAttemptAt = time.addingTimeInterval(limit?.wait ?? 60)
            case 413:
                current.state = .failed; current.problem = .tooLarge; current.nextAttemptAt = nil
            case 401, 403, 404:
                current.state = .failed; current.problem = .unauthorized; current.nextAttemptAt = nil
            case 408, 500..<600:
                current.state = .sending; current.problem = .busy
                current.mayHaveArrivedAt = current.mayHaveArrivedAt ?? started
                current.nextAttemptAt = time.addingTimeInterval(Self.backoff(current.attempts, random: random()))
            default:
                current.state = .failed; current.problem = .rejected; current.nextAttemptAt = nil
            }
        case .failure(let error):
            current.status = nil
            if Self.secureFailures.contains(error.code) {
                current.state = .failed; current.problem = .secureConnection; current.nextAttemptAt = nil
            } else if Self.neverConnected.contains(error.code) {
                // Nothing reached Sentry, so waiting for a connection keeps the same event ID safe.
                current.state = .waiting; current.problem = .offline
                current.nextAttemptAt = time.addingTimeInterval(Self.backoff(current.attempts, random: random()))
            } else {
                // A lost reply or a time-out mid-upload: it may have arrived. Try again with backoff.
                current.state = .sending; current.problem = .busy
                current.mayHaveArrivedAt = current.mayHaveArrivedAt ?? started
                current.nextAttemptAt = time.addingTimeInterval(Self.backoff(current.attempts, random: random()))
            }
        }
        try? store.save(current)
    }

    // MARK: Verifier

    /// The verifier's endpoint: a configured URL that already ends in /api/v1/verify is used as
    /// is; a bare origin gets that path.
    static func verifyEndpoint(_ url: URL) -> URL {
        url.path.hasSuffix("/api/v1/verify") ? url : url.appendingPathComponent("api/v1/verify")
    }

    private func verify(_ delivery: BugReportDelivery) async {
        guard let verifier = delivery.destination.verifier.flatMap({ BugReportConfiguration.verifierURL($0, allowLoopbackHTTP: delivery.destination.isOverride) }),
              let until = delivery.verifyUntil, let sentAt = delivery.sentAt else {
            var stopped = delivery; stopped.nextAttemptAt = nil; try? store.save(stopped); return
        }
        guard !delivery.files.isEmpty else {
            // A delivery without its file list is this Mac's own fault; asking would only earn a 422.
            var stopped = delivery
            stopped.nextAttemptAt = nil; stopped.verifyAtLaunch = false; stopped.verifierState = "local_error_no_files"
            try? store.save(stopped); return
        }
        var request = URLRequest(url: Self.verifyEndpoint(verifier))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Seconds since this Mac received Sentry's 200 for this event ID, by this Mac's own clock at
        // both ends, so a wrong clock cancels out. A clock that moved backwards counts as 0.
        let elapsed = max(0, Int(now().timeIntervalSince(sentAt).rounded(.down)))
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["event_id": delivery.eventID, "report_id": delivery.id,
                                                                        "attachments": delivery.files.map(\.object), "elapsed_seconds": elapsed],
                                                       options: [.sortedKeys, .withoutEscapingSlashes])
        let outcome = await perform(request)
        guard var current = store.delivery(delivery.id), current.eventID == delivery.eventID, current.state == .sent else { return }
        let time = now()
        var answer: String?
        var wait: TimeInterval?
        var answered = false
        current.verifyAttempts += 1
        if case .response(let response, let data) = outcome {
            answered = true
            if response.statusCode == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let state = object["state"] as? String, ["received", "pending", "mismatch", "not_found"].contains(state) {
                answer = state
            } else {
                wait = BugReportEnvelope.retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After"), now: time)
            }
        }
        if let answer { current.verifierState = answer }
        switch answer {
        case "received":
            current.state = .received; current.receivedAt = time
            current.nextAttemptAt = nil; current.problem = nil; current.verifyAtLaunch = false
            try? store.save(current)
            store.removeEvidence(current.id)
            return
        case "mismatch", "not_found":
            // The verifier answers pending while Sentry may still be storing the event, so these are its findings.
            current.state = .unconfirmed
            current.problem = answer == "mismatch" ? .mismatch : .notFound
            current.nextAttemptAt = nil; current.verifyAtLaunch = false
        default:
            // Pending, any other status or no answer: Sent stays, and checking continues. Only an
            // HTTP answer counts against the window, so a lost network never ends checking.
            if time < until || !answered {
                let next = time.addingTimeInterval(wait ?? Self.backoff(current.verifyAttempts, random: random(), cap: Self.verifyBackoffCap))
                current.nextAttemptAt = time < until ? min(until, next) : next
            } else {
                current.nextAttemptAt = nil
                // One more check at the next launch, unless this was it.
                current.verifyAtLaunch = !current.launchCheckUsed
            }
        }
        try? store.save(current)
    }

    // MARK: HTTP

    enum Outcome {
        case response(HTTPURLResponse, Data)
        case failure(URLError)
    }

    private func perform(_ request: URLRequest) async -> Outcome {
        do {
            let (data, response) = try await session.data(for: request, delegate: BugReportNoRedirects())
            guard let http = response as? HTTPURLResponse else { return .failure(URLError(.badServerResponse)) }
            return .response(http, data)
        } catch let error as URLError {
            return .failure(error)
        } catch {
            return .failure(URLError(.unknown))
        }
    }

    /// Failures before any connection: nothing can have reached Sentry.
    static let neverConnected: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive]

    /// Certificate and TLS failures are not retried automatically.
    static let secureFailures: Set<URLError.Code> = [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired, .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection]
}

/// Report requests never follow a redirect.
final class BugReportNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
