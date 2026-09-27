import SwiftUI
import AppKit

struct SnapOrganizationView: View {
    @ObservedObject var model: SnapModel
    let selectedIDs: Set<UUID>
    var savedSelectionID: UUID?
    let onHandOff: (String) -> Void
    var onExclude: ((Set<UUID>) -> Void)? = nil
    @State private var plan: SnapOrganizationPlan?
    @State private var proposed: Set<UUID> = []
    @State private var result: URL?
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Organise selected Snaps").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Review duplicate proposals, keep a source-linked overview, or ask your assistant to synthesize the selected evidence.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !unavailableIDs.isEmpty, let onExclude {
                Button("Exclude \(unavailableIDs.count) archived or unavailable Snaps from this selection") { onExclude(unavailableIDs) }
                Text("This keeps other selected evidence. A saved selection changes only when you use Update.").font(.caption).foregroundStyle(.secondary)
            }
            if let plan {
                Text("\(plan.sources.count) sources · \(plan.duplicates.count) proposed repeats").font(.headline)
                if plan.duplicates.isEmpty {
                    Text("No active captures are identical or look like repeats. Low-value captures still need your review.").font(.callout)
                } else {
                    ScrollView { VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.duplicates) { proposal in
                            Toggle(isOn: Binding(get: { proposed.contains(proposal.id) }, set: { value in
                                if value { proposed.insert(proposal.id) } else { proposed.remove(proposal.id) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(proposal.duplicate.title).font(.callout.weight(.semibold))
                                    Text("Keep \(proposal.retained.title). \(proposal.reason)").font(.caption).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                    Button("Archive and exclude \(proposed.count) reviewed repeats") { archive(plan) }.disabled(proposed.isEmpty)
                    Text("Archive is reversible. Original files and existing narrated sessions remain intact.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Button(result == nil ? "Save overview" : "Update overview") { save(plan) }
                    if let result { Button("Open overview") { NSWorkspace.shared.open(result) } }
                    Spacer()
                    Button("Hand off for synthesis…") { dismiss(); onHandOff(SnapOrganization.assistantInstruction) }.disabled(!unavailableIDs.isEmpty)
                }
                Text("The overview groups your titles and notes by saved tags. Assistant synthesis is optional and starts from the common selection review.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Button("Review again") { prepare() } }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(24).frame(width: 620).onAppear { prepare() }
            .onChange(of: selectedIDs) { prepare() }
            .onChange(of: savedSelectionID) { prepare() }
    }
    private var unavailableIDs: Set<UUID> {
        selectedIDs.subtracting(model.items.filter { $0.archivedAt == nil }.map(\.id))
    }
    private func prepare() {
        do {
            let plan = try SnapOrganization.prepare(store: model.store, ids: selectedIDs, selectionID: savedSelectionID)
            self.plan = plan; proposed = Set(plan.duplicates.map(\.id)); notice = nil
            result = try model.store.readOrganization(key: plan.key)?.url
        }
        catch { plan = nil; result = nil; proposed = []; notice = error.localizedDescription }
    }
    @discardableResult private func save(_ plan: SnapOrganizationPlan) -> Bool {
        do {
            let archived = Set(try plan.sources.filter { try model.store.read($0.item.id).archivedAt != nil }.map { $0.item.id })
            result = try model.store.writeOrganization(SnapOrganization.markdown(plan, archivedIDs: archived), key: plan.key)
            notice = "Overview saved. Repeating this selection updates the same document."
            return true
        } catch { notice = "The overview could not be saved. \(error.localizedDescription)"; return false }
    }
    private func archive(_ plan: SnapOrganizationPlan) {
        do {
            let excluded = proposed
            try SnapOrganization.archiveReviewed(excluded, plan: plan, store: model.store)
            model.refresh(); proposed = []
            if save(plan) { notice = "Reviewed repeats archived and overview updated. Restore them from Archived at any time." }
            else { notice = "Reviewed repeats are archived and can be restored. \(notice ?? "The overview could not be saved.")" }
            onExclude?(excluded)
        } catch { model.refresh(); notice = "Review the current history before retrying. \(error.localizedDescription)" }
    }
}
