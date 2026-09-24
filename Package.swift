// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Extraction flags apply only to our app target, never to dependency builds.
let environment = ProcessInfo.processInfo.environment
var intentSettings: [SwiftSetting] = []
if let protocols = environment["VOICE_INTENT_PROTOCOLS"], let output = environment["VOICE_INTENT_VALUES"] {
    intentSettings = [.unsafeFlags(["-Xfrontend", "-const-gather-protocols-file", "-Xfrontend", protocols,
                                   "-emit-const-values-path", output])]
}

let package = Package(
    name: "Workbench",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalVoice", targets: ["LocalVoice"]),
               .executable(name: "WorkbenchBrowserHost", targets: ["WorkbenchBrowserHost"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
                   .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "ToolbarCore"),
        .target(name: "ToolbarKit", dependencies: ["ToolbarCore"]),
        .executableTarget(name: "ToolbarGalleryRenderer", dependencies: ["ToolbarKit", "StageKit"]),
        .testTarget(name: "ToolbarKitTests", dependencies: ["ToolbarKit", "StageKit"]),
        .testTarget(name: "ToolbarCoreTests", dependencies: ["ToolbarCore"]),
        .target(name: "PresenterKit"),
        .testTarget(name: "PresenterKitTests", dependencies: ["PresenterKit"]),
        .executableTarget(name: "WorkbenchBrowserHost", dependencies: ["PresenterKit"]),
        .target(name: "PhotoHandoffKit"),
        .testTarget(name: "PhotoHandoffKitTests", dependencies: ["PhotoHandoffKit"]),
        .target(name: "SceneSyncKit"),
        .testTarget(name: "SceneSyncKitTests", dependencies: ["SceneSyncKit"]),
        .target(name: "StageKit", dependencies: ["SceneSyncKit", "PhotoHandoffKit"], linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "LocalVoice", dependencies: ["ToolbarCore", "ToolbarKit", "StageKit", "PhotoHandoffKit", "PresenterKit", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources/build-snap-and-talk-deck")], swiftSettings: intentSettings, linkerSettings: [.linkedFramework("Carbon"), .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]) ])
    ],
    swiftLanguageModes: [.v5]
)
