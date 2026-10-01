import Foundation

// Checks for honouring an organisation's MDM profile. Wrong for a managed Mac,
// transcripts reach a cloud vendor the company has forbidden. Wrong for
// everybody else — the larger group — an app nobody manages starts behaving
// differently because a feature it never uses exists.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runManagedChecks() -> Int {
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

func policy(forced: Set<String> = [], values: [String: Any] = [:]) -> ManagedPolicy {
    ManagedPolicy(isForced: { forced.contains($0) }, value: { values[$0] })
}

let providers = ["anthropic", "openAI", "gemini", "custom", "claudeCLI", "codexCLI"]

// The one that matters most: no profile at all.
let plain = policy()
let unchanged = providers.allSatisfy { plain.effectiveProvider($0) == $0 && plain.allows(provider: $0) }
check(unchanged && plain.cloudAllowed && !plain.isManaged
        && !ManagedPolicy.lockableKeys.contains(where: plain.isLocked),
      rule: "with no profile, every provider is allowed, used as saved, and nothing is locked",
      meaning: "almost nobody running Griasa is managed; for them this feature must not exist",
      saw: "cloudAllowed \(plain.cloudAllowed), managed \(plain.isManaged), effective \(providers.map(plain.effectiveProvider))")

let userValue = policy(values: ["llmProvider": "anthropic"])
check(userValue.effectiveProvider("anthropic") == "anthropic" && !userValue.isManaged
        && !userValue.isLocked("llmProvider"),
      rule: "a value the user saved is not treated as managed",
      meaning: "only a profile locks a setting; a person's own choice must stay editable",
      saw: "managed: \(userValue.isManaged)")

let closed = policy(forced: [ManagedPolicy.allowCloudAIKey], values: [ManagedPolicy.allowCloudAIKey: false])
let resolved = providers.map(closed.effectiveProvider)
check(!closed.cloudAllowed && resolved.allSatisfy { $0 == "custom" },
      rule: "allowCloudAI = false sends every provider, including the subscription CLIs, to the on-device one",
      meaning: "the CLIs send text to the vendor too, just billed differently — a block that missed them would be a hole",
      saw: "\(resolved)")

check(closed.allows(provider: "custom") && !closed.allows(provider: "claudeCLI"),
      rule: "with the cloud closed, only the on-device provider is offered",
      meaning: "the picker must not show a choice that would then be silently overridden",
      saw: "custom \(closed.allows(provider: "custom")), claudeCLI \(closed.allows(provider: "claudeCLI"))")

let typo = policy(forced: [ManagedPolicy.allowCloudAIKey], values: [ManagedPolicy.allowCloudAIKey: "false"])
let garbage = policy(forced: [ManagedPolicy.allowCloudAIKey], values: [ManagedPolicy.allowCloudAIKey: ["no"]])
check(!typo.cloudAllowed && !garbage.cloudAllowed,
      rule: "a written-but-unusual allowCloudAI closes the cloud rather than leaving it open",
      meaning: "<string>false</string> is the classic profile mistake; failing open would leave a company believing the cloud is closed while it is open",
      saw: "string \"false\" → \(typo.cloudAllowed), array → \(garbage.cloudAllowed)")

let open = policy(values: [ManagedPolicy.allowCloudAIKey: "YES"])
check(open.cloudAllowed && policy(values: [ManagedPolicy.allowCloudAIKey: 1]).cloudAllowed,
      rule: "the usual spellings of yes keep the cloud open",
      meaning: "an organisation that explicitly allows the cloud should not be blocked for writing YES or 1",
      saw: "\"YES\" → \(open.cloudAllowed)")

let pinned = policy(forced: ["llmProvider", "customBaseURL"],
                    values: ["llmProvider": "custom", "customBaseURL": "http://llm.corp.example:11434/v1"])
check(pinned.isLocked("llmProvider") && pinned.isLocked("customBaseURL") && !pinned.isLocked("customFastModel")
        && pinned.isManaged,
      rule: "exactly the keys a profile sets are locked",
      meaning: "locking more takes away choices the company left open; locking less shows a picker that does nothing",
      saw: "locked: \(ManagedPolicy.lockableKeys.filter(pinned.isLocked))")

return failures
}
