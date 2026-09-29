import AppKit
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
    @StateObject private var camera: ProfileCamera
    @State private var editors = PersonaEditorHolder()
    @State private var replacement: SavedPersona?
    @State private var notice: String?
    private var persona: SavedPersona? { LocalPersonaProfile.persona(in: library, defaults: defaults) }

    @MainActor init(library: PersonaLibrary, defaults: UserDefaults, changed: @escaping () -> Void,
         openPersona: @escaping () -> Void = {}, camera: ProfileCamera? = nil) {
        self.library = library; self.defaults = defaults; self.changed = changed; self.openPersona = openPersona
        _camera = StateObject(wrappedValue: camera ?? ProfileCamera())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if camera.isPresented {
                ProfileCameraView(camera: camera, captured: prepare) {
                    camera.cancel()
                    choosePhoto()
                }
            } else { profile }
        }.padding(24).frame(width: 470).background(Workbench.background).workbenchTheme()
            .sheet(item: $editors.current) { session in
                PersonaCardEditor(library: library, session: session, replacing: replacement,
                                  confirmationTitle: session.isNew ? "Use photo" : nil) { id in
                    if LocalPersonaProfile.choose(id, in: library, defaults: defaults) { library.objectWillChange.send(); changed() }
                }
            }
            .onDisappear { camera.cancel() }
    }
    private var profile: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Your profile").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
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
                    notice = nil; camera.start()
                }.disabled(library.isReadOnly).help("Allow Camera access, then take and review a photo")
                Button("Choose photo…") { choosePhoto() }.disabled(library.isReadOnly)
                if let persona {
                    Button("Edit appearance…") { replacement = nil; editors.open(.saved(persona)) }
                        .disabled(library.isReadOnly)
                }
            }
            if persona == nil, let selected = library.selected {
                Button("Use \(selected.name) as Me") {
                    if LocalPersonaProfile.choose(selected.id, in: library, defaults: defaults) { library.objectWillChange.send(); changed() }
                }.buttonStyle(.link).disabled(library.isReadOnly)
            }
            if let persona {
                Button("Open Me in Persona") {
                    library.prepareGroup(nil); library.selectedID = persona.id
                    dismiss(); openPersona()
                }.buttonStyle(.link)
            }
            Text("Taking or choosing a photo opens a preview. Use photo saves it as your Me persona; Cancel keeps everything as it was.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = notice ?? library.notice {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
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
