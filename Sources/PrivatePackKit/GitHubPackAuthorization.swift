import Foundation

public struct GitHubDeviceChallenge: Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let interval: TimeInterval
}
public struct GitHubPackToken: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let refreshExpiresAt: Date?
}

/// GitHub App device authorization, with no client secret and no broad OAuth
/// `repo` scope. The app registration and repository installation bound access.
public struct GitHubPackAuthorization: Sendable {
    private let clientID: String
    private let client: any PackHTTPClient
    public init(clientID: String, client: any PackHTTPClient = URLSessionPackClient()) throws {
        guard !clientID.isEmpty, clientID.count <= 100,
              clientID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }) else {
            throw PackError.authorization("GitHub connection is not available in this build yet. Installed packs remain usable.")
        }
        self.clientID = clientID; self.client = client
    }
    public func begin() async throws -> GitHubDeviceChallenge {
        let response = try await post("/login/device/code", form: ["client_id": clientID])
        struct Challenge: Decodable {
            let device_code: String; let user_code: String; let verification_uri: String
            let expires_in: Int; let interval: Int
        }
        guard let value = try? JSONDecoder().decode(Challenge.self, from: response.body),
              Self.tokenIsValid(value.device_code), !value.user_code.isEmpty, value.user_code.count <= 32,
              value.user_code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let url = URL(string: value.verification_uri), url.absoluteString == "https://github.com/login/device",
              (1...1800).contains(value.expires_in), (1...60).contains(value.interval) else {
            throw PackError.authorization("GitHub could not start device sign-in. Try connecting again.")
        }
        return GitHubDeviceChallenge(deviceCode: value.device_code, userCode: value.user_code,
                                     verificationURL: url, expiresAt: Date().addingTimeInterval(Double(value.expires_in)),
                                     interval: Double(value.interval))
    }
    public func complete(_ challenge: GitHubDeviceChallenge) async throws -> GitHubPackToken {
        var interval = challenge.interval
        while Date() < challenge.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try Task.checkCancellation()
            let response = try await post("/login/oauth/access_token", form: [
                "client_id": clientID, "device_code": challenge.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            let value = try decode(response)
            switch value.error {
            case "authorization_pending": continue
            case "slow_down": interval = min(interval + 5, 120); continue
            case "access_denied": throw PackError.authorization("GitHub sign-in was declined. Installed packs remain available.")
            case "expired_token": throw PackError.authorization("The sign-in code expired. Connect again for a new code.")
            case nil: return try token(value)
            default: throw PackError.authorization("GitHub could not complete sign-in. Connect again.")
            }
        }
        throw PackError.authorization("The sign-in code expired. Connect again for a new code.")
    }
    public func refresh(_ refreshToken: String) async throws -> GitHubPackToken {
        guard Self.tokenIsValid(refreshToken) else { throw PackError.authorization("Reconnect GitHub to update private packs.") }
        let value = try decode(await post("/login/oauth/access_token", form: [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken]))
        guard value.error == nil else { throw PackError.authorization("GitHub sign-in expired or was revoked. Reconnect to update private packs.") }
        return try token(value)
    }
    public func login(accessToken: String) async throws -> String {
        let request = try PackHTTPRequest(url: URL(string: "https://api.github.com/user")!, host: "api.github.com",
            accept: "application/vnd.github+json", authorization: accessToken, limit: 65_536)
        let response = try await client.send(request)
        try GitHubStatus.check(response, what: "your GitHub account")
        struct User: Decodable { let login: String }
        guard let user = try? JSONDecoder().decode(User.self, from: response.body),
              !user.login.isEmpty, user.login.count <= 100,
              user.login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw PackError.authorization("GitHub returned an unreadable account. Connect again.")
        }
        return user.login
    }
    private struct Reply: Decodable {
        var access_token: String?; var refresh_token: String?; var expires_in: Int?
        var refresh_token_expires_in: Int?; var error: String?; var token_type: String?
    }
    private func decode(_ response: PackHTTPResponse) throws -> Reply {
        guard let value = try? JSONDecoder().decode(Reply.self, from: response.body) else {
            throw PackError.authorization("GitHub returned an unreadable sign-in reply. Connect again.")
        }
        return value
    }
    private func token(_ value: Reply) throws -> GitHubPackToken {
        guard let access = value.access_token, Self.tokenIsValid(access),
              value.token_type?.lowercased() == "bearer",
              value.refresh_token.map(Self.tokenIsValid) ?? true,
              value.expires_in.map({ $0 > 0 && $0 <= 86_400 }) ?? true,
              value.refresh_token_expires_in.map({ $0 > 0 && $0 <= 31_622_400 }) ?? true else {
            throw PackError.authorization("GitHub returned an invalid sign-in record. Connect again.")
        }
        return GitHubPackToken(accessToken: access, refreshToken: value.refresh_token,
            expiresAt: value.expires_in.map { Date().addingTimeInterval(Double($0)) },
            refreshExpiresAt: value.refresh_token_expires_in.map { Date().addingTimeInterval(Double($0)) })
    }
    private static func tokenIsValid(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 4096 && text.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value != 127 }
    }
    private func post(_ path: String, form: [String: String]) async throws -> PackHTTPResponse {
        let request = try PackHTTPRequest(url: URL(string: "https://github.com" + path)!, host: "github.com",
            method: .post, accept: "application/json", form: form, limit: 65_536)
        let response = try await client.send(request)
        try GitHubStatus.check(response, what: "GitHub sign-in")
        return response
    }
}
