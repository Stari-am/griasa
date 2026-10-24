import Foundation

/// `Griasa --benchmark <dir> [--cloud <provider>] [--only a,b]` — a dev-only
/// probe that runs the three variants of `--long-meeting-eval` on the public,
/// invented meetings in `benchmark/meetings/` and scores the promises each one
/// finds against the meeting's `gold.json` (`BenchmarkScore`).
///
/// It reads nothing but `<dir>`: no history, no roster, no store — every name
/// and the user's own name come from each meeting's `meta.json`. The cloud
/// reference runs only when `--cloud` names a provider; the selected provider is
/// never used on its own. Writes, under `dist/benchmark-<date>/` (relative to
/// the directory it is run from), each meeting's notes, promises, timing and
/// `score.json`, and `RESULTS.md` — the table it also prints.
@MainActor
enum BenchmarkRun {
    private struct Row {
        var id: String
        var meta: BenchmarkScore.Meta
        var chars: Int
        var outcome: LongMeetingEval.Outcome
        var scores: [String: BenchmarkScore.Result]
    }

    static func run(directory: String, cloudRaw: String?, only: Set<String>?) async -> Never {
        let source = URL(fileURLWithPath: directory, isDirectory: true)
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? [])
            .filter { !$0.hasPrefix(".") && (only?.contains($0) ?? true) }
            .sorted()
        guard !ids.isEmpty else {
            print("No meeting folders in \(source.path)\(only.map { " matching --only \($0.sorted().joined(separator: ","))" } ?? "").")
            exit(2)
        }
        let (local, cloud) = LongMeetingEval.configs(cloudRaw: cloudRaw, currentIfCloud: false)
        let day = Date().formatted(.iso8601.year().month().day())
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/benchmark-\(day)", isDirectory: true)

