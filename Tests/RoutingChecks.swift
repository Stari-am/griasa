import Foundation

// Checks for which on-device model answers. Apple's model has a 4,096-token
// window and does not support Russian; anything outside what it can do goes
// to the downloaded model, never to the cloud.

func runRoutingChecks() -> Int {
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
func r(_ tier: ModelTier, _ en: Double, _ tokens: Int, _ apple: Bool) -> LocalRoute {
    LocalRouting.route(tier: tier, englishConfidence: en, inputTokens: tokens, appleAvailable: apple)
}

check(r(.fast, 0.95, 300, true) == .apple,
      rule: "a short English light job goes to Apple's model",
      meaning: "no download is needed for it and it is the fastest path", saw: "\(r(.fast, 0.95, 300, true))")
check(r(.smart, 0.99, 100, true) == .localLLM,
      rule: "heavy jobs never go to Apple's model",
      meaning: "summaries and promises need the long context only the downloaded model has", saw: "\(r(.smart, 0.99, 100, true))")
check(r(.fast, 0.6, 300, true) == .localLLM,
      rule: "mixed Russian-English text goes to the local model",
      meaning: "Apple's model throws on unsupported languages; a half-Russian sentence is still Russian", saw: "\(r(.fast, 0.6, 300, true))")
check(r(.fast, 0.95, 2501, true) == .localLLM,
      rule: "English text longer than Apple's budget goes to the local model",
      meaning: "the 4,096-token window holds the reply too", saw: "\(r(.fast, 0.95, 2501, true))")
check(r(.fast, 0.95, 2500, true) == .apple,
      rule: "the budget itself is still allowed", meaning: "boundary", saw: "\(r(.fast, 0.95, 2500, true))")
check(r(.fast, 0.95, 300, false) == .localLLM,
      rule: "without Apple Intelligence everything is local LLM",
      meaning: "Intel Macs, macOS 14–25, and Macs with Apple Intelligence off", saw: "\(r(.fast, 0.95, 300, false))")
check(LocalRouting.estimatedTokens(String(repeating: "a", count: 4001)) == 1001,
      rule: "token estimate is characters / 4, rounded up",
      meaning: "an underestimate overflows Apple's window", saw: "\(LocalRouting.estimatedTokens(String(repeating: "a", count: 4001)))")
return failures
}
