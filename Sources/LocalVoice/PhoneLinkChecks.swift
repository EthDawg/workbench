import Foundation
import StageKit

/// `LocalVoice --phone-link NEW_FOLDER [SECONDS]`: what this Mac shows of a phone, from the
/// monitor Present uses, run headless for a few seconds (#276). It watches the USB bus and the
/// screen sources macOS offers and reads the camera permission without asking for it. No capture
/// starts and nothing is shown on the phone.
///
/// Each change of status is printed as it happens. A run through the signed app
/// (`open -n … --args`) has no standard output, so the folder is the receipt: `phone-link.txt`
/// holds the facts Copy connection details copies, with no serial number, device identifier or device name,
/// then the changes seen while watching; `receipt.json` holds the final status and its counts.
enum PhoneLinkChecks {
    static let usage = "Usage: --phone-link NEW_FOLDER [SECONDS, 1 to 600; default 8] [--live]"

    /// `--live` also runs the capture session headless, which needs camera access and proves frames arrive.
    static func arguments(_ args: [String]) throws -> (folder: URL, seconds: TimeInterval, live: Bool) {
        var rest = Array(args.dropFirst())
        let live = rest.contains("--live")
        rest.removeAll { $0 == "--live" }
        guard (1...2).contains(rest.count) else { throw VoiceError.message(usage) }
        var seconds: TimeInterval = 8
        if rest.count == 2 {
            guard let value = TimeInterval(rest[1]), (1...600).contains(value) else { throw VoiceError.message(usage) }
            seconds = value
        }
        return (URL(fileURLWithPath: rest[0]).standardizedFileURL, seconds, live)
    }

    @MainActor static func run(folder: URL, seconds: TimeInterval, live: Bool = false) async throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: folder.path) else {
            throw VoiceError.message("Choose a new folder for the phone receipt; existing evidence was kept.")
        }
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let build = WorkbenchUpdates.shared.build
        print(live ? "Watching for a phone for \(Int(seconds)) s and running the capture headless; macOS may ask for camera access."
                   : "Watching for a phone for \(Int(seconds)) s. No capture starts and no permission is asked.")
        let started = Date()
        var changes: [String] = []
        let onChange: (String) -> Void = { line in
            let stamped = String(format: "%5.1f s  ", Date().timeIntervalSince(started)) + line
            changes.append(stamped)
            print(stamped); fflush(stdout)
        }
        var liveResult: (firstFrame: TimeInterval?, size: CGSize)? = nil
        let result: (signals: PhoneLinkSignals, status: PhoneLinkStatus, report: String)
        if live {
            let observed = await PhoneLinkMonitor.observeLive(seconds: seconds, build: build.label, onChange: onChange)
            liveResult = (observed.firstFrame, observed.size)
            result = (observed.signals, observed.status, observed.report)
        } else {
            result = await PhoneLinkMonitor.observe(seconds: seconds, build: build.label, onChange: onChange)
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
        let usbProbe: String
        switch result.signals.usbProbe {
        case .notChecked: usbProbe = "notChecked"
        case .checked: usbProbe = "checked"
        case .failed(let code): usbProbe = String(format: "failed 0x%08X", UInt32(bitPattern: code))
        }
        // The status words are the report's: device names are replaced by their kinds.
        var receipt: [String: Any] = [
            "mode": "--phone-link", "build": build.label, "version": "\(build.version) (\(build.number))", "source": build.revision,
            "seconds": seconds, "finalTitle": result.status.title, "finalDetail": result.status.detail ?? NSNull(),
            "usbProbe": usbProbe, "usbCount": result.signals.usb.count, "sourceCount": result.signals.sources.count, "access": access,
            "changes": changes, "writtenAt": ISO8601DateFormatter().string(from: Date())]
        if let liveResult {
            let firstFrame: Any = liveResult.firstFrame.map { $0 as Any } ?? NSNull()
            receipt["live"] = ["firstFrameSeconds": firstFrame, "width": Int(liveResult.size.width), "height": Int(liveResult.size.height)] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("receipt.json"), options: .atomic)
        print("\n" + result.report + "\n\nReceipt: " + folder.path)
    }
}
