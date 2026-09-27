import Foundation

// These checks exercise actual Snap models/stores. Native acquisition and the
// app's edition path are deliberately unreachable, so fixtures cannot capture
// a screen or write to an installed user's library.
enum Workbench {
    static func supportDirectory(component: String) -> URL { fatalError("Pass the synthetic store explicitly") }
}
struct ReadbackScreenshot { let data: Data }
enum ReadbackScreenCapture {
    @MainActor static func currentDisplay() async throws -> ReadbackScreenshot { fatalError("Native screen capture is outside this fixture") }
}
