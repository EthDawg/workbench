import AppKit
import AVFoundation
import CryptoKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

// Report a problem (#296): the version 1 manifest that becomes `context.json`, its safe
// context and the two media files it may describe. docs/bug-reporting.md owns the contract
// and docs/bug-reporting-schema.md the JSON Schema; `--check-bug-report` validates what this
// file produces against that schema. Everything here is a pure value or function: no window,
// microphone, network or Keychain.

enum BugReportError: LocalizedError, Equatable {
    case message(String)
    /// The outbox or the disk cannot hold the report. Nothing was sent or started; the draft is
    /// kept and Save a copy is offered.
    case full(String)
    var errorDescription: String? {
        switch self { case .message(let text), .full(let text): return text }
    }
}

enum BugReportLimits {
    static let explanationScalars = 2_048
    static let explanationBytes = 4_096
    /// Sentry's widget guidance: a live counter from 90% of the limit.
    static let explanationCounterFrom = 1_844
    static let emailBytes = 254
    static let manifestBytes = 32 * 1_024
    static let screenshotBytes = 8 * 1_024 * 1_024
    static let voiceBytes = 4 * 1_024 * 1_024
    static let voiceSeconds = 60
    static let payloadBytes = 16 * 1_024 * 1_024
    /// A chosen PNG or JPEG is read only up to this size and pixel count.
    static let importBytes = 25 * 1_024 * 1_024
    static let imagePixels = 40_000_000
    static let imageEdge = 16_384
    static let outboxEntries = 20
    static let outboxBytes: Int64 = 100 * 1_024 * 1_024
    /// Sentry trims the feedback context beyond this normalisation budget; a report that would be
    /// trimmed is refused before it is frozen.
    static let feedbackContextBytes = 8_192
}

// MARK: Safe context

/// Where the report was opened from, recorded where the problem was raised (never read back
/// from a message's words).
enum BugReportSurface: String, Codable, CaseIterable {
    case help, home, dictate, meetings, snap, readback, present, personas, history, library, settings, unknown

    /// The window page a route belongs to. Draw has no schema value, so it is unknown.
    static func page(_ route: String) -> BugReportSurface {
        switch route {
        case "home": return .home
        case "dictate", "dictionary": return .dictate
        case "meeting": return .meetings
        case "snap": return .snap
        case "readback": return .readback
        case "present": return .present
        case "personas": return .personas
        case "history": return .history
        case "library", "resources", "packs": return .library
        case "settings", "models", "shortcuts", "connections", "general": return .settings
        default: return .unknown
        }
    }
}

enum BugReportTool: String, Codable, CaseIterable {
    case dictate, meetings, snap, readback, draw, present, persona, timer
    case legacyRead = "legacy_read"
}

enum BugReportPermission: String, Codable, CaseIterable {
    case notRequested = "not_requested", authorized, denied, restricted, unknown

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notRequested
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .unknown
        }
    }
    /// A plain yes/no check cannot tell refused from never asked, so false stays unknown.
    init(granted: Bool) { self = granted ? .authorized : .unknown }
}

enum BugReportRecognitionProvider: String, Codable, CaseIterable {
    case parakeet, localServer = "local_server", unknown
}

/// The door the composer was opened from. A typed error code travels with the problem from
/// where it was raised.
struct BugReportOrigin: Codable, Equatable {
    var surface: BugReportSurface
    var errorCode: String?
    static let help = BugReportOrigin(surface: .help, errorCode: nil)
}

/// The allowlisted facts in `context`. Unknown or unavailable facts are left out.
struct BugReportContext: Codable, Equatable {
    var surface: BugReportSurface?
    var activeTools: [BugReportTool] = []
    var microphone: BugReportPermission?
    var screenCapture: BugReportPermission?
    var accessibility: BugReportPermission?
    var recognitionProvider: BugReportRecognitionProvider?
    var recognitionReady: Bool?
    var errorCode: String?

