import Foundation
import Security

/// The login keychain, as a `SecretStore`.
///
/// Generic-password items, one per key, under the app's own bundle identifier —
/// so the local build and the release keep separate items, the way they keep
/// separate preferences. The file-based login keychain rather than the data
/// protection one: the latter needs an application-identifier entitlement and a
/// provisioning profile, which a Developer ID app outside the App Store does not
/// have. What it gives is what was asked for — encrypted at rest, and any other
/// program reading an item meets a system prompt naming it.
struct KeychainSecrets: SecretStore {
    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "am.stari.griasa") {
        self.service = service
    }

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    func read(_ name: String) -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ name: String, _ value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(name) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(name)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Griasa — \(name)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
}

/// The one place the app reads and writes API keys.
enum Secrets {
    static let store: SecretStore = KeychainSecrets()

    /// Moves anything still in plain preferences. Run at launch, so a key for a
    /// provider nobody uses any more does not sit in plain text for ever just
    /// because nothing ever asks for it.
    static func migrate() {
        let moved = SecretMigration.run(plain: UserDefaults.standard, secrets: store)
        if !moved.isEmpty { NSLog("Griasa: moved %d API key(s) into the keychain", moved.count) }
    }

    /// A key, wherever it currently is. Paths that run before launch finishes —
    /// `--transcribe`, the probes — reach keys too, so a key found only in the
    /// old place is moved on the way past rather than read from there.
    static func value(_ name: String) -> String {
        if let found = store.read(name), !found.isEmpty { return found }
        guard let plain = UserDefaults.standard.string(forKey: name), !plain.isEmpty else { return "" }
        SecretMigration.run(names: [name], plain: UserDefaults.standard, secrets: store)
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Empty clears the key.
    static func set(_ name: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { store.delete(name) } else { _ = store.write(name, trimmed) }
        // Never leave an older copy behind in the place it used to live.
        UserDefaults.standard.removeObject(forKey: name)
    }
}
