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
///
/// `--rescore <results dir>` runs no model: it reads the promises and timing an
/// earlier run saved there, scores them against the current gold, and rewrites
/// that folder's `score.json` files and `RESULTS.md` — for a scorer or gold change.
@MainActor
enum BenchmarkRun {
    private struct Row {
        var id: String
        var meta: BenchmarkScore.Meta
        var chars: Int
        var outcome: LongMeetingEval.Outcome
        var scores: [String: BenchmarkScore.Result]
    }

    private struct Meeting {
        var raw: String
        var meta: BenchmarkScore.Meta
        var gold: BenchmarkScore.GoldFile
    }

    private static func meeting(in folder: URL) -> Meeting? {
        guard let raw = try? String(contentsOf: folder.appendingPathComponent("transcript-raw.txt"), encoding: .utf8),
              let meta = (try? Data(contentsOf: folder.appendingPathComponent("meta.json")))
                .flatMap({ try? JSONDecoder().decode(BenchmarkScore.Meta.self, from: $0) }),
              let gold = (try? Data(contentsOf: folder.appendingPathComponent("gold.json")))
                .flatMap({ try? JSONDecoder().decode(BenchmarkScore.GoldFile.self, from: $0) })
        else { return nil }
        return Meeting(raw: raw, meta: meta, gold: gold)
    }

