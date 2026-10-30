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

    /// The master switch: `false` closes every cloud provider at once.
    static let allowCloudAIKey = "allowCloudAI"

    /// One switch per way text can leave the Mac, so an organisation can allow
    /// one vendor and not another. The API and the subscription CLI of the same
    /// vendor are separate on purpose: a company API account under a data
    /// agreement and somebody's personal Claude Pro or ChatGPT Plus subscription
    /// are different contracts with different retention terms, and a security
    /// team will often want the first and not the second.
    static let providerKeys: [String: String] = [
        "anthropic": "allowAnthropic",
        "claudeCLI": "allowClaudeCode",
        "openAI": "allowOpenAI",
        "codexCLI": "allowCodex",
        "gemini": "allowGemini",
    ]

    /// The keys Settings shows as locked when a profile sets them. Anything
    /// else a profile sets still takes effect — macOS applies it — it is just
    /// not drawn as locked.
    static let lockableKeys = ["llmProvider", "customBaseURL", "customFastModel",
                               "customSmartModel", "mcpEnabled", allowCloudAIKey,
                               RecordingNotice.enabledKey, RecordingNotice.textKey,
                               "audioRetentionDays",
                               "localModelID", "localModelAutoDownload", "localEnginePreferred",
                               conversationsEnabledKey, conversationIngestEnabledKey,
                               conversationRetentionDaysKey, semanticSearchEnabledKey]
        + providerKeys.values.sorted()

    /// The providers that stay on this Mac. A custom endpoint counts even when
    /// it is a server on the company network: pointing it there is exactly what
    /// an organisation with its own model gateway wants to be able to do.
    static let onDeviceProviders: Set<String> = ["custom"]

    /// Absent means allowed: that is every install without a profile, and it
    /// must behave exactly as it always has.
    var cloudAllowed: Bool { flag(Self.allowCloudAIKey) ?? true }

    /// A policy switch as a profile wrote it: nil when absent.
    ///
    /// Present is a different matter from absent. Somebody wrote this key into
    /// a profile, so they meant to say something, and the common profile
    /// mistake — `<string>false</string>` where `<false/>` was meant — must not
    /// leave an organisation believing a provider is closed while it is open.
    /// So the usual spellings of yes and no are understood, and anything else
    /// is read as no. A security control that fails open on a typo is not one.
    func flag(_ key: String) -> Bool? {
        guard let raw = value(key) else { return nil }
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return ["true", "yes", "1"].contains(text)
        }
        return false
    }

    /// Conversations — chat history the person chooses to bring in — are off
    /// for the whole organisation when a profile says `false`. Absent means on:
    /// the feature still needs the person's own consent before it reads anything.
    static let conversationsEnabledKey = "conversationsEnabled"
    static let conversationIngestEnabledKey = "conversationIngestEnabled"
    static let conversationRetentionDaysKey = "conversationRetentionDays"

    var conversationsEnabled: Bool { flag(Self.conversationsEnabledKey) ?? true }

    /// Search by meaning: a local model turns meeting text into vectors kept in
    /// a file beside the history. A profile that says `false` keeps the model
    /// from being downloaded or run and the index from being built; absent
    /// leaves it to the person, who still has to download the model.
    static let semanticSearchEnabledKey = "semanticSearchEnabled"

    var semanticSearchAllowed: Bool { flag(Self.semanticSearchEnabledKey) ?? true }

    /// Whether an organisation lets the person bring chats in at all. Absent
    /// means the person's own switch decides, so this is true — it never turns
    /// ingestion on by itself, it only fails to close it. Present and not a
    /// clear yes is no, like every other policy switch.
    var conversationIngestAllowed: Bool { flag(Self.conversationIngestEnabledKey) ?? true }

    /// An organisation that has forced `mcpEnabled` off has closed the local
    /// assistant door; the add side shares that listener, so it is closed too.
    /// Forced on, or not forced, leaves it to the person's own switches.
    var mcpForcedOff: Bool { isLocked("mcpEnabled") && !(flag("mcpEnabled") ?? false) }

    /// Days to keep stored messages, when an organisation sets one. Only a
    /// positive whole number counts: a string, zero, a negative or a fraction
    /// is nil, which means messages are kept (there is no personal retention
    /// setting) rather than guessing at what a mistyped profile meant. (A Boolean is an NSNumber
    /// too, and "keep for true days" is not a policy.)
    var conversationRetentionDays: Int? {
        guard let raw = value(Self.conversationRetentionDaysKey),
              let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(),
              number.doubleValue >= 1, number.doubleValue < Double(Int32.max) else { return nil }
        return number.intValue
    }

    /// Whether any cloud provider at all is still allowed — the difference
    /// between "only on-device AI" and "some providers are off".
    var anyCloudAllowed: Bool {
        Self.providerKeys.keys.contains { allows(provider: $0) }
    }

    func isLocked(_ key: String) -> Bool { isForced(key) }

    var isManaged: Bool { Self.lockableKeys.contains(where: isForced) }

    /// The on-device provider is always allowed. A cloud one needs the master
    /// switch open and its own switch not closed; a provider with no switch of
    /// its own — one added later and not yet given a key — follows the master.
    func allows(provider raw: String) -> Bool {
        if Self.onDeviceProviders.contains(raw) { return true }
        guard cloudAllowed else { return false }
        guard let key = Self.providerKeys[raw] else { return true }
        return flag(key) ?? true
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
