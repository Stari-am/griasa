import Foundation

/// The decisions `LlamaServer` makes about processes it did not start and
/// starts that failed, kept apart so `test.sh` can reach them.
///
/// Foundation only.
enum LlamaServerRules {
    /// How much of llama-server's stderr is kept: enough for the lines that
    /// say why a start failed, which come last.
    static let stderrTailBytes = 4096

    /// The model a llama-server on the port is serving, as it reports it:
    /// `/props` → `model_path`, else `/v1/models` → `data[0].id` (the path
    /// unless an alias was set). Nil when neither says.
    static func servedModel(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let path = json["model_path"] as? String, !path.isEmpty { return path }
        if let list = json["data"] as? [[String: Any]], let id = list.first?["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    /// A server on Griasa's port is adopted only when it serves exactly the
    /// wanted file, by full path: only then is it one Griasa started (and can
    /// stop again). The same file name in another folder, an alias, or
    /// silence is not adopted.
    static func mayAdopt(served: String?, wantedPath: String) -> Bool {
        guard let served else { return false }
        return (served as NSString).standardizingPath == (wantedPath as NSString).standardizingPath
    }

    /// The reason given when the port stays taken after Griasa's own
    /// leftovers are stopped. Not a memory problem, so no step-down.
    static let portTakenReason = "port 8177 is used by another program"

    /// The `pkill -f` / `pgrep -f` pattern for a llama-server Griasa started:
    /// the binary name, a model from Griasa's own models folder, and Griasa's
    /// port — so a llama-server the person runs for something else is never
    /// touched. Extended-regex specials in the folder are escaped.
    static func orphanPattern(modelsDirectory: String, port: Int) -> String {
        let specials = Set(#".[]()*+?{}|^$\"#)
        let escaped = modelsDirectory.map { specials.contains($0) ? "\\\($0)" : String($0) }.joined()
        return "llama-server.*\(escaped)/.*--port \(port)( |$)"
    }

    /// Appends `chunk` and keeps only the last `limit` bytes.
    static func appendTail(_ tail: inout Data, _ chunk: Data, limit: Int = stderrTailBytes) {
        tail.append(chunk)
        if tail.count > limit { tail = Data(tail.suffix(limit)) }
    }

    /// One line saying why a start failed, from the end of stderr: the last
    /// line that reads like an error, else the last line. Paths are cut to
    /// their file name, so the log names the model file but not the person's
    /// folders.
    static func failureReason(stderrTail: String) -> String? {
        let lines = stderrTail.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let markers = ["error", "failed", "unable", "cannot", "can't", "out of memory", "abort", "terminate"]
        guard let line = lines.last(where: { line in
            let lower = line.lowercased()
            return markers.contains(where: lower.contains)
        }) ?? lines.last else { return nil }
        // A path's folders go, spaces and all ("Application Support"): only
        // the file name is left. Erring towards cutting a few words is the
        // safe side of a line that may carry the person's folder names.
        let reason = line.replacingOccurrences(of: #"(?<![\w.])~?/(?:[^/\n'"`]*/)+"#, with: "",
                                               options: .regularExpression)
        return reason.count > 200 ? String(reason.prefix(200)) + "…" : reason
    }
}
