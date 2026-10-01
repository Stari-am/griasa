import Foundation

/// Which AI provider an install is on when nobody has chosen one.
///
/// The answer is the local model. Griasa says it keeps your meetings on your
/// Mac, and until this existed that was true only for people who went into
/// Settings and changed it: an install that never touched the provider picker
/// was on Anthropic, and anybody who pasted a key had their transcripts going
/// to a cloud vendor by default. A security review put it plainly — announced
/// as local, configured as cloud.
///
/// Foundation only, so `test.sh` can reach it.
enum ProviderDefault {
    /// Ollama's OpenAI-compatible endpoint. LM Studio and anything else
    /// compatible are a base-URL change away in Settings.
    static let localBaseURL = "http://localhost:11434/v1"

    static let localProvider = "custom"

    /// The cloud providers that take a pasted key, in the order the old default
    /// would have reached them. CLI providers are deliberately absent: they are
    /// detected from what is installed, not chosen, so their presence is not a
    /// decision anybody made inside Griasa.
    static let keyedCloudProviders = ["anthropic", "openAI", "gemini"]

    /// - Parameters:
    ///   - stored: the provider saved in preferences, if any.
    ///   - keyed: providers that have a key stored.
    /// - Returns: the provider to use.
    ///
    /// A saved choice always wins. With none saved, an install that already has
    /// a cloud key keeps that provider: before the default changed, the only way
    /// to end up with a stored key and no stored provider was to be on the old
    /// default and paste a key into it, which is a choice, and silently moving
    /// that person to a model they never installed would break every AI feature
    /// they use. Everybody else — every new install — starts local.
    static func resolve(stored: String?, keyed: Set<String>) -> String {
        if let stored, !stored.isEmpty { return stored }
        return keyedCloudProviders.first(where: keyed.contains) ?? localProvider
    }

    /// Whether a base URL points at this machine. The local-model error message
    /// is only right when it does: "start Ollama" is no help to somebody whose
    /// compatible endpoint is a server down the hall.
    static func isOnThisMac(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// What to tell somebody whose local model is not there. Written for the
    /// moment it appears — right after they asked for something — so it says
    /// how to get the local path working first, and offers the cloud as a
    /// separate, explicit choice with its cost stated, rather than as a fix.
    static func notRunningAdvice(baseURL: String, model: String) -> String {
        let host = URL(string: baseURL).flatMap { url in
            url.port.map { "\(url.host ?? "localhost"):\($0)" } ?? url.host
        } ?? baseURL
        return """
        No local model is answering at \(host). Griasa keeps AI on this Mac by default: \
        install Ollama from ollama.com, then run `ollama pull \(model)`. \
        To use a cloud provider instead, choose one in Settings → AI & Actions — \
        text sent there leaves this Mac.
        """
    }

    /// Ollama is up but the model is not downloaded — the next most likely
    /// first-run state, and one with a one-line fix.
    static func missingModelAdvice(model: String) -> String {
        "The local model “\(model)” is not downloaded yet. Run `ollama pull \(model)`, " +
        "or pick a model you already have in Settings → AI & Actions."
    }
}
