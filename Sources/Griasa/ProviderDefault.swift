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

    static let notSetUpAdvice = "Local AI isn't set up yet. Open Griasa's menu → Local AI to download it (one time)."

    /// For a model Griasa already set up whose server is unreachable right
    /// now. The fix depends on who runs that server: Griasa restarts its own
    /// engine by itself, but Ollama and LM Studio are the person's programs,
    /// and only they can start them again. `storedEngine` is the raw value of
    /// the stored `LocalEngine`, kept a plain string so this file stays
    /// Foundation-only without the engine type.
    static func notAnsweringAdvice(storedEngine: String) -> String {
        switch storedEngine {
        case "ollama":
            return "Ollama isn't answering. Start Ollama again, then try once more — Griasa uses the model already in it."
        case "lmStudio":
            return "LM Studio isn't answering. Start LM Studio's server again, then try once more — Griasa uses the model already in it."
        default:
            return "The local AI model isn't answering. Griasa will start it again on the next request; if this keeps happening, open Settings → AI & Actions → Local model."
        }
    }

    /// What to tell somebody whose local model is not there. Written for the
    /// moment it appears — right after they asked for something — so it says
    /// how to get the local path working first, and offers the cloud as a
    /// separate, explicit choice with its cost stated, rather than as a fix.
    ///
    /// `typedByPerson` is true when the base URL came from Settings rather than
    /// from Griasa's own setup: only then is "install Ollama" the right advice,
    /// because otherwise Griasa downloads and runs the model itself.
    ///
    /// `storedEngine` is the engine Griasa's setup stored (its raw value), if
    /// any: then the model exists and the server is merely unreachable now.
    static func notRunningAdvice(baseURL: String, model: String, typedByPerson: Bool,
                                 storedEngine: String? = nil) -> String {
        if !typedByPerson { return managedAdvice(storedEngine) }
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
    static func missingModelAdvice(model: String, typedByPerson: Bool, storedEngine: String? = nil) -> String {
        if !typedByPerson { return managedAdvice(storedEngine) }
        return "The local model “\(model)” is not downloaded yet. Run `ollama pull \(model)`, " +
        "or pick a model you already have in Settings → AI & Actions."
    }

    private static func managedAdvice(_ storedEngine: String?) -> String {
        guard let storedEngine, !storedEngine.isEmpty else { return notSetUpAdvice }
        return notAnsweringAdvice(storedEngine: storedEngine)
    }
}
