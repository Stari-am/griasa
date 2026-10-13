import Foundation

/// Reads the event stream of Griasa's own llama-server, line by line.
///
/// Why a stream at all: a model on a Mac short of memory can spend many minutes
/// reading a long meeting before it writes a word, and a plain request sends
/// nothing back in that time, so the connection looks dead and gets dropped
/// while the model is still working. With `stream` and `return_progress` the
/// server reports how far it is, so "no bytes for a while" means stuck again.
///
/// Foundation only, so `test.sh` can reach it.
struct LlamaStream {
    struct Progress: Equatable {
        var total: Int
        var cache: Int
        var processed: Int
        var timeMs: Double
    }

    struct ServerError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var text = ""
    private(set) var finishReason: String?
    private(set) var progress: Progress?
    private(set) var done = false

    /// The server said it was finished: the end marker, or a finish reason.
    var complete: Bool { done || finishReason != nil }

    /// Feed one line as received. Blank lines and `:` comments carry nothing.
    /// An `{"error":…}` line throws with the server's own message.
    mutating func feed(line: String) throws {
        // An error may arrive as a data line or as an SSE `error:` field.
        let field: String
        if line.hasPrefix("data:") { field = "data:" }
        else if line.hasPrefix("error:") { field = "error:" }
        else { return }
        var payload = String(line.dropFirst(field.count))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        payload = payload.trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { done = true; return }
        guard let data = payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let error = json["error"] ?? (field == "error:" ? json : nil) {
            if let object = error as? [String: Any], let message = object["message"] as? String {
                throw ServerError(message: message)
            }
            if let message = error as? String { throw ServerError(message: message) }
            throw ServerError(message: "The model server reported an error.")
        }
        if let p = json["prompt_progress"] as? [String: Any] {
            progress = Progress(total: (p["total"] as? Int) ?? 0,
                                cache: (p["cache"] as? Int) ?? 0,
                                processed: (p["processed"] as? Int) ?? 0,
                                timeMs: (p["time_ms"] as? Double) ?? 0)
        }
        if let choice = (json["choices"] as? [[String: Any]])?.first {
            if let delta = choice["delta"] as? [String: Any], let piece = delta["content"] as? String {
                text += piece
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
        }
    }
}
