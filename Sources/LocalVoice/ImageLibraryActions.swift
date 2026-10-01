import Foundation

extension DemoLibraryModel {
    /// Resolve the explicitly chosen saved image. A different unfinished Snap
    /// may be suspended in the shared preview host and is never an input here.
    @MainActor func saveCapturedImageToLibrary(_ image: CaptureImagePreviewItem,
        chooseDestination: ((String) -> URL?)? = nil) -> String? {
        do {
            let bytes = try image.render?() ?? CaptureImageLoader.bytes(image.source)
            return saveImageToLibrary(renderedPNG: bytes, title: image.title,
                                      chooseDestination: chooseDestination) ? notice : error
        } catch {
            let message = "The image could not be saved to Library. " + error.localizedDescription
            self.error = message
            return message
        }
    }
}
