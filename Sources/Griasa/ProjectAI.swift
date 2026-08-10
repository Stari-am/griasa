import Foundation

/// Claude calls for the Projects feature: filing entries into projects and
/// answering questions with a project's content as context.
enum ProjectAI {
    /// Picks a project for a new entry by name, or nil when Claude is unsure,
    /// names don't match, or the request fails — callers treat nil as Inbox.
    static func classify(text: String, projects: [Project]) async -> UUID? {
        guard !projects.isEmpty else { return nil }
        let list = projects
            .map { "- \($0.name)" + ($0.about.isEmpty ? "" : " — \($0.about)") }
            .joined(separator: "\n")
        let system = Prompts.text(.projectClassify)
            .filling(["projects": list, "inbox": Project.inboxName])
        // Background classification never pops the cloud-fallback dialog —
        // failures silently file to Inbox.
        guard let reply = try? await AIFormatter.complete(
            system: system, user: String(text.prefix(1500)),
            tier: .fast, maxTokens: 50, timeout: 20, allowCloudFallback: false)
        else { return nil }
        let name = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return projects.first { $0.name.lowercased() == name }?.id
    }

    static func ask(question: String, context: String) async -> String? {
        let knowledgeBase = context.isEmpty
            ? "(empty — this project has no entries or readable files yet)"
            : context
        let system = Prompts.text(.projectAsk).filling(["knowledgeBase": knowledgeBase])
        return try? await AIFormatter.complete(system: system, user: question,
                                               tier: .smart, maxTokens: 4096, timeout: 180)
    }
}

/// Assembles the text Claude sees for "Ask Project": the project's Markdown
/// entries (newest first) plus text files from attached source folders, capped
/// so a huge folder can't blow up the request. Pure file IO on value types —
/// safe to run off the main actor.
enum ProjectContext {
    static let charBudget = 150_000
    private static let maxFileBytes = 256 * 1024
    private static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "swift", "ts", "tsx", "js", "jsx", "py", "rb",
        "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "json",
        "yaml", "yml", "toml", "xml", "html", "css", "scss", "sh", "sql", "csv",
    ]
    private static let skippedDirs: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "Pods", "DerivedData",
        ".venv", "venv", "vendor", "target",
    ]

    static func build(projectFolderName: String, sourceFolders: [String]) -> String {
        var out = ""
        var remaining = charBudget
        var truncated = false
        let fm = FileManager.default

        // Project entries: filenames start with the date, so descending name
        // order is newest first.
        let entriesDir = ProjectFiles.folder(named: projectFolderName)
        let entryFiles = ((try? fm.contentsOfDirectory(at: entriesDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in entryFiles {
            append(file, to: &out, remaining: &remaining, truncated: &truncated)
        }

        for folderPath in sourceFolders {
            guard remaining > 0 else { break }
            let base = URL(fileURLWithPath: folderPath)
            guard let enumerator = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if skippedDirs.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard textExtensions.contains(url.pathExtension.lowercased()) else { continue }
                append(url, to: &out, remaining: &remaining, truncated: &truncated)
                if remaining <= 0 { break }
            }
        }

        if truncated {
            out += "\n\n[Context truncated at \(charBudget) characters — newest entries were included first.]"
        }
        return out
    }

    private static func append(_ url: URL, to out: inout String,
                               remaining: inout Int, truncated: inout Bool) {
        guard remaining > 0 else {
            truncated = true
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxFileBytes,
              let content = try? String(contentsOf: url, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let chunk = "\n\n===== \(url.path) =====\n" + content
        if chunk.count <= remaining {
            out += chunk
            remaining -= chunk.count
        } else {
            out += String(chunk.prefix(remaining))
            remaining = 0
            truncated = true
        }
    }
}
