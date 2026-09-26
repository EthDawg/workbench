import Foundation

/// Immutable selected inputs. Editing or archiving history cannot alter a job
/// or narrated session that already owns these bytes.
struct SnapHandoffSnapshot {
    let id: UUID
    let title: String
    let createdAt: Date
    let originalPNG: Data
    let renderedPNG: Data?
    let note: String
    let tags: [String]
}
