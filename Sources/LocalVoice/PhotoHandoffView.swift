import AppKit
import ImageIO
import PhotoHandoffKit
import SwiftUI
import UniformTypeIdentifiers

struct PhotoBackdropRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

/// This collection displays only locally committed handoff records. The shared
/// model owns cloud eligibility, account boundaries and download validation.
struct PhotoHandoffView: View {
    @ObservedObject var handoff: PhotoHandoffModel
    var onUseAsBackdrop: ((URL, String) -> Void)?
    @State private var selection: UUID?
    @State private var notice: String?
    @State private var savePanel: NSSavePanel?
    @State private var saving = false
    @State private var copyTask: Task<Void, Never>?
    @State private var removingLocal: UUID?
    @State private var removingCloud: UUID?

    private var selected: HandoffPhoto? { handoff.photos.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From iPhone").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                    Text("The photos you send, ready for their next use.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await handoff.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.disabled(!handoff.isEnabled || !handoff.isConfigured || handoff.isBusy)
                    .accessibilityIdentifier("handoff.refresh")
            }
            if handoff.isConfigured {
                PhotoHandoffSettings(handoff: handoff, showsError: false)
            }
            if let message = notice ?? handoff.error {
                HStack(alignment: .top) {
                    Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { notice = nil; handoff.error = nil } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss photo notice")
                }.font(.caption).foregroundStyle(.orange)
            }
            if handoff.photos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.and.arrow.forward").font(.system(size: 36, weight: .light)).foregroundStyle(Workbench.accent)
                    Text("A photo now. A useful starting point later.").font(.headline)
                    Text("On iPhone or iPad, open Workbench and choose Take a photo for Mac. Take or select a photo, then send it.\nOpen Workbench on this Mac to check for arrivals.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    Text("Only photos you choose are shared. Other saved work stays independent.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 24)
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(handoff.photos) { photo in
                            HStack(spacing: 10) {
                                HandoffThumbnail(url: handoff.fileURL(for: photo), maximumPixels: 180)
                                    .frame(width: 64, height: 58)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(photo.title).fontWeight(.medium).lineLimit(2)
                                    Text(photo.statusLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.padding(.vertical, 4).tag(photo.id)
                                .accessibilityElement(children: .combine)
                        }
                    }.listStyle(.sidebar).frame(minWidth: 210, idealWidth: 250, maxWidth: 300)
                        .accessibilityLabel("Photos from iPhone")
                        .accessibilityIdentifier("handoff.photos")
                    if let selected {
                        detail(selected).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        Text("Choose a photo to preview it.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .confirmationDialog("Remove this photo from this Mac?", isPresented: Binding(
            get: { removingLocal != nil }, set: { if !$0 { removingLocal = nil } }), presenting: removingLocal) { id in
                Button("Remove from this Mac", role: .destructive) {
                    do { try handoff.removeLocalPhoto(id) } catch { handoff.error = error.localizedDescription }
                }
            } message: { _ in Text("The local handoff copy is removed. Photos in iCloud and pictures already used in a scene are kept. Save a copy first if needed.") }
        .confirmationDialog("Remove this photo from private iCloud?", isPresented: Binding(
            get: { removingCloud != nil }, set: { if !$0 { removingCloud = nil } }), presenting: removingCloud) { id in
                Button("Remove from private iCloud", role: .destructive) { Task { await handoff.removeFromCloud(id) } }
            } message: { _ in Text("Copies already downloaded or used in a scene are kept. This does not erase those independent copies.") }
        .onAppear { reconcileSelection() }
        .onChange(of: handoff.photos.map(\.id)) { _, _ in reconcileSelection() }
        .onDisappear { savePanel?.cancel(nil); savePanel = nil; copyTask?.cancel(); copyTask = nil; saving = false }
    }

