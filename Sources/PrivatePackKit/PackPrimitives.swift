import CryptoKit
import Foundation

/// Every bound the pack core enforces, in one place. They are deliberately
/// small: a private team pack carries a skill, some artwork and a few scripts.
public enum PackLimits {
    public static let maximumCatalogBytes = 1_048_576
    public static let maximumManifestBytes = 1_048_576
    public static let maximumFileCount = 512
    public static let maximumFileBytes = 100 * 1_048_576
    public static let maximumPayloadBytes = 256 * 1_048_576
    /// A skill is readable text; it is checked as UTF-8 before installation.
    public static let maximumSkillBytes = 4 * 1_048_576
    public static let maximumEntryCount = 64
    public static let maximumReleaseCount = 200
    public static let maximumIdentifierLength = 64
    public static let maximumNameLength = 80
    public static let maximumPathBytes = 400
    public static let maximumPathComponents = 12
    public static let maximumComponentLength = 96
    /// The receipt embeds its complete manifest.
    public static let maximumReceiptBytes = 4 * 1_048_576
    public static let maximumPointerBytes = 65_536
    /// Retained immutable revisions, including the active one.
    public static let maximumRetainedRevisions = 3
    /// Content-cache files kept after an interrupted install.
    public static let maximumCachedFiles = 64

    /// Checked addition. A manifest must not be able to describe an aggregate
    /// that overflows or that we would refuse to store anyway.
    public static func total<S: Sequence>(of sizes: S) throws -> Int where S.Element == Int {
        var total = 0
        for size in sizes {
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow, sum <= maximumPayloadBytes else {
                throw PackError.content("This pack is larger than the \(maximumPayloadBytes / 1_048_576) MB Workbench installs.")
            }
            total = sum
        }
        return total
    }
}

public enum PackDigest {
    private static let hexadecimal = "0123456789abcdef"

    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func isValid(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { hexadecimal.contains($0) }
    }

    @discardableResult
    static func validated(_ text: String, label: String) throws -> String {
        guard isValid(text) else {
            throw PackError.content("\(label) must be a lowercase SHA-256 digest.")
        }
        return text
    }
}

/// Pack, entry and other stable identifiers. Lowercase only, so an id can name
/// a directory without two ids colliding through case folding.
public enum PackIdentifier {
    @discardableResult
    public static func validated(_ text: String, label: String) throws -> String {
        let allowed = text.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isNumber || (character.isLetter && character.isLowercase) || character == "-" || character == "_"
        }
        guard !text.isEmpty, text.count <= PackLimits.maximumIdentifierLength, allowed,
              let first = text.first, first.isLetter || first.isNumber,
              let last = text.last, last.isLetter || last.isNumber else {
            throw PackError.content("\(label) must be 1–\(PackLimits.maximumIdentifierLength) lowercase letters, digits, hyphens or underscores.")
        }
        return text
    }
}

/// Human-readable display text carried in a catalogue or manifest.
public enum PackText {
    @discardableResult
    public static func validated(_ text: String, label: String, limit: Int = PackLimits.maximumNameLength) throws -> String {
        let printable = text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        guard !text.isEmpty, text.count <= limit, printable,
              text.trimmingCharacters(in: .whitespacesAndNewlines) == text else {
            throw PackError.content("\(label) must be 1–\(limit) characters without control characters or surrounding spaces.")
        }
        return text
    }
}

