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

// Catch-up, which runs with nobody watching
func catchUp(custom: Bool = true, url: String = "", names: [String] = [], stored: LocalEngine? = .griasa) -> Bool {
    LocalCatchUpGate.mayRun(providerIsCustom: custom, typedBaseURL: url, typedModelNames: names, storedEngine: stored)
}
check(!catchUp(custom: false) && !catchUp(custom: false, url: "http://localhost:11434/v1"),
      rule: "catch-up never runs on a cloud provider, whatever is set up locally",
      meaning: "a meeting summarized in the background must stay on this Mac; a switch to the cloud mid-way stops it",
      saw: "cloud → \(catchUp(custom: false))")
check(catchUp(stored: .ollama) && catchUp(stored: .griasa) && !catchUp(stored: nil),
      rule: "on the local provider, catch-up runs on an engine Griasa set up, and not with none",
      meaning: "with nothing set up there is no model to summarize with",
      saw: "ollama \(catchUp(stored: .ollama)), none \(catchUp(stored: nil))")
check(catchUp(url: "http://127.0.0.1:1234/v1", stored: nil) && catchUp(names: ["qwen3:8b", ""], stored: nil),
      rule: "a typed server on this Mac (or typed names, meaning the local Ollama) gets catch-up too",
      meaning: "otherwise meetings waiting for a model wait until the next one is queued",
      saw: "typed local → \(catchUp(url: "http://127.0.0.1:1234/v1", stored: nil))")
check(!catchUp(url: "http://gw.corp.example/v1", stored: .griasa),
      rule: "a typed server elsewhere never gets catch-up",
      meaning: "a company gateway is off this Mac; background summaries must not go there unasked",
      saw: "\(catchUp(url: "http://gw.corp.example/v1", stored: .griasa))")

check(LocalCatchUpGate.isLocal(providerIsCustom: true, baseURL: "http://127.0.0.1:8177/v1")
        && LocalCatchUpGate.isLocal(providerIsCustom: true, baseURL: "http://localhost:11434/v1")
        && !LocalCatchUpGate.isLocal(providerIsCustom: false, baseURL: "https://api.anthropic.com")
        && !LocalCatchUpGate.isLocal(providerIsCustom: true, baseURL: "http://gw.corp.example/v1"),
      rule: "each catch-up request may go only to the local provider at an address on this Mac",
      meaning: "a switch to the cloud while a meeting is half done must fail that meeting, not send its notes off the Mac",
      saw: "cloud → \(LocalCatchUpGate.isLocal(providerIsCustom: false, baseURL: "https://api.anthropic.com"))")

return failures
}
