import Foundation

/// The private-pack core reports one vocabulary of failures. Every message is
/// safe to show a person: it never contains a token, an HTTP header or a local
/// absolute path, and it always says what happened to the installed pack.
public enum PackError: LocalizedError, Equatable, Sendable {
    /// The repository address cannot be trusted or identified.
    case source(String)
    /// A catalogue, manifest, entry or payload byte failed validation.
    case content(String)
    /// A published release needs a newer app than this one.
    case compatibility(String)
    /// The request could not be completed safely: status, size or a redirect.
    case transport(String)
    /// GitHub refused the sign-in or this account cannot read the repository.
    case authorization(String)
    /// Local storage is missing, unsafe or unwritable.
    case storage(String)

    public var message: String {
        switch self {
        case .source(let text), .content(let text), .compatibility(let text),
             .transport(let text), .authorization(let text), .storage(let text):
            return text
        }
    }

    public var errorDescription: String? { message }
}

/// Wire formats are explicit and single-valued. An unknown version is refused
/// rather than guessed: a newer catalogue needs a newer Workbench.
public enum PackFormat {
    public static let current = 1
}
