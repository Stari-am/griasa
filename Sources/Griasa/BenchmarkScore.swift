import Foundation

/// Scores the promises found in a benchmark meeting against the promises a
/// person marked by hand (`benchmark/meetings/<id>/gold.json`).
///
/// One prediction is one gold promise at most, and the other way round: the
/// matching is greedy and one-to-one, quotes first. A prediction matches a gold
/// promise when the two quotes are the same words (`QuoteMatch`, either way
/// round, or a run of five words in common), otherwise when the owners are the
/// same person and the tasks share enough words (Jaccard ≥ 0.3 over word
/// stems, `taskWords`), the most similar pairs first. Everything the scorer needs is in the files, so the same
/// numbers come out on any Mac. Foundation only, for `test.sh`.
enum BenchmarkScore {
    /// `meta.json`.
    struct Meta: Codable, Equatable {
        var title: String
        var language: String
        var myName: String
        var participants: [String]
        /// Other spellings of a name ("Иван": ["Ваня", "Ivan"]), when the
        /// meeting uses more than one. Optional.
        var aliases: [String: [String]]?
    }

    /// One promise in `gold.json`.
    struct Gold: Codable, Equatable {
        var owner: String
        var isMine: Bool
        var task: String
        var due: String?
        /// Exact words of the transcript the promise is made in.
        var quote: String
    }

    /// A line that looks like a promise and is not one: declined, cancelled
    /// later, someone else's, or talk. A prediction that lands on one is
    /// counted, so a model that keeps cancelled promises shows it.
    struct Trap: Codable, Equatable {
        var quote: String
        var note: String
    }

    /// `gold.json`.
    struct GoldFile: Codable, Equatable {
        var promises: [Gold]
        var traps: [Trap]
    }

    /// One promise the app found.
    struct Prediction: Equatable {
        var owner: String
        var isMine: Bool
        var task: String
        var quote: String?
    }

    struct Result: Equatable {
        var gold: Int
        var predicted: Int
        var matched: Int
        /// Matched pairs where "mine" and "theirs" agree with the gold.
        var mineCorrect: Int
        /// Matched pairs where the owner is the same person (`sameOwner`).
        var ownerCorrect: Int
        /// Unmatched predictions that quote a trap.
        var trapsHit: Int
        /// (gold index, prediction index) of every match.
        var pairs: [Pair]

        struct Pair: Equatable { var gold: Int; var prediction: Int; var byQuote: Bool }

        var recall: Double? { gold == 0 ? nil : Double(matched) / Double(gold) }
        var precision: Double? { predicted == 0 ? nil : Double(matched) / Double(predicted) }
        var mineAccuracy: Double? { matched == 0 ? nil : Double(mineCorrect) / Double(matched) }
        var ownerAccuracy: Double? { matched == 0 ? nil : Double(ownerCorrect) / Double(matched) }

        /// Several meetings as one: counts add, so a long meeting weighs more.
        static func total(_ results: [Result]) -> Result {
            Result(gold: results.reduce(0) { $0 + $1.gold }, predicted: results.reduce(0) { $0 + $1.predicted },
                   matched: results.reduce(0) { $0 + $1.matched }, mineCorrect: results.reduce(0) { $0 + $1.mineCorrect },
                   ownerCorrect: results.reduce(0) { $0 + $1.ownerCorrect },
                   trapsHit: results.reduce(0) { $0 + $1.trapsHit }, pairs: [])
        }
    }

    static let minJaccard = 0.3
    static let sharedRun = 5

    static func score(gold: [Gold], predicted: [Prediction], traps: [Trap] = [], meta: Meta? = nil) -> Result {
        var usedGold = Set<Int>(), usedPrediction = Set<Int>()
        var pairs: [Result.Pair] = []

        // Quotes first: the same words are the strongest evidence there is. A
        // long quote can hold two gold promises (one line, two tasks), so among
        // the pairs whose quotes match, the same owner and the closer task win.
        var quoted: [(g: Int, p: Int, owner: Int, similarity: Double)] = []
        for (g, item) in gold.enumerated() {
            for p in predicted.indices where predicted[p].quote.map({ sameQuote($0, item.quote) }) == true {
                quoted.append((g, p, sameOwner(predicted[p].owner, item.owner, meta: meta) ? 1 : 0,
                               jaccard(predicted[p].task, item.task)))
            }
        }
        quoted.sort { ($0.owner, $0.similarity, -$0.g, -$0.p) > ($1.owner, $1.similarity, -$1.g, -$1.p) }
        for c in quoted where !usedGold.contains(c.g) && !usedPrediction.contains(c.p) {
            usedGold.insert(c.g); usedPrediction.insert(c.p)
            pairs.append(.init(gold: c.g, prediction: c.p, byQuote: true))
        }
        // Then the same owner and a similar task: every such pair, the most
        // similar first, so one gold promise cannot take the prediction that
        // another one fits better.
        var candidates: [(g: Int, p: Int, similarity: Double)] = []
        for (g, item) in gold.enumerated() where !usedGold.contains(g) {
            for p in predicted.indices where !usedPrediction.contains(p)
                && sameOwner(predicted[p].owner, item.owner, meta: meta) {
                let similarity = jaccard(predicted[p].task, item.task)
                if similarity >= minJaccard { candidates.append((g, p, similarity)) }
            }
        }
        candidates.sort { ($0.similarity, -$0.g, -$0.p) > ($1.similarity, -$1.g, -$1.p) }
        for c in candidates where !usedGold.contains(c.g) && !usedPrediction.contains(c.p) {
            usedGold.insert(c.g); usedPrediction.insert(c.p)
            pairs.append(.init(gold: c.g, prediction: c.p, byQuote: false))
        }
        pairs.sort { $0.gold < $1.gold }

        let mineCorrect = pairs.filter { predicted[$0.prediction].isMine == gold[$0.gold].isMine }.count
        let ownerCorrect = pairs.filter { sameOwner(predicted[$0.prediction].owner, gold[$0.gold].owner, meta: meta) }.count
        let trapsHit = predicted.indices.filter { p in
            !usedPrediction.contains(p) && traps.contains { trap in
                predicted[p].quote.map { sameQuote($0, trap.quote) } == true
            }
        }.count
        return Result(gold: gold.count, predicted: predicted.count, matched: pairs.count,
                      mineCorrect: mineCorrect, ownerCorrect: ownerCorrect, trapsHit: trapsHit, pairs: pairs)
    }

