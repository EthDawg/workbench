import Foundation

/// A manifest together with the digest of the exact bytes it was read from.
public struct PackManifestDocument: Equatable, Sendable {
    public let manifest: PackManifest
    public let digest: String
    /// Where the manifest lives, so payload paths resolve against it.
    public let path: String

    public init(manifest: PackManifest, digest: String, path: String) {
        self.manifest = manifest; self.digest = digest; self.path = path
    }
}

/// Where a pack's bytes come from. The store is written against this protocol,
/// so an install can be exercised end to end without a network, and a different
/// private host could be added later without touching the store.
public protocol PackContentSource: Sendable {
    var source: PackSource { get }
    /// The immutable commit every later request in this update must use.
    func currentRevision() async throws -> PackRevision
    func catalog(at revision: PackRevision) async throws -> PackCatalog
    func manifest(for release: PackRelease, in catalog: PackCatalog, at revision: PackRevision) async throws -> PackManifestDocument
    func file(_ file: PackFile, for release: PackRelease, at revision: PackRevision) async throws -> Data
}

/// Reads a private pack from GitHub's REST API over HTTPS.
///
/// The default branch's commit is resolved first, and the catalogue, manifest
/// and every file are then requested at that immutable ref. Only
/// `api.github.com` is contacted, redirects are refused, each body is bounded
/// before it is accumulated, and the token is supplied by the caller: this
/// library never stores or logs it.
public struct GitHubPackClient: PackContentSource {
    public static let host = "api.github.com"
    public static let rawAccept = "application/vnd.github.raw+json"
    public static let shaAccept = "application/vnd.github.sha"
    public static let jsonAccept = "application/vnd.github+json"

    public let source: PackSource
    /// Relative to the repository root.
    public let catalogPath: String
    private let client: any PackHTTPClient
    private let token: String?

    public init(source: PackSource, client: any PackHTTPClient, token: String? = nil,
                catalogPath: String = "catalog.json") throws {
        self.source = source
        self.client = client
        self.catalogPath = try PackPath.validated(catalogPath)
        if let token {
            let printable = token.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value != 127 }
            guard !token.isEmpty, token.count <= 4_096, printable else {
                throw PackError.authorization("This GitHub token is not usable. Sign in again to get a new one.")
            }
        }
        self.token = token
    }

    public func currentRevision() async throws -> PackRevision {
        let response = try await send(path: ["commits", "HEAD"], query: nil, accept: Self.shaAccept,
                                      limit: 64 * 1_024, what: "this pack repository")
        return try Self.revision(from: response.body)
    }

    public func catalog(at revision: PackRevision) async throws -> PackCatalog {
        let data = try await contents(path: catalogPath, at: revision,
                                      limit: PackLimits.maximumCatalogBytes, what: "the pack catalogue")
        return try PackCoder.decode(PackCatalog.self, from: data, what: "the pack catalogue").validated()
    }

    public func manifest(for release: PackRelease, in catalog: PackCatalog,
                         at revision: PackRevision) async throws -> PackManifestDocument {
        let path = try manifestPath(for: release)
        let data = try await contents(path: path, at: revision,
                                      limit: PackLimits.maximumManifestBytes, what: "the pack manifest")
        let digest = PackDigest.hex(data)
        guard digest == release.sha256 else {
            throw PackError.content("The pack manifest does not match the digest in the catalogue. Nothing was installed.")
        }
        let manifest = try PackCoder.decode(PackManifest.self, from: data, what: "the pack manifest").validated()
        try manifest.agrees(with: release, in: catalog)
        return PackManifestDocument(manifest: manifest, digest: digest, path: path)
    }

    public func file(_ file: PackFile, for release: PackRelease, at revision: PackRevision) async throws -> Data {
        let base = PackPath.directory(of: try manifestPath(for: release))
        let path = try PackPath.resolve(base: base, relative: file.path)
        let data = try await contents(path: path, at: revision, limit: file.size, what: "“\(file.path)”")
        guard data.count == file.size, PackDigest.hex(data) == file.sha256 else {
            throw PackError.content("“\(file.path)” does not match the size or digest this pack publishes. Nothing was installed.")
        }
        return data
    }

    /// Manifest paths are relative to the catalogue's own directory.
    private func manifestPath(for release: PackRelease) throws -> String {
        try PackPath.resolve(base: PackPath.directory(of: catalogPath), relative: release.manifestPath)
    }

    private func contents(path: String, at revision: PackRevision, limit: Int, what: String) async throws -> Data {
        let components = try PackPath.validated(path).split(separator: "/").map(String.init)
        let response = try await send(path: ["contents"] + components, query: "ref=" + revision.sha,
                                      accept: Self.rawAccept, limit: limit, what: what)
        guard !response.body.isEmpty else {
            throw PackError.content("GitHub returned nothing for \(what).")
        }
        return response.body
    }

    private func send(path: [String], query: String?, accept: String, limit: Int, what: String) async throws -> PackHTTPResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        // Owner, repository and every path component are already restricted to
        // characters that are safe in a URL path, so nothing needs escaping and
        // nothing can introduce a new path segment.
        components.percentEncodedPath = (["", "repos", source.owner, source.repository] + path).joined(separator: "/")
        components.percentEncodedQuery = query
        guard let url = components.url else {
            throw PackError.transport("Workbench could not prepare a GitHub request for \(what).")
        }
        let request = try PackHTTPRequest(url: url, host: Self.host, accept: accept,
                                          authorization: token, limit: limit)
        let response = try await client.send(request)
        try GitHubStatus.check(response, what: what, repository: true)
        return response
    }

    /// `application/vnd.github.sha` answers with the bare commit SHA. A JSON
    /// answer is also accepted, so a media-type change cannot break installs.
    static func revision(from data: Data) throws -> PackRevision {
        guard let text = String(data: data, encoding: .utf8) else {
            throw PackError.transport("GitHub returned an unreadable commit reply for this repository.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let revision = try? PackRevision(sha: trimmed.lowercased()) { return revision }
        struct Commit: Decodable { let sha: String }
        guard let commit = try? JSONDecoder().decode(Commit.self, from: data) else {
            throw PackError.transport("GitHub did not return a usable commit for this repository.")
        }
        return try PackRevision(sha: commit.sha.lowercased())
    }
}

enum GitHubStatus {
    static func check(_ response: PackHTTPResponse, what: String, repository: Bool = false) throws {
        switch response.status {
        case 200...299:
            return
        case 401:
            throw PackError.authorization("GitHub did not accept this sign-in. Sign in again to install or update the pack.")
        case 403 where response.headers["x-ratelimit-remaining"] == "0", 429:
            throw PackError.transport("GitHub is rate-limiting Workbench. Try again later; the installed pack is unchanged.")
        case 403:
            throw PackError.authorization(repository
                ? "GitHub denied access to \(what). Ask the owner to give both your account and the Workbench Packs app access to this repository."
                : "GitHub denied access to \(what). Check your account’s access and reconnect.")
        case 404:
            throw PackError.content(repository
                ? "GitHub could not find \(what). Check the address and ask the owner to give both your account and the Workbench Packs app access to this repository."
                : "GitHub could not find \(what). Check your account’s access and reconnect.")
        case 500...599:
            throw PackError.transport("GitHub could not answer for \(what) (HTTP \(response.status)). The installed pack is unchanged.")
        default:
            throw PackError.transport("GitHub answered unexpectedly for \(what) (HTTP \(response.status)).")
        }
    }
}