/// Relative pack file paths. The restricted character set keeps a path safe in
/// a URL, on a case-insensitive disk and inside a session snapshot, and removes
/// any question of Unicode normalisation deciding whether two paths collide.
public enum PackPath {
    @discardableResult
    public static func validated(_ path: String) throws -> String {
        func reject() -> PackError {
            PackError.content("“\(path)” is not a supported pack file path. Use relative names such as skills/deck/SKILL.md.")
        }
        guard !path.isEmpty, path.utf8.count <= PackLimits.maximumPathBytes,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains("//"), !path.hasSuffix("/") else { throw reject() }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= PackLimits.maximumPathComponents else { throw reject() }
        for component in components {
            let allowed = component.allSatisfy { character in
                guard character.isASCII else { return false }
                return character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
            }
            guard !component.isEmpty, component.count <= PackLimits.maximumComponentLength, allowed,
                  !component.hasPrefix("."), !component.hasSuffix("."),
                  component.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw reject() }
        }
        return path
    }

    /// "" for a top-level file, so a caller can tell a bare name from a subtree.
    public static func directory(of path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<separator])
    }

    public static func name(of path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: separator)...])
    }

    /// Resolve a manifest-relative path against the directory that contains the
    /// manifest. The combined result is validated again, so neither part can
    /// smuggle a traversal through concatenation.
    public static func resolve(base: String, relative: String) throws -> String {
        let relative = try validated(relative)
        guard !base.isEmpty else { return relative }
        return try validated(try validated(base) + "/" + relative)
    }

    /// Case-folded comparison key. Two paths that differ only by letter case
    /// cannot both exist on an ordinary Mac disk.
    public static func foldedKey(_ path: String) -> String { path.lowercased() }

    public static func isInside(_ path: String, directory: String) -> Bool {
        guard !directory.isEmpty else { return true }
        return path.hasPrefix(directory + "/")
    }

    public static func relative(_ path: String, to directory: String) -> String? {
        guard !directory.isEmpty else { return path }
        guard path.hasPrefix(directory + "/") else { return nil }
        return String(path.dropFirst(directory.count + 1))
    }

    /// Append a validated relative path to an owned directory, then check the
    /// result still resolves inside it.
    public static func url(_ path: String, in directory: URL) throws -> URL {
        var url = directory
        for component in try validated(path).split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        let base = directory.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard url.path.hasPrefix(prefix) else {
            throw PackError.content("“\(path)” does not stay inside the pack folder.")
        }
        return url
    }
}

/// A stable, ordered x.y.z version. Pre-release and build metadata are refused:
/// a private pack is installed by version number, so the number must be exact.
public struct PackVersion: Hashable, Comparable, Sendable, Codable, LosslessStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    public init?(_ description: String) {
        let parts = description.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...6).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || !part.hasPrefix("0"), let value = Int(part), value <= 100_000 else { return nil }
            numbers.append(value)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// The running app's own short version string may be shorter or carry a
    /// build suffix. Only the leading numeric part is read.
    public static func appVersion(_ text: String) -> PackVersion? {
        var parts = text.prefix { $0 == "." || ($0.isASCII && $0.isNumber) }
            .split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        while parts.count < 3 { parts.append("0") }
        return PackVersion(parts.joined(separator: "."))
    }

    @discardableResult
    public static func validated(_ text: String, label: String) throws -> PackVersion {
        guard let version = PackVersion(text) else {
            throw PackError.content("\(label) must be a version such as 1.0.0.")
        }
        return version
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: PackVersion, rhs: PackVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = PackVersion(text) else {
            throw PackError.content("“\(text)” is not a supported pack version. Use x.y.z.")
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The immutable repository commit every byte of one install came from. It is
/// part of the receipt, so a pack's provenance survives a restart.
public struct PackRevision: Hashable, Sendable, Codable, CustomStringConvertible {
    public let sha: String

    public init(sha: String) throws {
        let allowed = sha.allSatisfy { "0123456789abcdef".contains($0) }
        guard allowed, sha.count == 40 || sha.count == 64 else {
            throw PackError.transport("GitHub did not return a usable commit identifier for this repository.")
        }
        self.sha = sha
    }

    public var description: String { sha }
    public var short: String { String(sha.prefix(7)) }

    public init(from decoder: Decoder) throws {
        try self.init(sha: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sha)
    }
}

enum PackCoder {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(type, from: data) }
        catch let error as PackError { throw error }
        catch {
            throw PackError.content("Workbench could not read \(what): a required field is missing or has an unexpected value.")
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(value) }
        catch { throw PackError.storage("Workbench could not prepare its pack record.") }
    }
}