    func object(screenshot: BugReportImageInfo?) -> [String: Any] {
        var result: [String: Any] = [:]
        if let surface { result["surface"] = surface.rawValue }
        var tools: [String] = []
        for tool in activeTools where !tools.contains(tool.rawValue) { tools.append(tool.rawValue) }
        if !tools.isEmpty { result["active_tools"] = tools }
        var permissions: [String: Any] = [:]
        if let microphone { permissions["microphone"] = microphone.rawValue }
        if let screenCapture { permissions["screen_capture"] = screenCapture.rawValue }
        if let accessibility { permissions["accessibility"] = accessibility.rawValue }
        if !permissions.isEmpty { result["permissions"] = permissions }
        if let recognitionProvider {
            result["recognition"] = ["provider": recognitionProvider.rawValue, "ready": recognitionReady.map { $0 as Any } ?? NSNull()]
        }
        if let errorCode, BugReportText.isErrorCode(errorCode) { result["error_code"] = errorCode }
        if let screenshot { result["screenshot"] = ["width": screenshot.width, "height": screenshot.height, "scale": screenshot.scale] }
        return result
    }
}

/// The running build, read from the package's own Info.plist (WorkbenchBuild), never from the
/// website's latest release.
struct BugReportBuild: Codable, Equatable {
    var edition: String
    var version: String
    var build: String
    var revision: String
    var dirty: Bool?
    var kind: String
    var osVersion: String
    var osBuild: String

    static func running(_ info: WorkbenchBuild = WorkbenchBuild()) -> BugReportBuild {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        var osBuild = "unknown"
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 { osBuild = String(cString: bytes) }
        }
        let revision = info.revision.lowercased()
        let kind = info.released ? "release" : (info.info["WorkbenchBuildKind"] as? String == "local" ? "local" : "unknown")
        return BugReportBuild(edition: info.preview ? "preview" : "stable",
            version: BugReportText.safe(info.info["CFBundleShortVersionString"] as? String, limit: 64),
            build: BugReportText.safe(info.info["CFBundleVersion"] as? String, limit: 64),
            revision: revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) == nil ? "unknown" : revision,
            dirty: info.info["WorkbenchSourceDirty"] as? Bool, kind: kind,
            osVersion: BugReportText.safe("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", limit: 64),
            osBuild: BugReportText.safe(osBuild, limit: 32))
    }

    var object: [String: Any] {
        ["edition": edition, "version": version, "build": build, "revision": revision,
         "dirty": dirty.map { $0 as Any } ?? NSNull(), "kind": kind, "os_version": osVersion, "os_build": osBuild]
    }
}

struct BugReportImageInfo: Codable, Equatable {
    var width: Int
    var height: Int
    var scale: Double
}

struct BugReportAttachment: Codable, Equatable {
    static let screenshot = "screenshot.png"
    static let voice = "voice.wav"
    var name: String
    var contentType: String
    var bytes: Int
    var sha256: String

    init(name: String, data: Data) {
        self.name = name
        contentType = name == Self.screenshot ? "image/png" : "audio/wav"
        bytes = data.count
        sha256 = BugReportText.sha256(data)
    }
    var object: [String: Any] { ["name": name, "content_type": contentType, "bytes": bytes, "sha256": sha256] }
}

// MARK: Manifest

/// The reviewed report, frozen into exact bytes. Clients retry those bytes and never
/// re-serialise a mutable object under the same report ID.
struct BugReportManifest {
    var reportID: String
    var createdAt: Date?
    var explanation: String
    var replyEmail: String?
    var build: BugReportBuild
    var context: BugReportContext
    var screenshot: BugReportImageInfo?
    var attachments: [BugReportAttachment]

    /// A random UUIDv4 in the schema's lowercase form.
    static func newReportID() -> String { UUID().uuidString.lowercased() }

    var object: [String: Any] {
        var result: [String: Any] = [
            "schema_version": 1, "report_id": reportID,
            "created_at": createdAt.map { BugReportText.timestamp($0) as Any } ?? NSNull(),
            "explanation": explanation, "build": build.object,
            "context": context.object(screenshot: attachments.contains { $0.name == BugReportAttachment.screenshot } ? screenshot : nil),
            "attachments": attachments.map(\.object)]
        if let replyEmail, !replyEmail.isEmpty { result["reply_email"] = replyEmail }
        return result
    }

