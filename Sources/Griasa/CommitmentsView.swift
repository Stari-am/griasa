import SwiftUI
import AppKit

/// The "✅ Commitments" hub tab — my promises, what others owe me, and a
/// collapsible pile of finished ones.
struct CommitmentsView: View {
    @ObservedObject private var store = CommitmentStore.shared
    @State private var showDone = false
    @State private var addingNew = false
    @State private var exportMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.openMine.isEmpty && store.openTheirs.isEmpty && store.finished.isEmpty {
                    EmptyStateView(
                        icon: "checklist",
                        title: "No commitments yet",
                        message: "After each recorded meeting, promises made by you and your colleagues land here automatically — nothing to set up.")
                } else {
                    if !store.openMine.isEmpty {
                        section(title: "My promises", systemImage: "person.fill.checkmark",
                                tint: .blue, items: store.openMine)
                    }
                    if !store.openTheirs.isEmpty {
                        section(title: "Waiting on others", systemImage: "person.2",
                                tint: .orange, items: store.openTheirs, showOwner: true)
                    }
                    if !store.finished.isEmpty {
                        DisclosureGroup(isExpanded: $showDone) {
                            VStack(spacing: 2) {
                                ForEach(store.finished) { item in
                                    CommitmentRow(item: item, showOwner: true)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Label("Done · \(store.finished.count)", systemImage: "checkmark.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private func section(title: String, systemImage: String, tint: Color,
                         items: [Commitment], showOwner: Bool = false) -> some View {
        HubCard(icon: systemImage, title: title, tint: tint) {
            VStack(spacing: 2) {
                ForEach(items) { item in
                    CommitmentRow(item: item, showOwner: showOwner)
                }
            }
        } trailing: {
            Text("\(items.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if addingNew {
                NewCommitmentField { addingNew = false }
            } else {
                Button {
                    addingNew = true
                } label: {
                    Label("Add commitment", systemImage: "plus")
                }
                Menu {
                    Section("My promises") {
                        Button("Copy as Markdown checklist") {
                            export(CommitmentExport.markdownChecklist(store.openMine),
                                   count: store.openMine.count)
                        }
                        Button("Copy as task list (line per task)") {
                            export(CommitmentExport.taskLines(store.openMine),
                                   count: store.openMine.count)
                        }
                    }
                    Section("Everything open") {
                        Button("Copy as Markdown checklist") {
                            let items = store.openMine + store.openTheirs
                            export(CommitmentExport.markdownChecklist(items), count: items.count)
                        }
                        Button("Copy as task list (line per task)") {
                            let items = store.openMine + store.openTheirs
                            export(CommitmentExport.taskLines(items), count: items.count)
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                .disabled(store.openCount == 0)
                .help("Copy open commitments — task trackers create one task per pasted line")
                Spacer()
                if let exportMessage {
                    Label(exportMessage, systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity)
                } else if store.openCount > 0 {
                    Text("\(store.openCount) open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func export(_ text: String, count: Int) {
        guard count > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.snappy) {
            exportMessage = "Copied \(count) item\(count == 1 ? "" : "s") — paste into your tracker"
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { exportMessage = nil }
        }
    }
}

private struct CommitmentRow: View {
    @ObservedObject private var store = CommitmentStore.shared
    let item: Commitment
    var showOwner: Bool

    @State private var hovering = false
    @State private var sentToReminders = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                withAnimation(.snappy) { store.toggleDone(item.id) }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(item.done ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if showOwner && !item.isMine {
                        PersonAvatar(name: item.owner, size: 16)
                    }
                    Text(item.text)
                        .strikethrough(item.done, color: .secondary)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let due = item.dueDate, !item.done {
                        Text(due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(dueColor(due).opacity(0.15), in: Capsule())
                            .foregroundStyle(dueColor(due))
                    } else if let hint = item.dueHint, !item.done {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                caption
            }

            Spacer(minLength: 0)

            if hovering {
                HStack(spacing: 8) {
                    if !item.done {
                        Button {
                            sendToReminders()
                        } label: {
                            Image(systemName: sentToReminders ? "checkmark" : "bell")
                                .foregroundStyle(sentToReminders ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Create a reminder — it will ping your iPhone and Watch too")
                    }
                    Button {
                        withAnimation(.snappy) { store.delete(item.id) }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var caption: some View {
        let ownerPart = showOwner && !item.isMine ? "\(item.owner) · " : ""
        let sourcePart = item.sourceTitle.isEmpty ? "Added by hand" : "«\(item.sourceTitle)»"
        let when = item.date.formatted(.relative(presentation: .named))
        if let entryID = item.sourceEntryID,
           let path = HistoryStore.shared.entries.first(where: { $0.id == entryID })?.filePath {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                Text("\(ownerPart)\(sourcePart) · \(when)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open the meeting transcript")
        } else {
            Text("\(ownerPart)\(sourcePart) · \(when)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func dueColor(_ due: Date) -> Color {
        due < Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400) ? .red : .orange
    }

    private func sendToReminders() {
        Task { @MainActor in
            guard await RemindersService.requestAccess() else { return }
            // No spoken deadline → tomorrow 10:00, so the reminder actually fires.
            let due = item.dueDate.map { Calendar.current.date(
                bySettingHour: 10, minute: 0, second: 0, of: $0) ?? $0 }
                ?? Calendar.current.date(bySettingHour: 10, minute: 0, second: 0,
                                         of: Date().addingTimeInterval(86_400))
            let notes = item.sourceTitle.isEmpty ? nil : "From meeting: \(item.sourceTitle)"
            try? RemindersService.create(title: item.text, notes: notes, due: due)
            withAnimation(.snappy) { sentToReminders = true }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { sentToReminders = false }
        }
    }
}

private struct NewCommitmentField: View {
    let onDone: () -> Void
    @ObservedObject private var roster = ParticipantRoster.shared
    @State private var text = ""
    @State private var owner = ""
    @State private var duplicate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("What was promised…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Picker("", selection: $owner) {
                    Text("Me").tag("")
                    ForEach(roster.names, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 120)
                Button("Add", action: save)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", action: onDone)
            }
            if duplicate {
                Text("Already on the list, and still open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: text) { _, _ in duplicate = false }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let mine = owner.isEmpty
        let myName = ParticipantRoster.shared.myName
        // `add` refuses a duplicate of a commitment that is still open and says so
        // by returning false. Discarding that answer cleared the field and closed
        // the editor anyway, so the text vanished and read as saved. Keep what the
        // user typed and say why nothing happened.
        var added = false
        withAnimation(.snappy) {
            added = CommitmentStore.shared.add(Commitment(
                text: trimmed,
                owner: mine ? (myName.isEmpty ? "You" : myName) : owner,
                isMine: mine,
                sourceTitle: "", sourceEntryID: nil))
        }
        guard added else {
            withAnimation(.snappy) { duplicate = true }
            return
        }
        text = ""
        onDone()
    }
}
