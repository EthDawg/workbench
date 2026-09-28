import AppKit

/// Where a standalone capture's image comes from. The app uses `SnapCapture`;
/// checks pass a synthetic source, so they never capture the screen.
@MainActor
protocol SnapImageSource: AnyObject {
    /// Nanoseconds to wait after Workbench's windows hide, so the image never includes them.
    var settleDelay: UInt64 { get }
    /// The captured PNG, or nil when the person cancelled the selector.
    func capture(_ mode: SnapCapture.Mode) async throws -> Data?
    func cancel()
}

/// How a standalone capture ended, so the host can finish every door the same way.
enum SnapCaptureOutcome: Equatable {
    /// A new capture is open in the editor.
    case draft(UUID)
    /// An earlier Snap is still open in the editor; nothing new was captured.
    case pending
    /// Escape or Cancel capture: nothing was added.
    case cancelled
    /// The screen could not be captured; the model's notice says why.
    case failed
}

/// Apple owns region/window selection and Escape. Its output is directed only
/// to an owned private temporary directory, never Desktop or a configured path.
@MainActor
final class SnapCapture: SnapImageSource {
    enum Mode: String, CaseIterable, Identifiable {
        case region, window, screen
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var source: SnapSource { SnapSource(rawValue: rawValue)! }
    }
    private var process: Process?
    /// Gives WindowServer a frame to remove Workbench's hidden windows before acquiring.
    let settleDelay: UInt64 = 250_000_000

    func cancel() { if process?.isRunning == true { process?.terminate() } }

    func capture(_ mode: Mode) async throws -> Data? {
        guard process == nil else { throw SnapError.message("Finish the current capture first.") }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw SnapError.message("Allow Workbench to record the screen in System Settings, then capture again.")
        }
        if mode == .screen { return try await ReadbackScreenCapture.currentDisplay().data }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory); process = nil }
        let output = directory.appendingPathComponent("capture.png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-t", "png", "-i"] + (mode == .region ? ["-s"] : ["-w", "-o"]) + [output.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        process = task
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try task.run() }
            catch { task.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            // Escape (and Control-to-clipboard in Apple's picker) has no owned
            // file. It never creates an empty history item or reads clipboard.
            if status == 0 || status == 1 || status == SIGTERM { return nil }
            throw SnapError.message("The screen could not be captured. Check Screen Recording access and try again.")
        }
        let values = try output.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= SnapStore.maximumImageBytes else {
            throw SnapError.message("The capture is too large or unavailable.")
        }
        let bytes = try Data(contentsOf: output)
        _ = try SnapRendering.dimensions(bytes)
        return bytes
    }
}