    /// Compact, key-sorted UTF-8 JSON, checked against the byte and content rules the schema
    /// cannot express.
    func encoded() throws -> Data {
        if let problem = BugReportText.explanationProblem(explanation) { throw BugReportError.message(problem) }
        if let replyEmail, let problem = BugReportText.emailProblem(replyEmail) { throw BugReportError.message(problem) }
        guard BugReportText.hasVisibleText(explanation) || !attachments.isEmpty else {
            throw BugReportError.message("Describe the problem, or add a screenshot or voice note.")
        }
        guard Set(attachments.map(\.name)).count == attachments.count,
              attachments.allSatisfy({ [BugReportAttachment.screenshot, BugReportAttachment.voice].contains($0.name) && $0.bytes > 0 }) else {
            throw BugReportError.message("This report's attachments are not valid.")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= BugReportLimits.manifestBytes else { throw BugReportError.message("This report's details are too large to send.") }
        return data
    }
}

// MARK: Text rules

enum BugReportText {
    /// ECMAScript's `\s` (the schema's pattern) together with Python's `str.isspace` (Sentry's
    /// feedback check): text made only of either counts as blank, so a report can never pass
    /// one check and fail the other.
    static let whitespace: Set<UInt32> = Set([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] + Array(0x2000...0x200A))

    static func hasVisibleText(_ text: String) -> Bool { text.unicodeScalars.contains { !whitespace.contains($0.value) } }

    /// The explanation's limits, in words a person can act on. Nil when it fits.
    static func explanationProblem(_ text: String) -> String? {
        let scalars = text.unicodeScalars.count
        if scalars > BugReportLimits.explanationScalars {
            return "Shorten your description to 2,048 characters or fewer. It has \(scalars.formatted())."
        }
        if text.utf8.count > BugReportLimits.explanationBytes {
            return "Shorten your description. Some characters, such as emoji, take extra room, and this one is over the limit."
        }
        return nil
    }

