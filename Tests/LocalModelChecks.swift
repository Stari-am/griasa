import Foundation

// Checks for which local model Griasa offers. It must fit the Mac's memory —
// a model that does not fit fails to load, and the person sees AI "not work" —
// and it must fit the disk with room to spare, or the download cannot finish.

func runLocalModelChecks() -> Int {
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

let ids = LocalModelCatalog.entries.map(\.id)
check(LocalModelCatalog.entries.map(\.minMemoryGB) == LocalModelCatalog.entries.map(\.minMemoryGB).sorted(),
      rule: "entries are ordered by the memory they need",
      meaning: "pick walks the list from the top; out of order it would offer a model that does not fit",
      saw: "\(LocalModelCatalog.entries.map(\.minMemoryGB))")

for (memory, expected) in [(8, "qwen3.5-4b-q4"), (16, "qwen3.5-9b-q4"), (24, "gemma4-12b-q8"),
                           (32, "qwen3.6-35b-a3b-q4"), (48, "qwen3.6-35b-a3b-q4"), (64, "qwen3.6-35b-a3b-q8"),
                           (128, "qwen3.6-35b-a3b-q8")] {
    let got = LocalModelCatalog.pick(memoryGB: memory, freeDiskGB: 500)?.id
    check(got == expected,
          rule: "a \(memory) GB Mac with plenty of disk gets \(expected)",
          meaning: "the tier table in the spec is the promise; drifting from it changes what people download",
          saw: String(describing: got))
}

let tight = LocalModelCatalog.pick(memoryGB: 24, freeDiskGB: 9)
check(tight?.id == "qwen3.5-9b-q4",
      rule: "too little disk for the tier steps down to a smaller model",
      meaning: "a 12.7 GB download onto 9 GB free fails at 70% after ten minutes",
      saw: String(describing: tight?.id))

let none = LocalModelCatalog.pick(memoryGB: 24, freeDiskGB: 3)
check(none == nil,
      rule: "nothing fits → nil, not the smallest model anyway",
      meaning: "the card must say 'free up space', not offer a download that cannot finish",
      saw: String(describing: none?.id))

check(LocalModelCatalog.pick(memoryGB: 6, freeDiskGB: 500)?.id == "qwen3.5-4b-q4",
      rule: "below the smallest tier the smallest model is still offered",
      meaning: "8 GB Macs report 8; anything lower is a measurement quirk, not a reason for no AI",
      saw: String(describing: LocalModelCatalog.pick(memoryGB: 6, freeDiskGB: 500)?.id))

check(Set(ids).count == ids.count && ids.allSatisfy { LocalModelCatalog.entry(id: $0) != nil },
      rule: "ids are unique and findable",
      meaning: "an MDM profile pins a model by id",
      saw: "\(ids)")

check(LocalModelCatalog.entries.allSatisfy {
          $0.pinned.sha256.count == 64 && $0.pinned.url.absoluteString.contains("/resolve/")
              && !$0.pinned.url.absoluteString.contains("/resolve/main/") && $0.contextTokens == 32768
      },
      rule: "every model is pinned to a commit with a full SHA-256, and asks for a 32k context",
      meaning: "a model on `main` can change under the app; the hash is what the security review accepted",
      saw: "\(LocalModelCatalog.entries.map { $0.pinned.url.absoluteString })")

check(LocalModelCatalog.runnable(memoryGB: 24).map(\.id) == ["qwen3.5-4b-q4", "qwen3.5-9b-q4", "gemma4-12b-q8"],
      rule: "Settings offers only the models this Mac can run",
      meaning: "an expert picking a 37 GB model on a 24 GB Mac gets a server that never starts",
      saw: "\(LocalModelCatalog.runnable(memoryGB: 24).map(\.id))")

return failures
}
