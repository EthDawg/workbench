import Foundation

/// A private pack comes from one GitHub repository and nowhere else.
///
/// The only accepted inputs are an `https://github.com/OWNER/REPO` address (an
/// optional `.git` suffix and one trailing slash are tolerated) and the
/// `OWNER/REPO` shorthand. Credentials, ports, queries, fragments, other hosts,
/// other schemes, percent-encoding and extra path components are refused rather
/// than normalised, because a repository address decides where a token is sent.
///
/// `identity` is the case-folded canonical name and `storageKey` is derived from
/// it, so two different repositories can never share one pack's installed state
/// even when they publish the same pack id.
public struct PackSource: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable { case github }

    public let kind: Kind
    public let owner: String
    public let repository: String

    private init(owner: String, repository: String) {
        self.kind = .github
        self.owner = owner
        self.repository = repository
    }

    public static func github(owner: String, repository: String) throws -> PackSource {
        var repository = repository
        if repository.count > 4, repository.lowercased().hasSuffix(".git") { repository = String(repository.dropLast(4)) }
        guard isOwner(owner), isRepository(repository) else {
            throw PackError.source("A pack repository is written owner/repository, using letters, digits, hyphens, underscores and dots.")
        }
        return PackSource(owner: owner, repository: repository)
    }

    public static func github(url text: String) throws -> PackSource {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func reject() -> PackError {
            PackError.source("Use a plain repository address such as https://github.com/owner/repository.")
        }
        // Percent-encoding, credentials and a second host are refused outright
        // instead of being decoded and inspected.
        guard trimmed.count <= 300, !trimmed.contains("%"), !trimmed.contains("@"), !trimmed.contains("\\"),
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https", components.host?.lowercased() == "github.com",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw reject() }
        var parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "" else { throw reject() }
        parts.removeFirst()
        if parts.count == 3, parts.last == "" { parts.removeLast() }
        guard parts.count == 2 else { throw reject() }
        return try github(owner: parts[0], repository: parts[1])
    }

    /// Accepts either supported form, for one settings field.
    public static func parse(_ text: String) throws -> PackSource {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased()
        if folded.hasPrefix("https://") { return try github(url: trimmed) }
        if folded.hasPrefix("github.com/") { return try github(url: "https://" + trimmed) }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            throw PackError.source("Enter the pack repository as owner/repository or https://github.com/owner/repository.")
        }
        return try github(owner: parts[0], repository: parts[1])
    }

    /// GitHub owner and repository names are compared without case, so the
    /// canonical identity is folded. Two spellings of one repository share
    /// installed state; two repositories never do.
    public var identity: String { "github.com/\(owner.lowercased())/\(repository.lowercased())" }

    /// A short, filesystem-safe directory name qualified by that identity.
    public var storageKey: String { "github-" + String(PackDigest.hex(Data(identity.utf8)).prefix(32)) }

    public var description: String { "github.com/\(owner)/\(repository)" }

    public var webURL: URL? { URL(string: "https://github.com/\(owner)/\(repository)") }

    public static func == (lhs: PackSource, rhs: PackSource) -> Bool {
        lhs.kind == rhs.kind && lhs.identity == rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(identity)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Kind.self, forKey: .kind) == .github else {
            throw PackError.source("This pack source uses an unsupported kind.")
        }
        self = try PackSource.github(owner: try container.decode(String.self, forKey: .owner),
                                     repository: try container.decode(String.self, forKey: .repository))
    }

    private static func isOwner(_ text: String) -> Bool {
        let allowed = text.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || character == "-"
        }
        return !text.isEmpty && text.count <= 39 && allowed && !text.hasPrefix("-") && !text.hasSuffix("-")
    }

    private static func isRepository(_ text: String) -> Bool {
        let allowed = text.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        }
        return !text.isEmpty && text.count <= 100 && allowed
            && !text.hasPrefix(".") && !text.hasPrefix("-") && !text.hasSuffix(".")
            && text.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
}
