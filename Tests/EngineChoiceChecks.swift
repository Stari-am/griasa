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
return failures
}
