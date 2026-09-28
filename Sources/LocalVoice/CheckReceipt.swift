import Foundation

/// `open` drops a bundle's standard output, so a check started through the
/// signed app can name a new folder for its summary lines and a receipt. The
/// receipt is written whether the check passes or fails.
enum CheckReceipt {
    static func run(mode: String, folder: String?, _ body: (URL?) async throws -> [String]) async throws {
        var output: URL?
        if let folder {
            let url = URL(fileURLWithPath: folder).standardizedFileURL
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw VoiceError.message("Choose a new check folder; existing evidence was kept.")
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            output = url
        }
        let started = Date()
        do {
            let lines = try await body(output)
            print(lines.joined(separator: "\n"))
            if let output { try write(mode: mode, lines: lines, failure: nil, started: started, to: output) }
        } catch {
            if let output { try? write(mode: mode, lines: [], failure: error.localizedDescription, started: started, to: output) }
            throw error
        }
    }

    private static func write(mode: String, lines: [String], failure: String?, started: Date, to folder: URL) throws {
        let build = WorkbenchBuild()
        let receipt: [String: Any] = ["mode": mode, "passed": failure == nil, "failure": failure ?? NSNull(), "lines": lines,
            "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10, "finishedAt": ISO8601DateFormatter().string(from: Date()),
            "edition": build.edition, "version": build.version, "build": build.number, "source": build.revision,
            "bundle": Bundle.main.bundleIdentifier ?? "none", "synthetic": true]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("receipt.json"), options: .atomic)
        let summary = (failure.map { ["FAILED: " + $0] } ?? lines) + ["", build.details]
        try summary.joined(separator: "\n").write(to: folder.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    }
}
