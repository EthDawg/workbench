import SwiftUI

struct DemoLibraryImportView: View {
    @ObservedObject var library: DemoLibraryModel
    @State private var selection: UUID?

    var body: some View {
        if let review = library.importReview {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review library import").font(.title2.weight(.semibold))
                Text(review.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 24) {
                    ForEach(DemoLibraryImport.Status.allCases, id: \.self) { status in
                        Text("\(review.count(status)) \(status.rawValue)").font(.headline)
                    }
                }
                Text("\(review.unavailableFileCount) incoming file references unavailable on this Mac. Referenced files are not bundled; use Locate file after importing.")
                    .font(.callout).foregroundStyle(.secondary)
                HSplitView {
                    List(selection: $selection) {
                        ForEach(review.entries) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(entry.incoming.title, systemImage: entry.incoming.kind.symbol).lineLimit(2)
                                Text(entry.status.rawValue + (entry.status == .changed ? (library.importChoices.contains(entry.id) ? " · Use incoming" : " · Keep mine") : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(entry.id)
                        }
                    }.frame(minWidth: 190, idealWidth: 230, maxWidth: 280)
                        .accessibilityLabel("Resources to review")
                    if let entry = review.entries.first(where: { $0.id == selection }) {
                        VStack(alignment: .leading, spacing: 12) {
                            if entry.status == .changed {
                                Picker("For \(entry.incoming.title)", selection: Binding(
                                    get: { library.importChoices.contains(entry.id) },
                                    set: { if $0 { library.importChoices.insert(entry.id) } else { library.importChoices.remove(entry.id) } }
                                )) {
                                    Text("Keep mine").tag(false)
                                    Text("Use incoming").tag(true)
                                }.pickerStyle(.segmented)
                                    .accessibilityLabel("Import choice for \(entry.incoming.title)")
                            } else {
                                Text(entry.status == .new ? "This resource will be added." : "No changes. Your local resource will be kept.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            ScrollView {
                                HStack(alignment: .top, spacing: 18) {
                                    if let current = entry.current, entry.status == .changed { details(current, heading: "Mine") }
                                    details(entry.incoming, heading: entry.status == .changed ? "Incoming" : entry.status.rawValue)
                                }.padding(.trailing, 8)
                            }
                        }.padding(.leading, 12).frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        Text(review.entries.isEmpty ? "This library contains no resources." : "Select a resource to compare its details.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let error = library.importError {
                    HStack {
                        Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        Spacer()
                        Button("Review again") { library.refreshImportReview() }
                    }
                }
                HStack {
                    Text("Add \(review.count(.new)) · Update \(library.importChoices.count)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { library.cancelImport() }.keyboardShortcut(.cancelAction)
                    Button(review.count(.new) == 0 && library.importChoices.isEmpty ? "Keep library" : "Apply import") { library.applyImport() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Saves the chosen changes together and closes this review.")
                }
            }.padding(24).frame(minWidth: 800, idealWidth: 920, minHeight: 560, idealHeight: 660)
                .onAppear { selection = review.entries.first(where: { $0.status == .changed })?.id ?? review.entries.first?.id }
                .onChange(of: review.id) { _, _ in selection = review.entries.first(where: { $0.status == .changed })?.id ?? review.entries.first?.id }
        }
    }

    private func details(_ item: DemoResource, heading: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.headline).foregroundStyle(Workbench.accent)
            field("Name", item.title)
            field("Kind", item.kind.rawValue)
            field("Product", item.product)
            field("Persona", item.persona)
            field(item.kind == .prompt ? "Prompt" : item.kind == .link ? "Link" : "File path", item.kind == .file ? (item.fileURL?.path ?? item.content) : item.content)
            field("Notes", item.notes)
            field("Favorite", item.favorite ? "Yes" : "No")
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}
