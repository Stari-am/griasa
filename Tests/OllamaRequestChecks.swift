import Foundation

// Checks for the request Griasa sends to Ollama. Ollama gives a 4k context
// below 24 GB of memory and its OpenAI-compatible endpoint cannot raise it, so
// a one-hour meeting was being cut to its first minutes.

func runOllamaRequestChecks() -> Int {
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
let body = OllamaRequest.chatBody(model: "qwen3:30b", system: "S", user: "U", maxTokens: 2048)
let options = body["options"] as? [String: Any]
check((options?["num_ctx"] as? Int) == 32768,
      rule: "every request asks for a 32k context",
      meaning: "without it Ollama silently truncates meetings to ~4k tokens", saw: "\(String(describing: options))")
check((options?["num_predict"] as? Int) == 2048,
      rule: "the reply budget is passed as num_predict", meaning: "long summaries must not stop mid-sentence", saw: "\(String(describing: options))")
check(body["model"] as? String == "qwen3:30b",
      rule: "the person's own model name is kept",
      meaning: "someone who set up Ollama by hand keeps their model", saw: "\(String(describing: body["model"]))")
check(body["think"] as? Bool == false && body["stream"] as? Bool == false,
      rule: "thinking off, no streaming",
      meaning: "a <think> block breaks JSON and doubles the wait", saw: "\(body)")
let messages = body["messages"] as? [[String: String]]
check(messages?.map { $0["role"] ?? "" } == ["system", "user"],
      rule: "system then user message", meaning: "same prompt shape as every other provider", saw: "\(String(describing: messages))")
check(OllamaRequest.root(fromOpenAIBase: "http://localhost:11434/v1/") == "http://localhost:11434"
        && OllamaRequest.root(fromOpenAIBase: "http://box:11434") == "http://box:11434",
      rule: "the native root is the base URL without /v1", meaning: "Settings stores the OpenAI-style URL", saw: OllamaRequest.root(fromOpenAIBase: "http://localhost:11434/v1/"))
check(OllamaRequest.reply(Data(#"{"message":{"role":"assistant","content":" hi "},"done":true}"#.utf8)) == "hi",
      rule: "the reply is message.content, trimmed", meaning: "matches the other providers", saw: String(describing: OllamaRequest.reply(Data(#"{"message":{"content":" hi "}}"#.utf8))))
return failures
}
