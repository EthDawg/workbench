import Foundation
import Darwin

/// A saved response, bounded before and during its read. UTF-8, whitespace and
/// line endings stay exact; corrupt, replaced and oversized files are unavailable.
enum HandoffResultFile {
    static let maximumBytes = 2_000_000
    struct Contents { var text: String?; var problem: String? }

    static func read(directory: URL, folder: URL) -> Contents {
        func unavailable(_ reason: String) -> Contents { .init(problem: reason + " Show selected files opens the task folder.") }
        guard HandoffJobStore.isRealFolder(directory), HandoffJobStore.isRealFolder(folder) else {
            return unavailable("The task folder was replaced outside Workbench. Its result is unavailable.")
        }
        let url = folder.appendingPathComponent("result.md")
        // Do not follow a result swapped for a link or wait on a special file.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return unavailable("The saved result is missing or can’t be read.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            return unavailable("The saved result is not an ordinary text file.")
        }
        guard status.st_size <= maximumBytes else { return unavailable("The saved result is too large to review here (over 2 MB).") }
        let data: Data
        do { data = try file.read(upToCount: maximumBytes + 1) ?? Data() }
        catch { return unavailable("The saved result can’t be read.") }
        guard data.count <= maximumBytes else { return unavailable("The saved result is too large to review here (over 2 MB).") }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0000}") else {
            return unavailable("The saved result is not valid UTF-8 text.")
        }
        return .init(text: text)
    }
}
