import Foundation

/// Merges what the embedding model found with what word search found, and
/// scores a ranking against the pieces that answer the query.
///
/// Reciprocal rank fusion: each list gives an item 1 / (k + rank), and the sums
/// decide. It needs no score calibration between a cosine and a word count,
/// which is why it is the usual choice. One rule on top, from the search
/// benchmark: only word hits that contain every query word take part. When a
/// query is in another language than the meeting, word search falls back to
/// pieces with any one word, and fusing those pushed the right piece out of the
/// top five on six of eight cross-language queries.
///
/// Foundation only, so the rule is checked without the app.
enum HybridRank {
    static let k = 60.0

    /// Item ids, best first. `vector` and `allWords` are each best first.
    static func fuse(vector: [Int], allWords: [Int]) -> [Int] {
        var score: [Int: Double] = [:]
        var firstSeen: [Int: Int] = [:]
        for list in [vector, allWords] {
            for (rank, item) in list.enumerated() {
                score[item, default: 0] += 1 / (k + Double(rank) + 1)
                if firstSeen[item] == nil { firstSeen[item] = firstSeen.count }
            }
        }
        return score.keys.sorted {
            score[$0]! != score[$1]! ? score[$0]! > score[$1]! : firstSeen[$0]! < firstSeen[$1]!
        }
    }

    /// Whether any of the first `k` items answers the query.
    static func found(_ ranking: [Int], gold: Set<Int>, within k: Int) -> Bool {
        ranking.prefix(k).contains(where: gold.contains)
    }

    /// 1 / the position of the first answering item within the first ten, else 0.
    static func reciprocalRank(_ ranking: [Int], gold: Set<Int>) -> Double {
        guard let position = ranking.prefix(10).firstIndex(where: gold.contains) else { return 0 }
        return 1 / Double(position + 1)
    }

    /// Cosine of two vectors already scaled to length one.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? v.map { $0 / length } : v
    }
}
