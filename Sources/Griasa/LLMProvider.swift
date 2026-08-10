import AppKit
import Foundation

/// Which backend answers AI requests. `custom` is any OpenAI-compatible
/// endpoint — Ollama, LM Studio, OpenRouter, Groq… — so one integration
/// covers local models and every aggregator.
enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openAI
    case gemini
    case custom
    case claudeCLI
    case codexCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI"
        case .gemini: return "Google (Gemini)"
        case .custom: return "Custom / local (OpenAI-compatible)"
        case .claudeCLI: return "Claude Code (subscription, no API key)"
        case .codexCLI: return "Codex CLI (ChatGPT subscription)"
        }
    }

    /// Answers via a locally installed CLI using its own subscription login —
    /// no API key involved.
    var isCLI: Bool { self == .claudeCLI || self == .codexCLI }

    /// Defaults verified current as of 2026-07: Haiku 4.5 / Opus 4.8,
    /// GPT-5.6 Luna / Terra, Gemini 3.1 Flash-Lite / 3.5 Flash, Qwen3 for local.
    /// CLI providers take the CLI's model aliases; empty = the CLI's default.
    var defaultFastModel: String {
        switch self {
        case .anthropic: return "claude-haiku-4-5"
        case .openAI: return "gpt-5.6-luna"
        case .gemini: return "gemini-3.1-flash-lite"
        case .custom: return "qwen3:8b"
        case .claudeCLI: return "haiku"
        case .codexCLI: return ""
        }
    }

    var defaultSmartModel: String {
        switch self {
        case .anthropic: return "claude-opus-4-8"
        case .openAI: return "gpt-5.6-terra"
        case .gemini: return "gemini-3.5-flash"
        case .custom: return "qwen3:30b"
        case .claudeCLI: return "sonnet"
        case .codexCLI: return ""
        }
    }
}

/// Which class of model a request needs. Cheap in-the-flow tasks (dictation
/// cleanup, classification, reminder parsing, reply drafts) use `fast`;
/// heavy ones (presets, summaries, Ask Project, meeting notes) use `smart`.
enum ModelTier {
    case fast
    case smart
}

/// Immutable snapshot of the provider settings, safe to read from any thread
/// or detached task (UserDefaults is thread-safe; @AppStorage in Settings
/// writes to the same keys).
struct LLMConfig: Sendable {
    let provider: LLMProvider
    let apiKey: String
    let baseURL: String
    let fastModel: String
    let smartModel: String
    /// Transcript truncation budget in characters. Cloud models have 1M-token
    /// windows; local models rarely exceed 32k tokens of context.
    let contextCharLimit: Int

    func model(for tier: ModelTier) -> String {
        tier == .fast ? fastModel : smartModel
    }

    var isConfigured: Bool {
        switch provider {
        case .anthropic, .openAI, .gemini: return !apiKey.isEmpty
        case .custom: return !baseURL.isEmpty  // Ollama needs no key
        case .claudeCLI, .codexCLI: return !baseURL.isEmpty  // resolved binary path
        }
    }

    static func current() -> LLMConfig {
        let raw = UserDefaults.standard.string(forKey: "llmProvider") ?? ""
        return config(for: LLMProvider(rawValue: raw) ?? .anthropic)
    }

    static func config(for provider: LLMProvider) -> LLMConfig {
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        func stored(_ key: String) -> String {
            (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func model(_ key: String, or fallback: String) -> String {
            let value = stored(key)
            return value.isEmpty ? fallback : value
        }

        switch provider {
        case .anthropic:
            var key = stored("anthropicAPIKey")
            if key.isEmpty { key = env["ANTHROPIC_API_KEY"] ?? "" }
            return LLMConfig(provider: .anthropic, apiKey: key, baseURL: "",
                             fastModel: model("anthropicFastModel", or: provider.defaultFastModel),
                             smartModel: model("anthropicSmartModel", or: provider.defaultSmartModel),
                             contextCharLimit: 400_000)
        case .openAI:
            var key = stored("openAIKey")
            if key.isEmpty { key = env["OPENAI_API_KEY"] ?? "" }
            return LLMConfig(provider: .openAI, apiKey: key,
                             baseURL: "https://api.openai.com/v1",
                             fastModel: model("openAIFastModel", or: provider.defaultFastModel),
                             smartModel: model("openAISmartModel", or: provider.defaultSmartModel),
                             contextCharLimit: 400_000)
        case .gemini:
            var key = stored("geminiKey")
            if key.isEmpty { key = env["GEMINI_API_KEY"] ?? "" }
            // Google's OpenAI-compatible endpoint — same wire format as .custom.
            return LLMConfig(provider: .gemini, apiKey: key,
                             baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                             fastModel: model("geminiFastModel", or: provider.defaultFastModel),
                             smartModel: model("geminiSmartModel", or: provider.defaultSmartModel),
                             contextCharLimit: 400_000)
        case .custom:
            let limit = defaults.integer(forKey: "customContextLimit")
            return LLMConfig(provider: .custom, apiKey: stored("customAPIKey"),
                             baseURL: stored("customBaseURL"),
                             fastModel: model("customFastModel", or: provider.defaultFastModel),
                             smartModel: model("customSmartModel", or: provider.defaultSmartModel),
                             contextCharLimit: limit > 0 ? limit : 24_000)
        case .claudeCLI:
            // baseURL carries the resolved binary path; empty = not installed.
            return LLMConfig(provider: .claudeCLI, apiKey: "",
                             baseURL: CLIRunner.locate(.claudeCLI) ?? "",
                             fastModel: model("claudeCLIFastModel", or: provider.defaultFastModel),
                             smartModel: model("claudeCLISmartModel", or: provider.defaultSmartModel),
                             contextCharLimit: 400_000)
        case .codexCLI:
            return LLMConfig(provider: .codexCLI, apiKey: "",
                             baseURL: CLIRunner.locate(.codexCLI) ?? "",
                             fastModel: model("codexCLIFastModel", or: provider.defaultFastModel),
                             smartModel: model("codexCLISmartModel", or: provider.defaultSmartModel),
                             contextCharLimit: 400_000)
        }
    }

    /// A configured cloud provider to offer when `failed`'s request errored —
    /// nil when there's nothing to fall back to. CLI providers count as cloud:
    /// the text goes to the vendor, just billed to a subscription.
    static func cloudFallback(for failed: LLMConfig) -> LLMConfig? {
        for provider in [LLMProvider.anthropic, .openAI, .gemini, .claudeCLI, .codexCLI]
        where provider != failed.provider {
            let candidate = config(for: provider)
            if candidate.isConfigured { return candidate }
        }
        return nil
    }
}

/// "Ask each time" fallback consent (user's choice from the design session):
/// when the selected provider fails and a cloud key exists, explicit actions
/// ask before sending the text off-device. Dictation cleanup and background
/// classification never ask — they degrade silently instead.
@MainActor
enum CloudFallback {
    /// Set by the "until restart" button; resets when the app quits.
    static var allowUntilRestart = false

    static func approve(failed: LLMProvider, fallback: LLMProvider, error: String) -> Bool {
        if allowUntilRestart { return true }
        let alert = NSAlert()
        alert.messageText = "\(failed.displayName) request failed"
        alert.informativeText = """
        \(error)

        Send this request via \(fallback.displayName) instead? The text will leave this Mac.
        """
        alert.addButton(withTitle: "Send via \(fallback.displayName)")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use it until restart")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertThirdButtonReturn:
            allowUntilRestart = true
            return true
        default:
            return false
        }
    }
}
