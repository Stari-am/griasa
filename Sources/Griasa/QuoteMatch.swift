import Foundation

/// Whether the words a model says it is quoting are really in the text it read.
///
/// A promise with no real source is the costliest thing this app can invent —
/// somebody is then told they owe something nobody asked of them — so a
/// promise with a quote is kept only when the quote is found in the input. The
/// comparison ignores case, punctuation, line breaks, "ё" against "е", and the
/// space inside "1 000"; a model re-wraps and slightly tidies what it copies.
/// It tolerates a copy with a few words dropped (80% of the words, in order,
/// close together) and a quote with "…" in the middle, but never a made-up one.
enum QuoteMatch {
    /// Shorter than this is a word or two that matches anywhere.
    static let minLength = 8
    static let minWords = 4

    /// Lower case, letters and digits only, one space between words.
    /// Apostrophes vanish ("don't" = "dont"); every other mark is a space;
    /// "ё" is "е"; a space between two digits is closed.
    static func normalize(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch == "ё" ? "е" : ch)
            } else if ch == "'" || ch == "\u{2019}" {
                continue
            } else {
                pendingSpace = true
            }
        }
        return out.replacingOccurrences(of: #"(?<=\d) (?=\d)"#, with: "", options: .regularExpression)
    }

    /// The text a quote is looked for in, prepared once per input: speaker and
    /// time markers (`[12:30] You:`, `**Name:**`) are not speech, so a quote that
    /// runs across two lines still matches.
    static func prepare(_ text: String) -> String {
        normalize(stripMarkers(text))
    }

    /// The new lines of a part and the context repeated before it, prepared.
    struct Haystack {
        let combined: String
        let overlap: String
        let body: String
        init(overlap: String = "", body: String) {
            self.overlap = QuoteMatch.prepare(overlap)
            self.body = QuoteMatch.prepare(body)
            combined = QuoteMatch.prepare(overlap.isEmpty ? body : overlap + "\n" + body)
        }
    }

    /// Found in the part, and not only in the context repeated from the part
    /// before — that sentence belongs to the previous part's answer.
    static func contains(_ haystack: Haystack, quote: String) -> Bool {
        guard contains(haystack.combined, quote: quote) else { return false }
        if haystack.overlap.isEmpty { return true }
        return contains(haystack.body, quote: quote) || !contains(haystack.overlap, quote: quote)
    }

    static func contains(_ preparedText: String, quote: String) -> Bool {
        var candidates = [quote]
        // "Maria: I'll send it" — the model copies the speaker label too.
        let stripped = quote.replacingOccurrences(of: #"^\s*[^\s:]{1,30}:\s+"#, with: "",
                                                  options: .regularExpression)
        if stripped != quote { candidates.append(stripped) }
        return candidates.contains { matches(preparedText, quote: $0) }
    }

    private static func matches(_ preparedText: String, quote: String) -> Bool {
        let cleaned = stripMarkers(quote)
        // "…", "..." and "[...]" mark words left out: each fragment must be found, in order.
        let fragments = cleaned
            .replacingOccurrences(of: #"\[\s*(\.\.\.|…)\s*\]|\.\.\.|…"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}")
            .map(normalize)
            .filter { !$0.isEmpty }
        guard !fragments.isEmpty else { return false }
        let whole = fragments.joined(separator: " ")
        guard whole.count >= minLength, whole.split(separator: " ").count >= minWords else { return false }
        if fragments.count == 1 { return fuzzy(preparedText, fragments[0]) }
        guard fragments.allSatisfy({ $0.split(separator: " ").count >= 3 }) else { return false }
        var from = preparedText.startIndex
        for fragment in fragments {
            guard let end = fuzzyEnd(preparedText, fragment, from: from) else { return false }
            from = end
        }
        return true
    }

    private static func fuzzy(_ text: String, _ wanted: String) -> Bool {
        fuzzyEnd(text, wanted, from: text.startIndex) != nil
    }

    /// Where the match ends: an exact hit, or else 80% of the words in order
    /// inside a window of the quote's length plus three.
    private static func fuzzyEnd(_ text: String, _ wanted: String, from: String.Index) -> String.Index? {
        let tail = text[from...]
        if let range = tail.range(of: wanted) { return range.upperBound }
        let q = wanted.split(separator: " ")
        // Words of the tail with where each one ends.
        var words: [(word: Substring, end: String.Index)] = []
        var index = tail.startIndex
        while index < tail.endIndex {
            while index < tail.endIndex, tail[index] == " " { index = tail.index(after: index) }
            let start = index
            while index < tail.endIndex, tail[index] != " " { index = tail.index(after: index) }
            if start < index { words.append((tail[start..<index], index)) }
        }
        let need = Int((Double(q.count) * 0.8).rounded(.up))
        let window = q.count + 3
        let early = Set(q.prefix(3))
        for i in words.indices where early.contains(words[i].word) {
            let upper = min(words.count, i + window)
            var matched = 0, position = i, last = i
            for word in q {
                if let hit = (position..<upper).first(where: { words[$0].word == word }) {
                    matched += 1
                    position = hit + 1
                    last = hit
                }
            }
            if matched >= need { return words[last].end }
        }
        return nil
    }

    /// A time the model gave, kept only if the input shows it; "5:03" is
    /// "[05:03]". Returns it zero-padded as the transcript writes it.
    static func visibleTimestamp(_ claimed: String?, in text: String) -> String? {
        guard let claimed = claimed?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")),
              claimed.range(of: #"^\d{1,3}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil else { return nil }
        var parts = claimed.split(separator: ":").map(String.init)
        if parts[0].count < 2 { parts[0] = "0" + parts[0] }
        let padded = parts.joined(separator: ":")
        return text.contains("[\(padded)]") ? padded : nil
    }

    private static func stripMarkers(_ text: String) -> String {
        var out = text
        for pattern in [#"\[\d{1,3}:\d{2}(:\d{2})?\]\s*(You:|Them:|📝 NOTE:)?"#, #"\*\*[^*\n]{1,40}:\*\*"#] {
            out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return out
    }
}

/// The same promise reported twice: by two parts that share an overlap, or
/// said twice in one meeting.
enum PromiseDuplicate {
    struct Seen { let text: String; let owner: String; let quote: String }

    /// Index of the earlier copy of this promise, if there is one: the same
    /// words for the same owner; the same quoted sentence with similar wording;
    /// the same owner and nearly the same wording; or — the recap at the end of
    /// a meeting ("Даня — план миграции с откатом") — the same work in other
    /// words for the same person, or for a "Them" nobody could name yet.
    static func duplicate(text: String, owner: String, quote: String?, of seen: [Seen]) -> Int? {
        let t = QuoteMatch.normalize(text), o = owner.lowercased()
        let q = quote.map(QuoteMatch.normalize) ?? ""
        let words = Set(t.split(separator: " "))
        let stems = stems(of: t)
        for (index, s) in seen.enumerated() {
            let similarity = jaccard(words, Set(s.text.split(separator: " ")))
            if s.text == t, s.owner == o { return index }
            if !q.isEmpty, s.quote == q, similarity >= 0.5 { return index }
            if s.owner == o, similarity >= 0.8 { return index }
            if sameOwner(s.owner, o), restates(stems, self.stems(of: s.text)) { return index }
        }
        return nil
    }

    /// An owner nobody could name: a "Them" line, or none at all.
    static func isUnnamed(_ owner: String) -> Bool {
        ["", "them"].contains(owner.lowercased())
    }

    /// The same person, or one side not yet named.
    private static func sameOwner(_ a: String, _ b: String) -> Bool {
        isUnnamed(a) || isUnnamed(b) || PromiseOwner.sameName(a, b)
    }

    /// One task wording contains the other: every stem of the shorter one when
    /// it has two or three, three quarters of them when it has more. "Сделать
    /// постмортем" against "Написать постмортем по инциденту до пятницы" is the
    /// same work; "тест-план для bulk edit" against "базовый API для bulk edit" is not.
    static func restates(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let shorter = min(a.count, b.count)
        guard shorter >= 2 else { return false }
        let shared = Double(a.intersection(b).count)
        return shorter <= 3 ? shared == Double(shorter) : shared / Double(shorter) >= 0.75
    }

    /// Content words cut to five letters, so "мобильном" and "мобильное" meet;
    /// task verbs and filler ("сделать", "make", "для") are left out.
    static func stems(of normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ").compactMap { word -> String? in
            let w = String(word)
            guard w.count >= 3, !stopWords.contains(w) else { return nil }
            return String(w.prefix(5))
        })
    }

    private static let stopWords: Set<String> = [
        "сделать", "сделаю", "сделает", "для", "это", "что", "как", "все", "всех", "всем", "при", "после",
        "чтобы", "или", "его", "она", "они", "тоже", "уже", "так", "только", "через", "под", "над", "без",
        "до", "про", "зробити", "зроблю", "щоб", "або", "після",
        "make", "do", "the", "and", "for", "with", "from", "into", "that", "this", "will", "get", "set",
        "up", "out", "all", "after", "before", "about", "our", "their", "them",
    ]

    static func isDuplicate(text: String, owner: String, quote: String?, of seen: [Seen]) -> Bool {
        duplicate(text: text, owner: owner, quote: quote, of: seen) != nil
    }

    private static func jaccard(_ a: Set<Substring>, _ b: Set<Substring>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    static func entry(text: String, owner: String, quote: String?) -> Seen {
        Seen(text: QuoteMatch.normalize(text), owner: owner.lowercased(), quote: quote.map(QuoteMatch.normalize) ?? "")
    }
}
