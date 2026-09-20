import Foundation

/// Portable intent only. Profile IDs, Chrome node IDs and credentials live elsewhere.
public struct BrowserSetupBookmark: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var url: String
    public var folder: String
    public init(id: String, title: String, url: String, folder: String) {
        self.id = id; self.title = title; self.url = url; self.folder = folder
    }
}

public struct BrowserSetupRole: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var bookmarks: [BrowserSetupBookmark]
    public var launchURLs: [String]
    public var defaultURL: String
    public init(id: String, title: String, bookmarks: [BrowserSetupBookmark], launchURLs: [String], defaultURL: String) {
        self.id = id; self.title = title; self.bookmarks = bookmarks; self.launchURLs = launchURLs; self.defaultURL = defaultURL
    }
}

public struct BrowserSetupPayload: Codable, Equatable, Sendable {
    public var packID: String
    public var title: String
    public var roleID: String
    public var roleTitle: String
    public var bookmarks: [BrowserSetupBookmark]
    public var launchURLs: [String]
    public var defaultURL: String
}

public struct BrowserSetupResult: Codable, Equatable, Sendable {
    public var reviewToken: String?
    public var create: Int
    public var update: Int
    public var unchanged: Int
    public var conflicts: Int
    public var root: String
    public var notes: [String]
    public var isValid: Bool {
        [create, update, unchanged, conflicts].allSatisfy { (0...120).contains($0) }
            && root.count <= 160 && notes.count <= 20 && notes.allSatisfy { $0.count <= 500 }
            && (reviewToken.map { UUID(uuidString: $0) != nil } ?? true)
    }
}

