import Foundation
import Combine

/// One entry in the transcription history.
struct HistoryEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case dictation
        case meeting
        case action  // selection summary / grammar / preset
        case document  // generated from a template (PRD, RFC…)

        var label: String {
            switch self {
            case .dictation: return "Dictation"
            case .meeting: return "Meeting"
            case .action: return "Action"
            case .document: return "Document"
            }
        }
        var symbol: String {
            switch self {
            case .dictation: return "mic"
            case .meeting: return "record.circle"
            case .action: return "sparkles"
            case .document: return "doc.text"
            }
        }
    }

    var id = UUID()
    var date = Date()
    var kind: Kind
    /// Short label ("Dictation", meeting title, preset name).
    var title: String
    var text: String
    /// For meetings: the on-disk transcript file, so it can be revealed.
    var filePath: String?
    /// Owning project; nil = not yet categorized (shown as Inbox).
    var projectID: UUID?
    /// For meetings: who was on the call (drives the People pages). Optional
    /// so history saved before this field existed still decodes.
    var participants: [String]?
}

/// Persistent, searchable history of everything Griasa produced. Backed by a
/// single JSON file; keeps the most recent `maxEntries`.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    /// Progress line for the bulk "Categorize existing history" pass.
    @Published var categorizeStatus: String?
    /// Entries currently being re-summarized / mined for commitments — drives
    /// the per-entry spinner in the History detail pane.
    @Published private(set) var working: Set<UUID> = []

    private let maxEntries = 500
    private let fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Griasa/history.json")

    init() { load() }

    /// Pass `projectID` when the owning project is already known (e.g. Ask
    /// Project answers); otherwise Claude classifies the entry in the background.
    /// Returns the new entry's id (nil when the text was empty and nothing was
    /// saved) so callers can reference the entry later.
    @discardableResult
    func add(kind: HistoryEntry.Kind, title: String, text: String, filePath: String? = nil,
             projectID: UUID? = nil, participants: [String]? = nil) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = HistoryEntry(kind: kind, title: title, text: trimmed, filePath: filePath,
                                 participants: participants)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        save()
        if let projectID {
            assign(entryID: entry.id, to: projectID)
        } else {
            classifyAndFile(entry)
        }
        return entry.id
    }

    /// Files a fresh entry into a project in the background: Claude picks one
    /// by name; no key / no projects / failure → Inbox. Saving never waits.
    private func classifyAndFile(_ entry: HistoryEntry) {
        Task { @MainActor in
            let projects = ProjectStore.shared.projects
            var projectID = Project.inboxID
            if AIFormatter.isConfigured, !projects.isEmpty,
               let match = await ProjectAI.classify(text: entry.text, projects: projects) {
                projectID = match
            }
            assign(entryID: entry.id, to: projectID)
        }
    }

    /// Sets an entry's project and moves its Markdown mirror file.
    func assign(entryID: UUID, to projectID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let oldProjectID = entries[index].projectID
        entries[index].projectID = projectID
        save()
        let entry = entries[index]
        let oldName = ProjectStore.shared.displayName(for: oldProjectID)
        let newName = ProjectStore.shared.displayName(for: projectID)
        Task.detached {
            if let oldProjectID, oldProjectID != projectID {
                ProjectFiles.remove(entry: entry, projectName: oldName)
            }
            ProjectFiles.write(entry: entry, projectName: newName)
        }
    }

    /// Re-tags all entries of a deleted project as Inbox (files are merged on
    /// disk by ProjectStore.delete).
    func moveEntries(from projectID: UUID, to newProjectID: UUID) {
        for index in entries.indices where entries[index].projectID == projectID {
            entries[index].projectID = newProjectID
        }
        save()
    }

    /// One-time pass over entries that predate the Projects feature.
    func categorizeAll() {
        Task { @MainActor in
            let projects = ProjectStore.shared.projects
            guard AIFormatter.isConfigured else {
                categorizeStatus = "Configure an AI provider in AI & Actions first."
                return
            }
            guard !projects.isEmpty else {
                categorizeStatus = "Add at least one project first."
                return
            }
            let untagged = entries.filter { $0.projectID == nil }
            guard !untagged.isEmpty else {
                categorizeStatus = "Nothing to categorize."
                return
            }
            for (done, entry) in untagged.enumerated() {
                categorizeStatus = "Categorizing… \(done)/\(untagged.count)"
                let projectID = await ProjectAI.classify(
                    text: entry.text, projects: projects) ?? Project.inboxID
                assign(entryID: entry.id, to: projectID)
            }
            categorizeStatus = "Done — \(untagged.count) entries categorized."
        }
    }

    /// Replaces an entry's title and text in place (used after re-summarizing)
    /// and refreshes its Markdown mirror on disk.
    func updateEntry(id: UUID, title: String, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].title = title
        entries[index].text = text
        save()
        let entry = entries[index]
        let projectName = ProjectStore.shared.displayName(for: entry.projectID)
        Task.detached { ProjectFiles.write(entry: entry, projectName: projectName) }
    }

    /// Re-run the AI meeting summary from the saved raw transcript — for
    /// meetings the AI couldn't process the first time (no provider / failure).
    /// Rebuilds the notes, updates the entry, then refreshes commitments.
    /// Returns a short status line for the UI.
    func reprocessMeeting(_ entry: HistoryEntry) async -> String {
        guard entry.kind == .meeting, let path = entry.filePath else {
            return "Only meeting recordings can be re-summarized."
        }
        guard AIFormatter.isConfigured else {
            return "Configure an AI provider in AI & Actions first."
        }
        working.insert(entry.id)
        defer { working.remove(entry.id) }
        let participants = entry.participants ?? []
        let myName = ParticipantRoster.shared.myName
        do {
            let markdown = try await MeetingTranscriber.reformat(
                transcriptFile: URL(fileURLWithPath: path),
                participants: participants, myName: myName)
            let title = MeetingTranscriber.title(fromMarkdown: markdown)
            updateEntry(id: entry.id, title: title, text: markdown)
            let added = (try? await CommitmentExtractor.extract(
                markdown: markdown, participants: participants, myName: myName,
                sourceTitle: title, sourceEntryID: entry.id)) ?? 0
            return added > 0
                ? "✓ Summary rebuilt · \(added) commitment\(added == 1 ? "" : "s") added"
                : "✓ Summary rebuilt"
        } catch {
            return "✗ \(error.localizedDescription)"
        }
    }

    /// Mine an existing entry's text for commitments retrospectively — for
    /// meetings recorded before the tracker existed, or where extraction had
    /// failed. Returns a short status line.
    func collectCommitments(_ entry: HistoryEntry) async -> String {
        guard AIFormatter.isConfigured else {
            return "Configure an AI provider in AI & Actions first."
        }
        working.insert(entry.id)
        defer { working.remove(entry.id) }
        let participants = entry.participants ?? []
        let myName = ParticipantRoster.shared.myName
        do {
            let added = try await CommitmentExtractor.extract(
                markdown: entry.text, participants: participants, myName: myName,
                sourceTitle: entry.title, sourceEntryID: entry.id)
            return added > 0
                ? "✓ \(added) commitment\(added == 1 ? "" : "s") added — see the Commitments tab"
                : "No new commitments found in this text."
        } catch {
            return "✗ \(error.localizedDescription)"
        }
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
        let projectName = ProjectStore.shared.displayName(for: entry.projectID)
        Task.detached { ProjectFiles.remove(entry: entry, projectName: projectName) }
    }

    func clear() {
        entries.removeAll()
        save()
    }

    func filtered(_ query: String, project: UUID? = nil) -> [HistoryEntry] {
        var result = entries
        if let project {
            result = result.filter { ($0.projectID ?? Project.inboxID) == project }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return result }
        return result.filter {
            $0.text.lowercased().contains(q) || $0.title.lowercased().contains(q)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Griasa: failed to save history: %@", error.localizedDescription)
        }
    }
}
