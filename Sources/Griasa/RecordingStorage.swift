import Foundation

/// Applies `RecordingRules` to the files on disk: deletes old audio, keeps
/// recording folders beside their project's notes, and repairs the history's
/// paths when folders have moved.
///
/// Both settings are off until somebody turns them on. Deleting audio and
/// moving folders are not things an update should start doing to anybody's
/// files on its own.
@MainActor
enum RecordingStorage {
    /// Days to keep the audio of a transcribed recording; 0 keeps it for ever.
    static let retentionKey = "audioRetentionDays"
    /// Keep each recording folder inside its project's folder.
    static let byProjectKey = "recordingsByProject"

    static var retentionDays: Int { max(0, UserDefaults.standard.integer(forKey: retentionKey)) }
    static var byProject: Bool { UserDefaults.standard.bool(forKey: byProjectKey) }

    static var recordingsRoot: URL { ConversationRecorder.recordingsRoot }
    static var projectsRoot: URL { ProjectFiles.root }

    private static var activeFolder: URL? { AppState.shared.recorder.currentFolder }

    // MARK: - Scanning

    /// Every recording folder, wherever it lives: the recordings folder, and
    /// the `Recordings` folder of every project.
    nonisolated static func sessions(recordingsRoot: URL, projectsRoot: URL) -> [RecordingRules.Session] {
        let fm = FileManager.default
        func children(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                                          options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        let folders = children(recordingsRoot)
            + children(projectsRoot).flatMap { children($0.appendingPathComponent("Recordings")) }
        return folders.map { folder in
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let started = RecordingRules.startDate(ofFolderNamed: folder.lastPathComponent)
                ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantFuture  // undatable: never old enough to delete
            return RecordingRules.Session(
                folder: folder, started: started,
                hasTranscript: fm.fileExists(atPath: folder.appendingPathComponent("meeting-transcript.md").path),
                audio: files.filter { $0.pathExtension.lowercased() == "caf" })
        }
    }

    nonisolated static func size(of files: [URL]) -> Int64 {
        files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Audio on disk in total, and how much of it the given setting would free.
    static func usage(days: Int) async -> (total: Int64, freeable: Int64, recordings: Int) {
        let (roots, active) = ((recordingsRoot, projectsRoot), activeFolder)
        return await Task.detached(priority: .utility) {
            let all = sessions(recordingsRoot: roots.0, projectsRoot: roots.1)
            let doomed = RecordingRules.audioToDelete(all, olderThanDays: days, now: Date(), active: active)
            let recordings = Set(doomed.map { $0.deletingLastPathComponent() }).count
            return (size(of: all.flatMap(\.audio)), size(of: doomed), recordings)
        }.value
    }

    // MARK: - Deleting audio

    /// Deletes what the rules allow. Permanently: the point is disk space, and
    /// a hundred gigabytes moved to the Trash frees none of it.
    @discardableResult
    static func purgeAudio(days: Int? = nil) async -> (files: Int, bytes: Int64) {
        let keep = days ?? retentionDays
        guard keep > 0 else { return (0, 0) }
        let (roots, active) = ((recordingsRoot, projectsRoot), activeFolder)
        let result = await Task.detached(priority: .utility) { () -> (Int, Int64) in
            let doomed = RecordingRules.audioToDelete(
                sessions(recordingsRoot: roots.0, projectsRoot: roots.1),
                olderThanDays: keep, now: Date(), active: active)
            var freed: Int64 = 0, removed = 0
            for file in doomed {
                let bytes = size(of: [file])
                if (try? FileManager.default.removeItem(at: file)) != nil {
                    freed += bytes; removed += 1
                }
            }
            return (removed, freed)
        }.value
        if result.0 > 0 {
            NSLog("Griasa: deleted %d recording audio file(s), %lld bytes", result.0, result.1)
        }
        return result
    }

    // MARK: - Folders by project

    /// Moves one meeting's recording folder to where the setting says it lives,
    /// and points the history at it.
    static func place(_ entry: HistoryEntry) {
        guard entry.kind == .meeting, let path = entry.filePath else { return }
        let file = URL(fileURLWithPath: path)
        let folder = file.deletingLastPathComponent()
        // Only folders that are genuinely recordings, and never one still being
        // written to.
        guard folder.standardizedFileURL != activeFolder?.standardizedFileURL,
              RecordingRules.startDate(ofFolderNamed: folder.lastPathComponent) != nil,
              FileManager.default.fileExists(atPath: folder.path) else { return }
        let projectFolder = ProjectFiles.folder(named: ProjectStore.shared.displayName(for: entry.projectID))
        let home = RecordingRules.home(ofSessionNamed: folder.lastPathComponent, byProject: byProject,
                                       projectFolder: projectFolder, recordingsRoot: recordingsRoot)
        guard home.standardizedFileURL != folder.standardizedFileURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: home.path) {
            ProjectFiles.merge(from: folder, into: home)
        } else if (try? fm.moveItem(at: folder, to: home)) == nil {
            return
        }
        HistoryStore.shared.setFilePath(home.appendingPathComponent(file.lastPathComponent).path, for: entry.id)
    }

    /// Every meeting, to wherever the setting now says. Run when the setting
    /// changes and at launch; it does nothing for folders already in place.
    static func applyLayout() {
        for entry in HistoryStore.shared.entries where entry.kind == .meeting { place(entry) }
    }

    /// Points the history at recordings that moved without it being told — a
    /// project renamed or deleted, a folder tidied in Finder.
    static func repairPaths() {
        let fm = FileManager.default
        let projectFolders = { ((try? fm.contentsOfDirectory(at: ProjectFiles.root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])) ?? []) }
        for entry in HistoryStore.shared.entries where entry.kind == .meeting {
            guard let path = entry.filePath, !fm.fileExists(atPath: path) else { continue }
            if let found = RecordingRules.relocate(path, recordingsRoot: recordingsRoot,
                                                   projectsRoot: projectsRoot,
                                                   exists: { fm.fileExists(atPath: $0) },
                                                   projectFolders: projectFolders) {
                HistoryStore.shared.setFilePath(found, for: entry.id)
            }
        }
    }

    /// Everything, in the order that is safe: find what moved, put folders
    /// where they belong, then delete what has expired.
    static func maintain() async {
        repairPaths()
        if byProject { applyLayout() }
        await purgeAudio()
    }
}
