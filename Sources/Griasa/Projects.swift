import Foundation
import Combine

/// A user-defined bucket that history entries (dictations, meetings, capture
/// actions) are filed into. Each project mirrors its entries as Markdown files
/// on disk and can have source folders attached as extra Claude context.
struct Project: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var emoji: String = "🗂"
    /// Shown to Claude when auto-categorizing — describe what belongs here.
    var about: String = ""
    /// Folders whose text files are included as context in "Ask Project".
    var sourceFolders: [String] = []
    var createdAt = Date()

    /// Virtual catch-all for unclassified entries — always present, never
    /// stored, never deletable. Entries with a nil projectID belong to it too.
    static let inboxID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let inboxName = "Inbox"
}

/// Persists the project list and keeps the on-disk Markdown folders in sync
/// with renames and deletions.
@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    @Published var projects: [Project] = [] {
        didSet {
            save()
            syncFolderRenames()
        }
    }

    /// Last known name per project, to detect renames and move the MD folder.
    private var knownNames: [UUID: String] = [:]

    private let fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Griasa/projects.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
        for project in projects { knownNames[project.id] = project.name }
    }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func displayName(for id: UUID?) -> String {
        project(id)?.name ?? Project.inboxName
    }

    func add() {
        projects.append(Project(name: "New project"))
    }

    /// Entries and Markdown files move to Inbox; content is never destroyed.
    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        knownNames[project.id] = nil
        HistoryStore.shared.moveEntries(from: project.id, to: Project.inboxID)
        let name = project.name
        Task.detached { ProjectFiles.mergeIntoInbox(folderNamed: name) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(projects)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Griasa: failed to save projects: %@", error.localizedDescription)
        }
    }

    private func syncFolderRenames() {
        for project in projects {
            if let old = knownNames[project.id], old != project.name {
                ProjectFiles.renameFolder(old, to: project.name)
            }
            knownNames[project.id] = project.name
        }
    }
}
