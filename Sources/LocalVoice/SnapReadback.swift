import Foundation

/// Adds portable copies to the existing v1 session. The companion preserves
/// Snap provenance without changing the manifest or its frozen skill pack.
enum SnapReadback {
    struct Source: Codable, Equatable {
        let formatVersion: Int
        let snapID: UUID
        let createdAt: Date
        let title: String
        let note: String
        let tags: [String]
        let originalSHA256: String
        let renderedSHA256: String

        init(_ snapshot: SnapHandoffSnapshot) {
            formatVersion = 1; snapID = snapshot.id; createdAt = snapshot.createdAt
            title = snapshot.title; note = snapshot.note; tags = snapshot.tags
            originalSHA256 = SnapStore.digest(snapshot.originalPNG)
            renderedSHA256 = SnapStore.digest(snapshot.renderedPNG ?? snapshot.originalPNG)
        }
    }
    struct Result {
        let manifest: ReadbackManifest
        let added: Int
        let alreadyAdded: Int
        let warning: String?
    }

    static func importSnapshots(_ snapshots: [SnapHandoffSnapshot], at root: URL, expectedSessionID: UUID) throws -> Result {
        guard !snapshots.isEmpty, snapshots.count <= 100, Set(snapshots.map(\.id)).count == snapshots.count else {
            throw SnapError.message("Choose between 1 and 100 different Snaps to add.")
        }
        var totalBytes = 0
        for snapshot in snapshots {
            totalBytes += snapshot.originalPNG.count + (snapshot.renderedPNG?.count ?? 0)
            guard totalBytes <= 256 * 1_024 * 1_024, !snapshot.title.isEmpty, snapshot.title.count <= 240,
                  snapshot.note.count <= 50_000, snapshot.tags.count <= 50, snapshot.tags.allSatisfy({ $0.count <= 80 }),
                  snapshot.createdAt.timeIntervalSince1970.isFinite else {
                throw SnapError.message("The selected Snaps are too large or have unsupported metadata. Choose fewer images or shorten their notes.")
            }
            _ = try SnapRendering.image(snapshot.originalPNG)
            if let rendered = snapshot.renderedPNG { _ = try SnapRendering.image(rendered) }
        }
        var current = try ReadbackStore.load(from: root)
        guard current.id == expectedSessionID else { throw SnapError.message("The session changed. Open the intended Snap & Talk session again.") }
        let originalManifest = try Data(contentsOf: root.appendingPathComponent(ReadbackStore.manifestName))
        var existing: [Source] = []
        for section in current.sections {
            let url = try ReadbackStore.safeURL(root: root, relative: section.directory + "/source-snap.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1_024 * 1_024 else {
                    throw SnapError.message("A saved Snap source receipt is unreadable. The session was kept unchanged.")
                }
                let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: url))
                guard source.formatVersion == 1 else { throw SnapError.message("A saved Snap source receipt uses a newer format. The session was kept unchanged.") }
                existing.append(source)
            }
        }
        let pending = snapshots.filter { !existing.contains(Source($0)) }
        guard !pending.isEmpty else { return .init(manifest: current, added: 0, alreadyAdded: snapshots.count, warning: nil) }
        var created: [URL] = [], sections: [ReadbackSection] = []
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for snapshot in pending {
                let id = UUID(), directory = "items/\(id.uuidString.lowercased())"
                let folder = try ReadbackStore.safeURL(root: root, relative: directory)
                try ReadbackStore.createPrivateDirectory(folder, includingParents: false); created.append(folder)
                try ReadbackStore.writePrivate(snapshot.originalPNG, to: folder.appendingPathComponent("original-snap.png"))
                try ReadbackStore.writePrivate(snapshot.renderedPNG ?? snapshot.originalPNG, to: folder.appendingPathComponent("screen.png"))
                try ReadbackStore.writePrivate(encoder.encode(Source(snapshot)), to: folder.appendingPathComponent("source-snap.json"))
                try ReadbackStore.writePrivate(Data(snapshot.note.utf8), to: folder.appendingPathComponent("narration.txt"))
                sections.append(.init(id: id, capturedAt: snapshot.createdAt, displayName: snapshot.title, directory: directory,
                                      screenshot: directory + "/screen.png", audio: nil, originalTranscript: nil,
                                      transcript: directory + "/narration.txt", status: .ready, failure: nil, deletedAt: nil))
            }
            // A portable folder may also be open elsewhere. Never replace an
            // intervening save while preparing this batch's image files.
            guard try Data(contentsOf: root.appendingPathComponent(ReadbackStore.manifestName)) == originalManifest else {
                throw SnapError.message("The session changed while adding Snaps. Review it and try again.")
            }
            current.sections.append(contentsOf: sections)
            try ReadbackStore.save(current, at: root)
            return .init(manifest: current, added: sections.count, alreadyAdded: snapshots.count - pending.count, warning: nil)
        } catch {
            // The legacy writer can report a permission error after committing
            // session.json. Verify references before removing any owned files.
            if let reopened = try? ReadbackStore.load(from: root) {
                let referenced = Set(reopened.sections.map(\.id)), added = Set(sections.map(\.id))
                if !added.isEmpty, added.isSubset(of: referenced) {
                    return .init(manifest: reopened, added: added.count, alreadyAdded: snapshots.count - pending.count,
                                 warning: "The Snaps were saved, but a file-permission check failed: \(error.localizedDescription)")
                }
                for folder in created where !referenced.contains(UUID(uuidString: folder.lastPathComponent)!) { try? FileManager.default.removeItem(at: folder) }
            }
            throw error
        }
    }
}
