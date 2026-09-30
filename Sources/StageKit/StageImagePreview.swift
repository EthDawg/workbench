import AppKit

/// A frozen choice, rendered only when opened. The host owns the image window;
/// StageKit retains ownership of scene and persona preparation.
public struct StageImagePreview {
    public let id: UUID
    public let title: String
    public let detail: String
    public let png: @MainActor () throws -> Data
}

extension DemoScenes {
    func viewImages(startingAt id: UUID) {
        let size = outputSize
        let images = matches.map { scene in
            StageImagePreview(id: scene.id, title: scene.name, detail: "Scene · Edit a copy to save an image in Snap History") { [weak self] in
                guard let self, let image = self.image(for: scene) else { throw SceneError.noScene }
                return try self.renderPNG(scene, image: image, size: size)
            }
        }
        onViewImages?(images, id)
    }
}

extension PersonaLibrary {
    func viewImages(startingAt id: UUID) {
        let images = visibleItems.map { persona in
            StageImagePreview(id: persona.id, title: persona.name, detail: "Persona · Edit a copy to save an image in Snap History") { [weak self] in
                guard let image = self?.renderedImage(for: persona),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let bytes = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { throw SceneError.noScene }
                return bytes
            }
        }
        onViewImages?(images, id)
    }
}
