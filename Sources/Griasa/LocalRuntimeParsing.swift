import Foundation

/// Reading what Ollama and LM Studio answer. Kept apart from the networking so
/// the shapes can be checked against real samples without either installed.
///
/// Foundation only, so `test.sh` can reach it.
enum LocalRuntimeParsing {
    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func ollamaModelNames(_ data: Data) -> [String]? {
        guard let models = object(data)?["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    static func isOllamaVersion(_ data: Data) -> Bool {
        object(data)?["version"] is String
    }

    static func lmStudioModelKeys(_ data: Data) -> [String]? {
        guard let models = object(data)?["models"] as? [[String: Any]] else { return nil }
        return models.filter { ($0["type"] as? String ?? "llm") == "llm" }
            .compactMap { ($0["key"] as? String)?.lowercased() }
    }

    static func ollamaPullProgress(_ line: Data) -> (completed: Int64, total: Int64, done: Bool, error: String?)? {
        guard let json = object(line) else { return nil }
        if let error = json["error"] as? String { return (0, 0, true, error) }
        let total = (json["total"] as? NSNumber)?.int64Value ?? 0
        let completed = (json["completed"] as? NSNumber)?.int64Value ?? 0
        return (completed, total, json["status"] as? String == "success", nil)
    }
}
