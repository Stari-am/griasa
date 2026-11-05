import SwiftUI
import AppKit

/// Browses, searches, and re-uses past transcriptions — lives in the hub's
/// History tab.
@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()

    func show() {
        HubController.shared.open(.history)
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: HistoryStore
    @ObservedObject private var projects = ProjectStore.shared
    @State private var query = ""
    @State private var selection: HistoryEntry.ID?
    @State private var projectFilter: UUID?
    @State private var people: [String] = []
    @State private var peopleMode: MeetingPeople.Mode = .all

    private var results: [HistoryEntry] {
        store.filtered(query, project: projectFilter, people: people, mode: peopleMode)
    }
    /// Everyone who has been in a recorded meeting, most frequent first.
    private var roster: [String] {
        MeetingPeople.roster(store.entries.filter { $0.kind == .meeting }.compactMap(\.participants))
    }
    private var selected: HistoryEntry? { results.first { $0.id == selection } }

    /// "Meetings with…": one person or several, every one of them or any.
    private var peopleFilter: some View {
        HStack(spacing: 6) {
            Menu {
                if !people.isEmpty {
                    Button("Everyone") { people = [] }
                    Divider()
                }
                ForEach(roster.prefix(60), id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { people.contains(name) },
                        set: { on in
                            if on { people.append(name) } else { people.removeAll { $0 == name } }
                        }))
                }
                if roster.isEmpty {
                    Text("No meetings with participants yet")
                }
            } label: {
                Label(people.isEmpty ? "Everyone" : "With " + ListFormatter.localizedString(byJoining: people),
                      systemImage: people.count > 1 ? "person.2" : "person")
                    .lineLimit(1)
            }
            .help("Only meetings these people took part in. Pick one person or several.")
            if people.count > 1 {
                Picker("", selection: $peopleMode) {
                    Text("All").tag(MeetingPeople.Mode.all)
                    Text("Any").tag(MeetingPeople.Mode.any)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("All: meetings where every one of them took part. Any: meetings with at least one of them.")
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            Picker("Project", selection: $projectFilter) {
                Text("All projects").tag(UUID?.none)
                ForEach(projects.projects) { project in
                    Text("\(project.emoji) \(project.name)").tag(UUID?.some(project.id))
                }
                Text("📥 \(Project.inboxName)").tag(UUID?.some(Project.inboxID))
            }
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 6)
            peopleFilter
                .padding(.horizontal, 10)
            List(results, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: entry.kind.symbol)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(entry.title).font(.callout).lineLimit(1)
                    }
                    Text(entry.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .tag(entry.id)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search transcriptions")
            .overlay {
                if results.isEmpty && !people.isEmpty {
                    ContentUnavailableView("No meetings with \(ListFormatter.localizedString(byJoining: people))",
                                           systemImage: "person.2.slash",
                                           description: Text(people.count > 1 && peopleMode == .all
                                                             ? "Switch All to Any to see meetings with at least one of them." : "Pick someone else."))
                }
            }
            // Open on the newest entry rather than an empty detail pane. Opening
            // History almost always means "what did I just record", and an empty
            // pane makes you click before you can read anything.
            .onAppear { if selection == nil { selection = results.first?.id } }
            // Inline instead of .toolbar — the hub panel has no window toolbar.
            HStack {
                Button(role: .destructive) { store.clear() } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(store.entries.isEmpty)
                Spacer()
            }
            .padding(8)
            .frame(minWidth: 240)
        } detail: {
            if let entry = selected {
                DetailPane(entry: entry)
                    .id(entry.id)
            } else {
                ContentUnavailableView(
                    results.isEmpty ? "No history yet" : "Select an entry",
                    systemImage: "text.book.closed")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

private struct DetailPane: View {
    @EnvironmentObject var store: HistoryStore
    @ObservedObject private var projects = ProjectStore.shared
    let entry: HistoryEntry
    @State private var aiStatus = ""

    private var isWorking: Bool { store.working.contains(entry.id) }
    /// The raw fallback transcript is written when there was no provider — its
    /// telltale header means this meeting was never actually summarized.
    private var needsSummary: Bool {
        entry.kind == .meeting && entry.text.contains("Meeting transcript (raw)")
    }
    private var canFindCommitments: Bool {
        entry.kind == .meeting || entry.kind == .document
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(entry.kind.label, systemImage: entry.kind.symbol)
                    .font(.headline)
                Spacer()
                Picker("", selection: Binding(
                    get: { entry.projectID ?? Project.inboxID },
                    set: { store.assign(entryID: entry.id, to: $0) }
                )) {
                    ForEach(projects.projects) { project in
                        Text("\(project.emoji) \(project.name)").tag(project.id)
                    }
                    Text("📥 \(Project.inboxName)").tag(Project.inboxID)
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                Text(entry.date.formatted(date: .long, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if needsSummary {
                unprocessedBanner
            }
            Divider()
            ScrollView {
                // Rendered, not raw: the app writes Markdown, so showing "##"
                // to the person reading their own meeting notes is a leak of
                // the format. Copy and Export still hand over the source.
                MarkdownText(text: entry.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if entry.kind == .meeting || canFindCommitments {
                aiActionsRow
            }
            Divider()
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                }
                Button("Copy Rich Text") {
                    Exporter.copyRichText(markdown: entry.text)
                }
                Menu("Export…") {
                    ForEach(Exporter.Format.allCases) { format in
                        Button(format.rawValue) {
                            Exporter.save(title: entry.title, markdown: entry.text, format: format)
                        }
                    }
                }
                .frame(width: 110)
                Button("Insert") {
                    let text = entry.text
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        TextInserter.insert(text)
                    }
                }
                if let path = entry.filePath {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Spacer()
                Button(role: .destructive) { store.delete(entry) } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .padding(16)
    }

    /// Shown when a meeting only has the raw fallback transcript — the first
    /// AI pass never ran (no provider or it failed). Reassures the user their
    /// recording isn't lost and points at the one-tap fix.
    private var unprocessedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text("This meeting wasn't summarized — the transcript is saved, but the AI pass didn't run. Re-summarize it below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Re-run the meeting summary and/or mine commitments after the fact.
    private var aiActionsRow: some View {
        HStack(spacing: 10) {
            if entry.kind == .meeting {
                Button {
                    run { await store.reprocessMeeting(entry) }
                } label: {
                    Label(needsSummary ? "Summarize now" : "Re-summarize",
                          systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(needsSummary ? .large : .regular)
            }
            if canFindCommitments {
                Button {
                    run { await store.collectCommitments(entry) }
                } label: {
                    Label("Find commitments", systemImage: "checklist")
                }
            }
            if entry.kind == .meeting {
                shareMenu
            }
            if isWorking {
                ProgressView().controlSize(.small)
            } else if !aiStatus.isEmpty {
                Text(aiStatus)
                    .font(.caption)
                    .foregroundStyle(aiStatus.hasPrefix("✗") ? Color.red : .secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .disabled(isWorking)
        .padding(.top, 2)
    }

    /// Follow-up drafts for the mail app: everyone, or one person's promises.
    /// Griasa only opens the draft; sending is the person's.
    private var shareMenu: some View {
        Menu {
            Button("Email participants…") { FollowUpActions.open(FollowUpActions.meetingDraft(entry)) }
            let names = entry.participants ?? []
            if !names.isEmpty {
                Menu("Send promises to") {
                    ForEach(names, id: \.self) { name in
                        Button(name) { FollowUpActions.open(FollowUpActions.personDraft(entry, person: name)) }
                    }
                }
            }
            Divider()
            Toggle("Add \"made with Griasa\" line", isOn: Binding(
                get: { FollowUpActions.footer }, set: { FollowUpActions.footer = $0 }))
        } label: {
            Label("Share", systemImage: "envelope")
        }
        .fixedSize()
    }

    private func run(_ action: @escaping () async -> String) {
        aiStatus = ""
        Task { @MainActor in aiStatus = await action() }
    }
}
