import Foundation

/// `Griasa --decision-benchmark <dir> [--cloud <provider>] [--only a,b]` — a
/// dev-only probe that runs decision extraction on the public, invented
/// meetings in `benchmark/meetings/` and scores it against the `decisions` each
/// meeting's `gold.json` lists (`BenchmarkScore.scoreDecisions`).
///
/// Reads nothing but `<dir>`. Runs Griasa's own local engine, and the cloud
/// provider `--cloud` names when it is given. Writes, under
/// `dist/decision-benchmark-<date>/`, each meeting's predictions and `RESULTS.md`
/// — the table it also prints.
@MainActor
enum DecisionBenchmarkRun {
    static func run(directory: String, cloudRaw: String?, only: Set<String>?) async -> Never {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let (local, cloud) = LongMeetingEval.configs(cloudRaw: cloudRaw, currentIfCloud: false)
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let out = URL(fileURLWithPath: "dist/decision-benchmark-\(day)", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var configs: [(name: String, config: LLMConfig)] = [("local", local)]
        if let cloud { configs.append(("cloud", cloud)) }
        var rows: [String] = []
        var totals: [String: [BenchmarkScore.DecisionResult]] = [:]
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
            .filter { only == nil || only!.contains($0) }
        for id in folders {
            let folder = root.appendingPathComponent(id)
            guard let raw = try? String(contentsOf: folder.appendingPathComponent("transcript-raw.txt"), encoding: .utf8),
                  let meta = (try? Data(contentsOf: folder.appendingPathComponent("meta.json")))
                    .flatMap({ try? JSONDecoder().decode(BenchmarkScore.Meta.self, from: $0) }),
                  let gold = (try? Data(contentsOf: folder.appendingPathComponent("gold.json")))
                    .flatMap({ try? JSONDecoder().decode(BenchmarkScore.GoldFile.self, from: $0) })?.decisions
            else { continue }
            for (name, config) in configs {
                let started = Date()
                var cells = "| \(id) | \(name) | "
                do {
                    let found = try await DecisionExtractor.findDecisions(
                        markdown: raw, rawTranscript: raw, participants: meta.participants, myName: meta.myName,
                        sourceTitle: meta.title, sourceEntryID: nil, config: config)
                    let predicted = found.decisions.map {
                        BenchmarkScore.DecisionPrediction(text: $0.text, quote: $0.quote, reversed: $0.reversed)
                    }
                    let result = BenchmarkScore.scoreDecisions(gold: gold, predicted: predicted)
                    totals[name, default: []].append(result)
                    let saved = found.decisions.map { ["text": $0.text, "quote": $0.quote ?? "", "reversed": $0.reversed,
                                                       "why": $0.why ?? "", "by": $0.decidedBy ?? ""] as [String: Any] }
                    if let data = try? JSONSerialization.data(withJSONObject: saved, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: out.appendingPathComponent("\(id)-\(name).json"))
                    }
                    cells += "\(result.gold) | \(result.predicted) | \(result.matched) | \(percent(result.recall)) | "
                        + "\(percent(result.precision)) | \(result.reversedFound)/\(result.goldReversed) | "
                        + "\(found.unquoted)/\(found.tasks)/\(found.unreadable) | " + String(format: "%.0f s |", Date().timeIntervalSince(started))
                } catch {
                    cells += "failed: \(error.localizedDescription) | | | | | | | |"
                }
                rows.append(cells)
                print(cells)
            }
        }
        var report = """
            # Decision benchmark

            Decisions found in the six invented meetings, against the decisions marked by hand in each \
            `gold.json`. A prediction matches a gold decision by its quote, or failing that by the words \
            of its text. Unquoted: decisions the model gave without words found in the transcript; tasks: items \
            that were someone's task, not a decision; unreadable: replies that were not a list. All \
            three are dropped before scoring.

            | Meeting | Model | Gold | Found | Matched | Recall | Precision | Reversed found | Unquoted/tasks/unreadable | Time |
            |---|---|---:|---:|---:|---:|---:|---:|---:|---:|

            """
        report += rows.joined(separator: "\n") + "\n\n"
        for (name, results) in totals.sorted(by: { $0.key < $1.key }) {
            let total = BenchmarkScore.DecisionResult.total(results)
            report += "**\(name)**: recall \(percent(total.recall)), precision \(percent(total.precision)), "
                + "reversed found \(total.reversedFound) of \(total.goldReversed).\n\n"
        }
        print(report)
        try? report.write(to: out.appendingPathComponent("RESULTS.md"), atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "–"
    }
}
