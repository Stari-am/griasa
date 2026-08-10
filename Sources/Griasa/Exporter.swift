import AppKit
import UniformTypeIdentifiers

/// Exports transcripts and notes to portable formats — no external service or
/// auth required. Markdown imports cleanly into Notion / Obsidian / GitHub;
/// HTML and RTF paste with formatting into Google Docs / Confluence / Word;
/// "Copy as Rich Text" pastes formatted straight into any editor.
enum Exporter {
    enum Format: String, CaseIterable, Identifiable {
        case markdown = "Markdown (.md)"
        case pdf = "PDF (.pdf)"
        case html = "HTML (.html)"
        case rtf = "Rich Text (.rtf)"
        case plainText = "Plain Text (.txt)"

        var id: String { rawValue }
        var ext: String {
            switch self {
            case .markdown: return "md"
            case .pdf: return "pdf"
            case .html: return "html"
            case .rtf: return "rtf"
            case .plainText: return "txt"
            }
        }
        var utType: UTType {
            switch self {
            case .markdown: return UTType(filenameExtension: "md") ?? .plainText
            case .pdf: return .pdf
            case .html: return .html
            case .rtf: return .rtf
            case .plainText: return .plainText
            }
        }
    }

    // MARK: - Public

    @MainActor
    static func save(title: String, markdown: String, format: Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitize(title)).\(format.ext)"
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .markdown:
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            case .plainText:
                try plainText(from: markdown).write(to: url, atomically: true, encoding: .utf8)
            case .html:
                try htmlDocument(title: title, markdown: markdown).write(to: url, atomically: true, encoding: .utf8)
            case .rtf:
                let attr = attributed(from: markdown)
                let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                try data.write(to: url)
            case .pdf:
                try writePDF(attributed(from: markdown), to: url)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentError(error)
        }
    }

    /// Puts both RTF and plain text on the pasteboard so a paste into Docs /
    /// Notion / Confluence / Slack keeps headings, bold, and bullets.
    @MainActor
    static func copyRichText(markdown: String) {
        let attr = attributed(from: markdown)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let rtf = try? attr.data(from: NSRange(location: 0, length: attr.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(attr.string, forType: .string)
    }

    // MARK: - Markdown → HTML

    /// Small, dependency-free Markdown → HTML converter covering the subset our
    /// notes produce: #/##/### headings, **bold**, *italic*, `code`, bullet and
    /// numbered lists, blank-line paragraphs.
    static func html(from markdown: String) -> String {
        var out = "", listType: String? = nil
        func closeList() { if let t = listType { out += "</\(t)>\n"; listType = nil } }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { closeList(); continue }

            if let heading = headingLevel(line) {
                closeList()
                let text = inline(String(line.dropFirst(heading + 1)))
                out += "<h\(heading)>\(text)</h\(heading)>\n"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if listType != "ul" { closeList(); out += "<ul>\n"; listType = "ul" }
                out += "<li>\(inline(String(line.dropFirst(2))))</li>\n"
            } else if let dot = numberedPrefix(line) {
                if listType != "ol" { closeList(); out += "<ol>\n"; listType = "ol" }
                out += "<li>\(inline(String(line.dropFirst(dot))))</li>\n"
            } else {
                closeList()
                out += "<p>\(inline(line))</p>\n"
            }
        }
        closeList()
        return out
    }

    // MARK: - Helpers

    private static func headingLevel(_ line: String) -> Int? {
        for n in stride(from: 6, through: 1, by: -1) where line.hasPrefix(String(repeating: "#", count: n) + " ") {
            return n
        }
        return nil
    }

    private static func numberedPrefix(_ line: String) -> Int? {
        // "1. text" → number of leading chars to drop
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let numberPart = line[line.startIndex..<dotIndex]
        guard !numberPart.isEmpty, numberPart.allSatisfy(\.isNumber),
              line.index(after: dotIndex) < line.endIndex,
              line[line.index(after: dotIndex)] == " " else { return nil }
        return line.distance(from: line.startIndex, to: dotIndex) + 2
    }

    private static func inline(_ text: String) -> String {
        var s = escapeHTML(text)
        s = replacePairs(in: s, marker: "**", tag: "strong")
        s = replacePairs(in: s, marker: "`", tag: "code")
        s = replacePairs(in: s, marker: "*", tag: "em")
        return s
    }

    private static func replacePairs(in text: String, marker: String, tag: String) -> String {
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return text }
        var result = ""
        for (i, part) in parts.enumerated() {
            if i == 0 { result += part }
            else if i % 2 == 1 && i < parts.count - (parts.count % 2 == 0 ? 1 : 0) {
                result += "<\(tag)>\(part)</\(tag)>"
            } else {
                result += (i % 2 == 1 ? marker : "") + part
            }
        }
        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func htmlDocument(title: String, markdown: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escapeHTML(title))</title>
        <style>
          body { font: 15px/1.5 -apple-system, system-ui, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 20px; color: #1a1a1a; }
          h1 { font-size: 1.6em; } h2 { font-size: 1.25em; margin-top: 1.4em; } h3 { font-size: 1.1em; }
          code { background: #f2f2f2; padding: 1px 4px; border-radius: 3px; font-size: 0.9em; }
          ul, ol { padding-left: 1.4em; }
        </style></head><body>
        \(html(from: markdown))
        </body></html>
        """
    }

    /// Attributed string via the HTML importer — gives real headings, bold,
    /// and lists for RTF/PDF export and rich-text copy.
    private static func attributed(from markdown: String) -> NSAttributedString {
        let doc = htmlDocument(title: "", markdown: markdown)
        if let data = doc.data(using: .utf8),
           let attr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil) {
            return attr
        }
        return NSAttributedString(string: plainText(from: markdown))
    }

    private static func plainText(from markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    private static func sanitize(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Griasa export" : String(cleaned.prefix(80))
    }

    /// Renders an attributed string to a paginated PDF via the print system.
    @MainActor
    private static func writePDF(_ attributed: NSAttributedString, to url: URL) throws {
        let printInfo = NSPrintInfo()
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        printInfo.topMargin = 54; printInfo.bottomMargin = 54
        printInfo.leftMargin = 54; printInfo.rightMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic

        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attributed)
        textView.sizeToFit()

        let op = NSPrintOperation(view: textView, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if !op.run() {
            throw NSError(domain: "Griasa", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "PDF export failed."])
        }
    }

    @MainActor
    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
