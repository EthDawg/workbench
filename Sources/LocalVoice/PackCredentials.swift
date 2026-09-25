import Foundation
import Security

/// Tokens stay in the edition's Keychain, separate from pack files and exports.
struct PackGitHubCredential: Codable {
    var login: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var refreshExpiresAt: Date?

    func validated() throws -> Self {
        guard !login.isEmpty, login.count <= 100,
              Self.validToken(accessToken), refreshToken.map(Self.validToken) ?? true else {
            throw VoiceError.message("GitHub returned an invalid sign-in record. Connect again.")
        }
        return self
    }
    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }
}

enum PackCredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.ethdawg.workbench.development") + ".private-packs.github",
         kSecAttrAccount as String: "user-authorization"]
    }

    static func read() throws -> PackGitHubCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 16_384 else {
            throw VoiceError.message("Unlock Keychain to use private packs. Your installed content remains available.")
        }
        do { return try JSONDecoder().decode(PackGitHubCredential.self, from: data).validated() }
        catch { throw VoiceError.message("Reconnect GitHub to replace an unreadable sign-in record. Installed packs remain available.") }
    }

    static func save(_ credential: PackGitHubCredential) throws {
        let data = try JSONEncoder().encode(credential.validated())
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw VoiceError.message("GitHub sign-in could not be saved in Keychain. Unlock it and connect again.")
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceError.message("GitHub sign-in could not be removed from Keychain. Unlock it and try again.")
        }
    }
}
