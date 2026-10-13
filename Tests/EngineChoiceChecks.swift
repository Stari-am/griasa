import Foundation

// Checks for which runtime Griasa uses. A server the person set up themselves
// is never replaced; an existing runtime with a suitable model is used before
// anything is downloaded; Griasa's own engine is the last resort.

func runEngineChoiceChecks() -> Int {
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
let entry = LocalModelCatalog.entry(id: "qwen3.5-9b-q4")!
func d(_ p: LocalProbe, _ pref: LocalEngine? = nil) -> LocalEngineDecision {
    LocalEngineChoice.decide(p, entry: entry, preferred: pref)
}
let empty = LocalProbe(userBaseURL: "", ollamaModels: nil, lmStudioModels: nil, griasaModelOnDisk: false)

var p = empty; p.userBaseURL = "http://llm.corp.example:8000/v1"; p.ollamaModels = ["qwen3.5:9b"]
check(d(p) == .use(.userServer, model: ""),
      rule: "a server the person typed in always wins",
      meaning: "a company gateway must never be swapped for a model on the laptop", saw: "\(d(p))")
check(d(p, .griasa) == .use(.userServer, model: ""),
      rule: "…even over an Advanced preference",
      meaning: "the explicit URL is the more specific instruction", saw: "\(d(p, .griasa))")

p = empty; p.ollamaModels = ["llama3:8b", "qwen3.5:9b"]
check(d(p) == .use(.ollama, model: "qwen3.5:9b"),
      rule: "Ollama with a suitable model is used, no download",
      meaning: "the person already has it; a second copy wastes 6 GB", saw: "\(d(p))")

p = empty; p.ollamaModels = ["llama3:8b"]
check(d(p) == .pullIntoOllama(tag: "qwen3.5:9b"),
      rule: "Ollama without a suitable model gets the model pulled into it",
      meaning: "one runtime per Mac, not two", saw: "\(d(p))")

p = empty; p.lmStudioModels = ["qwen3.5-9b-gguf"]
check(d(p) == .use(.lmStudio, model: "qwen3.5-9b-gguf"),
      rule: "LM Studio with a suitable model is used", meaning: "same as Ollama", saw: "\(d(p))")

p = empty; p.lmStudioModels = ["mistral-7b"]
check(d(p) == .download,
      rule: "LM Studio without a suitable model → Griasa's engine",
      meaning: "LM Studio's own downloads are not driven from outside", saw: "\(d(p))")

p = empty; p.griasaModelOnDisk = true; p.ollamaModels = ["qwen3.5:9b"]
check(d(p) == .use(.ollama, model: "qwen3.5:9b"),
      rule: "Auto prefers a running Ollama even when Griasa's copy exists",
      meaning: "Ollama keeps its model in memory already; starting a second server doubles RAM", saw: "\(d(p))")
check(d(p, .griasa) == .use(.griasa, model: entry.id),
      rule: "an Advanced preference for Griasa's engine is honoured when its model is there",
      meaning: "experts choose", saw: "\(d(p, .griasa))")

p = empty; p.griasaModelOnDisk = true
check(d(p) == .use(.griasa, model: entry.id),
      rule: "Griasa's engine is used when its model is on disk", meaning: "the normal case after setup", saw: "\(d(p))")
check(d(empty) == .download,
      rule: "nothing anywhere → download (after consent)", meaning: "the first-run case", saw: "\(d(empty))")
func gate(_ url: String, _ names: [String] = [], busy: Bool = false) -> LocalRefreshGate.Action {
    LocalRefreshGate.action(typedBaseURL: url, typedModelNames: names, busy: busy)
}
check(gate(" http://gw.corp/v1\n") == .userServer && gate("  \n") == .proceed,
      rule: "a typed server address wins before any disk or memory decision; whitespace alone is not an address",
      meaning: "a company-gateway user must never see a download card or a no-space message",
      saw: "typed → \(gate(" http://gw.corp/v1")), blank → \(gate("  "))")
check(gate("", ["qwen3:8b", ""]) == .userServer && gate("", ["", "my-model"]) == .userServer,
      rule: "a typed model name, with no address, is hand configuration too",
      meaning: "somebody who typed the names of models in their own Ollama must keep them, not be moved to Griasa's engine",
      saw: "fast only → \(gate("", ["qwen3:8b", ""])), smart only → \(gate("", ["", "my-model"]))")
check(gate("", [" ", "\n"]) == .proceed && gate("", []) == .proceed,
      rule: "blank model names are not hand configuration",
      meaning: "an emptied field must give the person back the automatic setup",
      saw: "\(gate("", [" ", "\n"]))")
check(gate("", busy: true) == .skip && gate("http://x/v1", busy: true) == .skip
        && gate("", ["m"], busy: true) == .skip,
      rule: "a refresh while installing or downloading does nothing",
      meaning: "a second refresh must not reset a running download to the consent card",
      saw: "busy → \(gate("", busy: true))")

return failures
}
