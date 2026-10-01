import Foundation

/// Where API keys live, and how they get there from where they used to live.
///
/// They used to be ordinary preferences — `~/Library/Preferences/<bundle>.plist`,
/// plain text, readable by any process running as the user and copied into
/// every backup. A security review named it (MITRE ATT&CK T1552.001, unsecured
/// credentials). They now live in the login keychain, encrypted at rest, where
/// another program asking for them gets a system prompt instead of the key.
///
/// Foundation only — the rules for moving them are what can lose somebody's key,
/// so they are what `test.sh` checks, against stores it can fake.
enum SecretNames {
    /// The preference names the keys were stored under, kept as the keychain
    /// account names so nothing has to be renamed on the way across.
    static let all = ["anthropicAPIKey", "openAIKey", "geminiKey", "customAPIKey"]
}

/// Somewhere a secret can be kept.
protocol SecretStore {
    func read(_ name: String) -> String?
    /// True only when the value was stored.
    func write(_ name: String, _ value: String) -> Bool
    func delete(_ name: String)
}

/// The old home: anything shaped like UserDefaults.
protocol PlainStore {
    func string(forKey key: String) -> String?
    func removeObject(forKey key: String)
}

extension UserDefaults: PlainStore {}

enum SecretMigration {
    /// Moves every key still sitting in plain preferences into the secret store.
    ///
    /// The one rule that matters: a key leaves the old place only once it is
    /// provably in the new one — written, then read back, and equal. Anything
    /// short of that leaves it where it was, because a key that is plain text
    /// for one more launch is a smaller harm than a key that is gone.
    ///
    /// A plain value replaces one already in the store. The current app never
    /// writes keys to preferences, so a value there was typed into an older
    /// version — after a downgrade, say — and is the most recent one the person
    /// entered.
    ///
    /// - Returns: the names that were moved.
    @discardableResult
    static func run(names: [String] = SecretNames.all,
                    plain: PlainStore, secrets: SecretStore) -> [String] {
        var moved: [String] = []
        for name in names {
            guard let raw = plain.string(forKey: name) else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty entry is not a secret; there is nothing to protect and
            // nothing to lose by clearing it.
            guard !value.isEmpty else {
                plain.removeObject(forKey: name)
                continue
            }
            guard secrets.write(name, value), secrets.read(name) == value else { continue }
            plain.removeObject(forKey: name)
            moved.append(name)
        }
        return moved
    }
}
