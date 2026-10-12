import Foundation

/// The request Griasa sends to Ollama's native chat API.
///
/// Native rather than the OpenAI-compatible `/v1` endpoint for one reason:
/// Ollama defaults to a 4k-token context below 24 GB of memory, and `/v1`
/// cannot change that per request. Through `/v1` an hour-long meeting was
/// silently cut to its first minutes. `/api/chat` takes `num_ctx`.
///
/// Foundation only, so `test.sh` can reach it.
enum OllamaRequest {
    static let contextTokens = 32768

    static func chatBody(model: String, system: String, user: String, maxTokens: Int) -> [String: Any] {
        [
            "model": model,
            "stream": false,
            // Qwen thinks by default; the <think> block breaks JSON replies and
            // doubles the wait for a summary.
            "think": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["num_ctx": contextTokens, "num_predict": maxTokens],
        ]
    }

    static func root(fromOpenAIBase base: String) -> String {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        if root.hasSuffix("/v1") { root.removeLast(3) }
        return root
    }

    static func reply(_ data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
