import AppKit

/// Every SF Symbol StageKit names must exist on the Mac running the checks: a missing one
/// draws nothing, as "iphone.and.landscape" did on Present's empty state and Scenes heading
/// on macOS 26.5. Literal names come from the sources (run from the repository root, as
/// scripts/test-stage.sh does); the phone status's symbols come from its own property.
final class SymbolTests {
    func testEverySymbolStageKitNamesExists() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/StageKit")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "StageKit's sources are read from the repository root")
        let pattern = try NSRegularExpression(pattern: #"(?:systemName|systemImage|systemSymbolName):\s*"([A-Za-z0-9.]+)""#)
        var names: [String: String] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                names[String(text[range])] = file.lastPathComponent
            }
        }
        XCTAssertGreaterThan(names.count, 20, "Symbol names were found")
        let phases: [PhoneLinkStatus.Phase] = [.noPhone, .usbUnavailable, .phoneOnUSB, .screenFound, .chooseScreen, .waitingForRemembered, .available,
            .connecting, .live, .stalled, .interrupted, .busy, .couldNotOpen, .couldNotStart, .accessPending, .accessDenied, .accessRestricted, .released, .ended]
        for phase in phases { names[PhoneLinkStatus(phase: phase, title: "", detail: nil, step: nil).symbol] = "PhoneLink.swift (\(phase))" }
        for (name, file) in names.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(file) names \"\(name)\", which this macOS does not have")
        }
    }
}
