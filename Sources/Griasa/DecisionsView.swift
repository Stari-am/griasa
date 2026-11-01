import SwiftUI
import AppKit

/// The "Decisions" hub tab: what was decided in meetings, with the reason and
/// the words it was decided in. Searchable; the ones due for another look sit
/// on top.
struct DecisionsView: View {
    @ObservedObject private var store = DecisionStore.shared
    @State private var query = ""
    @State private var showReversed = false

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search decisions", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.decisions.isEmpty {
                        EmptyStateView(
                            icon: "signpost.right.and.left",
                            title: "No decisions yet",
                            message: "After each recorded meeting, the choices settled in it land here with the words they were made in.")
                    } else {
                        Text("Found by the AI model after each meeting, with the words each was decided in. On a local model the list is noisier: right-click a wrong one to delete it.")
                            .font(.caption).foregroundStyle(.secondary)
                        let found = DecisionRules.search(query, in: store.decisions, limit: 500)
                        let revisit = query.isEmpty ? store.toRevisit : []
                        if !revisit.isEmpty {
                            group("Look at again", systemImage: "calendar.badge.clock", tint: .orange, items: revisit)
                        }
                        let active = found.filter { !$0.reversed && !revisit.contains($0) }
                        if !active.isEmpty {
                            group(query.isEmpty ? "Decided" : "Found", systemImage: "checkmark.seal", tint: .blue, items: active)
                        } else if !query.isEmpty {
                            Text("Nothing decided about that.").foregroundStyle(.secondary)
                        }
                        let reversed = found.filter(\.reversed)
                        if !reversed.isEmpty {
                            DisclosureGroup(isExpanded: $showReversed) {
                                VStack(spacing: 2) { ForEach(reversed) { DecisionRow(decision: $0) } }
                                    .padding(.top, 4)
                            } label: {
                                Label("Reversed · \(reversed.count)", systemImage: "arrow.uturn.backward")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func group(_ title: String, systemImage: String, tint: Color, items: [Decision]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(title) · \(items.count)", systemImage: systemImage)
                .font(.headline).foregroundStyle(tint)
            VStack(spacing: 2) { ForEach(items) { DecisionRow(decision: $0) } }
        }
    }
}

private struct DecisionRow: View {
    let decision: Decision
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(decision.text)
                    .strikethrough(decision.reversed)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(decision.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let by = decision.decidedBy { Text(by).font(.caption).foregroundStyle(.secondary) }
                Text(decision.sourceTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let revisit = decision.revisitDate, !decision.reversed {
                    Label(revisit.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar.badge.clock")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if expanded {
                if let why = decision.why { Text("Why: \(why)").font(.callout) }
                if !decision.alternatives.isEmpty {
                    Text("Not chosen: " + decision.alternatives.joined(separator: "; ")).font(.callout).foregroundStyle(.secondary)
                }
                if let quote = decision.quote {
                    Text("“\(quote)”" + (decision.at.map { " — \($0)" } ?? ""))
                        .font(.callout).italic().foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let note = decision.reversedNote, decision.reversed {
                    Text("Reversed: \(note)").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .contextMenu {
            if decision.reversed {
                Button("Mark as still standing") { DecisionStore.shared.setReversed(decision, false) }
            } else {
                Button("Mark as reversed") { DecisionStore.shared.setReversed(decision, true) }
                Menu("Look at again") {
                    Button("In a week") { DecisionStore.shared.setRevisit(decision, Calendar.current.date(byAdding: .day, value: 7, to: Date())) }
                    Button("In a month") { DecisionStore.shared.setRevisit(decision, Calendar.current.date(byAdding: .month, value: 1, to: Date())) }
                    Button("In a quarter") { DecisionStore.shared.setRevisit(decision, Calendar.current.date(byAdding: .month, value: 3, to: Date())) }
                    if decision.revisitDate != nil {
                        Button("Never") { DecisionStore.shared.setRevisit(decision, nil) }
                    }
                }
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(decision.text + (decision.why.map { " — \($0)" } ?? ""), forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { DecisionStore.shared.delete(decision) }
        }
    }
}
