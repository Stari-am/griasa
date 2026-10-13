import Foundation

// Checks for what a refresh keeps from the setup it made before. A model that
// is already working must not be dropped because the download that brought it
// took the disk it was picked by, or because Ollama was still starting at login.

func runSetupMemoryChecks() -> Int {
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
let small = LocalModelCatalog.entry(id: "qwen3.5-4b-q4")!
let nine = LocalModelCatalog.entry(id: "qwen3.5-9b-q4")!
let gemma = LocalModelCatalog.entry(id: "gemma4-12b-q8")!
func choose(pinned: String? = nil, steppedDown: String? = nil,
            engine: LocalEngine? = nil, model: String? = nil,
            downloaded: [LocalModelEntry] = [], memory: Int = 16, disk: Int = 500) -> String? {
    LocalSetupMemory.choose(pinnedID: pinned, steppedDownID: steppedDown,
                            storedEngine: engine, storedModel: model,
                            isDownloaded: { entry in downloaded.contains { $0.id == entry.id } },
                            memoryGB: memory, freeDiskGB: disk)?.id
}

// 16 GB Mac, 7 GB free after the 9B download: a fresh pick would be the 4B.
let relaunch = choose(engine: .griasa, model: nine.id, downloaded: [nine], disk: 7)
check(relaunch == nine.id,
      rule: "a relaunch after the download keeps the downloaded model, though the disk now fits only a smaller one",
      meaning: "re-picking from free disk would drop a working model and offer (or, under MDM, silently start) a second download",
      saw: "\(relaunch ?? "nil")")

let gone = choose(engine: .griasa, model: nine.id, downloaded: [], disk: 500)
check(gone == nine.id,
      rule: "a stored model whose file is gone falls to a fresh pick (here the same tier)",
      meaning: "only a model still on disk is worth keeping; otherwise the Mac is set up as if new",
      saw: "\(gone ?? "nil")")
let goneShort = choose(engine: .griasa, model: nine.id, downloaded: [], disk: 7)
check(goneShort == small.id,
      rule: "…and a fresh pick then reads the disk as it is",
      meaning: "a download that cannot fit would never finish",
      saw: "\(goneShort ?? "nil")")

let ollama = choose(engine: .ollama, model: "gemma4:12b", memory: 16, disk: 3)
check(ollama == gemma.id,
      rule: "a stored Ollama model maps back to its catalog entry, whatever this Mac would pick now",
      meaning: "otherwise the next launch looks for another tier's tag and pulls a second model into Ollama",
      saw: "\(ollama ?? "nil")")
let lm = choose(engine: .lmStudio, model: "qwen3.5-9b-instruct-gguf", memory: 8, disk: 3)
check(lm == nine.id,
      rule: "a stored LM Studio model maps back to its entry by the same match the probe uses",
      meaning: "same as Ollama: a working setup is kept",
      saw: "\(lm ?? "nil")")

let pinned = choose(pinned: small.id, engine: .griasa, model: nine.id, downloaded: [nine], memory: 64)
check(pinned == small.id,
      rule: "a pinned entry (organization or Settings → Advanced) wins over the stored setup",
      meaning: "a pin is an explicit instruction; the stored setup is only memory of an earlier automatic choice",
      saw: "\(pinned ?? "nil")")
let stepped = choose(steppedDown: small.id, engine: .griasa, model: nine.id, downloaded: [nine])
check(stepped == small.id,
      rule: "after the model ran out of memory, the smaller tier Griasa stepped down to is used",
      meaning: "going back to the larger one would fail to start again on every request",
      saw: "\(stepped ?? "nil")")
let pinBeatsStep = choose(pinned: gemma.id, steppedDown: small.id, memory: 24)
check(pinBeatsStep == gemma.id,
      rule: "a pin still wins over a step-down",
      meaning: "the step-down never writes the organization's key, so the pin keeps its meaning",
      saw: "\(pinBeatsStep ?? "nil")")

let fresh = choose(memory: 16, disk: 500)
check(fresh == nine.id,
      rule: "first setup, nothing stored, picks fresh for this Mac",
      meaning: "the normal first run",
      saw: "\(fresh ?? "nil")")
let fullDisk = choose(downloaded: [small, nine], memory: 16, disk: 1)
check(fullDisk == nine.id,
      rule: "no tier fits the disk, nothing stored → the largest model already downloaded",
      meaning: "its space is taken by it already; telling the person there is no room would be wrong",
      saw: "\(fullDisk ?? "nil")")
check(choose(memory: 16, disk: 1) == nil,
      rule: "no tier fits and nothing is downloaded → nil (the no-space message)",
      meaning: "a download that cannot finish must not be offered",
      saw: "\(choose(memory: 16, disk: 1) ?? "nil")")

// Stepping down
check(LocalModelCatalog.smaller(than: gemma)?.id == nine.id && LocalModelCatalog.smaller(than: small) == nil,
      rule: "the step-down after running out of memory is the next tier down, and none below the smallest",
      meaning: "one step, not a jump to the bottom; and nothing to fall to from the bottom",
      saw: "\(LocalModelCatalog.smaller(than: gemma)?.id ?? "nil") / \(LocalModelCatalog.smaller(than: small)?.id ?? "nil")")

// A runtime slow to start
func v(_ engine: LocalEngine?, _ answered: Bool, _ waits: Int) -> LocalRuntimeWait.Verdict {
    LocalRuntimeWait.verdict(stored: engine, answered: answered, waitsSoFar: waits)
}
check(v(.ollama, false, 0) == .keep(retryAfter: 5) && v(.lmStudio, false, 1) == .keep(retryAfter: 30)
        && v(.ollama, false, 2) == .keep(retryAfter: 120),
      rule: "a stored Ollama or LM Studio that does not answer is kept, and asked again after 5 s, 30 s, 120 s",
      meaning: "at login the runtime is often still starting; dropping it shows the card and (under MDM) downloads a duplicate",
      saw: "\(v(.ollama, false, 0)) \(v(.lmStudio, false, 1)) \(v(.ollama, false, 2))")
check(v(.ollama, false, 3) == .decide,
      rule: "after the last wait a still-silent runtime goes to the ordinary decision",
      meaning: "a runtime that was uninstalled must not keep the Mac without AI for good",
      saw: "\(v(.ollama, false, 3))")
check(v(.ollama, true, 0) == .decide && v(.lmStudio, true, 2) == .decide,
      rule: "a runtime that answers is decided on at once (with or without the model)",
      meaning: "an answer without the model is the one real sign the model is gone",
      saw: "\(v(.ollama, true, 0)) \(v(.lmStudio, true, 2))")
check(v(.griasa, false, 0) == .decide && v(nil, false, 0) == .decide,
      rule: "Griasa's own engine and a first setup never wait",
      meaning: "Griasa starts its own engine on demand; there is nothing to wait for",
      saw: "\(v(.griasa, false, 0)) \(v(nil, false, 0))")

return failures
}
