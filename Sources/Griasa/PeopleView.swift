import SwiftUI
import AppKit

/// The "📇 People" hub tab — one page per colleague: notes, shared meetings,
/// open commitments and an AI dossier.
struct PeopleView: View {
    @ObservedObject private var store = PersonStore.shared
    @ObservedObject private var roster = ParticipantRoster.shared

    @State private var selected: String?
    @State private var search = ""
    @State private var newName = ""

    private var names: [String] {
        let all = store.allNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
            if let name = selected {
                PersonDetailView(name: name) { selected = $0 }
                    .id(name)  // fresh state (notes draft) per person
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptySelection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selected == nil { selected = names.first } }
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            if names.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(search.isEmpty
                         ? "People appear here once you\nname meeting participants."
                         : "No one matches “\(search)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(names, id: \.self) { name in
                            row(name)
                        }
                    }
                    .padding(6)
                }
            }
            Divider()
            HStack {
                TextField("Add a person", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPerson)
                Button(action: addPerson) { Image(systemName: "plus") }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
        }
    }

    private func row(_ name: String) -> some View {
        Button {
            selected = name
        } label: {
            HStack(spacing: 8) {
                PersonAvatar(name: name, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).lineLimit(1)
                    if let met = store.lastMet(name) {
                        Text("Met \(met.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No meetings yet")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(selected == name ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var emptySelection: some View {
        EmptyStateView(icon: "person.text.rectangle", title: "Select a person",
                       message: "Notes, shared meetings and their open promises — all on one page.")
    }

    private func addPerson() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        roster.remember([trimmed])
        newName = ""
        selected = trimmed
    }
}

private struct PersonDetailView: View {
    let name: String
    /// The list owns the selection, so a rename has to tell it which row to
    /// select — otherwise the sidebar keeps a name that no longer exists.
    let onRenamed: (String) -> Void
    @ObservedObject private var store = PersonStore.shared
    @ObservedObject private var commitments = CommitmentStore.shared

    @State private var notesDraft = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var renaming = false
    @State private var renameDraft = ""
    @State private var renameProblem: String?
    @State private var renameNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                HubCard(icon: "note.text", title: "Notes", tint: .yellow) {
                    TextEditor(text: $notesDraft)
                        .font(.body)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if notesDraft.isEmpty {
                                Text("Birthday, strengths, 1:1 agreements…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 1)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: notesDraft) { _, newValue in
                            // Autosave, debounced — no Save button to forget.
                            saveTask?.cancel()
                            saveTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                guard !Task.isCancelled else { return }
                                store.setNotes(newValue, for: name)
                            }
                        }
                } trailing: {
                    Text("saves automatically")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                let open = commitments.open(for: name)
                if !open.isEmpty {
                    HubCard(icon: "hand.raised", title: "They promised", tint: .orange) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(open) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Button {
                                        withAnimation(.snappy) { commitments.toggleDone(item.id) }
                                    } label: {
                                        Image(systemName: "circle")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    Text(item.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Text(item.date.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                dossierBox

                meetingsBox
            }
            .padding(16)
        }
        .onAppear { notesDraft = store.person(named: name)?.notes ?? "" }
        .onDisappear {
            saveTask?.cancel()
            if notesDraft != (store.person(named: name)?.notes ?? "") {
                store.setNotes(notesDraft, for: name)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PersonAvatar(name: name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.title2.weight(.semibold))
                    Button {
                        renameDraft = name
                        renameProblem = nil
                        renaming = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Fix this person's name everywhere — their meetings, their promises and the roster.")
                }
                if let met = store.lastMet(name) {
                    Text("Last met \(met.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let note = renameNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .popover(isPresented: $renaming, arrowEdge: .bottom) { renamePopover }
    }

    /// Names arrive typed in a hurry, right after a call ends, so getting one
    /// wrong is normal. This fixes it in the four places it is stored at once.
    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename this person")
                .font(.headline)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit(commitRename)
            Text("Changes their page, the participant list of every meeting they were on, the owner of their promises, and the roster offered after the next call. Recorded transcripts keep the original spelling.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 250, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = renameProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(width: 250, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { renaming = false }
                Button("Rename", action: commitRename)
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(width: 250)
        }
        .padding(14)
    }

    private func commitRename() {
        switch store.rename(name, to: renameDraft) {
        case .emptyName:
            renameProblem = "A name can't be empty."
        case .nameTaken:
            renameProblem = "Someone else already has that name. Renaming can't merge two people — their notes and dossiers would have to be combined, and only you can decide how."
        case .unchanged:
            renaming = false
        case .renamed(let meetings, let commitments):
            renaming = false
            let parts = [
                meetings == 1 ? "1 meeting" : "\(meetings) meetings",
                commitments == 1 ? "1 promise" : "\(commitments) promises",
            ]
            renameNote = "Renamed · \(parts.joined(separator: ", ")) updated"
            // The row this view was showing is gone; the list picks the new name
            // up on its own, and the note explains why the page changed under you.
            onRenamed(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.snappy) { renameNote = nil }
            }
        }
    }

    @ViewBuilder
    private var dossierBox: some View {
        let meetings = store.meetings(with: name)
        HubCard(icon: "sparkles", title: "AI dossier", tint: .purple) {
            VStack(alignment: .leading, spacing: 8) {
                if let person = store.person(named: name), let dossier = person.dossier {
                    Text(LocalizedStringKey(dossier))  // renders the markdown
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let date = person.dossierDate {
                            Text("Updated \(date.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        regenerateButton(title: "Refresh", meetings: meetings)
                    }
                } else if meetings.isEmpty {
                    Text("The dossier appears after your first recorded meeting with \(name).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !AIFormatter.isConfigured {
                    Text("Configure an AI provider in Settings → AI & Actions to generate a dossier.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("A short brief on \(name) from \(meetings.count) meeting\(meetings.count == 1 ? "" : "s") — role, promises, working style.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        regenerateButton(title: "Generate", meetings: meetings)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func regenerateButton(title: String, meetings: [HistoryEntry]) -> some View {
        if store.generating.contains(name) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading \(meetings.count) transcript\(meetings.count == 1 ? "" : "s")…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button(title) { store.generateDossier(for: name) }
                .disabled(meetings.isEmpty || !AIFormatter.isConfigured)
        }
    }

    @ViewBuilder
    private var meetingsBox: some View {
        let meetings = store.meetings(with: name)
        if !meetings.isEmpty {
            HubCard(icon: "record.circle", title: "Meetings", tint: .blue, content: {
                VStack(spacing: 2) {
                    ForEach(meetings.prefix(15)) { entry in
                        Button {
                            if let path = entry.filePath {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            } else {
                                HubController.shared.open(.history)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "record.circle")
                                    .foregroundStyle(.secondary)
                                Text(entry.title).lineLimit(1)
                                Spacer()
                                Text(entry.date.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open the transcript")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }, trailing: {
                Text("\(meetings.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            })
        }
    }
}
