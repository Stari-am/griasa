import Foundation

// Checks for reading what the local runtimes answer. Samples are trimmed real
// responses (Ollama api.md, LM Studio REST docs, 2026-10).

func runRuntimeParsingChecks() -> Int {
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
let tags = Data(#"{"models":[{"name":"qwen3.5:9b","model":"qwen3.5:9b","size":5680000000,"digest":"sha256:ab"},{"name":"llama3:8b","model":"llama3:8b"}]}"#.utf8)
check(LocalRuntimeParsing.ollamaModelNames(tags) == ["qwen3.5:9b", "llama3:8b"],
      rule: "Ollama's model list is read from /api/tags",
      meaning: "a suitable model already in Ollama means no download at all", saw: "\(String(describing: LocalRuntimeParsing.ollamaModelNames(tags)))")
check(LocalRuntimeParsing.ollamaModelNames(Data("<html>".utf8)) == nil,
      rule: "something else on the Ollama port is not Ollama",
      meaning: "another program on 11434 must not be sent meeting text", saw: "parsed")
check(LocalRuntimeParsing.isOllamaVersion(Data(#"{"version":"0.12.3"}"#.utf8))
        && !LocalRuntimeParsing.isOllamaVersion(Data(#"{"data":[]}"#.utf8)),
      rule: "Ollama is recognised by /api/version",
      meaning: "decides whether to use the native API with a 32k context", saw: "wrong")
let lms = Data(#"{"models":[{"type":"llm","key":"Qwen3.5-9B-GGUF","loaded_instances":[]},{"type":"embedding","key":"nomic-embed"}]}"#.utf8)
check(LocalRuntimeParsing.lmStudioModelKeys(lms) == ["qwen3.5-9b-gguf"],
      rule: "LM Studio's chat models are read, embeddings skipped, lowercased",
      meaning: "an embedding model cannot write a summary", saw: "\(String(describing: LocalRuntimeParsing.lmStudioModelKeys(lms)))")
let mid = LocalRuntimeParsing.ollamaPullProgress(Data(#"{"status":"pulling ab","digest":"sha256:ab","total":100,"completed":40}"#.utf8))
check(mid?.completed == 40 && mid?.total == 100 && mid?.done == false,
      rule: "pull progress is read from the stream", meaning: "the menu shows a real percentage", saw: "\(String(describing: mid))")
let end = LocalRuntimeParsing.ollamaPullProgress(Data(#"{"status":"success"}"#.utf8))
check(end?.done == true, rule: "status success ends the pull", meaning: "otherwise setup waits for ever", saw: "\(String(describing: end))")
let err = LocalRuntimeParsing.ollamaPullProgress(Data(#"{"error":"pull model manifest: file does not exist"}"#.utf8))
check(err?.error != nil, rule: "an error line is reported", meaning: "a wrong tag must say so, not hang", saw: "\(String(describing: err))")
return failures
}
