import Foundation

/// The single gateway for LLM requests. Routes to the configured provider
/// (Anthropic Messages API, or any OpenAI-compatible endpoint — OpenAI,
/// Ollama, LM Studio…) and maps model tiers to the provider's configured
/// models. Also cleans up raw dictation, falling back to a local rule-based
/// cleanup so dictation always works with no provider at all.
/// An HTTP-level rejection from an AI provider, classified so callers can
/// tell account problems (bad key, no credits, spend limit) — which break
/// every AI feature at once and deserve a visible alert — from transient noise.
struct AIProviderError: LocalizedError {
    let provider: String
    let status: Int
    let detail: String
    /// CLI providers supply their own fix-it text ("run `claude` and log in") —
    /// the status-based advice below assumes API keys.
    var adviceOverride: String? = nil

    var errorDescription: String? {
        detail.isEmpty ? "\(provider) returned \(status)"
                       : "\(provider) returned \(status): \(detail)"
    }

    var isAccountIssue: Bool {
        if [401, 402, 403, 429].contains(status) { return true }
        let lower = detail.lowercased()
        return ["credit balance", "billing", "quota", "payment"].contains { lower.contains($0) }
    }

    var accountAdvice: String {
        if let adviceOverride { return adviceOverride }
        switch status {
        case 401, 403:
            return "The API key looks invalid or revoked — check it in Settings → AI & Actions."
        case 402:
            return "The provider reports a payment problem — check your plan and billing."
        case 429:
            return "Rate or spend limit reached — top up credits or wait a bit, then try again."
        default:
            return "The provider reports a billing or quota problem — check your account."
        }
    }
}

enum AIFormatter {
    /// Whether AI features can run at all with the current provider settings.
    /// Replaces the old "is the Anthropic key set?" gates.
    static var isConfigured: Bool { LLMConfig.current().isConfigured }

    static func format(_ raw: String, targetApp: String?, aiEnabled: Bool) async -> String {
        guard aiEnabled, isConfigured else { return localClean(raw) }
        // Dictation cleanup sits on the typing path — after the user stops
        // speaking, they wait for text. CLI providers spawn a subprocess and
        // routinely take 5–10 s per call; that stacks with a ~10 s timeout
        // and produces exactly what the user reports ("delayed and bad
        // result"). Use the local rule-based cleanup instead — dictation
        // still lands fast; meeting notes and other smart tasks keep the CLI.
        if LLMConfig.current().provider.isCLI { return localClean(raw) }
        let appContext = targetApp.map { "The text will be inserted into the app \"\($0)\" — match the tone people use there (e.g. casual for chat apps, structured for editors and email)." } ?? ""
        let system = Prompts.text(.dictationCleanup).filling(["appContext": appContext])
        do {
            // No cloud-fallback dialog mid-dictation — the local cleanup is
            // the graceful path here.
            let cleaned = try await complete(system: system, user: raw, tier: .fast,
                                             maxTokens: 2048, timeout: 10,
                                             allowCloudFallback: false)
            return cleaned.isEmpty ? localClean(raw) : cleaned
        } catch {
            NSLog("Griasa: AI formatting failed (%@), using local cleanup", error.localizedDescription)
            return localClean(raw)
        }
    }

    // MARK: - Provider router

    /// One system prompt, one user message, first text block back. `tier`
    /// resolves to the provider's configured fast/smart model. On failure,
    /// `allowCloudFallback` offers (once per request, or silently after "use
    /// until restart") to retry via a configured cloud provider.
    static func complete(system: String, user: String, tier: ModelTier,
                         maxTokens: Int, timeout: TimeInterval = 120,
                         allowCloudFallback: Bool = true) async throws -> String {
        let config = LLMConfig.current()
        do {
            return try await complete(config, system: system, user: user,
                                      model: config.model(for: tier),
                                      maxTokens: maxTokens, timeout: timeout)
        } catch {
            guard allowCloudFallback,
                  let fallback = LLMConfig.cloudFallback(for: config) else { throw surfaced(error) }
            let message = error.localizedDescription
            let approved = await MainActor.run {
                CloudFallback.approve(failed: config.provider,
                                      fallback: fallback.provider,
                                      error: message)
            }
            guard approved else { throw surfaced(error) }
            do {
                return try await complete(fallback, system: system, user: user,
                                          model: fallback.model(for: tier),
                                          maxTokens: maxTokens, timeout: timeout)
            } catch {
                throw surfaced(error)
            }
        }
    }

    /// Account-level failures (no credits, bad key, spend limit) would
    /// otherwise die quietly in the menu bar while every AI feature breaks —
    /// pop a real alert before rethrowing.
    private static func surfaced(_ error: Error) -> Error {
        if let providerError = error as? AIProviderError, providerError.isAccountIssue {
            Task { @MainActor in AIAccountAlert.show(providerError) }
        }
        return error
    }