    /// The same expression ajv-formats uses for `format: email`, plus the byte limit.
    private static let emailPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$",
        options: [.caseInsensitive])
    static func isValidEmail(_ text: String) -> Bool {
        let bytes = text.utf8.count
        guard bytes >= 3, bytes <= BugReportLimits.emailBytes, text.allSatisfy(\.isASCII) else { return false }
        return emailPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func emailProblem(_ text: String) -> String? {
        isValidEmail(text) ? nil : "Check the email address, or leave it empty."
    }

    static func isErrorCode(_ text: String) -> Bool { text.range(of: "^[a-z][a-z0-9_.]{0,63}$", options: .regularExpression) != nil }

    /// A build or OS string without control characters, bounded, or `unknown` when empty.
    static func safe(_ text: String?, limit: Int) -> String {
        let cleaned = String(String.UnicodeScalarView((text ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        let bounded = String(String.UnicodeScalarView(cleaned.unicodeScalars.prefix(limit)))
        return bounded.isEmpty ? "unknown" : bounded
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
    static func preciseTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// What the receipt calls a report: the report ID's first eight characters.
    static func shortID(_ reportID: String) -> String { String(reportID.prefix(8)) }
}

// MARK: Media

/// A screenshot ready to send: PNG bytes without metadata, and its pixel size and scale.
struct BugReportImage: Equatable {
    var png: Data
    var width: Int
    var height: Int
    var scale: Double
    var info: BugReportImageInfo { .init(width: width, height: height, scale: scale) }
}

enum BugReportMedia {
    /// A capture or a chosen PNG/JPEG, decoded within the size limits, upright, and re-encoded as
    /// PNG with no metadata. A result over 8 MiB or wider than the schema allows is scaled down.
    static func image(_ data: Data, scale: Double, sourceLimit: Int) throws -> BugReportImage {
        let unsupported = BugReportError.message("Choose a PNG or JPEG image under 25 MB and 40 megapixels.")
        guard !data.isEmpty, data.count <= sourceLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Int64(width) * Int64(height) <= Int64(BugReportLimits.imagePixels) else { throw unsupported }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height), kCGImageSourceShouldCacheImmediately: true]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw unsupported }
        var factor = min(1, Double(BugReportLimits.imageEdge) / Double(max(upright.width, upright.height)))
        let sourceScale = scale.isFinite && scale > 0 ? min(scale, 8) : 1
        while true {
            let image = factor < 1 ? try resized(upright, factor: factor) : upright
            let png = try encodePNG(image)
            if png.count <= BugReportLimits.screenshotBytes {
                return BugReportImage(png: png, width: image.width, height: image.height, scale: max(0.001, (sourceScale * factor * 1000).rounded() / 1000))
            }
            guard min(image.width, image.height) > 256 else { throw BugReportError.message("This image is too large to send. Choose a smaller one.") }
            factor *= 0.75
        }
    }

    static func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw BugReportError.message("The screenshot could not be prepared.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BugReportError.message("The screenshot could not be prepared.") }
        return output as Data
    }

    private static func resized(_ image: CGImage, factor: Double) throws -> CGImage {
        let width = max(1, Int((Double(image.width) * factor).rounded())), height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BugReportError.message("The screenshot could not be prepared.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw BugReportError.message("The screenshot could not be prepared.") }
        return result
    }

    /// The pixel size of a PNG this report holds.
    static func pngSize(_ data: Data) throws -> (width: Int, height: Int) {
        guard data.count >= 24, data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw BugReportError.message("The screenshot is not a readable PNG.") }
        return (width, height)
    }

    /// Mono 16 kHz 16-bit PCM in a 44-byte RIFF header: a WAV anything can play, with no other
    /// chunks. Longer recordings are cut at 60 seconds.
    static func canonicalWAV(_ data: Data) throws -> (wav: Data, seconds: Double) {
        let invalid = BugReportError.message("The voice note could not be read.")
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF", String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { throw invalid }
        var offset = 12
        var format: (tag: UInt16, channels: UInt16, rate: UInt32, bits: UInt16)?
        var samples: ArraySlice<UInt8>?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = Int(u32(offset + 4))
            let start = offset + 8
            let end = min(bytes.count, start + size)
            if id == "fmt ", size >= 16, end - start >= 16 {
                var tag = u16(start)
                if tag == 0xFFFE, size >= 40, end - start >= 40 { tag = u16(start + 24) }
                format = (tag, u16(start + 2), u32(start + 4), u16(start + 14))
            } else if id == "data" {
                samples = bytes[start..<end]
            }
            offset = start + size + (size % 2)
        }
        guard let format, let samples else { throw invalid }
        guard format.tag == 1, format.channels == 1, format.rate == 16_000, format.bits == 16 else {
            throw BugReportError.message("The voice note is not in the expected format.")
        }
        var pcm = Data(samples)
        let maximum = BugReportLimits.voiceSeconds * 32_000
        if pcm.count > maximum { pcm = pcm.prefix(maximum) }
        if pcm.count % 2 == 1 { pcm = pcm.dropLast() }
        guard !pcm.isEmpty else { throw BugReportError.message("Nothing was recorded.") }
        return (wavHeader(dataBytes: pcm.count) + pcm, Double(pcm.count) / 32_000)
    }

    /// The seconds in a canonical WAV this report holds; anything else is refused.
    static func wavSeconds(_ data: Data) throws -> Double {
        guard data.count > 44, data.prefix(44) == wavHeader(dataBytes: data.count - 44), data.count - 44 <= BugReportLimits.voiceSeconds * 32_000 else {
            throw BugReportError.message("The voice note is not a 16 kHz mono WAV.")
        }
        return Double(data.count - 44) / 32_000
    }

    static func wavHeader(dataBytes: Int) -> Data {
        var header = Data()
        func append(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + dataBytes)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1); append32(16_000); append32(32_000); append16(2); append16(16)
        append("data"); append32(UInt32(dataBytes))
        return header
    }

    /// A quiet synthetic tone for fixtures; nothing is recorded.
    static func syntheticWAV(seconds: Double) -> Data {
        let count = Int(seconds * 16_000)
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let value = Int16(1_200 * sin(Double(index) * 2 * .pi * 220 / 16_000))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return wavHeader(dataBytes: pcm.count) + pcm
    }
}
