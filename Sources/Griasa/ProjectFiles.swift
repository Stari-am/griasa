import Foundation

/// Mirrors history entries as Markdown files under
/// `~/Documents/Griasa/Projects/<Project>/`, one file per entry with YAML
/// frontmatter. The JSON history stays the source of truth; failures here are
/// logged and never fatal.
enum ProjectFiles {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Griasa/Projects")
    }

    static func folder(named projectName: String) -> URL {
        root.appendingPathComponent(sanitize(projectName), isDirectory: true)
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Deterministic (date + kind + id prefix), so reassigning an entry to a
    /// different project can find and remove the old file.
    static func fileName(for entry: HistoryEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let idPrefix = entry.id.uuidString.prefix(8).lowercased()
        return "\(formatter.string(from: entry.date))-\(entry.kind.rawValue)-\(idPrefix).md"
    }

    static func write(entry: HistoryEntry, projectName: String) {
        let dir = folder(named: projectName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var lines = [
                "---",
                "date: \(ISO8601DateFormatter().string(from: entry.date))",
                "kind: \(entry.kind.rawValue)",
                "title: \"\(entry.title.replacingOccurrences(of: "\"", with: "'"))\"",
            ]
            if let path = entry.filePath {
                lines.append("source: \"\(path)\"")
            }
            lines.append("---")
            let content = lines.joined(separator: "\n") + "\n\n" + entry.text + "\n"
            try content.write(to: dir.appendingPathComponent(fileName(for: entry)),
                              atomically: true, encoding: .utf8)
        } catch {
            NSLog("Griasa: failed to write project file: %@", error.localizedDescription)
        }
    }

    static func remove(entry: HistoryEntry, projectName: String) {
        try? FileManager.default.removeItem(
            at: folder(named: projectName).appendingPathComponent(fileName(for: entry)))
    }

    static func renameFolder(_ old: String, to new: String) {
        let from = folder(named: old)
        let dest = folder(named: new)
        guard FileManager.default.fileExists(atPath: from.path), from != dest else { return }
        if FileManager.default.fileExists(atPath: dest.path) {
            merge(from: from, into: dest)
        } else {
            try? FileManager.default.moveItem(at: from, to: dest)
        }
    }

    static func mergeIntoInbox(folderNamed name: String) {
        merge(from: folder(named: name), into: folder(named: Project.inboxName))
    }

    private static func merge(from: URL, into dest: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else { return }
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for file in files {
            try? fm.moveItem(at: file, to: dest.appendingPathComponent(file.lastPathComponent))
        }
        try? fm.removeItem(at: from)
    }
}
