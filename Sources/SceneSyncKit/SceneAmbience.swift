import Foundation

/// A bounded, app-authored image rig. Geometry and animation belong to trusted
/// native preset definitions, never to executable content in an imported scene.
public struct SceneAmbience: Codable, Equatable, Sendable {
    public var version: Int
    public var preset: String
    public var cleanPlate: String
    public var detail: String

    public init(version: Int = 1, preset: String, cleanPlate: String, detail: String) {
        self.version = version; self.preset = preset
        self.cleanPlate = cleanPlate; self.detail = detail
    }

    public var assets: Set<String> { [cleanPlate, detail] }

    public func validate() throws {
        guard version == 1, ["window-light", "campus-breeze", "coastal-sky"].contains(preset)
        else { throw SceneDocumentError.futureVersion }
        guard assets.allSatisfy(SceneAsset.isName) else {
            throw SceneDocumentError.invalid("This scene's motion pictures are not valid. Its original has been kept.")
        }
    }

    public func validated() throws -> Self { try validate(); return self }
}
