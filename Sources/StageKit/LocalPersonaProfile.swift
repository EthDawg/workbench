import AppKit
import AVFoundation
import Quartz
import SwiftUI

/// A single reference in the existing edition's preferences; Persona remains the image owner.
enum LocalPersonaProfile {
    static let key = "persona.me.id.v1"
    static func persona(in library: PersonaLibrary, defaults: UserDefaults) -> SavedPersona? {
        guard let value = defaults.string(forKey: key), let id = UUID(uuidString: value) else { return nil }
        return library.items.first { $0.id == id }
    }
    static func choose(_ id: UUID, in library: PersonaLibrary, defaults: UserDefaults) -> Bool {
        guard library.items.contains(where: { $0.id == id }) else { return false }
        defaults.set(id.uuidString, forKey: key)
        return true
    }
}

/// The same portrait draft and appearance editor as Persona. Opening the profile does not
/// open a camera, request permission, select a different persona or write a file.
struct LocalPersonaProfileView: View {
    @ObservedObject var library: PersonaLibrary
    let defaults: UserDefaults
    var changed: () -> Void
    var openPersona: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = ProfilePictureTaker()
    @State private var editors = PersonaEditorHolder()
    @State private var replacement: SavedPersona?
    @State private var notice: String?
    private var persona: SavedPersona? { LocalPersonaProfile.persona(in: library, defaults: defaults) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Your profile").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(camera.isBusy)
            }
            HStack(spacing: 18) {
                Group {
                    if let persona, let image = library.renderedImage(for: persona) { Image(nsImage: image).resizable().scaledToFit() }
                    else { Image(systemName: "person.crop.circle").resizable().scaledToFit().foregroundStyle(.secondary).padding(12) }
                }.frame(width: 88, height: 88).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Me").font(.title3.weight(.semibold))
                    Text("Use your photo as a Persona when you present.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Saved on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Take photo…") {
                    camera.takePhoto(in: NSApp.keyWindow) { image in prepare(image) }
                }.disabled(library.isReadOnly || camera.isBusy).help("Allow Camera access, then take and review a photo")
                Button("Choose photo…") { choosePhoto() }.disabled(library.isReadOnly || camera.isBusy)
                if let persona {
                    Button("Edit appearance…") { replacement = nil; editors.open(.saved(persona)) }
                        .disabled(library.isReadOnly || camera.isBusy)
                }
            }
            if persona == nil, let selected = library.selected {
                Button("Use \(selected.name) as Me") {
                    if LocalPersonaProfile.choose(selected.id, in: library, defaults: defaults) { library.objectWillChange.send(); changed() }
                }.buttonStyle(.link).disabled(library.isReadOnly || camera.isBusy)
            }
            if let persona {
                Button("Open Me in Persona") {
                    library.prepareGroup(nil); library.selectedID = persona.id
                    dismiss(); openPersona()
                }.buttonStyle(.link).disabled(camera.isBusy)
            }
            Text("Taking or choosing a photo opens a preview. Use photo saves it as your Me persona; Cancel keeps everything as it was.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = notice ?? camera.notice ?? library.notice {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if camera.permissionDenied {
                Button("Open Camera settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
                }
            }
            if camera.isBusy { ProgressView("Waiting for your photo…").controlSize(.small) }
        }.padding(24).frame(width: 470).background(Workbench.background).workbenchTheme()
            .sheet(item: $editors.current) { session in
                PersonaCardEditor(library: library, session: session, replacing: replacement,
                                  confirmationTitle: session.isNew ? "Use photo" : nil) { id in
                    if LocalPersonaProfile.choose(id, in: library, defaults: defaults) { library.objectWillChange.send(); changed() }
                }
            }
            .onDisappear { camera.cancel() }
    }
    private func choosePhoto() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = LogoImport.contentTypes
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a photo for your Me persona. You can review its appearance before saving."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { open(try library.portraitDraft(from: url, card: PersonaCardStyle(), name: "Me")) }
            catch { notice = error.localizedDescription }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func prepare(_ image: NSImage) {
        do {
            guard let data = image.tiffRepresentation else { throw PersonaError.unreadableImage }
            let imported = LogoImport.Image(png: try LogoImport.normalizedPNG(data), name: "Me")
            open(try PersonaPortraitDraft(imported, card: PersonaCardStyle(), name: "Me"))
        } catch { notice = error.localizedDescription }
    }
    private func open(_ draft: PersonaPortraitDraft) {
        guard editors.current == nil else { return }
        replacement = persona; notice = nil
        editors.open(.new(draft))
    }
}

/// Apple's native picture taker owns the camera preview and its shutter. Its recent-picture
/// store is off: a photo stays in memory until the Persona editor's explicit confirmation.
@MainActor
final class ProfilePictureTaker: NSObject, ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var notice: String?
    @Published private(set) var permissionDenied = false
    private var generation = UUID()
    private var picker: IKPictureTaker?
    private var completion: ((NSImage) -> Void)?

    func takePhoto(in window: NSWindow?, completion: @escaping (NSImage) -> Void) {
        guard !isBusy else { return }
        isBusy = true; notice = nil; permissionDenied = false
        let request = UUID(); generation = request
        Task { [weak self, weak window] in
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            guard let self, self.generation == request else { return }
            guard authorized else {
                self.isBusy = false; self.permissionDenied = true
                self.notice = "Camera access is off. Allow it in Camera settings, or choose a photo from a file."
                return
            }
            guard let window else { self.isBusy = false; return }
            guard let picker = IKPictureTaker.pictureTaker() else {
                self.isBusy = false; self.notice = "The camera preview could not open. Choose a photo from a file instead."; return
            }
            self.picker = picker; self.completion = completion
            picker.setValue(true, forKey: IKPictureTakerAllowsVideoCaptureKey)
            picker.setValue(false, forKey: IKPictureTakerAllowsFileChoosingKey)
            picker.setValue(false, forKey: IKPictureTakerShowRecentPictureKey)
            picker.setValue(false, forKey: IKPictureTakerUpdateRecentPictureKey)
            picker.setValue(false, forKey: IKPictureTakerShowAddressBookPictureKey)
            picker.setValue(false, forKey: IKPictureTakerShowEffectsKey)
            picker.setValue(NSValue(size: NSSize(width: 1600, height: 1600)), forKey: IKPictureTakerOutputImageMaxSizeKey)
            picker.setValue("Take a photo for your Me persona.", forKey: IKPictureTakerInformationalTextKey)
            picker.setInputImage(nil)
            picker.beginSheet(for: window, withDelegate: self,
                              didEnd: #selector(finished(_:returnCode:contextInfo:)), contextInfo: nil)
        }
    }
    @objc private func finished(_ picker: IKPictureTaker, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        let image = returnCode == NSApplication.ModalResponse.OK.rawValue ? picker.outputImage() : nil
        let completed = completion
        self.picker = nil; completion = nil; isBusy = false
        picker.setInputImage(nil)
        if let image { completed?(image) }
    }
    func cancel() {
        generation = UUID(); completion = nil; isBusy = false
        if let picker {
            if let parent = picker.sheetParent { parent.endSheet(picker, returnCode: .cancel) }
            picker.orderOut(nil); self.picker = nil
        }
    }
}
