import Foundation

/// The pure half of the "map" step of a long meeting: what one part of the
/// transcript is asked to produce, how the reply is read, which promises in it
/// are believed, and how it is written down for the merge that follows.
/// Foundation only, so `test.sh` can reach it; the requests are in
/// `LongMeetingNotes`.
enum LongMeetingMap {
    struct Action: Decodable, Equatable {
        var owner: String?
        var task: String?
        var due: String?
        var quote: String?
    }
    struct Speaker: Decodable, Equatable {
        var name: String?
        var clue: String?
    }
    /// Every key optional: a reply missing a list is a part with none of that.
    struct Result: Decodable, Equatable {
        var points: [String]?
        var decisions: [String]?
        var actions: [Action]?
        var questions: [String]?
        var speakers: [Speaker]?
    }

    /// The JSON Schema a local engine constrains the reply to. Empty lists are
    /// allowed everywhere; every key is required so none is silently skipped.
    static let schema = """
    {"type":"object","additionalProperties":false,
     "required":["points","decisions","actions","questions","speakers"],
     "properties":{
      "points":{"type":"array","items":{"type":"string"}},
      "decisions":{"type":"array","items":{"type":"string"}},
      "actions":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["owner","task","due","quote"],
        "properties":{"owner":{"type":"string"},"task":{"type":"string"},
                      "due":{"type":"string"},"quote":{"type":"string"}}}},
      "questions":{"type":"array","items":{"type":"string"}},
      "speakers":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["name","clue"],
        "properties":{"name":{"type":"string"},"clue":{"type":"string"}}}}}}
    """

    static func decode(_ reply: String) -> Result? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Result.self, from: data)
    }

    /// Keeps only the promises whose quote is really in this part of the
    /// transcript (the new lines, not the context repeated from before).
    /// `dropped` counts the rest.
    static func believed(_ result: Result, chunkBody: String) -> (result: Result, dropped: Int) {
        let prepared = QuoteMatch.prepare(chunkBody)
        var kept = result
        let all = result.actions ?? []
        kept.actions = all.filter { action in
            guard let task = action.task, !task.trimmingCharacters(in: .whitespaces).isEmpty,
                  let quote = action.quote else { return false }
            return QuoteMatch.contains(prepared, quote: quote)
        }
        return (kept, all.count - (kept.actions?.count ?? 0))
    }

    /// Names the model has pinned to "Them" so far, newest clue winning, in
    /// the order first seen.
    static func merge(_ speakers: [Speaker]?, into known: inout [(name: String, clue: String)]) {
        for speaker in speakers ?? [] {
            guard let name = speaker.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let clue = speaker.clue?.trimmingCharacters(in: .whitespaces), !clue.isEmpty else { continue }
            if let at = known.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                known[at].clue = clue
            } else {
                known.append((name, clue))
            }
        }
    }

    /// The "known so far" paragraph of the next part's instructions.
    static func knownText(_ known: [(name: String, clue: String)], limit: Int = 20) -> String {
        guard !known.isEmpty else { return "" }
        let lines = known.suffix(limit).map { "- \($0.name): \($0.clue)" }.joined(separator: "\n")
        return "Speaker clues found in earlier parts — use them to tell who the \"Them\" speakers are:\n\(lines)\n"
    }

    /// One part's notes as the merge step reads them.
    static func render(_ result: Result, part: Int, parts: Int, range: String) -> String {
        var out = "### Part \(part) of \(parts)" + (range.isEmpty ? "" : " (\(range))")
        func list(_ title: String, _ items: [String]) {
            let clean = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !clean.isEmpty else { return }
            out += "\n\(title):\n" + clean.map { "- \($0)" }.joined(separator: "\n")
        }
        list("Points", result.points ?? [])
        list("Decisions", result.decisions ?? [])
        list("Actions", (result.actions ?? []).compactMap { action in
            guard let task = action.task, !task.isEmpty else { return nil }
            var line = (action.owner?.isEmpty == false ? "\(action.owner!): " : "") + task
            if let due = action.due, !due.isEmpty { line += " (due: \(due))" }
            return line
        })
        list("Open questions", result.questions ?? [])
        if !out.contains("\n") { out += "\n(nothing notable)" }
        return out
    }

    /// The merge step's reply with any transcript it added anyway removed — the
    /// transcript is built in code, and a model's copy would be a second one.
    static func withoutTranscript(_ markdown: String) -> String {
        guard let range = markdown.range(of: "\n## Transcript") else { return markdown.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(markdown[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
