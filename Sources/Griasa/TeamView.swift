import SwiftUI
import AppKit

/// The "My team" hub tab: for each person marked as a direct report in People,
/// what they promised the user and have not done, overdue first, with a
/// check-in note one click away.
struct TeamView: View {
    @ObservedObject private var people = PersonStore.shared
    @ObservedObject private var commitments = CommitmentStore.shared
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let reports = people.directReports
                if reports.isEmpty {
                    EmptyStateView(
                        icon: "person.3",
                        title: "No team yet",
                        message: "Open People and switch on “Reports to me” for each person on your team. Their open promises to you then gather here.")
                    Button("Open People") { HubController.shared.open(.people) }
                } else {
                    let members = TeamDigest.members(names: reports.map(\.name), commitments: commitments.commitments,
                                                     lastMet: { people.lastMet($0) })
                    ForEach(members, id: \.name) { member in memberCard(member) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func memberCard(_ member: TeamDigest.Member) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(member.name).font(.headline)
                if member.overdue > 0 {
                    Text("\(member.overdue) overdue").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                if let last = member.lastMet {
                    Text("Last met \(last.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !member.owed.isEmpty {
                    Button(copied == member.name ? "Copied" : "Nudge") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TeamDigest.nudge(to: member.name, about: member.owed), forType: .string)
                        copied = member.name
                    }
                    .help("Copies a short check-in about these promises, to paste into a chat")
                }
            }
            if member.owed.isEmpty {
                Text("Nothing open").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(member.owed) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: TeamDigest.isOverdue(item, now: Date()) ? "exclamationmark.circle" : "circle")
                            .foregroundStyle(TeamDigest.isOverdue(item, now: Date()) ? .red : .secondary)
                        Text(item.text).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let due = item.dueHint ?? item.dueDate?.formatted(date: .abbreviated, time: .omitted) {
                            Text(due).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Mark done") { CommitmentStore.shared.toggleDone(item.id) }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
