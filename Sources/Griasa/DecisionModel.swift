import Foundation

/// One decision taken in a meeting: what was chosen, why, and the words it was
/// taken in — so that months later "why did we do it this way?" has an answer
/// with a quote, not a recollection.
///
/// A decision is not a promise. "We go with Postgres" is a decision; "I'll write
/// the migration by Friday" is a promise that may follow from it. Both can come
/// out of the same minute of a meeting and are kept apart.
///
/// Foundation only, with a decoder written by hand, for the reason given on
/// `Commitment`: a file written before a field existed must still load.
struct Decision: Identifiable, Codable, Equatable {
    var id = UUID()
    /// What was decided, short and self-contained.
    var text: String
    /// The reason given, when one was.
    var why: String?
    /// Who made the call, when someone did; nil for "we agreed".
    var decidedBy: String?
    /// The options considered and not chosen.
    var alternatives: [String] = []
    /// The words it was decided in, and where ("mm:ss").
    var quote: String?
    var at: String?
    var sourceTitle: String
    var sourceEntryID: UUID?
    /// When the meeting happened.
    var date = Date()
    /// When the decision said it should be looked at again ("revisit in March").
    var revisitDate: Date?
    /// Taken back later — in the same meeting or by the person afterwards. Kept,
    /// not deleted: that it was decided and then reversed is history too.
    var reversed = false
    var reversedNote: String?

    init(id: UUID = UUID(), text: String, why: String? = nil, decidedBy: String? = nil,
         alternatives: [String] = [], quote: String? = nil, at: String? = nil,
         sourceTitle: String, sourceEntryID: UUID? = nil, date: Date = Date(),
         revisitDate: Date? = nil, reversed: Bool = false, reversedNote: String? = nil) {
        self.id = id
        self.text = text
        self.why = why
        self.decidedBy = decidedBy
        self.alternatives = alternatives
        self.quote = quote
        self.at = at
        self.sourceTitle = sourceTitle
        self.sourceEntryID = sourceEntryID
        self.date = date
        self.revisitDate = revisitDate
        self.reversed = reversed
        self.reversedNote = reversedNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        why = try container.decodeIfPresent(String.self, forKey: .why)
        decidedBy = try container.decodeIfPresent(String.self, forKey: .decidedBy)
        alternatives = try container.decodeIfPresent([String].self, forKey: .alternatives) ?? []
        quote = try container.decodeIfPresent(String.self, forKey: .quote)
        at = try container.decodeIfPresent(String.self, forKey: .at)
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle) ?? ""
        sourceEntryID = try container.decodeIfPresent(UUID.self, forKey: .sourceEntryID)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        revisitDate = try container.decodeIfPresent(Date.self, forKey: .revisitDate)
        reversed = try container.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        reversedNote = try container.decodeIfPresent(String.self, forKey: .reversedNote)
    }

    /// Whether this is due to be looked at again on `day` or before it.
    func needsRevisit(on day: Date, calendar: Calendar = .current) -> Bool {
        guard !reversed, let revisitDate else { return false }
        return calendar.startOfDay(for: revisitDate) <= calendar.startOfDay(for: day)
    }
}

/// The rules for what one extraction may add to the decisions already kept.
enum DecisionRules {
    /// Lower case, letters and digits only, single spaces: two phrasings that
    /// differ in case or punctuation are the same decision.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    /// Whether `candidate` repeats a decision already kept for the same meeting:
    /// the same text once normalised, or the same quote. Re-processing a
    /// meeting must not double its decisions.
    static func isDuplicate(_ candidate: Decision, of kept: [Decision]) -> Bool {
        let text = normalized(candidate.text)
        let quote = candidate.quote.map(normalized)
        return kept.contains { other in
            guard other.sourceEntryID == candidate.sourceEntryID else { return false }
            if normalized(other.text) == text { return true }
            if let quote, !quote.isEmpty, let otherQuote = other.quote.map(normalized) { return otherQuote == quote }
            return false
        }
    }

    /// Whether `text` opens with one of `names` (or its first word) as the
    /// subject — "Marcus will set the buffer", "Ваня выгрузит фикс". A
    /// decision is said about the team or the thing ("the buffer is three");
    /// a sentence about one named person doing something is their task.
    static func startsWithPerson(_ text: String, names: [String]) -> Bool {
        let words = text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
        guard let first = words.first.map({ String($0).lowercased() }) else { return false }
        return names.contains { name in
            let parts = name.split(separator: " ").map { String($0).lowercased() }
            guard let head = parts.first, !head.isEmpty else { return false }
            return first == head
        }
    }

    /// Decisions in `decisions` that `query` finds by their words (text, reason,
    /// who decided, alternatives, quote), best first; all of them, newest first,
    /// for an empty query.
    static func search(_ query: String, in decisions: [Decision], limit: Int) -> [Decision] {
        let ordered = decisions.sorted { $0.date > $1.date }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(ordered.prefix(limit)) }
        let documents = ordered.map { decision in
            WordSearch.Document(
                title: decision.text,
                text: ([decision.why, decision.decidedBy, decision.quote].compactMap { $0 } + decision.alternatives)
                    .joined(separator: "\n"))
        }
        return WordSearch.rank(query, in: documents, limit: limit).map { ordered[$0.index] }
    }
}
