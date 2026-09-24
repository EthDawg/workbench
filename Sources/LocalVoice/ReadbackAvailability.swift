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