    /// The same words: one quote found in the other, or five words in a row in common.
    static func sameQuote(_ a: String, _ b: String) -> Bool {
        if QuoteMatch.contains(QuoteMatch.prepare(a), quote: b) || QuoteMatch.contains(QuoteMatch.prepare(b), quote: a) {
            return true
        }
        let x = QuoteMatch.prepare(a).split(separator: " "), y = QuoteMatch.prepare(b).split(separator: " ")
        guard x.count >= sharedRun, y.count >= sharedRun else { return false }
        let runs = Set((0...(x.count - sharedRun)).map { x[$0..<($0 + sharedRun)].joined(separator: " ") })
        return (0...(y.count - sharedRun)).contains { runs.contains(y[$0..<($0 + sharedRun)].joined(separator: " ")) }
    }

    /// The same person: both the user, or the same name in any script, after
    /// the meeting's aliases are applied.
    static func sameOwner(_ a: String, _ b: String, meta: Meta?) -> Bool {
        let myName = meta?.myName ?? ""
        let x = canonical(PromiseOwner.normalizeOwner(a), meta: meta)
        let y = canonical(PromiseOwner.normalizeOwner(b), meta: meta)
        // fold() reads "y" as "i", so "You" is checked before it.
        func me(_ s: String) -> Bool {
            ["you", "me", "я"].contains(s.lowercased()) || PromiseOwner.isMe(s, myName: myName)
        }
        if me(x) || me(y) { return me(x) && me(y) }
        return PromiseOwner.sameName(x, y)
    }

    private static func canonical(_ name: String, meta: Meta?) -> String {
        guard let meta else { return name }
        for main in [meta.myName] + meta.participants {
            let spellings = [main] + (meta.aliases?[main] ?? [])
            if spellings.contains(where: { PromiseOwner.sameName($0, name) }) { return main }
        }
        return name
    }

    /// Word overlap of two tasks, over `taskWords`.
    static func jaccard(_ a: String, _ b: String) -> Double {
        let x = taskWords(a), y = taskWords(b)
        let union = x.union(y).count
        return union == 0 ? 0 : Double(x.intersection(y).count) / Double(union)
    }

    /// The words of a task that say what it is, in a form that survives
    /// Russian and Ukrainian endings: lower case, "ё" as "е", no punctuation or
    /// quotes (`QuoteMatch.normalize`), no words shorter than three letters or
    /// on `stopWords`, and each word cut to its first `stemLength` letters —
    /// "мобильном" and "мобильное" are both "мобил", "технических" and
    /// "Технические" both "техни". Crude, and meant to be: it is the same on
    /// every Mac and needs no dictionary.
    static func taskWords(_ text: String) -> Set<String> {
        Set(QuoteMatch.normalize(text).split(separator: " ")
            .filter { $0.count >= 3 && !stopWords.contains(String($0)) }
            .map { String($0.prefix(stemLength)) })
    }

    static let stemLength = 5

    /// Words of three letters or more that say nothing about the task.
    static let stopWords: Set<String> = [
        // ru
        "для", "что", "это", "эти", "как", "при", "под", "над", "все", "всех", "всем", "его", "она", "они",
        "или", "так", "уже", "тоже", "также", "еще", "чтобы", "после", "перед", "через", "без", "про",
        "них", "нам", "вам", "мне", "себя", "свой", "свои", "этот", "этой", "этом",
        // uk (words spelled as in ru are listed once, above)
        "які", "який", "яка", "або", "після", "щоб", "від", "всіх", "цей", "цього", "також",
        // en
        "the", "and", "for", "with", "from", "into", "onto", "that", "this", "these", "those", "their", "them",
        "they", "its", "our", "your", "his", "her", "all", "any", "about", "after", "before", "will", "then",
        "than", "also", "out", "off", "via", "per",
    ]
}
