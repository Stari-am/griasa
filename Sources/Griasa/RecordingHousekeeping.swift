import Foundation

/// Where recording folders live, and when their audio may go.
///
/// Foundation only, so `test.sh` can reach the rules. Two of them can destroy a
/// meeting if they are wrong, which is why they are written down here rather
/// than inline where the files are touched.
enum RecordingRules {
    /// What the rules need to know about one recording folder.
    struct Session: Equatable {
        var folder: URL
        var started: Date
        /// The finished transcript exists. Until it does, the audio is the only
        /// copy of the meeting there is.
        var hasTranscript: Bool
        var audio: [URL]
    }

    /// Recording folders are named by their start time.
    static let folderDateFormat = "yyyy-MM-dd HH.mm.ss"

    static func startDate(ofFolderNamed name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = folderDateFormat
        return formatter.date(from: name)
    }

    /// The audio files that may be deleted now.
    ///
    /// Only audio. Only from a recording old enough. Never from one without a
    /// finished transcript — a recording whose transcription failed, or has not
    /// run yet, would otherwise vanish entirely, and that is the one outcome
    /// this feature must never produce. And never from the recording in
    /// progress, whatever its age.
    ///
    /// - Parameter days: 0 means keep for ever, which is the default.
    static func audioToDelete(_ sessions: [Session], olderThanDays days: Int,
                              now: Date, active: URL?) -> [URL] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return sessions
            .filter { $0.hasTranscript && $0.started < cutoff }
            .filter { session in
                guard let active else { return true }
                return session.folder.standardizedFileURL != active.standardizedFileURL
            }
            .flatMap(\.audio)
            .filter { ["caf", "wav", "m4a"].contains($0.pathExtension.lowercased()) }
    }

    /// Where a recording folder belongs. With project folders on, inside its
    /// project — beside that project's meeting notes — and in Inbox while it
    /// has none; otherwise where recordings have always been.
    static func home(ofSessionNamed name: String, byProject: Bool,
                     projectFolder: URL, recordingsRoot: URL) -> URL {
        byProject
            ? projectFolder.appendingPathComponent("Recordings", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            : recordingsRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// Where a recording's file is now, given where the history last saw it.
    ///
    /// Paths go stale for reasons the history never hears about: a project is
    /// renamed and its whole folder moves, a project is deleted and merges into
    /// Inbox, somebody tidies up in Finder. Rather than chase every one of
    /// those, a missing file is looked up by the one thing that never changes
    /// — its recording folder's name — under every place recordings can live.
    static func relocate(_ path: String, recordingsRoot: URL, projectsRoot: URL,
                         exists: (String) -> Bool,
                         projectFolders: () -> [URL]) -> String? {
        if exists(path) { return path }
        let file = URL(fileURLWithPath: path)
        let session = file.deletingLastPathComponent().lastPathComponent
        let name = file.lastPathComponent
        guard !session.isEmpty, !name.isEmpty else { return nil }
        let candidates = [recordingsRoot.appendingPathComponent(session)]
            + projectFolders().map { $0.appendingPathComponent("Recordings").appendingPathComponent(session) }
        return candidates
            .map { $0.appendingPathComponent(name).path }
            .first(where: exists)
    }
}