    /// `--only a,b` takes a whole folder name or its letter ("a" is "a-webhooks-sync-ru").
    private static func folders(in directory: URL, only: Set<String>?) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { id in !id.hasPrefix(".") && (only?.contains { id == $0 || id.hasPrefix($0 + "-") } ?? true) }
            .sorted()
    }

    static func run(directory: String, cloudRaw: String?, only: Set<String>?) async -> Never {
        let source = URL(fileURLWithPath: directory, isDirectory: true)
        let ids = folders(in: source, only: only)
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
            guard let m = meeting(in: source.appendingPathComponent(id, isDirectory: true)) else {
                print("\(id): transcript-raw.txt, meta.json or gold.json is missing or unreadable — skipped.")
                continue
            }
            print("\(id) · \(m.meta.title) · \(m.raw.count) chars · \(m.gold.promises.count) gold promises…")
            let out = root.appendingPathComponent(id, isDirectory: true)
            let outcome = await LongMeetingEval.runVariants(raw: m.raw, participants: m.meta.participants,
                                                            myName: m.meta.myName, local: local, cloud: cloud, folder: out)
            let predictions = variants(outcome, cloud: cloud != nil).compactMap { name, variant in
                variant.found.map { found in
                    (name, found.map { BenchmarkScore.Prediction(owner: $0.owner, isMine: $0.isMine,
                                                                 task: $0.text, quote: $0.sourceQuote) })
                }
            }
            let scores = scoreAndWrite(predictions, meeting: m, to: out)
            rows.append(Row(id: id, meta: m.meta, chars: m.raw.count, outcome: outcome, scores: scores))
        }

        let table = results(rows, cloud: cloud != nil, header: header(local: local, cloud: cloud))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? table.write(to: root.appendingPathComponent("RESULTS.md"), atomically: true, encoding: .utf8)
        print("\n" + table)
        print("files: \(root.path)/")
        // No stop(), for the reason in LongMeetingEval: the engine on 8177 may be the app's.
        exit(0)
    }

    /// `--benchmark <dir> --rescore <results dir> [--only a,b]`: no model, only
    /// the promises a run saved. The run's header (Mac, models) is kept, since
    /// the promises are still that run's.
    static func rescore(directory: String, results resultsPath: String, only: Set<String>?) -> Never {
        let source = URL(fileURLWithPath: directory, isDirectory: true)
        let root = URL(fileURLWithPath: resultsPath, isDirectory: true)
        let ids = folders(in: root, only: only).filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("timing.json").path)
        }
        guard !ids.isEmpty else {
            print("No saved meeting results (folders with timing.json) in \(root.path).")
            exit(2)
        }
        var rows: [Row] = []
        var anyCloud = false
        for id in ids {
            let out = root.appendingPathComponent(id, isDirectory: true)
            guard let m = meeting(in: source.appendingPathComponent(id, isDirectory: true)),
                  let timing = (try? Data(contentsOf: out.appendingPathComponent("timing.json")))
                    .flatMap({ try? JSONDecoder().decode(SavedTiming.self, from: $0) })
            else {
                print("\(id): the meeting's files or the saved timing.json are missing or unreadable — skipped.")
                continue
            }
            var outcome = LongMeetingEval.Outcome()
            outcome.chunks = timing.chunks ?? 0
            var predictions: [(String, [BenchmarkScore.Prediction])] = []
            for name in ["single", "chunked", "cloud"] {
                let saved = (try? Data(contentsOf: out.appendingPathComponent("promises-\(name).json")))
                    .flatMap { try? JSONDecoder().decode(SavedPromises.self, from: $0) }
                let time = timing.variant(name)
                let variant = LongMeetingEval.Variant(seconds: time?.notesSeconds, promisesSeconds: time?.promisesSeconds,
                                                      found: nil, error: time?.error)
                switch name {
                case "single": outcome.single = variant
                case "chunked": outcome.chunked = variant
                default: outcome.cloud = variant
                }
                if name == "cloud", saved != nil || time?.notesSeconds != nil { anyCloud = true }
                if let saved {
                    predictions.append((name, saved.promises.map {
                        BenchmarkScore.Prediction(owner: $0.owner, isMine: $0.isMine, task: $0.text, quote: $0.sourceQuote)
                    }))
                }
            }
            let scores = scoreAndWrite(predictions, meeting: m, to: out)
            print("\(id): \(m.gold.promises.count) gold · " + predictions.map { name, _ in
                scores[name].map { "\(name) \($0.matched) of \($0.predicted) found" } ?? name
            }.joined(separator: " · "))
            rows.append(Row(id: id, meta: m.meta, chars: m.raw.count, outcome: outcome, scores: scores))
        }

        let previous = ((try? String(contentsOf: root.appendingPathComponent("RESULTS.md"), encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
        let title = previous.first { $0.hasPrefix("# ") } ?? "# Griasa promise benchmark"
        let kept = previous.prefix { !$0.hasPrefix("|") }.filter { $0.hasPrefix("- ") && !$0.hasPrefix("- Rescored") }
        let day = Date().formatted(.iso8601.year().month().day())
        let table = results(rows, cloud: anyCloud, header: [title, ""] + kept
            + ["- Rescored \(day) against the current gold.json and scorer, from the saved promises; no model was run."])
        try? table.write(to: root.appendingPathComponent("RESULTS.md"), atomically: true, encoding: .utf8)
        print("\n" + table)
        print("files: \(root.path)/")
        exit(0)
    }

    /// `promises-<variant>.json` as `LongMeetingEval` saves it.
    private struct SavedPromises: Decodable {
        struct Item: Decodable { var owner: String; var isMine: Bool; var text: String; var sourceQuote: String? }
        var promises: [Item]
    }

    /// `timing.json` as `LongMeetingEval` saves it.
    private struct SavedTiming: Decodable {
        struct Part: Decodable { var notesSeconds: Double?; var promisesSeconds: Double?; var error: String? }
        var chunks: Int?
        var single: Part?, chunked: Part?, cloud: Part?
        func variant(_ name: String) -> Part? {
            switch name {
            case "single": return single
            case "chunked": return chunked
            default: return cloud
            }
        }
    }

    /// Scores each variant's promises and writes the meeting's `score.json`.
    private static func scoreAndWrite(_ predictions: [(String, [BenchmarkScore.Prediction])],
                                      meeting m: Meeting, to out: URL) -> [String: BenchmarkScore.Result] {
        var scores: [String: BenchmarkScore.Result] = [:]
        var report: [String: Any] = [:]
        for (name, predicted) in predictions {
            let result = BenchmarkScore.score(gold: m.gold.promises, predicted: predicted, traps: m.gold.traps, meta: m.meta)
            scores[name] = result
            report[name] = detail(result, gold: m.gold.promises, predicted: predicted)
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("score.json"))
        }
        return scores
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
            "mineCorrect": r.mineCorrect, "ownerCorrect": r.ownerCorrect, "trapsHit": r.trapsHit,
            "matches": r.pairs.map { ["gold": gold[$0.gold].task, "predicted": predicted[$0.prediction].task,
                                      "byQuote": $0.byQuote, "predictedOwner": predicted[$0.prediction].owner,
                                      "mineRight": predicted[$0.prediction].isMine == gold[$0.gold].isMine] },
            "missed": gold.indices.filter { !matchedGold.contains($0) }.map { "\(gold[$0].owner): \(gold[$0].task)" },
            "extra": predicted.indices.filter { !matchedPredicted.contains($0) }
                .map { "\(predicted[$0].owner): \(predicted[$0].task)" },
        ]
    }

    private static func header(local: LLMConfig, cloud: LLMConfig?) -> [String] {
        [
            "# Griasa promise benchmark — \(Date().formatted(.iso8601.year().month().day()))",
            "",
            "- Mac: \(sysctl("hw.model") ?? "unknown") · \(sysctl("machdep.cpu.brand_string") ?? "unknown CPU")"
                + " · \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB RAM",
            "- Local model: \(local.smartModel) (Griasa's own engine)",
            "- Cloud reference: \(cloud.map { "\($0.provider.rawValue) · \($0.smartModel)" } ?? "none")",
            "- Variants: **single** — today's local single pass, truncated as today; **chunked** — the local path in parts;"
                + " **cloud** — a cloud model reading the whole transcript.",
        ]
    }

    private static func results(_ rows: [Row], cloud: Bool, header: [String]) -> String {
        func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "–" }
        func seconds(_ v: LongMeetingEval.Variant) -> String {
            guard let notes = v.seconds else { return "–" }
            return String(format: "%.0f+%.0f", notes, v.promisesSeconds ?? 0)
        }
        func cells(_ r: BenchmarkScore.Result?) -> String {
            guard let r else { return "failed | – | – | – | – | –" }
            return "\(r.matched)/\(r.gold) (\(r.predicted) found) | \(percent(r.recall)) | \(percent(r.precision))"
                + " | \(percent(r.mineAccuracy)) | \(percent(r.ownerAccuracy)) | \(r.trapsHit)"
        }
        let names = ["single", "chunked"] + (cloud ? ["cloud"] : [])
        var lines = header + [
            "",
            "| Meeting | Language | Chars | Variant | Matched | Recall | Precision | Mine/theirs | Owner | Traps hit | Notes+promises s |",
            "|---|---|---:|---|---|---:|---:|---:|---:|---:|---:|",
        ]
        for row in rows {
            let outcome = variants(row.outcome, cloud: true)
            for name in names {
                let variant = outcome.first { $0.0 == name }!.1
                lines.append("| \(row.id) | \(row.meta.language) | \(row.chars) | \(name) | \(cells(row.scores[name])) | \(seconds(variant)) |")
            }
        }
        lines += ["", "**Totals** (counts summed over the meetings, so a long meeting weighs more):", "",
                  "| Variant | Matched | Recall | Precision | Mine/theirs | Owner | Traps hit | Notes+promises s |",
                  "|---|---|---:|---:|---:|---:|---:|---:|"]
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
