import Foundation

enum ReadbackResources {
    // Explicit payload: no private examples, caches or unrelated bundle files travel.
    static let deckFiles = [
        "SKILL.md", "requirements.txt", "brand/brand.json",
        "brand/assets/bg_purple.jpg", "brand/assets/bg_thankyou.jpg",
        "brand/assets/deco_hex.png", "brand/assets/logo_wordmark.png",
        "brand/assets/logo_wordmark_closing.png",
        "scripts/session_outline.py", "scripts/session_io.py", "scripts/build_deck.py"
    ]

    /// SwiftPM's generated Bundle.module accessor traps if its development
    /// paths are absent. A shipped Mac app owns resources under Contents/Resources.
    /// Resolve those explicitly; a broken package must produce an error, not a trap.
    static func deckPayload(in application: Bundle = .main) throws -> [String: Data] {
        let name = "Workbench_LocalVoice.bundle"
        var locations = [application.resourceURL?.appendingPathComponent(name)].compactMap { $0 }
        if application.bundleURL.pathExtension != "app" {
            // `swift run` / CLI checks keep the resource bundle beside the executable.
            locations.append(application.bundleURL.appendingPathComponent(name))
            if let executable = application.executableURL {
                locations.append(executable.deletingLastPathComponent().appendingPathComponent(name))
            }
        }
        for location in locations {
            guard let resources = Bundle(url: location),
                  let url = resources.url(forResource: "SKILL", withExtension: "md", subdirectory: "build-snap-and-talk-deck") else { continue }
            let root = url.deletingLastPathComponent()
            var payload: [String: Data] = [:]
            for path in deckFiles {
                let file = root.appendingPathComponent(path)
                guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true,
                      let data = try? Data(contentsOf: file), !data.isEmpty else { break }
                payload[path] = data
            }
            if payload.count == deckFiles.count,
               let skill = payload["SKILL.md"], String(data: skill, encoding: .utf8) != nil { return payload }
        }
        throw ReadbackError.message("This Workbench installation is missing its readable Snap & Talk deck skill. Reinstall a complete Workbench app. No session was created.")
    }
}