    /// Providers wrap the human-readable reason as {"error":{"message":…}}
    /// (Anthropic nests it one level deeper) — pull it out, else raw body.
    private static func errorDetail(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let message = err["message"] as? String {
            return message
        }
        return String((String(data: data, encoding: .utf8) ?? "").prefix(200))
    }

    private static func complete(_ config: LLMConfig, system: String, user: String,
                                 model: String, maxTokens: Int,
                                 timeout: TimeInterval) async throws -> String {
        guard config.isConfigured else {
            throw NSError(domain: "Griasa", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No AI provider configured (Settings → AI & Actions)."
            ])
        }
        switch config.provider {
        case .anthropic:
            return try await anthropicComplete(system: system, user: user, model: model,
                                               maxTokens: maxTokens, apiKey: config.apiKey,
                                               timeout: timeout)
        case .openAI, .gemini, .custom:
            return try await openAIComplete(config, system: system, user: user, model: model,
                                            maxTokens: maxTokens, timeout: timeout)
        case .claudeCLI, .codexCLI:
            // maxTokens doesn't apply — the CLIs have no such flag.
            return try await CLIRunner.complete(config, system: system, user: user,
                                                model: model, timeout: timeout)
        }
    }

    /// Settings → Test: one tiny request against a specific provider's fast
    /// model, reporting latency or the error.
    static func test(provider: LLMProvider) async -> String {
        let config = LLMConfig.config(for: provider)
        guard config.isConfigured else { return "Not configured yet." }
        let started = Date()
        do {
            _ = try await complete(config, system: Prompts.text(.connectionTest),
                                   user: "ping", model: config.fastModel,
                                   maxTokens: 16, timeout: 60)
            return String(format: "✓ %@ answered in %.1fs", config.fastModel,
                          Date().timeIntervalSince(started))
        } catch {
            return "✗ \(error.localizedDescription)"
        }
    }

    // MARK: - Anthropic

    private static func anthropicComplete(system: String, user: String, model: String,
                                          maxTokens: Int, apiKey: String,
                                          timeout: TimeInterval) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIProviderError(provider: "Anthropic",
                                  status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                                  detail: Self.errorDetail(from: data))
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw NSError(domain: "Griasa", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected API response"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI-compatible (OpenAI, Ollama, LM Studio, …)

    private static func openAIComplete(_ config: LLMConfig, system: String, user: String,
                                       model: String, maxTokens: Int,
                                       timeout: TimeInterval) async throws -> String {
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            throw NSError(domain: "Griasa", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Invalid base URL: \(config.baseURL)"
            ])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ]
        ]
        // GPT-5.x rejects max_tokens; Gemini's compat layer, Ollama, and
        // LM Studio expect it.
        if config.provider == .openAI {
            body["max_completion_tokens"] = maxTokens
        } else {
            body["max_tokens"] = maxTokens
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIProviderError(
                provider: config.provider == .custom ? "The endpoint" : config.provider.displayName,
                status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                detail: Self.errorDetail(from: data))
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw NSError(domain: "Griasa", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected API response"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Model list from an OpenAI-compatible endpoint (`GET {base}/models`) —
    /// works on OpenAI, Ollama, and LM Studio. Used by Settings.
    static func listModels(baseURL: String, apiKey: String) async throws -> [String] {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/models") else {
            throw NSError(domain: "Griasa", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]]
        else {
            throw NSError(domain: "Griasa", code: 6, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the model list"])
        }
        // Gemini's compat layer returns ids as "models/gemini-…"; chat calls
        // accept the bare name, so strip the prefix.
        return list.compactMap { $0["id"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
            .sorted()
    }

    // MARK: - Local fallback

    static func localClean(_ raw: String) -> String {
        var text = raw

        // Spoken formatting commands.
        let commands: [(String, String)] = [
            ("new paragraph", "\n\n"),
            ("new line", "\n"),
            ("bullet point", "\n- "),
            ("question mark", "?"),
            ("exclamation mark", "!"),
            ("exclamation point", "!"),
            ("period", "."),
            ("comma", ","),
        ]
        for (spoken, symbol) in commands {
            text = text.replacingOccurrences(of: "\\s*\\b\(spoken)\\b\\s*", with: symbol,
                                             options: [.regularExpression, .caseInsensitive])
        }

        // Filler words.
        text = text.replacingOccurrences(of: "\\b(um+|uh+|erm+|you know,?)\\b\\s*", with: "",
                                         options: [.regularExpression, .caseInsensitive])

        // Collapse repeated spaces and space-before-punctuation.
        text = text.replacingOccurrences(of: " +([.,!?;:])", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Capitalize first letter and ensure terminal punctuation for sentence-like input.
        if let first = text.first {
            text = String(first).uppercased() + text.dropFirst()
        }
        if text.count > 12, let last = text.last, !"?!.\n:;,-".contains(last) {
            text += "."
        }
        return text
    }
}
