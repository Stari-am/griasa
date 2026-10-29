import Foundation

/// Finds documents by the words of a query, in any order, and ranks them.
///
/// The query was once matched as one substring, so "auth migration" missed a
/// meeting that said "migration of auth", and "миграция авторизации" missed one
/// that said "миграцию авторизации". Here each word is looked for on its own, at
/// the start of a word in the text, after a light stem: common Russian,
/// Ukrainian and English endings are cut from the query word (never the text),
/// so the stem is a prefix of every inflected form. Case, ё/е and other
/// diacritics are folded on both sides.
///
/// Foundation only, so the rule is checked without the app.
enum WordSearch {
    struct Document {
        var title: String
        var text: String
    }

    struct Hit: Equatable {
        /// Position in the documents passed in.
        var index: Int
        /// How many distinct query words were found.
        var matchedTerms: Int
        var score: Int
        /// The text around the first match, or "" when only the title matched.
        var snippet: String
    }

    /// Words so common they say nothing about a meeting. Dropped from the query
    /// unless nothing else is left.
    static let stopWords: Set<String> = [
        "и", "в", "во", "на", "с", "со", "по", "о", "об", "к", "у", "за", "из", "от", "до",
        "не", "что", "как", "это", "а", "но", "или", "про", "для", "мы", "я", "он", "она",
        "та", "те", "то", "і", "що", "як", "це", "з", "із", "ми",
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "about",
        "is", "are", "was", "we", "i", "it", "at", "by", "from",
    ]

    /// Inflectional endings, longest first. Cut only when at least four letters remain.
    static let endings: [String] = [
        "иями", "ями", "ами", "иях", "ого", "его", "ому", "ему", "ыми", "ими", "ией",
        "ing", "ах", "ях", "ов", "ев", "ей", "ом", "ем", "ой", "ий", "ый", "ая", "яя",
        "ое", "ее", "ые", "ие", "ую", "юю", "ам", "ям", "ии", "ия", "ию", "ою", "ею",
        "ів", "ed", "es",
        "а", "я", "о", "е", "ы", "и", "у", "ю", "ь", "і", "s",
    ].map(fold).sorted { $0.count > $1.count }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Meeting texts are long and do not change between queries; folding them
    /// was most of the cost of a search. Kept per text, for the life of the app.
    private static let foldCache = NSCache<NSString, NSString>()

    private static func foldedText(_ text: String) -> NSString {
        let key = text as NSString
        if let hit = foldCache.object(forKey: key) { return hit }
        let folded = fold(text) as NSString
        foldCache.setObject(folded, forKey: key, cost: folded.length)
        return folded
    }

    static func stem(_ word: String) -> String {
        let word = fold(word)
        for ending in endings where word.hasSuffix(ending) && word.count - ending.count >= 4 {
            return String(word.dropLast(ending.count))
        }
        return word
    }

    /// The query's searchable words: folded, stemmed, without repeats.
    static func terms(_ query: String) -> [String] {
        let words = fold(query)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
        let meaningful = words.filter { !stopWords.contains($0) }
        var seen = Set<String>()
        return (meaningful.isEmpty ? words : meaningful)
            .map(stem)
            .filter { seen.insert($0).inserted }
    }

    /// Documents that contain every query word come first; if none does, those
    /// that contain any. Within a group: more words found, then a higher score
    /// (a title match counts three, each text match one, up to three per word),
    /// then the order passed in, which callers keep newest first.
    static func rank(_ query: String, in documents: [Document], limit: Int) -> [Hit] {
        let terms = terms(query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        var hits: [Hit] = []
        for (index, document) in documents.enumerated() {
            let title = fold(document.title) as NSString
            let text = foldedText(document.text)
            var matched = 0, score = 0
            var first: NSRange?
            for term in terms {
                let inTitle = !wordStarts(of: term, in: title, upTo: 1).isEmpty
                let inText = wordStarts(of: term, in: text, upTo: 3)
                guard inTitle || !inText.isEmpty else { continue }
                matched += 1
                score += (inTitle ? 3 : 0) + inText.count
                if let found = inText.first, first == nil || found.location < first!.location {
                    first = found
                }
            }
            guard matched > 0 else { continue }
            let snippet = first.map { snippetAround($0, folded: text, original: document.text) } ?? ""
            hits.append(Hit(index: index, matchedTerms: matched, score: score, snippet: snippet))
        }
        let complete = hits.filter { $0.matchedTerms == terms.count }
        let pool = complete.isEmpty ? hits : complete
        return Array(pool.sorted {
            ($0.matchedTerms, $0.score, -$0.index) > ($1.matchedTerms, $1.score, -$1.index)
        }.prefix(limit))
    }

    /// Where `term` begins a word in `text`, at most `cap` places. Both sides are
    /// already folded, so a literal comparison is enough, and it is many times
    /// faster than a Unicode-aware one over a long transcript.
    private static func wordStarts(of term: String, in text: NSString, upTo cap: Int) -> [NSRange] {
        var found: [NSRange] = []
        var from = 0
        while found.count < cap, from < text.length {
            let range = text.range(of: term, options: .literal, range: NSRange(location: from, length: text.length - from))
            guard range.location != NSNotFound else { break }
            if range.location == 0
                || !(Unicode.Scalar(text.character(at: range.location - 1)).map(CharacterSet.alphanumerics.contains) ?? false) {
                found.append(range)
            }
            from = range.location + range.length
        }
        return found
    }

    /// About 160 characters around the match, cut at spaces, from the original
    /// text when folding kept its length, else from the folded one.
    private static func snippetAround(_ match: NSRange, folded: NSString, original: String) -> String {
        let originalText = original as NSString
        let source = originalText.length == folded.length ? originalText : folded
        let center = match.location
        var start = max(0, center - 60), end = min(source.length, center + 100)
        if start > 0 {
            let space = source.rangeOfCharacter(from: .whitespacesAndNewlines, options: [],
                                                range: NSRange(location: start, length: center - start))
            if space.location != NSNotFound { start = space.location + 1 }
        }
        if end < source.length {
            let space = source.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards,
                                                range: NSRange(location: center, length: end - center))
            if space.location != NSNotFound { end = space.location }
        }
        // Never split a letter made of two UTF-16 units.
        let whole = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let body = source.substring(with: whole)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (whole.location > 0 ? "…" : "") + body + (whole.location + whole.length < source.length ? "…" : "")
    }
}
