import Foundation

// Checks for Griasa's own llama-server: a process it did not start, a start
// that failed, and how long a request to it may take.

func runLlamaServerChecks() -> Int {
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

// Which model an orphan on the port serves
let props = Data(#"{"default_generation_settings":{},"model_path":"/Users/x/Library/Application Support/Griasa/models/Qwen3.5-9B-Q4_K_M.gguf","total_slots":1}"#.utf8)
let models = Data(#"{"object":"list","data":[{"id":"/Users/x/models/gemma-4-12b-Q8_0.gguf","object":"model"}]}"#.utf8)
let wanted = "/Users/x/Library/Application Support/Griasa/models/Qwen3.5-9B-Q4_K_M.gguf"
check(LlamaServerRules.servedModel(props) == wanted
        && LlamaServerRules.servedModel(models) == "/Users/x/models/gemma-4-12b-Q8_0.gguf"
        && LlamaServerRules.servedModel(Data("{}".utf8)) == nil
        && LlamaServerRules.servedModel(Data("<html>".utf8)) == nil,
      rule: "the served model is read from /props, else /v1/models; nothing readable → nil",
      meaning: "an orphan is only reused when it is known to serve the wanted file",
      saw: "\(String(describing: LlamaServerRules.servedModel(props)))")
check(LlamaServerRules.mayAdopt(served: wanted, wantedPath: wanted)
        && !LlamaServerRules.mayAdopt(served: "/Users/x/other/Qwen3.5-9B-Q4_K_M.gguf", wantedPath: wanted)
        && !LlamaServerRules.mayAdopt(served: "Qwen3.5-9B-Q4_K_M.gguf", wantedPath: wanted)
        && !LlamaServerRules.mayAdopt(served: "/Users/x/models/gemma-4-12b-Q8_0.gguf", wantedPath: wanted)
        && !LlamaServerRules.mayAdopt(served: nil, wantedPath: wanted),
      rule: "only a server serving the wanted file at Griasa's own path is reused — not the same name elsewhere, an alias, or silence",
      meaning: "an adopted server must be one Griasa can stop again; another program's would hold the port for good",
      saw: "same name elsewhere → \(LlamaServerRules.mayAdopt(served: "/Users/x/other/Qwen3.5-9B-Q4_K_M.gguf", wantedPath: wanted))")

// Which processes count as Griasa's orphans
let pattern = LlamaServerRules.orphanPattern(modelsDirectory: "/Users/x/Library/Application Support/Griasa/models",
                                             port: 8177)
func matches(_ commandLine: String) -> Bool {
    // pkill uses extended regular expressions; NSRegularExpression agrees on this subset.
    commandLine.range(of: pattern, options: .regularExpression) != nil
}
let ours = "/opt/homebrew/bin/llama-server -m /Users/x/Library/Application Support/Griasa/models/q.gguf -c 32768 --host 127.0.0.1 --port 8177 -ngl 99"
check(matches(ours),
      rule: "a llama-server with a model from Griasa's folder on port 8177 is Griasa's",
      meaning: "a leftover from a crash must be found to be stopped", saw: pattern)
check(!matches("/opt/homebrew/bin/llama-server -m /Users/x/models/q.gguf --port 8177")
        && !matches("/opt/homebrew/bin/llama-server -m /Users/x/Library/Application Support/Griasa/models/q.gguf --port 8080")
        && !matches("/opt/homebrew/bin/llama-server -m /Users/x/Library/Application Support/Griasa/models/q.gguf --port 81770")
        && !matches("/usr/bin/vim /Users/x/Library/Application Support/Griasa/models/notes --port 8177"),
      rule: "a llama-server with another model folder or port, or another program, is never matched",
      meaning: "the person's own llama-server, or anything else, must never be killed",
      saw: pattern)
check(LlamaServerRules.orphanPattern(modelsDirectory: "/a.b(c)", port: 1).hasPrefix(#"llama-server.*/a\.b\(c\)/"#),
      rule: "regex characters in the folder are escaped",
      meaning: "a dot or bracket in a home folder name would otherwise widen or break the match",
      saw: LlamaServerRules.orphanPattern(modelsDirectory: "/a.b(c)", port: 1))

// Why a start failed
var tail = Data()
LlamaServerRules.appendTail(&tail, Data(repeating: 65, count: 3000))
LlamaServerRules.appendTail(&tail, Data(repeating: 66, count: 3000))
check(tail.count == LlamaServerRules.stderrTailBytes && tail.last == 66,
      rule: "only the last 4 KB of stderr is kept",
      meaning: "llama-server logs every request; keeping it all would grow for as long as it runs",
      saw: "\(tail.count) bytes")
let stderr = """
build: 6000 (abc) with Apple clang
llama_model_load: loading model from '/Users/x/Library/Application Support/Griasa/models/q.gguf'
ggml_metal_init: allocating
llama_model_load: error loading model: failed to allocate buffer of size 9000 MiB for /Users/x/Library/Application Support/Griasa/models/q.gguf
main: exiting due to model loading error
srv    operator(): cleaning up before exit...
"""
let reason = LlamaServerRules.failureReason(stderrTail: stderr)
check(reason == "main: exiting due to model loading error",
      rule: "the reason is the last line that reads like an error, not the trailing housekeeping",
      meaning: "\"could not start\" with no reason left launch failures invisible",
      saw: "\(reason ?? "nil")")
let pathReason = LlamaServerRules.failureReason(stderrTail: "error: unable to open /Users/x/Library/Application Support/Griasa/models/q.gguf\n")
check(pathReason == "error: unable to open q.gguf",
      rule: "paths in the reason are cut to the file name",
      meaning: "a log line or error message must not carry the person's folder names",
      saw: "\(pathReason ?? "nil")")
check(LlamaServerRules.failureReason(stderrTail: "\n  \n") == nil
        && LlamaServerRules.failureReason(stderrTail: "just this") == "just this",
      rule: "empty stderr gives no reason; otherwise the last line stands",
      meaning: "an invented reason would mislead", saw: "\(LlamaServerRules.failureReason(stderrTail: "just this") ?? "nil")")

// How long a request to a managed local model may take
check(LocalFailure.timeout(10, managedLocal: true) == 10 && LocalFailure.timeout(30, managedLocal: true) == 30,
      rule: "interactive timeouts (dictation cleanup's 10 s) are not lengthened on a local model",
      meaning: "the person is waiting for text; after 10 s the local cleanup is better than 30 s of nothing",
      saw: "\(LocalFailure.timeout(10, managedLocal: true))")
check(LocalFailure.timeout(60, managedLocal: true) == 180 && LocalFailure.timeout(300, managedLocal: true) == 900,
      rule: "background jobs (a minute or more) get three times as long on a local model",
      meaning: "a meeting summary that times out is lost work, and a local model is far slower than the cloud",
      saw: "\(LocalFailure.timeout(300, managedLocal: true))")
check(LocalFailure.timeout(300, managedLocal: false) == 300,
      rule: "nothing changes for a cloud or hand-configured provider",
      meaning: "their timeouts were set for them", saw: "\(LocalFailure.timeout(300, managedLocal: false))")

return failures
}
