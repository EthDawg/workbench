import SwiftUI
import AppKit

/// The editing mode of the same expanded image window used across Workbench.
struct SnapEditorView: View {
    @ObservedObject var model: SnapModel
    @ObservedObject var editing: ImageWorkspaceEditing
    @ObservedObject private var appearance = WorkbenchSettings.shared
    let save: (Bool) -> Void
    let close: () -> Void
    let discard: () -> Void
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(editing.draft.existing == nil ? "New Snap" : editing.draft.title).font(.headline).lineLimit(1)
                    Text("Edit image · Original preserved").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Discard…", role: .destructive, action: discard)
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                    .help("Keep this draft to review later on the Snap page")
                Button("Save") { save(false) }.keyboardShortcut("s", modifiers: .command)
                Button("Save & Copy") { save(true) }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: [.command, .shift])
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            HStack(spacing: 5) {
                ForEach(ImageWorkspaceTool.allCases) { tool in
                    Button {
                        editing.showingOriginal = false
                        if tool == .text { editing.addText(); textFocused = true }
                        else { editing.tool = tool; editing.selected = nil }
                    } label: { Label(tool.title, systemImage: tool.symbol).font(.callout) }
                    .buttonStyle(.bordered)
                    .background(editing.tool == tool ? Workbench.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(editing.tool == tool ? Workbench.accent.opacity(0.7) : .clear))
                    .accessibilityValue(editing.tool == tool ? "Selected" : "")
                    .help(tool == .text ? "Add a text or comment box to the image" : tool.title)
                }
                Divider().frame(height: 22).padding(.horizontal, 5)
                Button { editing.rotate() } label: { Image(systemName: "rotate.right") }
                    .help("Rotate clockwise").accessibilityLabel("Rotate clockwise")
                Button { editing.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(editing.undoStack.isEmpty).help("Undo (⌘Z)").accessibilityLabel("Undo").keyboardShortcut("z", modifiers: .command)
                Button { editing.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(editing.redoStack.isEmpty).help("Redo (⇧⌘Z)").accessibilityLabel("Redo").keyboardShortcut("z", modifiers: [.command, .shift])
                Spacer(minLength: 4)
                Button { editing.showingDetails.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help("Show or hide details").accessibilityLabel("Show or hide details")
            }.padding(.horizontal, 16).padding(.vertical, 10)
            if editing.tool == .crop {
                HStack {
                    Picker("Aspect", selection: Binding(get: { editing.aspect }, set: { editing.setAspect($0) })) {
                        ForEach(ImageCropAspect.allCases) { Text($0.title).tag($0) }
                    }.id(appearance.colorScheme).frame(width: 240)
                    Text("Drag the corners to crop. Drag inside to move.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset crop") { editing.mutate { $0.crop = .full }; editing.aspect = .free }.disabled(editing.draft.edit.crop == .full)
                    Button("Done cropping") { editing.tool = .select }
                }.padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            HStack(spacing: 0) {
                ImageWorkspaceCanvas(editing: editing).frame(maxWidth: .infinity, maxHeight: .infinity)
                if editing.showingDetails {
                    Divider()
                    ScrollView { inspector.padding(16) }.frame(width: 250).background(.background)
                }
            }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            Divider()
            HStack(spacing: 12) {
                let size = SnapRendering.outputSize(image: editing.imageSize, edit: editing.draft.edit)
                Text("\(Int(size.width)) × \(Int(size.height)) px").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Toggle("Original", isOn: $editing.showingOriginal).toggleStyle(.button).help("Compare with the untouched original")
                Spacer()
                ImageWorkspaceZoomControls(percent: editing.percent, perform: editing.zoom)
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }.frame(minWidth: 820, minHeight: 520).tint(Workbench.accent).workbenchTheme()
            .onReceive(editing.$draft) { if model.draft?.id == $0.id { model.draft = $0 } }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let mark = editing.selectedMark {
                Text(mark.kind == .text ? "Text on image" : "Selected mark").font(.headline)
                if mark.kind == .text {
                    TextEditor(text: Binding(get: { editing.selectedMark?.text ?? "" }, set: { value in editing.updateSelected { $0.text = String(value.prefix(10_000)) } }))
                        .font(.body).frame(height: 120).focused($textFocused)
                        .scrollContentBackground(.hidden).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Text on image")
                    Picker("Background", selection: Binding(get: { editing.selectedMark?.background ?? "none" }, set: { value in editing.background = value; editing.updateSelected { $0.background = value } })) {
                        ForEach(["none", "white", "black", "yellow"], id: \.self) { Text($0.capitalized).tag($0) }
                    }.id(appearance.colorScheme)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Text size · \(Int((mark.fontSize ?? 0.035) * min(editing.imageSize.width, editing.imageSize.height))) px").font(.caption)
                        Slider(value: Binding(get: { editing.selectedMark?.fontSize ?? 0.035 }, set: { value in editing.fontSize = value; editing.updateSelected { $0.fontSize = value } }), in: 0.008...0.15)
                            .accessibilityLabel("Text size")
                    }
                }
                colourPicker(selected: true)
                if mark.kind != .text {
                    Slider(value: Binding(get: { editing.selectedMark?.width ?? 0.004 }, set: { value in editing.updateSelected { $0.width = value } }), in: 0.001...0.02)
                        .accessibilityLabel("Line width")
                }
                Text("Drag to move. Drag a corner to resize. Arrow keys nudge; Shift moves ten pixels.").font(.caption).foregroundStyle(.secondary)
                Button("Delete mark", role: .destructive) { editing.removeSelected() }
                Divider()
            } else if [.pen, .arrow, .rectangle].contains(editing.tool) {
                Text("Mark style").font(.headline)
                colourPicker(selected: false)
                Slider(value: $editing.lineWidth, in: 0.001...0.02).accessibilityLabel("Line width")
                Divider()
            } else {
                Text("Make it clear").font(.headline)
                Text("Add text, point with an arrow, or crop to fit a slide. Select any mark to move or change it.")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
            }
            Text("Details").font(.headline)
            TextField("Title", text: $editing.draft.title).textFieldStyle(.roundedBorder).accessibilityLabel("Snap title")
            TextField("Tags, separated by commas", text: Binding(get: { editing.draft.tags.joined(separator: ", ") }, set: { value in
                editing.draft.tags = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            })).textFieldStyle(.roundedBorder).accessibilityLabel("Snap tags")
            Text("Image notes").font(.caption.weight(.semibold))
            TextEditor(text: $editing.draft.notes).frame(height: 85).font(.callout)
                .scrollContentBackground(.hidden).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)).accessibilityLabel("Image notes")
            Text("Notes stay with this Snap. Text boxes appear in the copied or exported image.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func colourPicker(selected: Bool) -> some View {
        Picker("Colour", selection: Binding(get: { editing.colour }, set: { value in
            editing.colour = value; if selected { editing.updateSelected { $0.colour = value } }
        })) { ForEach(["red", "yellow", "blue", "white", "black"], id: \.self) { Text($0.capitalized).tag($0) } }
            // Native popup labels can retain their previous colour when appearance changes.
            .id(appearance.colorScheme)
    }
}

struct ImageWorkspaceZoomControls: View {
    let percent: Int
    let perform: (CaptureImagePreviewModel.Command) -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button("Fit") { perform(.fit) }.help("Fit the image (⌘9)")
            Button("Actual size") { perform(.actualSize) }.help("One image pixel per screen pixel (⌘0)")
            Button { perform(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom out").help("Zoom out (⌘−)")
            Text("\(percent)%").font(.callout.monospacedDigit()).frame(width: 46)
            Button { perform(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom in").help("Zoom in (⌘+)")
        }
    }
}
