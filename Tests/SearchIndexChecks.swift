import Foundation

// Checks for the stored side of search: vectors packed to a byte a dimension,
// meetings ranked by their closest piece, and the SQLite file that keeps them.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runSearchIndexChecks() -> Int {
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

// Packing.
do {
    var seed: UInt64 = 42
    func random() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: seed >> 11) % 2000 - 1000) / 1000
    }
    let a = HybridRank.normalized((0..<1024).map { _ in random() })
    let b = HybridRank.normalized((0..<1024).map { _ in random() })
    let exact = HybridRank.dot(a, b)
    let packed = SearchVectors.dot(a, SearchVectors.pack(b))
    check(abs(exact - packed) < 0.01,
          rule: "a packed vector gives the same cosine to the second decimal",
          meaning: "a byte per dimension must not change which piece ranks first",
          saw: "\(exact) vs \(packed)")
    let roundTrip = SearchVectors.decode(SearchVectors.encode(SearchVectors.pack(b)))
    check(roundTrip == SearchVectors.pack(b) && SearchVectors.encode(SearchVectors.pack(b)).count == 1028,
          rule: "a packed vector is 4 bytes of scale plus a byte a dimension, and reads back the same",
          meaning: "the index stores it and ranks with what it reads", saw: "\(String(describing: roundTrip?.scale))")
    check(SearchVectors.pack([0, 0]).values == [0, 0] && SearchVectors.decode(Data([1, 2])) == nil,
          rule: "a zero vector packs to zeros and a short blob is refused",
          meaning: "a broken row must not crash the ranking", saw: "")
}

// Ranking meetings by their closest piece.
do {
    let one = UUID(), two = UUID(), three = UUID()
    let pieces = [
        SearchVectors.Piece(entry: one, text: "far", vector: SearchVectors.pack([0, 1])),
        SearchVectors.Piece(entry: two, text: "near", vector: SearchVectors.pack([0.9, 0.1])),
        SearchVectors.Piece(entry: one, text: "nearest", vector: SearchVectors.pack([1, 0])),
        SearchVectors.Piece(entry: three, text: "filtered out", vector: SearchVectors.pack([1, 0])),
    ]
    let ranked = SearchVectors.rankMeetings([1, 0], pieces: pieces, among: [one, two], limit: 10)
    check(ranked.map(\.entry) == [one, two] && ranked.first?.piece == "nearest",
          rule: "a meeting ranks by its closest piece, and that piece is returned",
          meaning: "one relevant minute in an hour-long meeting must be enough to find it",
          saw: "\(ranked.map(\.piece))")
    check(!ranked.contains { $0.entry == three },
          rule: "meetings outside the filter are never returned",
          meaning: "a person or project filter must still hold with the model on", saw: "\(ranked.count)")
    check(SearchVectors.rankMeetings([1, 0], pieces: pieces, among: [one, two], limit: 1).count == 1,
          rule: "the limit is honoured", meaning: "an assistant asked for one meeting", saw: "")
    let long = String(repeating: "слово ", count: 100)
    let excerpt = SearchVectors.excerpt(long)
    check(excerpt.count <= 201 && excerpt.hasSuffix("…") && SearchVectors.excerpt("short\nline") == "short line",
          rule: "an excerpt is about 200 characters on one line",
          meaning: "it is shown as why a meeting matched", saw: excerpt)
}

// The SQLite file.
do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("griasa-search-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let index = try SearchIndex(url: url)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
        check(permissions == 0o600, rule: "the index file is readable only by its owner",
              meaning: "it holds copies of meeting text", saw: String(permissions, radix: 8))
        let meeting = UUID(), other = UUID()
        try index.replace(entry: meeting, hash: "h1", model: "m",
                          pieces: [("first", SearchVectors.pack([1, 0])), ("second", SearchVectors.pack([0, 1]))])
        try index.replace(entry: other, hash: "h2", model: "m", pieces: [("other", SearchVectors.pack([1, 1]))])
        try index.replace(entry: meeting, hash: "h3", model: "m", pieces: [("rewritten", SearchVectors.pack([1, 0]))])
        let pieces = try index.pieces()
        check(pieces.filter { $0.entry == meeting }.map(\.text) == ["rewritten"],
              rule: "re-indexing a meeting replaces all its pieces",
              meaning: "an edited meeting must not keep pieces of its old text", saw: "\(pieces.map(\.text))")
        check(try index.indexed()[meeting]?.hash == "h3",
              rule: "the hash of the text indexed is kept", meaning: "it decides whether a meeting is stale",
              saw: "\(String(describing: try index.indexed()[meeting]))")
        try index.remove([meeting])
        check(try index.pieces().map(\.entry) == [other] && (try index.indexed()[meeting]) == nil,
              rule: "removing a meeting removes its pieces and its record",
              meaning: "a deleted meeting must not be found", saw: "\(try index.pieces().map(\.text))")
        try index.removeAll()
        check(try index.pieces().isEmpty && (try index.indexed()).isEmpty,
              rule: "removing everything empties the index",
              meaning: "turning search off or removing the model leaves no copies", saw: "")
    } catch {
        check(false, rule: "the index opens and writes", meaning: "search depends on it", saw: "\(error)")
    }
}

return failures
}
