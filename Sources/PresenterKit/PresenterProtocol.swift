import Foundation

/// A machine-local attachment to an existing saved resource. Never exported.
public struct BrowserTarget: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var profileName: String
    public var machineID: UUID
    public init(profileID: UUID, profileName: String, machineID: UUID) {
        self.profileID = profileID; self.profileName = profileName; self.machineID = machineID
    }
    public var isValid: Bool { PresenterURL.validName(profileName) }
}

public enum PresenterURL {
    public static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    /// Keep only a deliberately selected navigation address, without URL credentials,
    /// queries or fragments. No tenant wildcard or inferred identity matching.
    public static func canonical(_ string: String) -> String? {
        guard string.utf8.count <= 4096, !string.contains("\\"),
              !string.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(string: string), let scheme = parts.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        parts.scheme = scheme; parts.host = host.lowercased(); parts.query = nil; parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.url?.absoluteString
    }
}

public struct PresenterDestination: Codable, Sendable {
    public var id: UUID
    public var title: String
    public var profileName: String
    public var profileID: UUID
    public var url: String
    public var connected: Bool
    public init(id: UUID, title: String, profileName: String, profileID: UUID, url: String, connected: Bool) {
        self.id = id; self.title = title; self.profileName = profileName; self.profileID = profileID
        self.url = url; self.connected = connected
    }
    enum CodingKeys: String, CodingKey { case id, title, profileName, profileID, url, connected }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id); try c.encode(title, forKey: .title)
        try c.encode(profileName, forKey: .profileName); try c.encode(profileID.uuidString.lowercased(), forKey: .profileID)
        try c.encode(url, forKey: .url); try c.encode(connected, forKey: .connected)
    }
}

/// Explicit wire fields. No arbitrary scripts, file paths, page contents or secrets.
public struct PresenterMessage: Codable, Sendable {
    public var v = 1
    public var id: UUID
    public var type: String
    public var profileID: UUID?
    public var profileName: String?
    public var destinationID: UUID?
    public var title: String?
    public var url: String?
    public var ok: Bool?
    public var status: String?
    public var error: String?
    public var destinations: [PresenterDestination]?
    public var expiresAt: Double?
    public init(id: UUID = UUID(), type: String) { self.id = id; self.type = type }
    enum CodingKeys: String, CodingKey { case v, id, type, profileID, profileName, destinationID, title, url, ok, status, error, destinations, expiresAt }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v); try c.encode(id.uuidString.lowercased(), forKey: .id); try c.encode(type, forKey: .type)
        try c.encodeIfPresent(profileID?.uuidString.lowercased(), forKey: .profileID)
        try c.encodeIfPresent(destinationID?.uuidString.lowercased(), forKey: .destinationID)
        try c.encodeIfPresent(profileName, forKey: .profileName); try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(url, forKey: .url); try c.encodeIfPresent(ok, forKey: .ok)
        try c.encodeIfPresent(status, forKey: .status); try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(destinations, forKey: .destinations); try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }
    public func reply(ok: Bool, error: String? = nil) -> Self {
        var reply = Self(id: id, type: "result"); reply.ok = ok; reply.error = error; return reply
    }
}

public enum PresenterWire {
    public static let limit = 65_536
    public static let hostName = "com.ethdawg.workbench.browser"
    // Public extension identity; this is not a credential or a signing secret.
    public static let extensionID = "ajafaiojgpdgmeblldllnhhfnafiiieo"
    public static func encode(_ message: PresenterMessage) throws -> Data {
        let data = try JSONEncoder().encode(message)
        guard !data.isEmpty, data.count <= limit else { throw PresenterError.invalidMessage }
        var length = UInt32(data.count).littleEndian
        var frame = Data(bytes: &length, count: 4); frame.append(data); return frame
    }
    public static func decode(_ data: Data) throws -> PresenterMessage {
        guard !data.isEmpty, data.count <= limit else { throw PresenterError.invalidMessage }
        let message = try JSONDecoder().decode(PresenterMessage.self, from: data)
        guard message.v == 1, message.type.count <= 32 else { throw PresenterError.invalidMessage }
        return message
    }
    public static func length(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw PresenterError.invalidMessage }
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard (1...limit).contains(length) else { throw PresenterError.invalidMessage }
        return length
    }
}

public enum PresenterError: Error, LocalizedError {
    case invalidMessage, unavailable, unsafePath, disconnected
    public var errorDescription: String? {
        switch self {
        case .invalidMessage: "The Chrome connection sent an unsupported message. Update Workbench and its extension."
        case .unavailable: "Open Workbench and enable Chrome connection in Saved resources, then Retry."
        case .unsafePath: "Workbench could not create its private Chrome connection. Restart Workbench or choose Retry."
        case .disconnected: "The Chrome connection closed. Open that profile and choose Retry."
        }
    }
}
