import Foundation

// Checks for moving API keys out of plain preferences into the keychain. Wrong
// one way, a key stays in a plain-text file every process can read. Wrong the
// other way — the one that matters more — somebody's key is gone and every AI
// feature stops, with nothing to say why.

private final class FakePlain: PlainStore {
    var values: [String: String]
    init(_ values: [String: String]) { self.values = values }
    func string(forKey key: String) -> String? { values[key] }
    func removeObject(forKey key: String) { values[key] = nil }
}

private final class FakeSecrets: SecretStore {
    var values: [String: String] = [:]
    var refuseWrites = false
    var corruptReads = false
    func read(_ name: String) -> String? { corruptReads ? values[name].map { $0 + "!" } : values[name] }
    func write(_ name: String, _ value: String) -> Bool {
        if refuseWrites { return false }
        values[name] = value
        return true
    }
    func delete(_ name: String) { values[name] = nil }
}

/// Returns the number of failed checks, so the entry point decides the exit code.
func runSecretChecks() -> Int {
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

do {
    let plain = FakePlain(["anthropicAPIKey": "sk-ant-test", "openAIKey": "sk-test"])
    let secrets = FakeSecrets()
    let moved = SecretMigration.run(plain: plain, secrets: secrets)
    check(secrets.values["anthropicAPIKey"] == "sk-ant-test" && secrets.values["openAIKey"] == "sk-test"
            && plain.values.isEmpty && moved.count == 2,
          rule: "a key in plain preferences ends up in the keychain and nowhere else",
          meaning: "this is the fix itself — a copy left behind in the plist is the plain-text key the review was about",
          saw: "keychain \(secrets.values.keys.sorted()), plist still has \(plain.values.keys.sorted())")
}

do {
    let plain = FakePlain(["geminiKey": "g-test"])
    let secrets = FakeSecrets(); secrets.refuseWrites = true
    SecretMigration.run(plain: plain, secrets: secrets)
    check(plain.values["geminiKey"] == "g-test",
          rule: "if the keychain refuses the write, the key stays where it was",
          meaning: "plain text for one more launch is a smaller harm than a key that is simply gone",
          saw: "plist now \(plain.values)")
}

do {
    let plain = FakePlain(["customAPIKey": "local-test"])
    let secrets = FakeSecrets(); secrets.corruptReads = true
    SecretMigration.run(plain: plain, secrets: secrets)
    check(plain.values["customAPIKey"] == "local-test",
          rule: "a write that reads back different does not count as moved",
          meaning: "\"the call returned success\" is not evidence the key is there — the only proof is reading it back",
          saw: "plist now \(plain.values)")
}

do {
    let plain = FakePlain(["anthropicAPIKey": "sk-ant-newer"])
    let secrets = FakeSecrets(); secrets.values["anthropicAPIKey"] = "sk-ant-older"
    SecretMigration.run(plain: plain, secrets: secrets)
    check(secrets.values["anthropicAPIKey"] == "sk-ant-newer" && plain.values.isEmpty,
          rule: "a key found in preferences replaces the one in the keychain",
          meaning: "the current app never writes keys to preferences, so one there was typed into an older version and is the latest the person entered",
          saw: "keychain has \(secrets.values["anthropicAPIKey"] ?? "nothing")")
}

do {
    let plain = FakePlain(["openAIKey": "   ", "geminiKey": "  g-padded \n"])
    let secrets = FakeSecrets()
    SecretMigration.run(plain: plain, secrets: secrets)
    check(secrets.values["openAIKey"] == nil && secrets.values["geminiKey"] == "g-padded" && plain.values.isEmpty,
          rule: "blank entries are cleared without being stored, and stray whitespace is trimmed",
          meaning: "a blank \"key\" in the keychain would make the provider look configured when it is not; a pasted trailing newline is the classic reason a valid key is rejected",
          saw: "keychain \(secrets.values), plist \(plain.values)")
}

do {
    let plain = FakePlain(["somethingElse": "keep me", "anthropicAPIKey": "sk-ant-test"])
    SecretMigration.run(plain: plain, secrets: FakeSecrets())
    check(plain.values["somethingElse"] == "keep me",
          rule: "only the named key preferences are touched",
          meaning: "the migration runs against the user's real preferences; anything outside the list is somebody's setting",
          saw: "plist now \(plain.values)")
}

check(Set(SecretNames.all) == ["anthropicAPIKey", "openAIKey", "geminiKey", "customAPIKey"],
      rule: "every stored API key is on the list of names to move",
      meaning: "a key left off the list is a key left in plain text, silently, for ever",
      saw: "\(SecretNames.all)")

return failures
}
