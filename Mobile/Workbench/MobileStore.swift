import SwiftUI
import UIKit
import ImageIO

@MainActor final class MobileStore: ObservableObject {
    @Published private(set) var document = MobileDocument()
    @Published var error: String?
    @Published private(set) var writesDisabled = false
    let disk: MobileDocumentStore

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Workbench", isDirectory: true)
        disk = MobileDocumentStore(directory: root)
        do { document = try disk.load() }
        catch { self.error = "Your library could not be opened. Saving is paused to preserve it. \(error.localizedDescription)"; writesDisabled = true }
    }

    @discardableResult func change(_ edit: (inout MobileDocument) -> Void) -> Bool {
        guard !writesDisabled else { error = "Saving is paused because your library could not be opened. Your existing files are unchanged."; return false }
        var next = document; edit(&next)
        do { try disk.save(next); document = next; return true }
        catch { self.error = "Could not save this change. \(error.localizedDescription)"; return false }
    }

    @discardableResult func saveText(_ text: String, original: String, id: UUID? = nil, audioURL: URL? = nil) -> UUID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var record = document.texts.first { $0.id == id } ?? MobileText(title: "", original: original, text: text)
        record.title = String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(80) ?? "Saved text")
        record.text = text; record.modified = Date()
        if let audioURL {
            do { record.audioAsset = try disk.importAsset(Data(contentsOf: audioURL), suffix: ["caf", "m4a", "wav", "mp3"].contains(audioURL.pathExtension) ? audioURL.pathExtension : "audio") }
            catch { self.error = "Could not save the original audio. \(error.localizedDescription)"; return nil }
        }
        let saved = record
        return change { state in state.texts.removeAll { $0.id == saved.id }; state.texts.insert(saved, at: 0) } ? saved.id : nil
    }

    /// Paste replaces the whole editor. Keep the previous draft and install its
    /// replacement in one disk transaction before the view changes either value.
    @discardableResult func replaceDraftWithPaste(_ text: String, preserving draft: String,
                                                  original: String, savedID: UUID?) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard text.count <= 50_000 else { error = "Choose a passage under 50,000 characters. Your draft is unchanged."; return false }
        return change { state in
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var saved = state.texts.first { $0.id == savedID }
                    ?? MobileText(title: "", original: original.isEmpty ? draft : original, text: draft)
                saved.title = String(draft.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(80) ?? "Saved text")
                saved.text = draft; saved.modified = Date()
                state.texts.removeAll { $0.id == saved.id }; state.texts.insert(saved, at: 0)
            }
            state.draft = text; state.draftOriginal = text
        }
    }

    func image(_ project: MobileImageProject, maxPixels: Int = 2400) -> UIImage? { imageAsset(project.asset, maxPixels: maxPixels) }
    func imageAsset(_ name: String, maxPixels: Int = 2400) -> UIImage? {
        guard let url = disk.assetURL(name), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    func importImage(_ data: Data, kind: MobileImageKind, title: String = "Untitled") -> MobileImageProject? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { error = "This file is not a supported image."; return nil }
        do {
            let name = try disk.importAsset(data, suffix: "image")
            let project = MobileImageProject(title: title, kind: kind, asset: name)
            return change { $0.images.insert(project, at: 0) } ? project : nil
        } catch { self.error = error.localizedDescription; return nil }
    }

    func importLayer(_ data: Data) -> String? {
        guard CGImageSourceCreateWithData(data as CFData, nil) != nil else { error = "Choose a supported image."; return nil }
        do { return try disk.importAsset(data, suffix: "image") } catch { self.error = error.localizedDescription; return nil }
    }

    @discardableResult func updateImage(_ project: MobileImageProject) -> Bool {
        var next = project; next.modified = Date()
        return change { state in
            if let i = state.images.firstIndex(where: { $0.id == project.id }) { state.images[i] = next }
            else { state.images.insert(next, at: 0) }
        }
    }

    func reuse(_ project: MobileImageProject, as kind: MobileImageKind) -> MobileImageProject? {
        let copy = MobileImageProject(title: project.title, kind: kind, asset: project.asset)
        return updateImage(copy) ? copy : nil
    }

    func deleteText(_ id: UUID) { change { $0.texts.removeAll { $0.id == id } } }
    func deleteImage(_ id: UUID) { change { $0.images.removeAll { $0.id == id } } }
    // Retained original assets intentionally outlive individual records in Preview.
    // Reclamation requires a separately tested reference/export recovery transaction.
}