public struct BrowserSetupPack: Codable, Equatable, Sendable {
    public var schema: Int = 1
    public var id: String
    public var title: String
    public var sharedBookmarks: [BrowserSetupBookmark]
    public var roles: [BrowserSetupRole]
    public static let byteLimit = 262_144
    public init(id: String = UUID().uuidString.lowercased(), title: String, sharedBookmarks: [BrowserSetupBookmark], roles: [BrowserSetupRole]) {
        self.id = id; self.title = title; self.sharedBookmarks = sharedBookmarks; self.roles = roles
    }
    public func payload(for roleID: String) throws -> BrowserSetupPayload {
        try validate()
        guard let role = roles.first(where: { $0.id == roleID }) else { throw BrowserSetupError.invalid("Choose a role in this pack.") }
        return BrowserSetupPayload(packID: id.lowercased(), title: title, roleID: role.id, roleTitle: role.title,
            bookmarks: sharedBookmarks + role.bookmarks, launchURLs: role.launchURLs, defaultURL: role.defaultURL)
    }
    public func validate() throws {
        guard schema == 1, UUID(uuidString: id) != nil, Self.name(title), (1...12).contains(roles.count),
              Set(roles.map(\.id)).count == roles.count else { throw BrowserSetupError.invalid("Use schema 1, a UUID pack ID, a title and 1–12 distinct roles.") }
        for role in roles {
            let bookmarks = sharedBookmarks + role.bookmarks
            guard Self.identifier(role.id, limit: 40), Self.name(role.title), bookmarks.count <= 60,
                  Set(bookmarks.map(\.id)).count == bookmarks.count, role.launchURLs.count <= 8,
                  Set(role.launchURLs.compactMap(Self.navigationURL)).count == role.launchURLs.count,
                  role.launchURLs.allSatisfy(Self.safeURL), Self.safeURL(role.defaultURL) else {
                throw BrowserSetupError.invalid("Each role needs a unique ID, up to 60 distinct bookmarks, up to 8 distinct launch URLs and a default URL.")
            }
            for bookmark in bookmarks {
                guard Self.identifier(bookmark.id, limit: 64), Self.name(bookmark.title), Self.name(bookmark.folder), Self.safeURL(bookmark.url) else {
                    throw BrowserSetupError.invalid("A bookmark has an invalid ID, title, folder or URL. Use plain HTTP(S) navigation links without credentials or secret query parameters.")
                }
            }
            let payload = BrowserSetupPayload(packID: id.lowercased(), title: title, roleID: role.id, roleTitle: role.title,
                bookmarks: bookmarks, launchURLs: role.launchURLs, defaultURL: role.defaultURL)
            guard try JSONEncoder().encode(payload).count < 60_000 else { throw BrowserSetupError.invalid("This role is too large for the Chrome connection. Shorten its URLs or split the pack.") }
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= byteLimit else { throw BrowserSetupError.invalid("Choose a browser setup JSON file smaller than 256 KB.") }
        // Reject unknown fields rather than silently discarding agent-added intentions.
        let raw = try JSONSerialization.jsonObject(with: data)
        func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
            guard let o = value as? [String: Any], Set(o.keys) == keys else { throw BrowserSetupError.invalid("The pack contains missing or unsupported fields. Use the included SKILL.md schema.") }
            return o
        }
        func bookmarks(_ value: Any?) throws {
            guard let list = value as? [Any] else { throw BrowserSetupError.invalid("Bookmarks must be a list.") }
            for item in list { _ = try object(item, keys: ["id", "title", "url", "folder"]) }
        }
        let o = try object(raw, keys: ["schema", "id", "title", "sharedBookmarks", "roles"])
        try bookmarks(o["sharedBookmarks"])
        guard let roles = o["roles"] as? [Any] else { throw BrowserSetupError.invalid("Roles must be a list.") }
        for role in roles {
            let r = try object(role, keys: ["id", "title", "bookmarks", "launchURLs", "defaultURL"])
            try bookmarks(r["bookmarks"])
        }
        let pack = try JSONDecoder().decode(Self.self, from: data); try pack.validate(); return pack
    }
    public func data() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.byteLimit else { throw BrowserSetupError.invalid("This pack exceeds 256 KB.") }
        return data
    }
    public static func name(_ value: String) -> Bool { PresenterURL.validName(value) && value == value.trimmingCharacters(in: .whitespacesAndNewlines) }
    public static func identifier(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
    public static func safeURL(_ value: String) -> Bool {
        guard let normalized = navigationURL(value), normalized.utf8.count <= 4096, let parts = URLComponents(string: value) else { return false }
        let secretKeys: Set<String> = ["token", "access_token", "refresh_token", "id_token", "password", "passwd", "secret", "auth", "authorization", "session", "sessionid", "signature", "sig", "key", "api_key", "apikey", "code"]
        var items = parts.queryItems ?? []
        if let fragment = parts.fragment, fragment.contains("?") || fragment.contains("=") {
            var fragmentQuery = URLComponents()
            fragmentQuery.query = fragment.contains("?") ? String(fragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).last ?? "") : fragment
            items += fragmentQuery.queryItems ?? []
        }
        return !items.contains { secretKeys.contains($0.name.lowercased()) }
    }
    private static func navigationURL(_ value: String) -> String? {
        guard let canonical = PresenterURL.canonical(value), var parts = URLComponents(string: canonical),
              let original = URLComponents(string: value) else { return nil }
        parts.percentEncodedQuery = original.percentEncodedQuery; parts.percentEncodedFragment = original.percentEncodedFragment
        return parts.url?.absoluteString
    }
    public func bookmarkHTML(for roleID: String) throws -> String {
        let payload = try payload(for: roleID)
        let groups = payload.bookmarks.reduce(into: [String]()) { if !$0.contains($1.folder) { $0.append($1.folder) } }
        var text = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n<DT><H3>\(Self.html(title)) — \(Self.html(payload.roleTitle))</H3>\n<DL><p>\n"
        for folder in groups {
            text += "<DT><H3>\(Self.html(folder))</H3>\n<DL><p>\n"
            for b in payload.bookmarks where b.folder == folder { text += "<DT><A HREF=\"\(Self.html(b.url))\">\(Self.html(b.title))</A>\n" }
            text += "</DL><p>\n"
        }
        return text + "</DL><p>\n</DL><p>\n"
    }
    private static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    public static func compound() -> Self {
        let base = "https://compound-snowy-pi.vercel.app"
        func b(_ id: String, _ title: String, _ path: String, _ folder: String) -> BrowserSetupBookmark {
            .init(id: id, title: title, url: base + path, folder: folder)
        }
        return Self(title: "Compound demo", sharedBookmarks: [
            b("compound", "Compound — field guide", "/", "Shared"),
            b("brief", "12-minute brief", "/brief", "Shared"),
            b("about", "About this independent demo", "/about", "Shared")
        ], roles: [
            .init(id: "presenter", title: "Presenter", bookmarks: [b("backstage", "Backstage", "/companies/rippling/backstage", "Present"), b("desk", "Demo desk", "/desk", "Present")], launchURLs: [base + "/brief", base + "/companies/rippling/backstage"], defaultURL: base + "/companies/rippling/backstage"),
            .init(id: "manager", title: "Manager · desktop", bookmarks: [b("app", "Desktop app", "/companies/rippling/app", "Desktop"), b("org", "Organisation example", "/companies/rippling/backstage/org", "Desktop")], launchURLs: [base + "/companies/rippling/app"], defaultURL: base + "/companies/rippling/app"),
            .init(id: "mobile", title: "Employee · Pocket", bookmarks: [b("pocket", "Pocket · mobile example", "/pocket", "Mobile"), b("ask", "Pocket · Ask", "/pocket/ask", "Mobile")], launchURLs: [base + "/pocket"], defaultURL: base + "/pocket")
        ])
    }
}

public enum BrowserSetupError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let reason): reason } }
}
