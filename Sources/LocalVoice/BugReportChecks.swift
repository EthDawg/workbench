import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `LocalVoice --check-bug-report [docs/bug-reporting-schema.md]` (#296): the manifest against the
/// shared JSON Schema and its fixtures, media limits, the Sentry envelope's exact shape, the
/// outbox and delivery against stubbed Sentry and verifier servers, the per-edition configuration,
/// draft resume and Save a copy. Everything runs in a new temporary folder with a URLProtocol
/// stub: no network, Keychain, microphone, screen capture or window.
enum BugReportChecks {
    static let dsn = "https://0123456789abcdef0123456789abcdef@o1.ingest.example.test/42"
    static let verifier = "https://verify.example.test"

    @MainActor static func run(schemaDocument: URL?) async throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-bug-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root); BugReportStub.reset() }
        var lines: [String] = []
        lines += try schemaChecks(document: schemaDocument)
        lines += try mediaChecks()
        lines += try configurationChecks(root: root)
        lines += try await envelopeChecks(root: root.appendingPathComponent("envelope"))
        lines += try await transportChecks(root: root.appendingPathComponent("transport"))
        lines += try await verifierChecks(root: root.appendingPathComponent("verifier"))
        lines += try await outboxChecks(root: root.appendingPathComponent("outbox"))
        lines.append("BUG_REPORT_CHECK_OK: \(lines.count) groups")
        return lines
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw VoiceError.message("Report a problem check failed: \(message)") }
    }
    static func expectValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw VoiceError.message("Report a problem check failed: \(message)") }
        return value
    }

    // MARK: Fixtures

    final class Clock { var now = Date(timeIntervalSince1970: 1_791_349_200); func advance(_ seconds: TimeInterval) { now += seconds } }

    struct Harness {
        let clock: Clock
        let store: BugReportStore
        let transport: BugReportTransport
        let model: BugReportModel
    }

    @MainActor static func harness(_ root: URL, clock: Clock = Clock(), destination: BugReportDestination? = .init(dsn: dsn, verifier: nil, environment: "production", isOverride: false),
                                    limits: BugReportStore.Limits = .init(), capacity: Int64? = nil, folder: URL? = nil) -> Harness {
        let store = BugReportStore(root: root, limits: limits, now: { clock.now }, availableCapacity: { capacity })
        let transport = BugReportTransport(store: store, session: BugReportTransport.session(protocols: [BugReportStub.self]),
                                           client: "workbench-mac/2.5.0", now: { clock.now }, random: { 0.5 })
        var services = BugReportModel.Services()
        services.build = { build }
        services.now = { clock.now }
        services.announce = { _ in }
        services.chooseFolder = { folder }
        let model = BugReportModel(store: store, transport: transport, destination: destination, services: services)
        return Harness(clock: clock, store: store, transport: transport, model: model)
    }

    static let build = BugReportBuild(edition: "stable", version: "2.5.0", build: "20261007010203", revision: String(repeating: "a", count: 40),
                                      dirty: false, kind: "release", osVersion: "15.5.0", osBuild: "24F74")

    static func syntheticPNG(width: Int = 64, height: Int = 40) throws -> BugReportImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 4, y: 4, width: width / 2, height: height / 3))
        return try BugReportMedia.image(try BugReportMedia.encodePNG(context.makeImage()!), scale: 2, sourceLimit: BugReportLimits.importBytes)
    }

    /// A draft with words, email, screenshot and voice, then frozen by Send.
    @MainActor static func fill(_ model: BugReportModel, text: String = "The Snap window disappeared before I could show the problem.",
                                email: String = "reporter@example.com", screenshot: Bool = true, voice: Bool = true) throws {
        model.open(origin: BugReportOrigin(surface: .snap, errorCode: "snap.capture_failed"))
        model.explanation = text
        model.replyEmail = email
        if screenshot { try model.setScreenshot(try syntheticPNG()) }
        if voice { try model.setVoice(BugReportMedia.syntheticWAV(seconds: 1.5)) }
        model.persist()
    }

    // MARK: Schema

    static func schemaChecks(document: URL?) throws -> [String] {
        let schemaText: String
        let fixtureText: String
        if let document {
            repository = document.deletingLastPathComponent().deletingLastPathComponent()
            let blocks = try String(contentsOf: document, encoding: .utf8).components(separatedBy: "```json").dropFirst()
                .compactMap { $0.components(separatedBy: "```").first }
            try expect(blocks.count >= 2, "the schema document has a schema and a synthetic input")
            schemaText = blocks[0]; fixtureText = blocks[1]
        } else {
            throw VoiceError.message("Pass docs/bug-reporting-schema.md: the manifest is checked against the shared schema, never a copy.")
        }
        guard let schema = try JSONSerialization.jsonObject(with: Data(schemaText.utf8)) as? [String: Any] else { throw VoiceError.message("Schema is not an object") }
        let validator = BugReportSchemaValidator(schema: schema)
        let fixture = try JSONSerialization.jsonObject(with: Data(fixtureText.utf8))
        try expect(validator.errors(fixture).isEmpty, "the synthetic input is valid: \(validator.errors(fixture))")

        // What this app produces: text only, screenshot only, voice only and everything.
        let png = try syntheticPNG(), wav = BugReportMedia.syntheticWAV(seconds: 2)
        let full = BugReportContext(surface: .dictate, activeTools: [.dictate, .draw, .timer], microphone: .authorized, screenCapture: .unknown,
                                    accessibility: .notRequested, recognitionProvider: .parakeet, recognitionReady: nil, errorCode: "dictate.failed")
        func manifest(_ text: String, email: String? = nil, shot: Bool = false, voice: Bool = false, context: BugReportContext = BugReportContext()) -> BugReportManifest {
            BugReportManifest(reportID: BugReportManifest.newReportID(), createdAt: Date(timeIntervalSince1970: 1_791_349_200), explanation: text,
                              replyEmail: email, build: build, context: context, screenshot: shot ? png.info : nil,
                              attachments: [shot ? BugReportAttachment(name: BugReportAttachment.screenshot, data: png.png) : nil,
                                            voice ? BugReportAttachment(name: BugReportAttachment.voice, data: wav) : nil].compactMap { $0 })
        }
        let produced = [manifest("Text only."), manifest(" \n", shot: true), manifest("", voice: true),
                        manifest("Everything — with “quotes”, emoji 🙂 and a / slash.", email: "a.b+c@example.co.uk", shot: true, voice: true, context: full),
                        manifest(String(repeating: "x", count: 2_048)), manifest(String(repeating: "é", count: 2_048))]
        var valid: [[String: Any]] = []
        for item in produced {
            let data = try item.encoded()
            try expect(data.count <= BugReportLimits.manifestBytes, "manifest fits 32 KiB")
            try expect(BugReportJSON.duplicateKeys(data) == false, "no duplicate keys")
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try expect(validator.errors(object).isEmpty, "produced manifest is valid: \(validator.errors(object))")
            try expect(try item.encoded() == data, "encoding the same manifest is byte-identical")
            valid.append(object)
        }
        try expect((valid[3]["context"] as? [String: Any])?["screenshot"] != nil && (valid[0]["context"] as? [String: Any])?.isEmpty == true,
                   "screenshot context appears only with screenshot.png")

        // Refusals made before anything is frozen.
        for (text, why) in [("", "blank text with no attachment"), (" \t\n\u{3000}\u{1C}", "whitespace-only text with no attachment"),
                            (String(repeating: "x", count: 2_049), "2,049 characters"), (String(repeating: "🙂", count: 1_100), "over 4,096 UTF-8 bytes"),
                            (String(repeating: "e\u{301}", count: 1_025), "2,050 code points of decomposed text")] {
            try expect((try? manifest(text).encoded()) == nil, "refuses \(why)")
        }
        try expect((try? manifest("ok", email: "not an email").encoded()) == nil, "refuses an invalid email")
        try expect((try? manifest("ok", email: String(repeating: "a", count: 250) + "@x.io").encoded()) == nil, "refuses an email over 254 bytes")
        try expect(BugReportText.explanationProblem(String(repeating: "x", count: 2_048)) == nil, "exactly 2,048 characters is allowed")

        // The shared negative vectors, applied to a valid produced manifest.
        let base = valid[3]
        func mutated(_ change: (inout [String: Any]) -> Void) -> [String: Any] { var copy = base; change(&copy); return copy }
        func nested(_ key: String, _ change: @escaping (inout [String: Any]) -> Void) -> [String: Any] {
            mutated { var inner = $0[key] as! [String: Any]; change(&inner); $0[key] = inner }
        }
        var attachments = base["attachments"] as! [[String: Any]]
        let negatives: [(String, Any)] = [
            ("blank text and no attachment", mutated { $0["explanation"] = "  "; $0["attachments"] = [] as [Any]; $0["context"] = [:] as [String: Any] }),
            ("unknown top-level property", mutated { $0["extra"] = true }),
            ("unknown nested property", nested("build") { $0["hostname"] = "Ethan's Mac" }),
            ("malformed UUID", mutated { $0["report_id"] = "not-a-uuid" }),
            ("non-v4 UUID", mutated { $0["report_id"] = "a02149ed-36f5-1f10-9a21-10acfe2289b2" }),
            ("unknown edition", nested("build") { $0["edition"] = "beta" }),
            ("unknown permission", nested("context") { $0["permissions"] = ["microphone": "maybe"] }),
            ("unknown provider", nested("context") { $0["recognition"] = ["provider": "cloud", "ready": true] }),
            ("over-limit explanation characters", mutated { $0["explanation"] = String(repeating: "x", count: 2_049) }),
            ("invalid email", mutated { $0["reply_email"] = "nobody" }),
            ("duplicate image descriptors", mutated { attachments[1] = attachments[0]; attachments[1]["sha256"] = String(repeating: "b", count: 64); $0["attachments"] = attachments }),
            ("mismatched filename and MIME", mutated { var a = base["attachments"] as! [[String: Any]]; a[0]["content_type"] = "audio/wav"; $0["attachments"] = a }),
            ("zero-byte media", mutated { var a = base["attachments"] as! [[String: Any]]; a[0]["bytes"] = 0; $0["attachments"] = a }),
            ("oversized media", mutated { var a = base["attachments"] as! [[String: Any]]; a[1]["bytes"] = 4_194_305; $0["attachments"] = a }),
            ("missing build field", nested("build") { $0.removeValue(forKey: "os_build") }),
            ("negative dimensions", nested("context") { $0["screenshot"] = ["width": -1, "height": 10, "scale": 2] }),
            ("non-integer dimensions", nested("context") { $0["screenshot"] = ["width": 10.5, "height": 10, "scale": 2] }),
            ("unknown SHA format", mutated { var a = base["attachments"] as! [[String: Any]]; a[0]["sha256"] = "XYZ"; $0["attachments"] = a }),
            ("invalid date", mutated { $0["created_at"] = "yesterday" }),
            ("arbitrary file name", mutated { var a = base["attachments"] as! [[String: Any]]; a[0]["name"] = "../secrets.png"; $0["attachments"] = a }),
            ("error code with words", nested("context") { $0["error_code"] = "Something failed: /Users/name" }),
        ]
        for (name, value) in negatives {
            try expect(!validator.errors(value).isEmpty, "the schema rejects \(name)")
        }
        try expect(BugReportJSON.duplicateKeys(Data(#"{"schema_version":1,"schema_version":1}"#.utf8)), "a duplicate JSON key is detected")
        return ["schema: fixture, \(produced.count) produced manifests valid; \(negatives.count) negative vectors and 7 producer refusals rejected"]
    }

    // MARK: Media

    static func mediaChecks() throws -> [String] {
        // A JPEG with EXIF, GPS and a rotation comes back upright as a PNG with none of it.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 33.86, kCGImagePropertyGPSLatitudeRef: "S"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "synthetic secret"]] as CFDictionary)
        try expect(CGImageDestinationFinalize(destination), "synthetic JPEG")
        let image = try BugReportMedia.image(jpeg as Data, scale: 1, sourceLimit: BugReportLimits.importBytes)
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(image.png as CFData, nil)!, 0, nil) as! [CFString: Any]
        try expect(image.width == 40 && image.height == 80, "the image is upright (\(image.width) × \(image.height))")
        try expect(properties[kCGImagePropertyGPSDictionary] == nil && (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] == nil
                   && (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "GPS, EXIF comment and orientation are not kept")
        try expect(!String(decoding: image.png, as: UTF8.self).contains("synthetic secret"), "the EXIF comment is gone")
        let size = try BugReportMedia.pngSize(image.png)
        try expect(size.width == 40 && size.height == 80, "the PNG's size reads back")
        // Refusals: a 100-megapixel header, a GIF, text and an empty file.
        try expect((try? BugReportMedia.image(hugePNGHeader(), scale: 1, sourceLimit: BugReportLimits.importBytes)) == nil, "refuses over 40 megapixels")
        try expect((try? BugReportMedia.image(Data("GIF89a".utf8) + Data(count: 64), scale: 1, sourceLimit: BugReportLimits.importBytes)) == nil, "refuses a GIF")
        try expect((try? BugReportMedia.image(Data("not an image".utf8), scale: 1, sourceLimit: BugReportLimits.importBytes)) == nil, "refuses text")
        try expect((try? BugReportMedia.image(jpeg as Data, scale: 1, sourceLimit: 100)) == nil, "refuses a source over its byte limit")

        // WAV: other chunks and the extensible header are read; the result is the 44-byte canonical form.
        let pcm = Data((0..<3_200).flatMap { [UInt8($0 % 256), 0] })
        var wav = Data("RIFF".utf8) + le32(0) + Data("WAVE".utf8)
        let fields: [Data] = [Data("fmt ".utf8), le32(40), le16(0xFFFE), le16(1), le32(16_000), le32(32_000), le16(2), le16(16),
                              le16(22), le16(16), le32(4), le16(1), Data(count: 14)]
        for field in fields { wav += field }
        wav += Data("LIST".utf8) + le32(5) + Data("INFOx".utf8) + Data([0])
        wav += Data("data".utf8) + le32(UInt32(pcm.count)) + pcm
        let canonical = try BugReportMedia.canonicalWAV(wav)
        try expect(canonical.wav == BugReportMedia.wavHeader(dataBytes: pcm.count) + pcm && canonical.wav.count == 44 + pcm.count, "canonical 44-byte WAV")
        try expect(abs(canonical.seconds - 0.2) < 0.0001 && abs(try BugReportMedia.wavSeconds(canonical.wav) - 0.2) < 0.0001, "duration 0.2 s")
        let long = BugReportMedia.syntheticWAV(seconds: 61)
        try expect(try BugReportMedia.canonicalWAV(long).wav.count == 44 + 60 * 32_000, "cut at 60 seconds")
        var stereo = BugReportMedia.wavHeader(dataBytes: 4) + Data(count: 4); stereo[22] = 2
        try expect((try? BugReportMedia.canonicalWAV(stereo)) == nil, "refuses stereo")
        try expect((try? BugReportMedia.canonicalWAV(BugReportMedia.wavHeader(dataBytes: 0))) == nil, "refuses an empty recording")
        try expect((try? BugReportMedia.wavSeconds(wav)) == nil, "a non-canonical WAV is not sent as is")
        return ["media: JPEG metadata and rotation removed, 40 MP and type limits, WAV canonicalised, 60 s cap, stereo and empty refused"]
    }

    static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// A PNG signature and IHDR claiming 10,000 × 10,000 pixels, with no image data.
    static func hugePNGHeader() -> Data {
        func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func crc(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) } }
            return ~crc
        }
        let ihdr = Data("IHDR".utf8) + be32(10_000) + be32(10_000) + Data([8, 6, 0, 0, 0])
        let iend = Data("IEND".utf8)
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + be32(13) + ihdr + be32(crc(ihdr)) + be32(0) + iend + be32(crc(iend))
    }

    // MARK: Configuration

    /// The checkout the schema document came from, for source checks of the app's wiring.
    nonisolated(unsafe) static var repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    @MainActor static func configurationChecks(root: URL) throws -> [String] {
        let real = "https://a839282de76ebabd96a4cacae63ba2eb@o4512211018121216.ingest.us.sentry.io/4512211067011072"
        let parsed = BugReportDSN(real, allowLoopbackHTTP: false)
        try expect(parsed?.envelopeURL.absoluteString == "https://o4512211018121216.ingest.us.sentry.io/api/4512211067011072/envelope/"
                   && parsed?.publicKey == "a839282de76ebabd96a4cacae63ba2eb" && parsed?.projectID == "4512211067011072", "the edition DSN parses to its envelope endpoint")
        try expect(parsed?.authorization(client: "workbench-mac/2.5.0") == "Sentry sentry_version=7, sentry_key=a839282de76ebabd96a4cacae63ba2eb, sentry_client=workbench-mac/2.5.0", "X-Sentry-Auth")
        try expect(BugReportDSN("https://key@host.example/sub/7", allowLoopbackHTTP: false)?.envelopeURL.absoluteString == "https://host.example/sub/api/7/envelope/", "a DSN path prefix is kept")
        for bad in ["http://key@o1.ingest.example.test/42", "https://o1.ingest.example.test/42", "https://key@o1.ingest.example.test/", "https://key@o1.ingest.example.test/42?x=1", "nonsense"] {
            try expect(BugReportDSN(bad, allowLoopbackHTTP: false) == nil, "refuses DSN \(bad)")
        }
        try expect(BugReportDSN("http://key@127.0.0.1:9000/1", allowLoopbackHTTP: true) != nil && BugReportDSN("http://key@10.0.0.2:9000/1", allowLoopbackHTTP: true) == nil,
                   "plain HTTP only to this Mac, and only for the override")

        // Per edition. A settings suite in a temporary folder, never a named suite (#128).
        let suite = root.appendingPathComponent("defaults-\(UUID().uuidString)").path
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(atPath: suite + ".plist") }
        let realVerifier = "https://workbench-report-check.vercel.app/api/v1/verify"
        let stable = WorkbenchBuild(info: ["WorkbenchBuildKind": "release", BugReportConfiguration.dsnKey: real, BugReportConfiguration.verifierKey: realVerifier])
        let stableNoVerifier = WorkbenchBuild(info: ["WorkbenchBuildKind": "release", BugReportConfiguration.dsnKey: real])
        let previewRelease = WorkbenchBuild(info: ["WorkbenchBuildKind": "release", "WorkbenchChannel": "preview", BugReportConfiguration.dsnKey: real])
        let local = WorkbenchBuild(info: ["WorkbenchBuildKind": "local"])
        try expect(BugReportConfiguration.destination(build: stable, defaults: defaults) == .init(dsn: real, verifier: realVerifier, environment: "production", isOverride: false),
                   "Stable release: its DSN, verifier and the production environment")
        try expect(BugReportConfiguration.destination(build: stableNoVerifier, defaults: defaults)?.verifier == nil, "the verifier is optional")
        try expect(BugReportConfiguration.destination(build: previewRelease, defaults: defaults) == nil, "Preview carries no DSN, even if one were stamped")
        try expect(BugReportConfiguration.destination(build: local, defaults: defaults) == nil, "a local build has no DSN by default")
        defaults.set(real, forKey: BugReportConfiguration.dsnOverrideKey)
        defaults.set("http://127.0.0.1:8787", forKey: BugReportConfiguration.verifierOverrideKey)
        let override = BugReportDestination(dsn: real, verifier: "http://127.0.0.1:8787", environment: "preview", isOverride: true)
        try expect(BugReportConfiguration.destination(build: previewRelease, defaults: defaults) == override, "Preview honours the override as the preview environment")
        try expect(BugReportConfiguration.destination(build: local, defaults: defaults) == override, "a local build honours the override")
        try expect(BugReportConfiguration.destination(build: stable, defaults: defaults)?.environment == "production", "a Stable release ignores the override")
        defaults.set("http://10.0.0.2:8787", forKey: BugReportConfiguration.verifierOverrideKey)
        try expect(BugReportConfiguration.destination(build: local, defaults: defaults)?.verifier == nil, "a remote plain-HTTP verifier is ignored")
        defaults.set("http://key@10.0.0.2/1", forKey: BugReportConfiguration.dsnOverrideKey)
        try expect(BugReportConfiguration.destination(build: local, defaults: defaults) == nil, "an unsafe override DSN is ignored")

        // Rate limits: X-Sentry-Rate-Limits on any status, Retry-After on 429.
        let now = Date(timeIntervalSince1970: 1_791_349_200)
        typealias Limit = BugReportEnvelope.RateLimit
        func limit(_ status: Int, _ header: String?, _ retry: String? = nil, at time: Date = now) -> Limit? {
            BugReportEnvelope.rateLimit(status: status, rateLimits: header, retryAfter: retry, now: time)
        }
        try expect(limit(200, nil) == nil, "200 without a limit")
        try expect(limit(200, "60:transaction:key, 2700:default;error;security:organization") == nil, "unrelated categories")
        try expect(limit(200, "60:transaction:key, 120:feedback:project:quota") == Limit(wait: 120, attachmentsOnly: false), "feedback category")
        try expect(limit(200, "30:attachment:org") == Limit(wait: 30, attachmentsOnly: true), "only the attachment category: the event went through")
        try expect(limit(200, "30:attachment:org, 10:feedback:org") == Limit(wait: 30, attachmentsOnly: false), "attachment with feedback")
        try expect(limit(200, "45::organization") == Limit(wait: 45, attachmentsOnly: false), "empty categories mean all")
        try expect(limit(429, nil, "90") == Limit(wait: 90, attachmentsOnly: false), "Retry-After seconds")
        try expect(limit(429, nil, "Thu, 01 Oct 2026 21:02:00 GMT", at: Date(timeIntervalSince1970: 1_790_888_400))?.wait == 120, "Retry-After date")
        try expect(limit(429, nil) == Limit(wait: 60, attachmentsOnly: false) && limit(429, "30:attachment:org") == Limit(wait: 60, attachmentsOnly: false),
                   "429 without a feedback limit waits for Retry-After or 60 s")
        try expect(BugReportTransport.session().configuration.timeoutIntervalForResource >= 1_800, "an upload may take 30 minutes on a slow uplink")
        try expect(BugReportView.sendShortcut == KeyboardShortcut(.return, modifiers: .command), "Send is Command-Return; plain Return in the email field never sends")
        // The email caption and the privacy page say the team can see and search an added address.
        try expect(BugReportView.emailNote == "If you add your email, the team sees it with your report, and can search for it, so they can reply.", "the email caption")
        let privacy = try String(contentsOf: repository.appendingPathComponent("site/privacy.html"), encoding: .utf8)
        try expect(privacy.contains("If you add your email, the team sees it with your report, and can search for it in their private inbox, so they can reply.")
                   && privacy.contains("keeps reports for up to 90 days"), "the privacy page's email and retention wording")

        // Every other recorder asks one microphone rule while a report records or transcribes.
        try expect(BugReportAdmission.microphone(recording: true, transcribing: false) != nil && BugReportAdmission.microphone(recording: false, transcribing: true) != nil
                   && BugReportAdmission.microphone(recording: false, transcribing: false) == nil, "the report's microphone rule")
        do {
            let main = try String(contentsOf: repository.appendingPathComponent("Sources/LocalVoice/main.swift"), encoding: .utf8)
            for owner in ["model.microphoneStartFailure = {", "model.meetings.hostAdmission = {", "readback.mayBeginCapture = {"] {
                guard let start = main.range(of: owner) else { throw VoiceError.message("Report a problem check failed: \(owner) not found in main.swift") }
                let body = main[start.upperBound...].prefix(900)
                try expect(body.contains("bugReportMicrophoneBusy"), "\(owner) asks the report's microphone rule")
            }
        }
        return ["configuration: Stable-only DSN (production), override for Preview/local (preview), endpoint/auth from the real DSN form, rate-limit scopes, 30-minute uploads, Command-Return, one microphone rule"]
    }

    // MARK: Envelope

    @MainActor static func envelopeChecks(root: URL) async throws -> [String] {
        let sentry = FakeSentry()
        BugReportStub.route = { sentry.handle($0) }
        let h = harness(root)
        try fill(h.model)
        let screenshot = h.store.draftScreenshot()!, voice = h.store.draftVoice()!
        let details = h.model.detailsJSON
        h.model.send()
        try expect(h.model.problem == nil, "Send froze the report: \(h.model.problem ?? "")")
        try expect(h.store.loadDraft() == nil && h.model.explanation.isEmpty && h.model.screenshot == nil, "the draft is done once frozen")
        let delivery = h.store.deliveries()[0]
        try expect(h.model.receipts.first?.title == "Sending…", "a report frozen a moment ago says Sending…, not Waiting for connection")
        let frozen = try h.store.envelope(delivery.id)
        try expect(BugReportText.sha256(frozen) == delivery.envelopeSHA256, "the delivery names its frozen bytes")
        try expect(!String(decoding: frozen.prefix(while: { $0 != 0x0A }), as: UTF8.self).contains("sent_at"), "the stored envelope has no sent_at")
        // Two attempts: the first is lost on the way back, the second is accepted.
        sentry.script = [.lostResponse]
        await h.transport.attempt(delivery.id)
        h.clock.advance(600)
        await h.transport.attempt(delivery.id)
        try expect(sentry.bodies.count == 2, "two transmissions")
        func afterHeader(_ data: Data) -> Data { data[(data.firstIndex(of: 0x0A)! + 1)...] }
        try expect(sentry.bodies.allSatisfy { afterHeader($0) == afterHeader(frozen) }, "every item byte is identical on retry")

        let (header, items) = try BugReportEnvelope.parse(sentry.bodies[1])
        try expect(Set(header.keys) == ["event_id", "sent_at", "dsn"] && header["event_id"] as? String == delivery.eventID && header["dsn"] as? String == dsn,
                   "header: event_id, sent_at and dsn")
        try expect(BugReportEnvelope.isEventID(delivery.eventID), "event ID is 32 hex characters of a UUIDv4")
        try expect((header["sent_at"] as? String).flatMap { ISO8601DateFormatter.fractional.date(from: $0) } != nil, "sent_at is RFC 3339 UTC")
        try expect(items.map(\.type) == ["feedback", "attachment", "attachment", "attachment"]
                   && items.dropFirst().map(\.filename) == ["context.json", "screenshot.png", "voice.wav"], "exactly feedback, context.json, screenshot.png and voice.wav")
        try expect(NSDictionary(dictionary: items[0].header) == NSDictionary(dictionary: ["type": "feedback"]), "the feedback item header is {\"type\":\"feedback\"}")
        for (item, type) in zip(items.dropFirst(), ["application/json", "image/png", "audio/wav"]) {
            try expect(Set(item.header.keys) == ["type", "length", "filename", "content_type", "attachment_type"]
                       && item.header["length"] as? Int == item.payload.count && item.header["content_type"] as? String == type
                       && item.header["attachment_type"] as? String == "event.attachment", "\(item.filename ?? "") item header")
        }
        try expect(items[2].payload == screenshot && items[3].payload == voice, "attachment bytes equal the outbox's frozen files")
        let manifest = items[1].payload
        let object = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
        try expect(object["report_id"] as? String == delivery.id && (object["attachments"] as? [[String: Any]])?.map { $0["sha256"] as? String }
                   == [BugReportText.sha256(screenshot), BugReportText.sha256(voice)], "context.json describes the attached bytes")
        var expectedDetails = try JSONSerialization.jsonObject(with: Data(details.utf8)) as! [String: Any]
        expectedDetails["report_id"] = delivery.id
        try expect(NSDictionary(dictionary: expectedDetails) == NSDictionary(dictionary: object), "Details showed exactly what was sent, apart from the new report ID")
        let event = try JSONSerialization.jsonObject(with: items[0].payload) as! [String: Any]
        let tags = event["tags"] as? [String: String], contexts = event["contexts"] as? [String: Any]
        let feedback = contexts?["feedback"] as? [String: String]
        try expect(event["event_id"] as? String == delivery.eventID && event["platform"] as? String == "other" && event["level"] as? String == "info"
                   && event["environment"] as? String == "production" && event["release"] as? String == "workbench@2.5.0+20261007010203"
                   && event["dist"] as? String == "20261007010203" && (event["timestamp"] as? Double).map { abs($0 - 1_791_349_200) < 1 } == true,
                   "event attributes")
        try expect(tags == ["report_id": delivery.id, "edition": "stable", "tool": "snap", "schema": "1", "build": "20261007010203"], "tags")
        try expect(feedback == ["message": "The Snap window disappeared before I could show the problem.", "source": "workbench-mac", "contact_email": "reporter@example.com"],
                   "feedback context")
        try expect(Set(event.keys).isDisjoint(with: ["user", "server_name", "request", "breadcrumbs", "exception", "extra"]), "no user, host, request or log fields")
        // Accepted once: Sentry kept one event for the repeated event ID.
        try expect(sentry.events.count == 1 && h.store.delivery(delivery.id)?.state == .sent, "the repeated event ID is one report, now Sent")
        try expect(sentry.authorizations.allSatisfy { $0 == "Sentry sentry_version=7, sentry_key=0123456789abcdef0123456789abcdef, sentry_client=workbench-mac/2.5.0" }
                   && sentry.contentTypes.allSatisfy { $0 == "application/x-sentry-envelope" } && sentry.paths.allSatisfy { $0 == "/api/42/envelope/" }, "request headers and path")

        // Image-only and voice-only reports carry a fixed placeholder, never a guess.
        for (shot, voiceNote, message) in [(true, false, "Screenshot attached"), (false, true, "Voice note attached"), (true, true, "Screenshot and voice note attached")] {
            let other = harness(root.appendingPathComponent("placeholder-\(shot)-\(voiceNote)"))
            try fill(other.model, text: " \n", email: "", screenshot: shot, voice: voiceNote)
            other.model.send()
            let parsed = try BugReportEnvelope.parse(try other.store.envelope(other.store.deliveries()[0].id))
            let event = try JSONSerialization.jsonObject(with: parsed.items[0].payload) as! [String: Any]
            let feedback = (event["contexts"] as? [String: Any])?["feedback"] as? [String: String]
            try expect(feedback == ["message": message, "source": "workbench-mac"], "placeholder “\(message)”")
        }
        return ["envelope: golden header and four items, identical item bytes on retry, attachments equal outbox files, Details equals context.json, placeholders"]
    }

    // MARK: Transport

    @MainActor static func transportChecks(root: URL) async throws -> [String] {
        let sentry = FakeSentry()
        BugReportStub.route = { sentry.handle($0) }
        func frozen(_ name: String, clock: Clock = Clock()) throws -> (Harness, String) {
            let h = harness(root.appendingPathComponent(name), clock: clock)
            try fill(h.model, screenshot: false, voice: false)
            h.model.send()
            return (h, h.store.deliveries()[0].id)
        }
        func state(_ h: Harness, _ id: String) -> BugReportDelivery { h.store.delivery(id)! }

        // 200 with a feedback rate limit is not delivered; it waits, then goes.
        var (h, id) = try frozen("rate-limited-200")
        sentry.script = [.status(200, ["X-Sentry-Rate-Limits": "60:feedback:project:quota"])]
        await h.transport.runDue()
        try expect(state(h, id).state == .sending && state(h, id).problem == .rateLimited && state(h, id).nextAttemptAt == h.clock.now + 60, "200 naming feedback is not delivered")
        h.clock.advance(59); let before = sentry.bodies.count
        await h.transport.runDue()
        try expect(sentry.bodies.count == before, "nothing is sent before the limit ends")
        h.clock.advance(1)
        sentry.script = [.status(200, ["X-Sentry-Rate-Limits": "60:transaction:key"])]
        await h.transport.runDue()
        try expect(state(h, id).state == .sent && state(h, id).nextAttemptAt == nil, "an unrelated limit still counts as Sent")
        try expect(h.model.receipts.first?.title == "Sent · \(BugReportText.shortID(id))", "receipt: Sent · short ID")

        // 429 honours Retry-After exactly.
        (h, id) = try frozen("429")
        sentry.script = [.status(429, ["Retry-After": "120"])]
        await h.transport.runDue()
        try expect(state(h, id).nextAttemptAt == h.clock.now + 120 && state(h, id).problem == .rateLimited, "429 waits for Retry-After")
        try expect(h.model.receipts.first?.title == "Sending…", "receipt while asked to wait: Sending…")

        // 200 limiting only attachments: the event went through, so it is Sent and the verifier decides.
        // A 200 limiting only attachments: the words arrived without their files. Sent · words only,
        // nothing checked or resent by itself, and Send attachments again under a new event ID.
        let words = harness(root.appendingPathComponent("words-only"), destination: .init(dsn: dsn, verifier: verifier, environment: "production", isOverride: false))
        try fill(words.model)
        words.model.send()
        let wid = words.store.deliveries()[0].id
        sentry.script = [.status(200, ["X-Sentry-Rate-Limits": "60:attachment:organization"])]
        await words.transport.runDue()
        var wd = words.store.delivery(wid)!
        try expect(wd.state == .sent && wd.wordsOnly && wd.nextAttemptAt == nil && !wd.isSettled && !wd.isUnsent, "a 200 limiting only attachments is Sent · words only")
        let quiet = sentry.bodies.count
        words.clock.advance(3_600); await words.transport.runDue()
        try expect(sentry.bodies.count == quiet, "words only: nothing is checked or resent by itself")
        let short = BugReportText.shortID(wid)
        let wordsReceipt = words.model.receipts.first
        try expect(wordsReceipt?.title == "Sent · words only · \(short)" && wordsReceipt?.detail.contains("The screenshot and voice note couldn't go with it.") == true
                   && wordsReceipt?.actions == [.sendAttachmentsAgain, .saveCopy, .remove] && wordsReceipt?.detail.contains("didn't confirm") == false,
                   "the receipt says the words arrived and offers Send attachments again, not Send again")
        let firstWordsEvent = wd.eventID
        words.model.perform(.sendAttachmentsAgain, on: wid)
        sentry.script = []
        await words.transport.runDue()
        wd = words.store.delivery(wid)!
        let resent = try BugReportEnvelope.parse(sentry.bodies.last!)
        let resentEvent = try JSONSerialization.jsonObject(with: resent.items[0].payload) as! [String: Any]
        try expect(wd.eventID != firstWordsEvent && wd.previousEventIDs == [firstWordsEvent] && !wd.wordsOnly && wd.state == .sent
                   && wd.files.count == 3 && wd.nextAttemptAt == words.clock.now + 15, "Send attachments again goes under a new event ID and is checked")
        try expect(resent.items.dropFirst().map(\.filename) == ["context.json", "screenshot.png", "voice.wav"]
                   && (resentEvent["tags"] as? [String: String])?["report_id"] == wid, "with every attachment and the same report ID")

        // A lost reply may have arrived: after 55 minutes the same event ID is not sent again by itself.
        (h, id) = try frozen("lost-then-late")
        sentry.script = [.lostResponse]
        await h.transport.runDue()
        try expect(state(h, id).state == .sending && state(h, id).problem == .busy && state(h, id).mayHaveArrivedAt == h.clock.now,
                   "a lost reply retries with backoff and starts the duplicate clock")
        sentry.script = [.failure(.notConnectedToInternet)]
        h.clock.advance(state(h, id).nextAttemptAt!.timeIntervalSince(h.clock.now)); await h.transport.runDue()
        h.clock.advance(56 * 60)
        let beforeLate = sentry.bodies.count
        await h.transport.runDue()
        try expect(state(h, id).state == .unconfirmed && state(h, id).problem == .uncertain && sentry.bodies.count == beforeLate,
                   "56 minutes after a possible arrival, nothing is resent by itself")
        try expect(h.model.receipts.first?.title == "Couldn't confirm delivery" && h.model.receipts.first?.detail.contains("may already have arrived") == true
                   && h.model.receipts.first?.actions.first == .sendAgain, "the receipt explains and offers Send again")
        let lateEvent = state(h, id).eventID
        h.model.perform(.sendAgain, on: id)
        await h.transport.runDue()
        try expect(state(h, id).state == .sent && state(h, id).eventID != lateEvent && sentry.lastEventID == state(h, id).eventID, "Send again goes under a new event ID")

        // Failures before any connection never start that clock: a report offline for hours still goes by itself.
        (h, id) = try frozen("offline-hours")
        sentry.script = [.failure(.cannotFindHost)]
        await h.transport.runDue()
        try expect(state(h, id).mayHaveArrivedAt == nil && state(h, id).state == .waiting, "no connection, no duplicate clock")
        h.clock.advance(3 * 3_600)
        await h.transport.runDue()
        try expect(state(h, id).state == .sent, "sent by itself three hours later")

        // A time-out after the upload's bytes went may have arrived, so it backs off as busy; one that
        // sent no bytes never connected and waits for a connection without starting the clock.
        (h, id) = try frozen("timed-out")
        sentry.script = [.timeoutAfterUpload]
        await h.transport.runDue()
        try expect(state(h, id).state == .sending && state(h, id).problem == .busy && state(h, id).mayHaveArrivedAt != nil
                   && h.model.receipts.first?.title == "Sending…", "a time-out after sending bytes backs off as busy, not offline")
        (h, id) = try frozen("timed-out-early")
        sentry.script = [.failure(.timedOut)]
        await h.transport.runDue()
        try expect(state(h, id).state == .waiting && state(h, id).problem == .offline && state(h, id).mayHaveArrivedAt == nil,
                   "a time-out that sent no bytes is never-connected")
        try expect(BugReportTransport.neverConnected(.timedOut, bytesSent: 0) && !BugReportTransport.neverConnected(.timedOut, bytesSent: 1)
                   && BugReportTransport.neverConnected(.cannotFindHost, bytesSent: 9) && !BugReportTransport.neverConnected(.networkConnectionLost, bytesSent: 0),
                   "never-connected classification")

        // The clock is saved before the request: a Quit mid-upload still counts it, and a relaunch
        // past the hour sends nothing by itself.
        (h, id) = try frozen("quit-mid-upload")
        let store = h.store, crashed = root.appendingPathComponent("quit-mid-upload-relaunched")
        var seenDuringRequest: Date?
        sentry.onRequest = {
            DispatchQueue.main.sync { MainActor.assumeIsolated {
                seenDuringRequest = store.delivery(id)?.mayHaveArrivedAt
                try? FileManager.default.copyItem(at: store.root, to: crashed)
            } }
        }
        await h.transport.runDue()
        sentry.onRequest = nil
        try expect(seenDuringRequest == h.clock.now, "the possible-arrival time is on disk before the request")
        let afterQuit = harness(crashed, clock: h.clock)
        h.clock.advance(56 * 60)
        let beforeRelaunch = sentry.bodies.count
        await afterQuit.transport.runDue()
        try expect(afterQuit.store.delivery(id)?.state == .unconfirmed && afterQuit.store.delivery(id)?.problem == .uncertain && sentry.bodies.count == beforeRelaunch,
                   "an upload cut off by Quit is not resent by itself past the hour")
        // A never-connected failure puts the earlier value back.
        (h, id) = try frozen("never-connected-restores")
        sentry.script = [.failure(.cannotConnectToHost)]
        await h.transport.runDue()
        try expect(state(h, id).mayHaveArrivedAt == nil, "a never-connected failure clears the clock it saved")

        // Budget: an automatic resend must finish inside Sentry's hour.
        let t0 = Date(timeIntervalSince1970: 1_791_349_200)
        try expect(BugReportTransport.sendDeadline(mayHaveArrivedAt: nil, now: t0) == BugReportTransport.uploadLimit
                   && BugReportTransport.sendDeadline(mayHaveArrivedAt: t0, now: t0 + 50 * 60) == 600
                   && BugReportTransport.sendDeadline(mayHaveArrivedAt: t0, now: t0 + 10 * 60) == BugReportTransport.uploadLimit
                   && BugReportTransport.sendDeadline(mayHaveArrivedAt: t0, now: t0 + 56 * 60) == nil, "send deadlines inside the hour")
        (h, id) = try frozen("budget")
        sentry.script = [.lostResponse, .status(200, [:])]
        await h.transport.runDue()
        h.clock.advance(50 * 60)
        await h.transport.runDue()
        try expect(h.transport.lastSendDeadline == 600 && state(h, id).state == .sent, "a resend 50 minutes on may take 10 minutes at most")

        // A list of due reports taken earlier (a run that started before a connectivity burst) never
        // sends a report again before its saved time: attempt reads the report fresh and checks it.
        (h, id) = try frozen("stale-list")
        sentry.script = [.lostResponse]
        await h.transport.runDue()
        let staleEvent = state(h, id).eventID, sentOnce = sentry.count(staleEvent)
        try expect(state(h, id).nextAttemptAt! > h.clock.now, "after a lost reply the next attempt is later")
        await h.transport.attempt(id)
        try expect(sentry.count(staleEvent) == sentOnce && sentOnce == 1, "a stale due list cannot send it again at once")

        // 413, 401, 400 and a TLS failure stop, with no loop.
        for (name, reply, problem) in [("413", FakeSentry.Reply.status(413, [:]), BugReportDelivery.Problem.tooLarge),
                                       ("401", .status(401, [:]), .unauthorized), ("403", .status(403, [:]), .unauthorized),
                                       ("400", .status(400, [:]), .rejected), ("tls", .failure(.serverCertificateUntrusted), .secureConnection)] {
            (h, id) = try frozen(name)
            sentry.script = [reply]
            await h.transport.runDue()
            let count = sentry.bodies.count
            h.clock.advance(86_400)
            await h.transport.runDue()
            try expect(state(h, id).state == .failed && state(h, id).problem == problem && sentry.bodies.count == count, "\(name) stops without retrying")
            try expect(h.store.envelope(id).count > 0 && h.model.receipts.first?.title == "Couldn't deliver", "\(name) keeps the report and says Couldn't deliver")
        }
        try expect(h.model.receipts.first?.actions.contains(.retry) == true, "Couldn't deliver offers Retry")
        h.transport.retry(id); sentry.script = []
        await h.transport.runDue()
        try expect(state(h, id).state == .sent, "Retry sends the same report")

        // Offline, then a relaunch: the same report, event ID and bytes.
        let clock = Clock()
        (h, id) = try frozen("offline", clock: clock)
        let event = state(h, id).eventID, bytes = try h.store.envelope(id)
        sentry.script = [.failure(.notConnectedToInternet)]
        await h.transport.runDue()
        try expect(state(h, id).state == .waiting && state(h, id).problem == .offline, "offline waits")
        try expect(h.model.receipts.first?.title == "Waiting for connection", "receipt: Waiting for connection")
        let wait = state(h, id).nextAttemptAt!.timeIntervalSince(clock.now)
        try expect(wait >= 5 && wait <= 900, "backoff between 5 s and 15 min")
        let relaunched = harness(root.appendingPathComponent("offline"), clock: clock)
        clock.advance(wait)
        let count = sentry.bodies.count
        await relaunched.transport.runDue()
        let after = relaunched.store.delivery(id)!
        try expect(after.state == .sent && after.eventID == event && sentry.bodies.count == count + 1 && sentry.lastEventID == event, "a relaunch sends the same event")
        try expect(sentry.bodies.last.map { $0[($0.firstIndex(of: 0x0A)! + 1)...] } == bytes[(bytes.firstIndex(of: 0x0A)! + 1)...], "with the same bytes")

        // 5xx backs off and grows to 15 minutes at most.
        (h, id) = try frozen("busy")
        sentry.script = [.status(503, [:])]
        await h.transport.runDue()
        try expect(state(h, id).state == .sending && state(h, id).problem == .busy, "5xx retries")
        let delays = (1...12).map { BugReportTransport.backoff($0, random: 1) }
        try expect(delays.first == 5 && delays.last == 900 && zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 }
                   && (1...12).allSatisfy { BugReportTransport.backoff($0, random: 0) >= 5 }, "backoff 5 s to 15 min: \(delays)")

        // Removed while its request is in flight: the late reply cannot bring it back.
        (h, id) = try frozen("removed")
        let transport = h.transport
        sentry.onRequest = { DispatchQueue.main.sync { MainActor.assumeIsolated { try? transport.remove(id) } } }
        await h.transport.attempt(id)
        sentry.onRequest = nil
        try expect(h.store.delivery(id) == nil && !FileManager.default.fileExists(atPath: h.store.outboxFolder.appendingPathComponent(id).path),
                   "a report removed during sending stays removed")

        // Changed bytes are never sent under the same event ID.
        (h, id) = try frozen("tampered")
        var tampered = try h.store.envelope(id); tampered[tampered.count - 2] ^= 0x01
        try BugReportFiles.writeDurably(tampered, to: h.store.outboxFolder.appendingPathComponent(id).appendingPathComponent("report.envelope"))
        let sent = sentry.bodies.count
        await h.transport.runDue()
        try expect(state(h, id).state == .failed && state(h, id).problem == .unreadable && sentry.bodies.count == sent, "changed bytes are refused, not sent")
        return ["transport: 200, 200+feedback limit, 200+attachment-only limit is Sent · words only with Send attachments again, clock saved before the request (Quit mid-upload), uploads finish inside Sentry's hour, time-outs with no bytes never connected, stale due lists, 429 Retry-After, 413/401/403/400/TLS without loops, Retry, offline then relaunch with the same event and bytes, no automatic resend 55 minutes after a possible arrival, time-out as busy, 5xx backoff, removal in flight, changed bytes"]
    }

    // MARK: Verifier

    @MainActor static func verifierChecks(root: URL) async throws -> [String] {
        let sentry = FakeSentry()
        var answers: [String?] = []
        var requests: [[String: Any]] = []
        var paths: Set<String> = []
        BugReportStub.route = { request in
            if request.url.host == "verify.example.test" {
                paths.insert(request.url.path)
                requests.append((try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:])
                let answer = answers.isEmpty ? "pending" : answers.removeFirst()
                guard let answer else { return .failure(.cannotConnectToHost) }
                if answer == "503" { return .status(503, ["Retry-After": "120"], Data()) }
                if answer == "422" { return .status(422, [:], Data(#"{"error":"invalid_request"}"#.utf8)) }
                if answer == "html" { return .status(200, ["Content-Type": "text/html"], Data("<html>".utf8)) }
                return .status(200, ["Content-Type": "application/json"], Data(#"{"state":"\#(answer)","checked_at":"2026-10-07T05:00:30Z"}"#.utf8))
            }
            return sentry.handle(request)
        }
        func frozen(_ name: String, clock: Clock = Clock()) async throws -> (Harness, String) {
            let h = harness(root.appendingPathComponent(name), clock: clock, destination: .init(dsn: dsn, verifier: verifier, environment: "production", isOverride: false))
            try fill(h.model)
            h.model.send()
            let id = h.store.deliveries()[0].id
            await h.transport.runDue()
            return (h, id)
        }
        func elapsed() -> Int? { requests.last?["elapsed_seconds"] as? Int }

        // Pending, then received: the local copy goes and the receipt stays.
        var (h, id) = try await frozen("received")
        var delivery = h.store.delivery(id)!
        try expect(delivery.state == .sent && delivery.nextAttemptAt == h.clock.now + 15, "the first check comes 15 s after Sent")
        try expect(h.model.receipts.first?.detail.hasPrefix("Checking that it arrived.") == true, "Sent explains it is being checked")
        answers = ["pending", "received"]
        h.clock.advance(15); await h.transport.runDue()
        delivery = h.store.delivery(id)!
        try expect(delivery.state == .sent && delivery.verifierState == "pending" && (delivery.nextAttemptAt ?? .distantPast) > h.clock.now, "pending keeps checking")
        try expect(elapsed() == 15, "elapsed_seconds counts from Sentry's 200 by this Mac's clock")
        h.clock.advance(30); await h.transport.runDue()
        delivery = h.store.delivery(id)!
        try expect(delivery.state == .received && delivery.evidenceRemoved && (try? h.store.envelope(id)) == nil, "received drops the local copy and keeps the receipt")
        try expect(h.model.receipts.first?.title == "Received · \(BugReportText.shortID(id))", "receipt: Received · short ID")
        let body = requests.last!
        let files = body["attachments"] as? [[String: Any]]
        try expect(body["event_id"] as? String == delivery.eventID && body["report_id"] as? String == id && id == id.lowercased()
                   && files?.map { $0["name"] as? String } == ["context.json", "screenshot.png", "voice.wav"]
                   && files?.allSatisfy({ ($0["size"] as? Int ?? 0) > 0 && ($0["sha256"] as? String)?.count == 64 }) == true, "the verifier request names every file")
        try expect(Set(body.keys) == ["event_id", "report_id", "attachments", "elapsed_seconds"] && elapsed() == 45
                   && (try JSONSerialization.data(withJSONObject: body)).count <= 4_096, "the request is exactly event, report, files and elapsed seconds, within 4 KiB")
        try expect(paths == ["/api/v1/verify"], "the verifier endpoint path")
        try expect(BugReportTransport.verifyEndpoint(URL(string: "https://workbench-report-check.vercel.app/api/v1/verify")!).absoluteString
                   == "https://workbench-report-check.vercel.app/api/v1/verify"
                   && BugReportTransport.verifyEndpoint(URL(string: "http://127.0.0.1:8787")!).absoluteString == "http://127.0.0.1:8787/api/v1/verify",
                   "a full endpoint is used as is; an origin gets /api/v1/verify")

        // A clock moved backwards counts as 0 elapsed seconds.
        (h, id) = try await frozen("clock")
        h.clock.advance(-120); answers = ["pending"]
        var due = h.store.delivery(id)!; due.nextAttemptAt = h.clock.now; try h.store.save(due)
        await h.transport.attempt(id)
        try expect(elapsed() == 0 && h.store.delivery(id)?.state == .sent, "a clock moved backwards sends 0")

        // A mismatch is the verifier's finding: Couldn't confirm delivery, then Send again under a new event ID.
        (h, id) = try await frozen("mismatch")
        let manifest = try BugReportEnvelope.parse(try h.store.envelope(id)).items[1].payload
        let firstEvent = h.store.delivery(id)!.eventID
        answers = ["mismatch"]
        h.clock.advance(15); await h.transport.runDue()
        delivery = h.store.delivery(id)!
        try expect(delivery.state == .unconfirmed && delivery.problem == .mismatch && delivery.nextAttemptAt == nil, "mismatch is Couldn't confirm delivery")
        try expect(h.model.receipts.first?.title == "Couldn't confirm delivery" && h.model.receipts.first?.actions.first == .sendAgain, "receipt offers Send again")
        let sends = sentry.bodies.count
        h.clock.advance(3_600); await h.transport.runDue()
        try expect(sentry.bodies.count == sends, "nothing is sent again without the person's choice")
        h.model.perform(.sendAgain, on: id)
        await h.transport.runDue()
        delivery = h.store.delivery(id)!
        let again = try BugReportEnvelope.parse(try h.store.envelope(id))
        try expect(delivery.eventID != firstEvent && delivery.previousEventIDs == [firstEvent] && sentry.bodies.count == sends + 1 && delivery.state == .sent,
                   "Send again uses a new event ID, once")
        try expect(again.items[1].payload == manifest && again.header["event_id"] as? String == delivery.eventID, "the same report ID and context.json")
        answers = ["pending"]
        h.clock.advance(15); await h.transport.runDue()
        try expect(elapsed() == 15, "the new 200 resets elapsed seconds")

        (h, id) = try await frozen("not-found")
        answers = ["not_found"]
        h.clock.advance(15); await h.transport.runDue()
        try expect(h.store.delivery(id)?.state == .unconfirmed && h.store.delivery(id)?.problem == .notFound, "not_found is Couldn't confirm delivery")

        // Anything else keeps Sent and checks again: 503 with Retry-After, 422, a page that is not JSON.
        (h, id) = try await frozen("unavailable")
        answers = ["503"]
        h.clock.advance(15); await h.transport.runDue()
        delivery = h.store.delivery(id)!
        try expect(delivery.state == .sent && delivery.nextAttemptAt == h.clock.now + 120, "503 keeps Sent and honours Retry-After")
        answers = ["422", "html"]
        h.clock.advance(120); await h.transport.runDue()
        h.clock.advance(300); await h.transport.runDue()
        delivery = h.store.delivery(id)!
        try expect(delivery.state == .sent && delivery.nextAttemptAt != nil, "422 and a non-JSON answer keep Sent and check again")

        // A lost network never ends checking: only an HTTP answer counts against the window.
        let clock = Clock()
        (h, id) = try await frozen("unreachable", clock: clock)
        answers = Array(repeating: nil, count: 40)
        for _ in 0..<40 { clock.advance(60); await h.transport.runDue() }
        delivery = h.store.delivery(id)!
        try expect(delivery.state == .sent && delivery.nextAttemptAt != nil && !delivery.verifyAtLaunch
                   && clock.now.timeIntervalSince(delivery.sentAt!) > BugReportTransport.verifyWindow, "40 minutes without a network still checks")
        try expect(h.model.receipts.first?.title == "Sent · \(BugReportText.shortID(id))", "receipt stays Sent")
        try expect((delivery.nextAttemptAt!.timeIntervalSince(clock.now)) <= BugReportTransport.verifyBackoffCap
                   && (1...30).allSatisfy { BugReportTransport.backoff($0, random: 1, cap: BugReportTransport.verifyBackoffCap) <= 300 }, "checks are at most five minutes apart")
        // Connectivity returning checks a Sent report at once.
        h.transport.connectivity(false); h.transport.connectivity(true)
        try expect(h.store.delivery(id)?.nextAttemptAt == clock.now, "a restored connection checks Sent reports now")
        // The first HTTP answer after the window ends checking, with one more at the next launch.
        answers = ["pending"]
        await h.transport.runDue()
        delivery = h.store.delivery(id)!
        try expect(delivery.state == .sent && delivery.nextAttemptAt == nil && delivery.verifyAtLaunch, "an answer after the window ends checking for now")
        // At launch: a network failure does not use up that check; the next answer does.
        clock.advance(86_400)
        answers = [nil, "received"]
        let relaunched = harness(root.appendingPathComponent("unreachable"), clock: clock)
        relaunched.transport.start(watchConnectivity: false)
        relaunched.transport.stop()
        await relaunched.transport.attempt(id)
        delivery = relaunched.store.delivery(id)!
        try expect(delivery.state == .sent && delivery.nextAttemptAt != nil, "a failed launch check is tried again")
        clock.advance(delivery.nextAttemptAt!.timeIntervalSince(clock.now))
        await relaunched.transport.runDue()
        try expect(relaunched.store.delivery(id)?.state == .received && elapsed() == Int(clock.now.timeIntervalSince(delivery.sentAt!)),
                   "the launch check finds it Received")

        // The file list lives in delivery.json: checking works without the envelope, and an empty
        // list is this Mac's error, never a reason to poll.
        (h, id) = try await frozen("files")
        delivery = h.store.delivery(id)!
        try expect(delivery.files.map(\.name) == ["context.json", "screenshot.png", "voice.wav"] && delivery.files.allSatisfy { $0.size > 0 && $0.sha256.count == 64 },
                   "the verifier's file list is saved at freeze")
        try FileManager.default.removeItem(at: h.store.outboxFolder.appendingPathComponent(id).appendingPathComponent("report.envelope"))
        answers = ["received"]; let asked = requests.count
        h.clock.advance(15); await h.transport.runDue()
        try expect(requests.count == asked + 1 && (requests.last?["attachments"] as? [[String: Any]])?.count == 3
                   && h.store.delivery(id)?.state == .received, "checking needs no local envelope")
        (h, id) = try await frozen("no-files")
        delivery = h.store.delivery(id)!; delivery.files = []; try h.store.save(delivery)
        let before = requests.count
        h.clock.advance(15); await h.transport.runDue()
        delivery = h.store.delivery(id)!
        try expect(requests.count == before && delivery.state == .sent && delivery.nextAttemptAt == nil && delivery.verifierState == "local_error_no_files",
                   "an empty file list stops checking without asking")
        // An older delivery.json without the file list and later fields still loads; checking it is a
        // local error, never a request.
        (h, id) = try await frozen("old-format")
        let file = h.store.outboxFolder.appendingPathComponent(id).appendingPathComponent("delivery.json")
        var old = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        for key in ["files", "contents", "previousEventIDs", "attempts", "verifyAttempts", "verifyAtLaunch", "launchCheckUsed",
                    "evidenceRemoved", "wordsOnly", "unansweredOnline", "checkLaunches"] { old.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        delivery = try expectValue(h.store.delivery(id), "an older delivery.json loads")
        try expect(delivery.files.isEmpty && !delivery.wordsOnly && delivery.checkLaunches == 0, "missing fields take their defaults")
        let beforeOld = requests.count
        h.clock.advance(15); await h.transport.runDue()
        try expect(requests.count == beforeOld && h.store.delivery(id)?.verifierState == "local_error_no_files", "and its empty file list is a local error")

        // No HTTP answer at all: checking ends after 24 hours with the Mac online, then settles as Sent.
        let day = Clock()
        (h, id) = try await frozen("unanswered-day", clock: day)
        answers = Array(repeating: nil, count: 2_000)
        h.transport.connectivity(false)
        for _ in 0..<200 { day.advance(600); await h.transport.runDue() }
        delivery = h.store.delivery(id)!
        try expect(delivery.nextAttemptAt != nil && delivery.unansweredOnline == 0, "time offline does not count")
        h.transport.connectivity(true)
        var rounds = 0
        while let next = h.store.delivery(id)?.nextAttemptAt, rounds < 1_000 {
            day.now = max(day.now, next); await h.transport.runDue(); rounds += 1
        }
        delivery = h.store.delivery(id)!
        try expect(delivery.state == .sent && delivery.nextAttemptAt == nil && delivery.verifierState == "unanswered" && delivery.isSettled
                   && delivery.unansweredOnline >= BugReportTransport.unansweredLimit && delivery.unansweredOnline < BugReportTransport.unansweredLimit + 900,
                   "24 hours online without an answer settles as Sent (\(Int(delivery.unansweredOnline)) s)")
        try expect(h.model.receipts.first?.title == "Sent · \(BugReportText.shortID(id))", "the receipt stays Sent")

        // Or after 3 launches that found it still unanswered past its window.
        let launches = Clock()
        (h, id) = try await frozen("unanswered-launches", clock: launches)
        answers = Array(repeating: nil, count: 2_000)
        for _ in 0..<20 { launches.advance(60); await h.transport.runDue() }
        try expect(h.store.delivery(id)?.nextAttemptAt != nil, "still checking after its window")
        for launch in 1...3 {
            let relaunch = harness(root.appendingPathComponent("unanswered-launches"), clock: launches)
            relaunch.transport.start(watchConnectivity: false); relaunch.transport.stop()
            delivery = relaunch.store.delivery(id)!
            try expect((delivery.nextAttemptAt == nil) == (launch == 3), "launch \(launch) of 3")
        }
        try expect(delivery.isSettled && delivery.verifierState == "unanswered", "3 launches without an answer settle as Sent")

        return ["verifier: first check at 15 s with elapsed_seconds, pending then received, mismatch and not_found are Couldn't confirm delivery, Send again resets the count, 503/422/non-JSON/unreachable stay Sent, a lost network never ends checking, checks at most 5 minutes apart and on reconnection, one more check at launch, file list kept in delivery.json, older delivery.json loads, no answer settles after 24 h online or 3 launches"]
    }

    // MARK: Outbox, draft and Save a copy

    @MainActor static func outboxChecks(root: URL) async throws -> [String] {
        let sentry = FakeSentry()
        BugReportStub.route = { sentry.handle($0) }
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        // Private files.
        var h = harness(root.appendingPathComponent("private"), folder: exports)
        try fill(h.model)
        func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        try expect(mode(h.store.root) == 0o700 && mode(h.store.draftFolder) == 0o700 && mode(h.store.draftFolder.appendingPathComponent("draft.json")) == 0o600
                   && mode(h.store.draftFolder.appendingPathComponent("screenshot.png")) == 0o600, "draft folders 0700, files 0600")

        // Draft resume in a new owner, as after a relaunch.
        let resumed = harness(root.appendingPathComponent("private"), folder: exports).model
        try expect(resumed.explanation == h.model.explanation && resumed.replyEmail == "reporter@example.com" && resumed.screenshot == h.model.screenshot
                   && resumed.voiceSeconds == h.model.voiceSeconds && resumed.draft?.context.errorCode == "snap.capture_failed", "the unfinished draft resumes")
        resumed.open(origin: .help)
        try expect(resumed.draft?.context.errorCode == "snap.capture_failed" && resumed.explanation == h.model.explanation, "Help keeps the unfinished draft and its problem")

        // An empty composer leaves nothing; an empty draft takes the newest origin.
        let empty = harness(root.appendingPathComponent("empty")).model
        empty.open(origin: .help); empty.persist()
        try expect(empty.store.loadDraft() == nil, "an empty draft is not saved")
        empty.open(origin: BugReportOrigin(surface: .dictate, errorCode: "dictate.failed"))
        try expect(empty.draft?.origin.errorCode == "dictate.failed" && empty.draft?.context.surface == .dictate, "an empty draft takes the newest origin")
        empty.explanation = "Typed"; empty.open(origin: BugReportOrigin(surface: .snap, errorCode: "snap.capture_failed"))
        try expect(empty.draft?.origin.errorCode == "dictate.failed", "a started draft keeps its own problem")

        // Over-limit text is kept and blocks Send with a reason; nothing is cut.
        let long = String(repeating: "y", count: 2_100)
        empty.explanation = long
        try expect(empty.explanation == long && !empty.canSend && empty.explanationProblem != nil && empty.counter == "2,100 / 2,048", "over-limit text is kept, counted and blocks Send")
        empty.explanation = String(repeating: "y", count: 1_800)
        try expect(empty.counter == nil && empty.canSend, "under 90% shows no counter")
        empty.replyEmail = "x@"
        try expect(!empty.canSend && empty.emailProblem != nil, "an invalid email blocks Send")

        // Save a copy: fixed names, a new folder each time, nothing overwritten.
        h.model.send()
        let id = h.store.deliveries()[0].id
        let taken = exports.appendingPathComponent("Workbench report \(BugReportText.shortID(id))", isDirectory: true)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: false)
        try Data("someone else's".utf8).write(to: taken.appendingPathComponent("context.json"))
        h.model.perform(.saveCopy, on: id)
        h.model.perform(.saveCopy, on: id)
        let names = try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted()
        let short = BugReportText.shortID(id)
        try expect(names == ["Workbench report \(short)", "Workbench report \(short) 2", "Workbench report \(short) 3"], "copies get new folders: \(names)")
        try expect(try Data(contentsOf: taken.appendingPathComponent("context.json")) == Data("someone else's".utf8), "an existing folder is untouched")
        let copy = exports.appendingPathComponent("Workbench report \(short) 2", isDirectory: true)
        let items = try BugReportEnvelope.parse(try h.store.envelope(id)).items
        try expect(try FileManager.default.contentsOfDirectory(atPath: copy.path).sorted() == ["context.json", "screenshot.png", "voice.wav"]
                   && (try Data(contentsOf: copy.appendingPathComponent("context.json"))) == items[1].payload
                   && (try Data(contentsOf: copy.appendingPathComponent("screenshot.png"))) == items[2].payload
                   && (try Data(contentsOf: copy.appendingPathComponent("voice.wav"))) == items[3].payload, "the copy holds exactly the report's files")
        let entry = h.store.outboxFolder.appendingPathComponent(id)
        try expect(mode(h.store.outboxFolder) == 0o700 && mode(entry) == 0o700 && mode(entry.appendingPathComponent("report.envelope")) == 0o600
                   && mode(entry.appendingPathComponent("delivery.json")) == 0o600, "outbox folders 0700, files 0600")

        // Quota: entries and bytes are reserved before Send; delivered copies make room, unsent never do.
        var limits = BugReportStore.Limits(); limits.entries = 2
        h = harness(root.appendingPathComponent("quota"), limits: limits, folder: exports)
        for _ in 0..<2 { try fill(h.model, screenshot: false, voice: false); h.model.send() }
        try fill(h.model, screenshot: false, voice: false)
        h.model.send()
        try expect(h.store.deliveries().count == 2 && h.model.problemAction == .saveCopy && h.store.loadDraft() != nil, "a full outbox refuses and keeps the draft")
        try expect(h.model.problem?.contains("2 reports that haven't been sent") == true, "the refusal counts the reports not yet sent")
        let countBefore = try FileManager.default.contentsOfDirectory(atPath: exports.path).count
        h.model.saveDraftCopy()
        try expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).count == countBefore + 1, "the refused draft can be saved as a copy")
        var oldest = h.store.deliveries().last!
        oldest.state = .sent; oldest.sentAt = h.clock.now; oldest.nextAttemptAt = nil
        try h.store.save(oldest)
        h.model.send()
        try expect(h.store.deliveries().count == 3 && h.store.delivery(oldest.id)?.evidenceRemoved == true && h.model.problem == nil,
                   "a delivered report's local copy makes room; unsent reports are kept")

        // With a verifier: a Sent report still being checked keeps its copy; a settled one makes room.
        let checked = BugReportDestination(dsn: dsn, verifier: verifier, environment: "production", isOverride: false)
        h = harness(root.appendingPathComponent("quota-verifier"), destination: checked, limits: limits, folder: exports)
        for _ in 0..<2 { try fill(h.model, screenshot: false, voice: false); h.model.send() }
        var pair = h.store.deliveries()
        var checking = pair[1], settled = pair[0]
        checking.state = .sent; checking.sentAt = h.clock.now; checking.verifyUntil = h.clock.now + 960; checking.nextAttemptAt = h.clock.now + 15
        settled.state = .sent; settled.sentAt = h.clock.now; settled.nextAttemptAt = nil
        try h.store.save(checking); try h.store.save(settled)
        try fill(h.model, screenshot: false, voice: false); h.model.send()
        try expect(h.store.delivery(checking.id)?.evidenceRemoved == false && h.store.delivery(settled.id)?.evidenceRemoved == true
                   && h.store.deliveries().count == 3, "only a settled Sent report's copy makes room")
        pair = h.store.deliveries()
        try fill(h.model, screenshot: false, voice: false); h.model.send()
        try expect(h.model.problemAction == .saveCopy && h.store.delivery(checking.id)?.evidenceRemoved == false, "a report still being checked is never evicted")
        try expect(h.model.problem?.contains("1 report that hasn't been sent") == true, "only the unsent report is counted: \(h.model.problem ?? "")")
        for var other in h.store.deliveries() where other.isUnsent {
            other.state = .sent; other.sentAt = h.clock.now; other.verifyUntil = h.clock.now + 960; other.nextAttemptAt = h.clock.now + 15
            try h.store.save(other)
        }
        h.model.send()
        try expect(h.model.problem?.contains("outbox is full for now") == true && h.model.problem?.contains("haven't been sent") == false
                   && h.model.problem?.contains("unsent") == false, "with only sent reports being checked, no report is called unsent")

        // The report describes the moment the person chose to report: a draft resumed in a later
        // launch keeps its open-time build, tools, surface and code; Send reads access and speech again.
        var opened = BugReportContext(); opened.activeTools = [.draw]; opened.microphone = .authorized
        opened.recognitionProvider = .parakeet; opened.recognitionReady = true
        h = harness(root.appendingPathComponent("refresh"), folder: exports)
        h.model.services.context = { origin in var context = opened; context.surface = origin.surface; context.errorCode = origin.errorCode; return context }
        try fill(h.model, screenshot: false, voice: false)
        let later = harness(root.appendingPathComponent("refresh"), folder: exports)
        var newer = build; newer.version = "2.6.0"; newer.build = "20261008000000"
        var now = BugReportContext(); now.activeTools = [.timer]; now.microphone = .denied; now.screenCapture = .authorized
        now.recognitionProvider = .localServer; now.recognitionReady = false
        later.model.services.build = { newer }
        later.model.services.context = { origin in var context = now; context.surface = .home; context.errorCode = "dictate.failed"; _ = origin; return context }
        later.model.open(origin: .help)
        later.model.send()
        let sentManifest = try JSONSerialization.jsonObject(with: try BugReportEnvelope.parse(try later.store.envelope(later.store.deliveries()[0].id)).items[1].payload) as! [String: Any]
        let sentContext = sentManifest["context"] as? [String: Any], sentBuild = sentManifest["build"] as? [String: Any]
        try expect(sentBuild?["version"] as? String == "2.5.0" && sentBuild?["build"] as? String == "20261007010203"
                   && sentContext?["active_tools"] as? [String] == ["draw"], "a resumed draft keeps the build and tools from when it was reported")
        try expect(sentContext?["surface"] as? String == "snap" && sentContext?["error_code"] as? String == "snap.capture_failed", "and the origin's surface and problem code")
        let recognition = sentContext?["recognition"] as? [String: Any]
        try expect((sentContext?["permissions"] as? [String: String]) == ["microphone": "denied", "screen_capture": "authorized"]
                   && recognition?["provider"] as? String == "local_server" && recognition?["ready"] as? Bool == false,
                   "Send reads access and speech readiness again")

        // Add screenshot never captures without Screen Recording, and never prompts.
        h = harness(root.appendingPathComponent("screen-off"), folder: exports)
        var captured = false
        h.model.services.screenCaptureGranted = { false }
        h.model.services.captureScreenshot = { captured = true; return nil }
        h.model.open(origin: .help)
        await h.model.addScreenshot()
        try expect(!captured && h.model.problemAction == .screenAccess && h.model.problem == BugReportModel.screenAccessOff && !h.model.capturing,
                   "Screen Recording off offers Choose image… and Open System Settings… without capturing")
        var bytes = BugReportStore.Limits(); bytes.bytes = 1_024
        h = harness(root.appendingPathComponent("bytes"), limits: bytes)
        try fill(h.model)
        h.model.send()
        try expect(h.store.deliveries().isEmpty && h.model.problemAction == .saveCopy, "the byte reservation refuses a large report")
        h = harness(root.appendingPathComponent("disk"), capacity: 1_024 * 1_024)
        try fill(h.model)
        h.model.send()
        try expect(h.store.deliveries().isEmpty && h.model.problem?.contains("room") == true && h.store.loadDraft() != nil, "a full disk refuses truthfully")

        // No inbox in this build: Send is unavailable and Save a copy works.
        h = harness(root.appendingPathComponent("unavailable"), destination: nil, folder: exports)
        try fill(h.model)
        try expect(!h.model.available && !h.model.canSend && h.model.canSubmit, "a build without a DSN cannot send")
        h.model.send()
        try expect(h.store.deliveries().isEmpty && sentry.bodies.isEmpty, "Send does nothing without a DSN")
        let exported = try FileManager.default.contentsOfDirectory(atPath: exports.path).count
        h.model.saveDraftCopy()
        try expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).count == exported + 1 && h.model.note != nil, "Save a copy works without a DSN")

        // The destination is read again when the composer opens, so an override needs no relaunch.
        var current: BugReportDestination?
        h.model.services.currentDestination = { current }
        current = .init(dsn: dsn, verifier: nil, environment: "preview", isOverride: true)
        h.model.open(origin: .help)
        try expect(h.model.available && h.model.destination?.environment == "preview", "an override set later applies when the composer opens")

        // Removal of a delivered receipt, and pruning keeps unsent reports.
        h = harness(root.appendingPathComponent("prune"))
        try fill(h.model, screenshot: false, voice: false); h.model.send()
        let unsent = h.store.deliveries()[0].id
        h.clock.advance(200 * 86_400)
        h.store.prune()
        try expect(h.store.delivery(unsent) != nil, "pruning never removes an unsent report")
        return ["outbox: 0700/0600, draft resume and origin rules, over-limit text kept, Save a copy without overwrite, entry/byte/disk quota with the draft kept, only settled copies make room (with a verifier), refusal names only unsent reports, facts from the moment of reporting with fresh access and speech, older delivery.json loads, Screen Recording preflight, no-DSN build"]
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
}

// MARK: Stub servers

/// A URLProtocol for the checks' own session. Each request goes to `route`.
final class BugReportStub: URLProtocol {
    struct Request { var method: String; var url: URL; var headers: [String: String]; var body: Data }
    enum Reply {
        case status(Int, [String: String], Data)
        case failure(URLError.Code)
        /// Fails after reading the whole request body, as an upload cut off part-way would.
        case failureAfterSending(URLError.Code)
    }
    nonisolated(unsafe) static var route: ((Request) -> Reply)?
    static func reset() { route = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let incoming = Request(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        switch Self.route?(incoming) ?? .failure(.cannotConnectToHost) {
        case .status(let code, let headers, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .failureAfterSending(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [BugReportTransport.bytesSentKey: body.count]))
        }
    }
}

/// Sentry as the checks need it: it keeps one event per event ID and answers from a script.
final class FakeSentry: @unchecked Sendable {
    enum Reply {
        case status(Int, [String: String])
        case failure(URLError.Code)
        /// Sentry stores the event, but the reply never arrives.
        case lostResponse
        /// The upload times out after its bytes went, so it may have arrived.
        case timeoutAfterUpload
    }
    var script: [Reply] = []
    var bodies: [Data] = []
    var events: [String: Data] = [:]
    var authorizations: [String] = []
    var contentTypes: [String] = []
    var paths: [String] = []
    var lastEventID: String?
    var onRequest: (() -> Void)?
    func count(_ id: String) -> Int { bodies.filter { (try? BugReportEnvelope.parse($0).header["event_id"] as? String) == id }.count }

    func handle(_ request: BugReportStub.Request) -> BugReportStub.Reply {
        onRequest?()
        bodies.append(request.body)
        authorizations.append(request.headers["X-Sentry-Auth"] ?? "")
        contentTypes.append(request.headers["Content-Type"] ?? "")
        paths.append(request.url.path.hasSuffix("/") ? request.url.path : request.url.path + "/")
        guard let parsed = try? BugReportEnvelope.parse(request.body), let id = parsed.header["event_id"] as? String else {
            return .status(400, [:], Data())
        }
        lastEventID = id
        let reply = script.isEmpty ? .status(200, [:]) : script.removeFirst()
        switch reply {
        case .status(let code, let headers):
            if (200..<300).contains(code), headers["X-Sentry-Rate-Limits"] == nil || headers["X-Sentry-Rate-Limits"]?.contains("feedback") == false {
                if events[id] == nil { events[id] = request.body }
            }
            return .status(code, headers.merging(["Content-Type": "application/json"]) { a, _ in a }, Data(#"{"id":"\#(id)"}"#.utf8))
        case .failure(let code): return .failure(code)
        case .timeoutAfterUpload: return .failureAfterSending(.timedOut)
        case .lostResponse:
            if events[id] == nil { events[id] = request.body }
            return .failure(.networkConnectionLost)
        }
    }
}

// MARK: Schema validator

/// The JSON Schema keywords docs/bug-reporting-schema.md uses, with format assertions on.
struct BugReportSchemaValidator {
    let schema: [String: Any]

    func errors(_ value: Any) -> [String] { validate(value, schema, "$") }

    private func validate(_ value: Any, _ schema: [String: Any], _ path: String) -> [String] {
        var errors: [String] = []
        if let type = schema["type"] {
            let types = (type as? [String]) ?? [(type as? String) ?? ""]
            if !types.contains(where: { matches(value, $0) }) { return ["\(path): expected \(types)"] }
        }
        if let constant = schema["const"], !equal(value, constant) { errors.append("\(path): const") }
        if let options = schema["enum"] as? [Any], !options.contains(where: { equal(value, $0) }) { errors.append("\(path): enum") }
        if let text = value as? String, !(value is NSNumber) {
            let count = text.unicodeScalars.count
            if let maximum = schema["maxLength"] as? Int, count > maximum { errors.append("\(path): maxLength") }
            if let minimum = schema["minLength"] as? Int, count < minimum { errors.append("\(path): minLength") }
            if let pattern = schema["pattern"] as? String, text.range(of: pattern, options: .regularExpression) == nil { errors.append("\(path): pattern") }
            if let format = schema["format"] as? String {
                let formats = ["date-time": #"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$"#,
                               "email": #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#]
                if let expression = formats[format], text.range(of: expression, options: .regularExpression) == nil { errors.append("\(path): format \(format)") }
            }
        }
        if let number = value as? NSNumber, !isBool(number) {
            let double = number.doubleValue
            if let minimum = schema["minimum"] as? Double, double < minimum { errors.append("\(path): minimum") }
            if let maximum = schema["maximum"] as? Double, double > maximum { errors.append("\(path): maximum") }
            if let minimum = schema["exclusiveMinimum"] as? Double, double <= minimum { errors.append("\(path): exclusiveMinimum") }
        }
        if let object = value as? [String: Any] {
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { errors.append("\(path).\(key): required") }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, item) in object {
                if let inner = properties[key] as? [String: Any] { errors += validate(item, inner, "\(path).\(key)") }
                else if schema["additionalProperties"] as? Bool == false { errors.append("\(path).\(key): additional property") }
            }
        }
        if let array = value as? [Any] {
            if let maximum = schema["maxItems"] as? Int, array.count > maximum { errors.append("\(path): maxItems") }
            if let minimum = schema["minItems"] as? Int, array.count < minimum { errors.append("\(path): minItems") }
            if schema["uniqueItems"] as? Bool == true {
                let encoded = array.map { (try? JSONSerialization.data(withJSONObject: [$0], options: .sortedKeys)) ?? Data() }
                if Set(encoded).count != encoded.count { errors.append("\(path): uniqueItems") }
            }
            if let items = schema["items"] as? [String: Any] {
                for (index, item) in array.enumerated() { errors += validate(item, items, "\(path)[\(index)]") }
            }
            if let contains = schema["contains"] as? [String: Any] {
                let found = array.filter { validate($0, contains, path).isEmpty }.count
                let minimum = schema["minContains"] as? Int ?? 1
                if found < minimum { errors.append("\(path): minContains") }
                if let maximum = schema["maxContains"] as? Int, found > maximum { errors.append("\(path): maxContains") }
            }
        }
        for item in schema["allOf"] as? [[String: Any]] ?? [] { errors += validate(value, item, path) }
        if let any = schema["anyOf"] as? [[String: Any]], !any.contains(where: { validate(value, $0, path).isEmpty }) { errors.append("\(path): anyOf") }
        if let one = schema["oneOf"] as? [[String: Any]], one.filter({ validate(value, $0, path).isEmpty }).count != 1 { errors.append("\(path): oneOf") }
        return errors
    }

    private func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
    private func matches(_ value: Any, _ type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String && !(value is NSNumber)
        case "null": return value is NSNull
        case "boolean": return (value as? NSNumber).map(isBool) ?? false
        case "number": return (value as? NSNumber).map { !isBool($0) } ?? false
        case "integer": return (value as? NSNumber).map { !isBool($0) && $0.doubleValue.rounded() == $0.doubleValue } ?? false
        default: return false
        }
    }
    private func equal(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? NSNumber, let b = b as? NSNumber { return isBool(a) == isBool(b) && a == b }
        if let a = a as? String, let b = b as? String { return a == b }
        return a is NSNull && b is NSNull
    }
}

/// A strict reader that reports a repeated key in any JSON object.
enum BugReportJSON {
    static func duplicateKeys(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var index = 0
        var found = false
        func space() { while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 } }
        func string() -> String? {
            guard index < bytes.count, bytes[index] == 0x22 else { return nil }
            let start = index; index += 1
            while index < bytes.count, bytes[index] != 0x22 { index += bytes[index] == 0x5C ? 2 : 1 }
            index += 1
            return (try? JSONSerialization.jsonObject(with: Data(bytes[start..<min(index, bytes.count)]), options: .fragmentsAllowed)) as? String
        }
        func value() {
            space()
            guard index < bytes.count else { return }
            switch bytes[index] {
            case 0x7B:
                index += 1; var keys = Set<String>()
                space()
                if index < bytes.count, bytes[index] == 0x7D { index += 1; return }
                while index < bytes.count {
                    space()
                    guard let key = string() else { return }
                    if !keys.insert(key).inserted { found = true }
                    space(); index += 1; value(); space()
                    if index < bytes.count, bytes[index] == 0x2C { index += 1; continue }
                    index += 1; return
                }
            case 0x5B:
                index += 1; space()
                if index < bytes.count, bytes[index] == 0x5D { index += 1; return }
                while index < bytes.count {
                    value(); space()
                    if index < bytes.count, bytes[index] == 0x2C { index += 1; continue }
                    index += 1; return
                }
            case 0x22: _ = string()
            default: while index < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
            }
        }
        value()
        return found
    }
}