        var rows: [Row] = []
        for id in ids {
            let folder = source.appendingPathComponent(id, isDirectory: true)
            guard let raw = try? String(contentsOf: folder.appendingPathComponent("transcript-raw.txt"), encoding: .utf8),
                  let meta = (try? Data(contentsOf: folder.appendingPathComponent("meta.json")))
                    .flatMap({ try? JSONDecoder().decode(BenchmarkScore.Meta.self, from: $0) }),
                  let gold = (try? Data(contentsOf: folder.appendingPathComponent("gold.json")))
                    .flatMap({ try? JSONDecoder().decode(BenchmarkScore.GoldFile.self, from: $0) })
            else {
                print("\(id): transcript-raw.txt, meta.json or gold.json is missing or unreadable — skipped.")
                continue
            }
            print("\(id) · \(meta.title) · \(raw.count) chars · \(gold.promises.count) gold promises…")
            let out = root.appendingPathComponent(id, isDirectory: true)
            let outcome = await LongMeetingEval.runVariants(raw: raw, participants: meta.participants,
                                                            myName: meta.myName, local: local, cloud: cloud, folder: out)
            var scores: [String: BenchmarkScore.Result] = [:]
            var report: [String: Any] = [:]
            for (name, variant) in variants(outcome, cloud: cloud != nil) {
                guard let found = variant.found else { continue }
                let predicted = found.map {
                    BenchmarkScore.Prediction(owner: $0.owner, isMine: $0.isMine, task: $0.text, quote: $0.sourceQuote)
                }
                let result = BenchmarkScore.score(gold: gold.promises, predicted: predicted, traps: gold.traps, meta: meta)
                scores[name] = result
                report[name] = detail(result, gold: gold.promises, predicted: predicted)
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appendingPathComponent("score.json"))
            }
            rows.append(Row(id: id, meta: meta, chars: raw.count, outcome: outcome, scores: scores))
        }

        let table = results(rows, local: local, cloud: cloud)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? table.write(to: root.appendingPathComponent("RESULTS.md"), atomically: true, encoding: .utf8)
        print("\n" + table)
        print("files: \(root.path)/")
        // No stop(), for the reason in LongMeetingEval: the engine on 8177 may be the app's.
        exit(0)
    }

    private static func variants(_ o: LongMeetingEval.Outcome, cloud: Bool) -> [(String, LongMeetingEval.Variant)] {
        [("single", o.single), ("chunked", o.chunked)] + (cloud ? [("cloud", o.cloud)] : [])
    }

    /// What matched what, and what was missed, for reading a result by hand.
    private static func detail(_ r: BenchmarkScore.Result, gold: [BenchmarkScore.Gold],
                               predicted: [BenchmarkScore.Prediction]) -> [String: Any] {
        let matchedGold = Set(r.pairs.map(\.gold)), matchedPredicted = Set(r.pairs.map(\.prediction))
        return [
            "gold": r.gold, "predicted": r.predicted, "matched": r.matched,
            "mineCorrect": r.mineCorrect, "trapsHit": r.trapsHit,
            "matches": r.pairs.map { ["gold": gold[$0.gold].task, "predicted": predicted[$0.prediction].task,
                                      "byQuote": $0.byQuote,
                                      "mineRight": predicted[$0.prediction].isMine == gold[$0.gold].isMine] },
            "missed": gold.indices.filter { !matchedGold.contains($0) }.map { "\(gold[$0].owner): \(gold[$0].task)" },
            "extra": predicted.indices.filter { !matchedPredicted.contains($0) }
                .map { "\(predicted[$0].owner): \(predicted[$0].task)" },
        ]
    }

    private static func results(_ rows: [Row], local: LLMConfig, cloud: LLMConfig?) -> String {
        func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "–" }
        func seconds(_ v: LongMeetingEval.Variant) -> String {
            guard let notes = v.seconds else { return "–" }
            return String(format: "%.0f+%.0f", notes, v.promisesSeconds ?? 0)
        }
        func cells(_ r: BenchmarkScore.Result?) -> String {
            guard let r else { return "failed | – | – | – | –" }
            return "\(r.matched)/\(r.gold) (\(r.predicted) found) | \(percent(r.recall)) | \(percent(r.precision))"
                + " | \(percent(r.mineAccuracy)) | \(r.trapsHit)"
        }
        let names = ["single", "chunked"] + (cloud == nil ? [] : ["cloud"])
        var lines = [
            "# Griasa promise benchmark — \(Date().formatted(.iso8601.year().month().day()))",
            "",
            "- Mac: \(sysctl("hw.model") ?? "unknown") · \(sysctl("machdep.cpu.brand_string") ?? "unknown CPU")"
                + " · \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB RAM",
            "- Local model: \(local.smartModel) (Griasa's own engine)",
            "- Cloud reference: \(cloud.map { "\($0.provider.rawValue) · \($0.smartModel)" } ?? "none")",
            "- Variants: **single** — today's local single pass, truncated as today; **chunked** — the local path in parts;"
                + " **cloud** — a cloud model reading the whole transcript.",
            "",
            "| Meeting | Language | Chars | Variant | Matched | Recall | Precision | Mine/theirs | Traps hit | Notes+promises s |",
            "|---|---|---:|---|---|---:|---:|---:|---:|---:|",
        ]
        for row in rows {
            let outcome = variants(row.outcome, cloud: true)
            for name in names {
                let variant = outcome.first { $0.0 == name }!.1
                lines.append("| \(row.id) | \(row.meta.language) | \(row.chars) | \(name) | \(cells(row.scores[name])) | \(seconds(variant)) |")
            }
        }
        lines += ["", "**Totals** (counts summed over the meetings, so a long meeting weighs more):", "",
                  "| Variant | Matched | Recall | Precision | Mine/theirs | Traps hit | Notes+promises s |",
                  "|---|---|---:|---:|---:|---:|---:|"]
        for name in names {
            let scored = rows.compactMap { $0.scores[name] }
            let total = BenchmarkScore.Result.total(scored)
            let time = rows.reduce((0.0, 0.0)) { sum, row in
                let v = variants(row.outcome, cloud: true).first { $0.0 == name }!.1
                return (sum.0 + (v.seconds ?? 0), sum.1 + (v.promisesSeconds ?? 0))
            }
            let failed = rows.count - scored.count
            lines.append("| \(name)\(failed > 0 ? " (\(failed) failed)" : "") | \(cells(total))"
                         + " | \(String(format: "%.0f+%.0f", time.0, time.1)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
