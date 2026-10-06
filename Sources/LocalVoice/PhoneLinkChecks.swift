import Foundation
import StageKit

/// `LocalVoice --phone-link NEW_FOLDER [SECONDS]`: what this Mac shows of a phone, from the
/// monitor Present uses, run headless for a few seconds (#276). It watches the USB bus and the
/// screen sources macOS offers and reads the camera permission without asking for it. No capture
/// starts and nothing is shown on the phone.
///
/// Each change of status is printed as it happens. A run through the signed app
/// (`open -n … --args`) has no standard output, so the folder is the receipt: `phone-link.txt`
/// holds the facts Copy connection details copies, with no serial number or device identifier,
/// then the changes seen while watching; `receipt.json` holds the final status and its counts.
enum PhoneLinkChecks {
    static let usage = "Usage: --phone-link NEW_FOLDER [SECONDS, 1 to 600; default 8]"

    static func arguments(_ args: [String]) throws -> (folder: URL, seconds: TimeInterval) {
        guard (2...3).contains(args.count) else { throw VoiceError.message(usage) }
        var seconds: TimeInterval = 8
        if args.count == 3 {
            guard let value = TimeInterval(args[2]), (1...600).contains(value) else { throw VoiceError.message(usage) }
            seconds = value
        }
        return (URL(fileURLWithPath: args[1]).standardizedFileURL, seconds)
    }

    @MainActor static func run(folder: URL, seconds: TimeInterval) async throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: folder.path) else {
            throw VoiceError.message("Choose a new folder for the phone receipt; existing evidence was kept.")
        }
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let build = WorkbenchUpdates.shared.build
        print("Watching for a phone for \(Int(seconds)) s. No capture starts and no permission is asked.")
        let started = Date()
        var changes: [String] = []
        let result = await PhoneLinkMonitor.observe(seconds: seconds, build: build.label) { line in
            let stamped = String(format: "%5.1f s  ", Date().timeIntervalSince(started)) + line
            changes.append(stamped)
            print(stamped); fflush(stdout)
        }
        let report = result.report + "\n\nWhile watching for \(Int(seconds)) s:\n" + changes.joined(separator: "\n") + "\n"
        try report.write(to: folder.appendingPathComponent("phone-link.txt"), atomically: true, encoding: .utf8)
        let access: String
        switch result.signals.access {
        case .notDetermined: access = "notDetermined"
        case .authorized: access = "authorized"
        case .denied: access = "denied"
        case .restricted: access = "restricted"
        }
        let receipt: [String: Any] = [
            "mode": "--phone-link", "build": build.label, "version": "\(build.version) (\(build.number))", "source": build.revision,
            "seconds": seconds, "finalTitle": result.status.title, "finalDetail": result.status.detail ?? NSNull(),
            "usbCount": result.signals.usb.count, "sourceCount": result.signals.sources.count, "access": access,
            "changes": changes, "writtenAt": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("receipt.json"), options: .atomic)
        print("\n" + result.report + "\n\nReceipt: " + folder.path)
    }
}
