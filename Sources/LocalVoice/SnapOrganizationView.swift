import SwiftUI
import AppKit

struct SnapOrganizationView: View {
    @ObservedObject var model: SnapModel
    let selectedIDs: Set<UUID>
    var savedSelectionID: UUID?
    let onHandOff: (String) -> Void
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
            if let plan {
                Text("\(plan.sources.count) sources · \(plan.duplicates.count) exact duplicates").font(.headline)
                if plan.duplicates.isEmpty {
                    Text("No active captures have identical rendered image bytes. Similar-looking or low-value captures still need your review.").font(.callout)
                } else {
                    ScrollView { VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.duplicates) { proposal in
                            Toggle(isOn: Binding(get: { proposed.contains(proposal.id) }, set: { value in
                                if value { proposed.insert(proposal.id) } else { proposed.remove(proposal.id) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(proposal.duplicate.title).font(.callout.weight(.semibold))
                                    Text("Keep \(proposal.retained.title). These rendered images are identical.").font(.caption).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                    Button("Archive \(proposed.count) reviewed duplicates") { archive(plan) }.disabled(proposed.isEmpty)
                    Text("Archive is reversible. Original files and existing narrated sessions remain intact.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Button(result == nil ? "Save overview" : "Update overview") { save(plan) }
                    if let result { Button("Open overview") { NSWorkspace.shared.open(result) } }
                    Spacer()
                    Button("Hand off for synthesis…") { dismiss(); onHandOff(SnapOrganization.assistantInstruction) }
                }
                Text("The overview groups your titles and notes by saved tags. Assistant synthesis is optional and starts from the common selection review.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Button("Review again") { prepare() } }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(24).frame(width: 620).onAppear { prepare() }
    }
    private func prepare() {
        do { let plan = try SnapOrganization.prepare(store: model.store, ids: selectedIDs, selectionID: savedSelectionID); self.plan = plan; proposed = Set(plan.duplicates.map(\.id)); notice = nil }
        catch { notice = error.localizedDescription }
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
            try SnapOrganization.archiveReviewed(proposed, plan: plan, store: model.store)
            model.refresh(); proposed = []
            if save(plan) { notice = "Reviewed duplicates archived and overview updated. Restore them from Archived at any time." }
            else { notice = "Reviewed duplicates are archived and can be restored. \(notice ?? "The overview could not be saved.")" }
        } catch { model.refresh(); notice = "Review the current history before retrying. \(error.localizedDescription)" }
    }
}
