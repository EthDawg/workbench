import AppKit
import PrivatePackKit

/// Platform boundaries used by the existing Packs owner. Synthetic checks replace
/// these operations; installed content still belongs to the real PackStore.
@MainActor struct PackLibraryServices {
    var readCredential: () throws -> PackGitHubCredential? = { try PackCredentialStore.read() }
    var saveCredential: (PackGitHubCredential) throws -> Void = { try PackCredentialStore.save($0) }
    var removeCredential: () throws -> Void = { try PackCredentialStore.remove() }
    var authorization: () throws -> GitHubPackAuthorization = {
        try GitHubPackAuthorization(clientID: Bundle.main.object(forInfoDictionaryKey: "WorkbenchGitHubClientID") as? String ?? "")
    }
    var contentSource: (PackSource, String) throws -> any PackContentSource = {
        try GitHubPackClient(source: $0, client: URLSessionPackClient(), token: $1)
    }
    var copyCode: (String) -> Bool = { TextDelivery.copy($0) != nil }
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
}
