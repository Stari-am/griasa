import Foundation
import Combine

/// A named, reusable instruction applied to selected text (or the last
/// dictation). Users can add their own; a few ship as defaults.
struct PromptPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var emoji: String
    var systemPrompt: String
    /// When true, the popup offers "Replace Selection" (edits like grammar,
    /// translation, rewrites). Summaries leave the source untouched.
    var replacesSelection: Bool
    /// Optional global hotkey, e.g. "ctrl+opt+cmd+s"; empty = menu-only.
    var hotkey: String = ""

    static let defaults: [PromptPreset] = [
        PromptPreset(
            name: "Summarize", emoji: "📝", systemPrompt: """
            Summarize the user's text concisely, in the same language as the text.
            Format for a small popup window using ONLY inline Markdown:
            - First line: a short **bold** title.
            - Then 3–8 bullet lines starting with "• " (use **bold** for key terms).
            - If the text contains action items or conclusions, add a final "• Итог/Takeaway:" bullet.
            Keep English tech/crypto terms in English. No headers (#), no tables. Output only the summary.
            """,
            replacesSelection: false, hotkey: "ctrl+opt+cmd+s"),
        PromptPreset(
            name: "Fix grammar & spelling", emoji: "✅", systemPrompt: """
            Fix grammar, spelling, and punctuation in the user's text. Rules:
            - Keep the original language, meaning, tone, and formatting (line breaks, lists).
            - Keep English tech/crypto terms as-is.
            - Change as little as possible — do not rephrase beyond what corrections require.
            Output ONLY the corrected text, no commentary.
            """,
            replacesSelection: true, hotkey: "ctrl+opt+cmd+g"),
        PromptPreset(
            name: "Translate to English", emoji: "🌐", systemPrompt: """
            Translate the user's text into natural, fluent English.
            Keep tech/crypto terms and proper nouns intact. Preserve formatting and line breaks.
            Output ONLY the translation.
            """,
            replacesSelection: true),
        PromptPreset(
            name: "Make it professional", emoji: "💼", systemPrompt: """
            Rewrite the user's text in a clear, professional tone suitable for work chat or email.
            Keep the original language and meaning; keep tech/crypto terms as-is. Fix grammar.
            Output ONLY the rewritten text.
            """,
            replacesSelection: true),
        PromptPreset(
            name: "To bullet points", emoji: "•", systemPrompt: """
            Rewrite the user's text as a tight bulleted list of the key points, in the same language.
            Start each line with "• ". Merge redundant points. Output ONLY the list.
            """,
            replacesSelection: false),
        PromptPreset(
            name: "Rewrite as commit message", emoji: "🔧", systemPrompt: """
            Turn the user's text into a conventional git commit message in English:
            a concise imperative subject line (≤72 chars), a blank line, then bullet details if useful.
            Output ONLY the commit message.
            """,
            replacesSelection: false),
    ]
}

/// Persists prompt presets and exposes them to the UI and the hotkey monitor.
@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()

    @Published var presets: [PromptPreset] = [] { didSet { save() } }

    // `nonisolated` because `presetsWithHotkeys()` below is deliberately
    // callable off the main actor, and an immutable String needs no isolation to
    // be read safely.
    private nonisolated static let defaultsKey = "promptPresets"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([PromptPreset].self, from: data),
           !decoded.isEmpty {
            presets = decoded
        } else {
            presets = PromptPreset.defaults
        }
    }

    func add() {
        presets.append(PromptPreset(name: "New preset", emoji: "✨",
                                    systemPrompt: "Rewrite the user's text.", replacesSelection: true))
    }

    func delete(_ preset: PromptPreset) {
        presets.removeAll { $0.id == preset.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Nonisolated snapshot for the hotkey monitor (decoded from UserDefaults).
    nonisolated static func presetsWithHotkeys() -> [PromptPreset] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([PromptPreset].self, from: data) else {
            return PromptPreset.defaults.filter { !$0.hotkey.isEmpty }
        }
        return decoded.filter { !$0.hotkey.isEmpty }
    }
}
