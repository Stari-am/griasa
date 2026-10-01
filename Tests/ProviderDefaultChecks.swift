import Foundation

// Checks for which AI provider an install is on when nobody chose one. Wrong one
// way, meeting transcripts go to a cloud vendor from an app that says it keeps
// them on your Mac. Wrong the other way, somebody who deliberately set up a cloud
// key wakes up to every AI feature broken.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runProviderDefaultChecks() -> Int {
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

let fresh = ProviderDefault.resolve(stored: nil, keyed: [])
check(fresh == "custom",
      rule: "a new install, with nothing chosen and no keys, is on the local model",
      meaning: "this is the whole point — an app announced as local must be local without anybody opening Settings",
      saw: fresh)

let emptyStored = ProviderDefault.resolve(stored: "", keyed: [])
check(emptyStored == "custom",
      rule: "an empty stored value counts as nothing chosen",
      meaning: "UserDefaults hands back an empty string as easily as nil, and an empty provider must not fall through to anything cloud",
      saw: emptyStored)

let kept = ProviderDefault.resolve(stored: nil, keyed: ["anthropic"])
check(kept == "anthropic",
      rule: "an install already holding a cloud key, with no provider saved, keeps that provider",
      meaning: "before the default changed, the only way to be in that state was to be on the old default and paste a key into it — a choice; moving that person to a model they never installed breaks every AI feature they use",
      saw: kept)

let chosen = ProviderDefault.resolve(stored: "custom", keyed: ["anthropic", "openAI"])
check(chosen == "custom",
      rule: "a saved choice always wins over which keys exist",
      meaning: "somebody who chose local and also has a key lying around must stay local — a stored key is not consent to use it",
      saw: chosen)

let explicitCloud = ProviderDefault.resolve(stored: "gemini", keyed: [])
check(explicitCloud == "gemini",
      rule: "an explicitly saved cloud provider is respected even without a key yet",
      meaning: "the person picked it in Settings; the app's job is to say the key is missing, not to change their mind for them",
      saw: explicitCloud)

check(ProviderDefault.isOnThisMac("http://localhost:11434/v1")
        && ProviderDefault.isOnThisMac("http://127.0.0.1:1234/v1")
        && !ProviderDefault.isOnThisMac("http://ollama.office.lan:11434/v1")
        && !ProviderDefault.isOnThisMac("not a url"),
      rule: "only an address on this Mac is treated as the local model",
      meaning: "\"install Ollama\" is the right advice for localhost and the wrong one for a shared server down the hall",
      saw: "isOnThisMac disagreed for one of localhost, 127.0.0.1, a LAN host, garbage")

let advice = ProviderDefault.notRunningAdvice(baseURL: ProviderDefault.localBaseURL, model: "qwen3:8b")
check(advice.contains("ollama pull qwen3:8b") && advice.contains("leaves this Mac") && advice.contains("localhost:11434"),
      rule: "the not-running message says how to fix it locally, and what the cloud alternative costs",
      meaning: "this is the moment the cloud gets suggested — it has to come with what it means, and after the local fix, not instead of it",
      saw: advice)

return failures
}