    private func detail(_ photo: HandoffPhoto) -> some View {
        let url = handoff.fileURL(for: photo)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HandoffThumbnail(url: url, maximumPixels: 1200)
                    .frame(maxWidth: .infinity).frame(height: 250)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Preview of " + photo.title)
                HStack {
                    Text(photo.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Spacer()
                    Menu {
                        if photo.isUploaded {
                            Button("Remove from private iCloud…", role: .destructive) { removingCloud = photo.id }
                                .disabled(!handoff.isEnabled || handoff.isBusy)
                        }
                        Button("Remove from this Mac…", role: .destructive) { removingLocal = photo.id }
                            .disabled(handoff.isBusy)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Photo options")
                        .disabled(saving)
                }
                Text(photo.sourceDevice + " · " + photo.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Text(photo.statusLabel).font(.callout).foregroundStyle(.secondary)
                if url == nil {
                    Label("The local copy could not be opened. Enable handoff and refresh to try again.", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { useButton(photo, url: url); saveButton(photo, url: url) }
                    VStack(alignment: .leading) { useButton(photo, url: url); saveButton(photo, url: url) }
                }
                Text("Use as backdrop opens a preview for a saved scene. Its other layers stay in place, and nothing changes until you apply.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("This is an optimised JPEG copy. Your chosen original stays on the sending device.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func useButton(_ photo: HandoffPhoto, url: URL?) -> some View {
        Button("Use as backdrop…") {
            guard let fresh = handoff.fileURL(for: photo) else { notice = "This photo is no longer available locally. Refresh and try again."; return }
            onUseAsBackdrop?(fresh, photo.title)
        }.buttonStyle(.borderedProminent).disabled(url == nil || onUseAsBackdrop == nil || saving)
            .accessibilityIdentifier("handoff.use-backdrop")
    }

    private func saveButton(_ photo: HandoffPhoto, url: URL?) -> some View {
        Button("Save a copy…") { saveCopy(photo) }.disabled(url == nil || saving)
            .accessibilityIdentifier("handoff.save-copy")
    }

    private func reconcileSelection() {
        if !handoff.photos.contains(where: { $0.id == selection }) { selection = handoff.photos.first?.id }
    }

    private func saveCopy(_ photo: HandoffPhoto) {
        guard !saving, let source = handoff.fileURL(for: photo) else { notice = "The local photo is unavailable. Refresh and try again."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        let title = photo.title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
        panel.nameFieldStringValue = String(title.prefix(120)) + ".jpg"
        panel.message = "Save an independent copy. The photo in Workbench stays available."
        savePanel = panel; saving = true; notice = nil
        let completion: (NSApplication.ModalResponse) -> Void = { [weak panel] response in
            let destination = panel?.url
            savePanel = nil
            guard response == .OK, let destination else { saving = false; return }
            guard destination.standardizedFileURL != source.standardizedFileURL else {
                saving = false; notice = "Choose another location to save an independent copy."
                return
            }
            copyTask = Task {
                defer { saving = false; copyTask = nil }
                do {
                    let work = Task.detached(priority: .userInitiated) { try Data(contentsOf: source, options: .mappedIfSafe) }
                    let bytes = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                    try Task.checkCancellation()
                    let access = destination.startAccessingSecurityScopedResource()
                    defer { if access { destination.stopAccessingSecurityScopedResource() } }
                    try bytes.write(to: destination, options: .atomic)
                    notice = "Copy saved as \(destination.lastPathComponent)."
                } catch is CancellationError { }
                catch { notice = "The copy could not be saved. " + error.localizedDescription }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

struct PhotoHandoffSettings: View {
    @ObservedObject var handoff: PhotoHandoffModel
    var showsError = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Photo handoff", systemImage: "icloud").font(.headline)
                Spacer()
                if handoff.isBusy { ProgressView().controlSize(.small).accessibilityLabel("Checking photo handoff") }
                if handoff.isEnabled {
                    Button("Turn off") { handoff.disable() }.help("Stop cloud work. Downloaded photos stay on this Mac.")
                } else {
                    Button("Enable photo handoff") { Task { await handoff.enable() } }
                        .disabled(!handoff.isConfigured || handoff.isBusy)
                        .accessibilityIdentifier("handoff.enable")
                }
            }
            Text("Use private iCloud with the same Apple Account on iPhone and Mac. Only photos you send are transferred, as optimised JPEGs up to 3840 pixels with photo location and camera metadata removed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !handoff.isConfigured {
                Label("Photo handoff is unavailable in this build. It needs a signed Workbench Preview configured for iCloud. Local tools and downloaded photos still work.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(handoff.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if showsError, let error = handoff.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(14).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PhotoHandoffArrivalCue: View {
    @ObservedObject var handoff: PhotoHandoffModel
    var action: () -> Void
    var body: some View {
        if !handoff.photos.isEmpty {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle").font(.title2).foregroundStyle(Workbench.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("From iPhone").font(.headline)
                        Text("\(handoff.photos.count) \(handoff.photos.count == 1 ? "photo" : "photos") in Saved resources")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }.padding(18).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityIdentifier("home.phone-photos")
        }
    }
}

private struct HandoffThumbnail: View {
    let url: URL?
    let maximumPixels: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary) }
        }.task(id: url) {
            image = nil
            guard let url else { return }
            let size = maximumPixels
            let work = Task.detached(priority: .utility) { () -> NSImage? in
                guard !Task.isCancelled,
                      let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: min(1200, max(1, size))
                      ] as CFDictionary), !Task.isCancelled else { return nil }
                return NSImage(cgImage: thumbnail, size: .zero)
            }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}
