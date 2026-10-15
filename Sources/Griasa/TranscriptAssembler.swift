import Foundation

/// Builds the `## Transcript` section of long-meeting notes from the raw
/// dialogue, without the model.
///
/// On a local model the old way — ask for the whole transcript back, cleaned —
/// doubled the work and was most of the time a long meeting took. Here the
/// raw lines are tidied by rule: consecutive lines from one speaker become one
/// paragraph, a `[mm:ss]` stamp appears every few minutes, "You" becomes the
/// user's name, and typed notes become blockquotes. What is lost is the
/// model's repair of misheard words and its names for "Them".
enum TranscriptAssembler {
    static func assemble(raw: String, myName: String, stampEvery: Int = 180) -> String {
        enum Block {
            case speech(start: Int, label: String, text: String)
            case note(seconds: Int, text: String)
        }
        var blocks: [Block] = []
        for line in raw.components(separatedBy: "\n") {
            switch RawLine.parse(line) {
            case let .speech(seconds, speaker, text):
                let label = speaker == "You" ? (myName.isEmpty ? "You" : myName) : speaker
                if case let .speech(start, last, existing)? = blocks.last, last == label {
                    blocks[blocks.count - 1] = .speech(start: start, label: label, text: join(existing, text))
                } else {
                    blocks.append(.speech(start: seconds, label: label, text: text))
                }
            case let .note(seconds, text):
                blocks.append(.note(seconds: seconds, text: text))
            case let .other(text):
                let extra = text.trimmingCharacters(in: .whitespaces)
                guard !extra.isEmpty else { continue }
                switch blocks.last {
                case let .speech(start, label, existing)?:
                    blocks[blocks.count - 1] = .speech(start: start, label: label, text: join(existing, extra))
                case let .note(seconds, existing)?:
                    blocks[blocks.count - 1] = .note(seconds: seconds, text: join(existing, extra))
                case nil:
                    blocks.append(.speech(start: 0, label: "Them", text: extra))
                }
            }
        }

        var paragraphs: [String] = []
        var lastStamp: Int?
        for block in blocks {
            switch block {
            case let .speech(start, label, text):
                var prefix = ""
                if lastStamp == nil || start - lastStamp! >= stampEvery {
                    prefix = "[\(RawLine.clock(start))] "
                    lastStamp = start
                }
                paragraphs.append("\(prefix)**\(label):** \(text)")
            case let .note(seconds, text):
                paragraphs.append("> 📝 **Note [\(RawLine.clock(seconds))]:** \(text)")
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The part of finished notes that is the transcript — everything after the
    /// `## Transcript` heading — or the whole text when there is no such heading
    /// (notes imported from another tool).
    static func transcriptSection(of markdown: String) -> String {
        // The heading is a line of its own; the words "## Transcript" inside a
        // sentence are not it.
        guard let range = markdown.range(of: #"(?m)^## Transcript[ \t]*$"#, options: .regularExpression)
        else { return markdown }
        let body = markdown[range.upperBound...]
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
