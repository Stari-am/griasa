import Foundation

/// `Griasa --search-benchmark <dir> [--embed-url <url>] [--query-prefix <p>] [--passage-prefix <p>]`
/// — a dev-only probe that measures meeting search on the public, invented
/// meetings in `benchmark/meetings/` with the queries in `benchmark/search/queries.json`.
///
/// Each meeting is cut with `SearchChunks`; a query's answer is the piece that
/// holds its anchor phrase. It ranks the pieces three ways — the old
/// one-phrase match, `WordSearch`, and, when `--embed-url` names an
/// OpenAI-style `/v1/embeddings` endpoint (such as `llama-server --embedding`),
/// the model alone and fused with word search (`HybridRank`) — and reports
/// recall@5 and MRR, overall and per kind of query. Reads nothing but the
/// benchmark folders; writes `dist/search-benchmark-<date>/RESULTS.md`.
enum SearchBenchmarkRun {
    struct Query: Decodable {
        var id: String
        var kind: String
        var query: String
        var meeting: String
        var anchor: String
    }

    static func run(meetings directory: String, queries path: String, embedURL: String?,
                    queryPrefix: String, passagePrefix: String) async {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        var pieces: [(meeting: String, text: String)] = []
        for folder in folders {
            let file = root.appendingPathComponent(folder).appendingPathComponent("transcript-raw.txt")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            pieces += SearchChunks.split(text).map { (folder, $0) }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let queries = try? JSONDecoder().decode([Query].self, from: data), !pieces.isEmpty else {
            fail("no meetings in \(directory) or no queries in \(path)")
        }
        var gold: [String: Set<Int>] = [:]
        for query in queries {
            gold[query.id] = Set(pieces.indices.filter {
                pieces[$0].meeting == query.meeting && pieces[$0].text.contains(query.anchor)
            })
            if gold[query.id]!.isEmpty { fail("\(query.id): anchor not found in \(query.meeting)") }
        }

        let documents = pieces.map { WordSearch.Document(title: "", text: $0.text) }
        var runs: [(name: String, rankings: [String: [Int]])] = []
        var old: [String: [Int]] = [:], words: [String: [Int]] = [:], allWords: [String: [Int]] = [:]
        for query in queries {
            old[query.id] = documents.indices.filter { documents[$0].text.localizedCaseInsensitiveContains(query.query) }
            let hits = WordSearch.rank(query.query, in: documents, limit: 50)
            let wanted = WordSearch.terms(query.query).count
            words[query.id] = hits.map(\.index)
            allWords[query.id] = hits.filter { $0.matchedTerms == wanted }.map(\.index)
        }
        runs.append(("one phrase (before)", old))
        runs.append(("word search", words))

        var timing = ""
        if let embedURL {
            do {
                let started = Date()
                let pieceVectors = try await embed(pieces.map { passagePrefix + $0.text }, at: embedURL)
                let indexing = Date().timeIntervalSince(started)
                let asked = Date()
                let queryVectors = try await embed(queries.map { queryPrefix + $0.query }, at: embedURL)
                let perQuery = Date().timeIntervalSince(asked) / Double(queries.count)
                var vector: [String: [Int]] = [:], hybrid: [String: [Int]] = [:]
                for (query, q) in zip(queries, queryVectors) {
                    let similarity = pieceVectors.map { HybridRank.dot(q, $0) }
                    let ranked = Array(similarity.indices.sorted { similarity[$0] > similarity[$1] }.prefix(50))
                    vector[query.id] = ranked
                    hybrid[query.id] = HybridRank.fuse(vector: ranked, allWords: allWords[query.id] ?? [])
                }
                runs.append(("model", vector))
                runs.append(("model + word search", hybrid))
                timing = String(format: "Model: %.0f ms per piece to index, %.0f ms per query.\n",
                                indexing * 1000 / Double(pieces.count), perQuery * 1000)
            } catch {
                fail("embeddings from \(embedURL): \(error.localizedDescription)")
            }
        }

        let kinds = Array(Set(queries.map(\.kind))).sorted()
        func recall(_ rankings: [String: [Int]], _ subset: [Query]) -> Double {
            Double(subset.filter { HybridRank.found(rankings[$0.id] ?? [], gold: gold[$0.id]!, within: 5) }.count)
                / Double(max(subset.count, 1))
        }
        func mrr(_ rankings: [String: [Int]]) -> Double {
            queries.map { HybridRank.reciprocalRank(rankings[$0.id] ?? [], gold: gold[$0.id]!) }.reduce(0, +)
                / Double(queries.count)
        }
        var table = "| Search | R@5 | MRR | " + kinds.joined(separator: " | ") + " |\n"
        table += "|---|---:|---:|" + String(repeating: "---:|", count: kinds.count) + "\n"
        for run in runs {
            let perKind = kinds.map { kind in String(format: "%.2f", recall(run.rankings, queries.filter { $0.kind == kind })) }
            table += "| \(run.name) | " + String(format: "%.2f | %.2f", recall(run.rankings, queries), mrr(run.rankings))
                + " | " + perKind.joined(separator: " | ") + " |\n"
        }
        let report = """
            # Search benchmark

            \(queries.count) queries over \(pieces.count) pieces of \(folders.count) meetings. \
            R@5: the piece holding the answer is among the first five. MRR: 1 / its position \
            in the first ten. Per-kind columns are R@5.

            \(table)
            \(timing)
            """
        print(report)
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let out = URL(fileURLWithPath: "dist/search-benchmark-\(day)", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? report.write(to: out.appendingPathComponent("RESULTS.md"), atomically: true, encoding: .utf8)
        exit(0)
    }

    private struct EmbeddingReply: Decodable {
        struct Item: Decodable { var index: Int; var embedding: [Float] }
        var data: [Item]
    }

    /// Unit-length vectors for `texts`, eight per request.
    private static func embed(_ texts: [String], at base: String) async throws -> [[Float]] {
        guard let url = URL(string: base.hasSuffix("/v1/embeddings") ? base : base + "/v1/embeddings") else {
            throw URLError(.badURL)
        }
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: texts.count, by: 8) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["input": Array(texts[start..<min(start + 8, texts.count)])])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let reply = try JSONDecoder().decode(EmbeddingReply.self, from: data)
            vectors += reply.data.sorted { $0.index < $1.index }.map { HybridRank.normalized($0.embedding) }
        }
        return vectors
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("search-benchmark: \(message)\n".utf8))
        exit(1)
    }
}
