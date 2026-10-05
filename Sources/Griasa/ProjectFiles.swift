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

    /// Moves everything in `from` into `dest`, merging folders that exist on
    /// both sides, and removes `from` only once it is empty.
    ///
    /// It used to move top-level items with `try?` and then delete the source
    /// regardless. Harmless while a project folder held only Markdown files;
    /// once recordings live inside projects, a `Recordings` folder already in
    /// the destination made the move fail silently and the delete that followed
    /// took the recordings with it. Now a clash recurses, a file that still
    /// clashes is kept under a new name, and anything that cannot be moved
    /// stays where it is — the source folder survives until it is genuinely
    /// empty.
    static func merge(from: URL, into dest: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for item in items {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            var isDirectory: ObjCBool = false
            let clash = fm.fileExists(atPath: target.path, isDirectory: &isDirectory)
            let itemIsDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if clash && isDirectory.boolValue && itemIsDirectory {
                merge(from: item, into: target)
            } else if clash {
                let stem = target.deletingPathExtension().lastPathComponent
                let ext = target.pathExtension
                let renamed = dest.appendingPathComponent(
                    "\(stem) (from \(from.lastPathComponent))" + (ext.isEmpty ? "" : ".\(ext)"))
                try? fm.moveItem(at: item, to: renamed)
            } else {
                try? fm.moveItem(at: item, to: target)
            }
        }
        if (try? fm.contentsOfDirectory(atPath: from.path))?.isEmpty == true {
            try? fm.removeItem(at: from)
        }
    }
}
