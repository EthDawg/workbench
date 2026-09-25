import Foundation

enum ReadbackResources {
    /// SwiftPM's generated Bundle.module accessor traps if its development
    /// paths are absent. A shipped Mac app owns resources under Contents/Resources.
    /// Resolve those explicitly; a broken package must produce an error, not a trap.
    static func deckSkill(in application: Bundle = .main) throws -> Data {
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
                  let url = resources.url(forResource: "SKILL", withExtension: "md", subdirectory: "build-snap-and-talk-deck"),
                  let data = try? Data(contentsOf: url), !data.isEmpty,
                  String(data: data, encoding: .utf8) != nil else { continue }
            return data
        }
        throw ReadbackError.message("This Workbench installation is missing its readable Snap & Talk deck skill. Reinstall a complete Workbench app. No session was created.")
    }
}
