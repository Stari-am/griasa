import Foundation

// Checks for the pieces search ranks and for merging the model's ranking with
// word search: where meetings are cut, how two rankings become one, and the
// measures the search benchmark reports.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runHybridSearchChecks() -> Int {
var failures = 0

func check(_ passed: Bool, rule: String, meaning: String, saw: String) {
    if passed { return }
    failures += 1
    print("""

    ✗ \(rule)
      why it matters: \(meaning)
      what happened:  \(saw)
    """)
}

// Cutting.
do {
    let lines = (0..<100).map { "[\($0):00] Them: line \($0) with enough words to take some room" }
    let text = lines.joined(separator: "\n")
    let pieces = SearchChunks.split(text)
    check(pieces.count > 1 && pieces.allSatisfy { $0.count <= SearchChunks.target + 80 },
          rule: "a long meeting is cut into pieces of about 800 characters",
          meaning: "a whole meeting embeds into a vector close to nothing in particular",
          saw: "\(pieces.count) pieces, longest \(pieces.map(\.count).max() ?? 0)")
    let everyLineWhole = lines.allSatisfy { line in pieces.contains { $0.split(separator: "\n").contains(Substring(line)) } }
    check(everyLineWhole, rule: "cuts fall between lines and every line is in some piece",
          meaning: "a line split in two matches neither half", saw: "a line is missing or cut")
    let shared = zip(pieces, pieces.dropFirst()).allSatisfy { a, b in
        a.split(separator: "\n").last.map { b.split(separator: "\n").contains($0) } ?? false
    }
    check(shared, rule: "each piece repeats the last line of the one before",
          meaning: "a sentence at a boundary stays whole in at least one piece", saw: "no overlap")
    check(SearchChunks.split("short") == ["short"] && SearchChunks.split("").isEmpty && SearchChunks.split("\n\n").isEmpty,
          rule: "a short text is one piece, an empty one none",
          meaning: "empty pieces would be ranked and shown", saw: "\(SearchChunks.split("")) \(SearchChunks.split("\n\n"))")
    let monologue = (0..<400).map { "word\($0)" }.joined(separator: " ")
    let cut = SearchChunks.split("a\n" + monologue + "\nb")
    let words = Set(cut.flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) })
    check(cut.count > 2 && cut.allSatisfy { $0.count <= SearchChunks.target + 120 }
          && (0..<400).allSatisfy { words.contains("word\($0)") },
          rule: "a line longer than a piece is cut at spaces, and no word is lost or split",
          meaning: "a monologue without line breaks would be one huge piece no model can read whole",
          saw: "\(cut.count) pieces, longest \(cut.map(\.count).max() ?? 0)")
    let solid = String(repeating: "x", count: 2000)
    check(SearchChunks.split(solid).joined().filter { $0 == "x" }.count >= 2000,
          rule: "a stretch with no space is cut at the limit and kept",
          meaning: "a pasted log line must not vanish", saw: "\(SearchChunks.split(solid).map(\.count))")
}

// Fusing.
do {
    check(HybridRank.fuse(vector: [1, 2, 3], allWords: []) == [1, 2, 3],
          rule: "with no word hits the model's order stands",
          meaning: "a query in another language than the meeting has no word hits", saw: "\(HybridRank.fuse(vector: [1, 2, 3], allWords: []))")
    let fused = HybridRank.fuse(vector: [1, 2, 3, 4], allWords: [4])
    check(fused.first == 4 || fused.firstIndex(of: 4)! < 3,
          rule: "a piece both lists found rises above pieces only one found",
          meaning: "an exact name the model ranked fourth should not stay fourth", saw: "\(fused)")
    check(HybridRank.fuse(vector: [], allWords: [7, 8]) == [7, 8],
          rule: "with no model ranking the word order stands",
          meaning: "fusion must not reorder a single list", saw: "\(HybridRank.fuse(vector: [], allWords: [7, 8]))")
    check(HybridRank.fuse(vector: [5, 6], allWords: [6, 5]) == [5, 6],
          rule: "an exact tie keeps the model's order",
          meaning: "the same query must always give the same answer", saw: "\(HybridRank.fuse(vector: [5, 6], allWords: [6, 5]))")
}

// Measures.
do {
    check(HybridRank.found([9, 8, 7, 6, 5, 4], gold: [5], within: 5) && !HybridRank.found([9, 8, 7, 6, 4, 5], gold: [5], within: 5),
          rule: "recall@5 counts the answer only in the first five",
          meaning: "the benchmark's main number", saw: "wrong cut-off")
    check(HybridRank.reciprocalRank([3, 1], gold: [1]) == 0.5 && HybridRank.reciprocalRank(Array(20...40), gold: [1]) == 0,
          rule: "MRR is 1 / the position of the first answer, 0 past ten",
          meaning: "the benchmark's second number", saw: "\(HybridRank.reciprocalRank([3, 1], gold: [1]))")
    let v = HybridRank.normalized([3, 4])
    check(abs(HybridRank.dot(v, v) - 1) < 1e-6 && HybridRank.normalized([0, 0]) == [0, 0],
          rule: "vectors are scaled to length one, and a zero vector stays zero",
          meaning: "a dot product is a cosine only for unit vectors", saw: "\(v)")
}

return failures
}
