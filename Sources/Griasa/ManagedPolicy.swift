import Foundation

/// What an organisation's MDM profile has decided for this Mac.
///
/// macOS already does the hard part. A configuration profile whose payload type
/// is the app's bundle identifier installs those keys as *managed preferences*,
/// and `UserDefaults` returns them ahead of anything the user saved — so a
/// managed `llmProvider` is simply what the app reads. Two things are left for
/// the app: saying so in Settings, rather than letting somebody change a picker
/// that then does nothing, and one policy that is not a setting at all —
/// `allowCloudAI`, which closes every path that sends text off the Mac.
///
/// Built so that an ordinary install cannot tell it exists. With no profile,
/// nothing is forced and `allowCloudAI` is absent, and absent means allowed:
/// every answer below is then the answer the app gave before. `test.sh` holds
/// it to that.
///
/// Foundation only, with the preference lookups passed in, so the rules can be
/// checked without a managed Mac.
struct ManagedPolicy {
    /// Whether the key is set by a profile rather than by the user.
    let isForced: (String) -> Bool
    /// The value currently in effect for a key, managed or not.
    let value: (String) -> Any?

    /// The one policy key that is not an existing setting.
    static let allowCloudAIKey = "allowCloudAI"

    /// The keys Settings shows as locked when a profile sets them. Anything
    /// else a profile sets still takes effect — macOS applies it — it is just
    /// not drawn as locked.
    static let lockableKeys = ["llmProvider", "customBaseURL", "customFastModel",
                               "customSmartModel", "mcpEnabled", allowCloudAIKey]

    /// The providers that stay on this Mac. A custom endpoint counts even when
    /// it is a server on the company network: pointing it there is exactly what
    /// an organisation with its own model gateway wants to be able to do.
    static let onDeviceProviders: Set<String> = ["custom"]

    /// Absent means allowed: that is every install without a profile, and it
    /// must behave exactly as it always has.
    ///
    /// Present is a different matter. Somebody wrote this key into a profile,
    /// so they meant to say something about the cloud, and the common profile
    /// mistake — `<string>false</string>` where `<false/>` was meant — must not
    /// leave an organisation believing the cloud is closed while it is open. So
    /// the usual spellings of yes and no are understood, and anything else is
    /// read as no. A security control that fails open on a typo is not one.
    var cloudAllowed: Bool {
        guard let raw = value(Self.allowCloudAIKey) else { return true }
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return ["true", "yes", "1"].contains(text)
        }
        return false
    }

    func isLocked(_ key: String) -> Bool { isForced(key) }

    var isManaged: Bool { Self.lockableKeys.contains(where: isForced) }

    func allows(provider raw: String) -> Bool {
        cloudAllowed || Self.onDeviceProviders.contains(raw)
    }

    /// The provider to actually use. A cloud provider saved before the policy
    /// arrived — or pinned by a profile that also forbids the cloud, a profile
    /// mistake — resolves to the local one rather than sending anything.
    func effectiveProvider(_ raw: String) -> String {
        allows(provider: raw) ? raw : "custom"
    }

    static let live = ManagedPolicy(
        isForced: { UserDefaults.standard.objectIsForced(forKey: $0) },
        value: { UserDefaults.standard.object(forKey: $0) })
}
