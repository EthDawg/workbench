import Foundation

/// A read-only filesystem check. An unavailable volume or denied folder is not
/// evidence that the user deleted it, so never prune recents automatically.
enum ReadbackAvailability {
    static func problem(at root: URL) -> String? {
        do {
            var folder = root
            folder.removeAllCachedResourceValues()
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                return "The session folder is unavailable. It may have been moved, removed or disconnected."
            }
            var manifest = folder.appendingPathComponent("session.json")
            manifest.removeAllCachedResourceValues()
            guard try manifest.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  FileManager.default.isReadableFile(atPath: manifest.path) else {
                return "This folder's session.json is unavailable or cannot be read."
            }
            return nil
        } catch {
            return "The session folder or session.json is unavailable. It may have been moved, removed, disconnected or access may be restricted."
        }
    }
}

/// Reconnecting a folder must resume orphaned work without interrupting owners
/// that are still using its recording or recognition result.
enum ReadbackRecovery {
    static func reconcile(_ value: ReadbackManifest, activeTranscription: UUID?, activeRecording: UUID?) -> ReadbackManifest {
        var current = value
        for index in current.sections.indices where current.sections[index].deletedAt == nil {
            let section = current.sections[index]
            if section.status == .transcribing, section.id != activeTranscription {
                current.sections[index].status = .queued
            } else if section.status == .recording, section.id != activeRecording {
                current.sections[index].status = .needsNarration
                current.sections[index].failure = "Recording was interrupted. The screenshot was kept; record its narration again."
            }
        }
        return current
    }
}
