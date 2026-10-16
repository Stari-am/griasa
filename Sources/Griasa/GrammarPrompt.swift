import Foundation

/// The language-aware instructions behind "Fix grammar & spelling".
///
/// One prompt did not work for both languages people here write in. Told to
/// "change as little as possible", the local 9B model left real English
/// mistakes alone ("as soon as it will be available", "say me your opinion").
/// Told to make the text fluent, it rewrote Russian — switched "ты" to "вы",
/// swapped words for synonyms, dropped prepositions, and sometimes translated
/// the whole message into English. So English gets a copy editor and every
/// other language gets a careful corrector, and both are told the language
/// outright, because a small model does not keep to it on its own.
enum GrammarPrompt {
    /// Filled in by `SelectionAI` in any preset that uses them.
    static let languagePlaceholder = "{{language}}"
    static let rulesPlaceholder = "{{languageRules}}"

    /// The built-in preset's prompt. The placeholders are what make it
    /// language-aware; a person who edits the preset can keep or drop them.
    static let defaultPrompt = """
    You correct the user's text. The text is in {{language}}; write the corrected text in {{language}} — never translate it.
    {{languageRules}}
    - Keep formatting (line breaks, lists), names, product names and English tech/crypto terms as they are.
    - Do not add or remove content, and do not comment.
    Output ONLY the corrected text.
    """

    /// The prompt the preset shipped with until 1.0.18. A stored preset whose
    /// prompt is exactly this was never edited, so it moves to the new one.
    static let legacyDefaultPrompt = """
    Fix grammar, spelling, and punctuation in the user's text. Rules:
    - Keep the original language, meaning, tone, and formatting (line breaks, lists).
    - Keep English tech/crypto terms as-is.
    - Change as little as possible — do not rephrase beyond what corrections require.
    Output ONLY the corrected text, no commentary.
    """

    static func rules(english: Bool) -> String {
        english ? """
        - Act as a careful copy editor: fix every spelling, grammar (tenses, articles, prepositions, agreement, word order) and punctuation error, and any wording a native speaker would find wrong.
        - Make it read the way a fluent native speaker would write it, keeping the meaning and tone. Leave what is already correct.
        """ : """
        - Fix misspelled words, wrong endings and agreement, missing or extra commas, and words wrongly merged or split.
        - Keep every word that is already correct: no synonyms, no rewording, no change of register (informal stays informal, "ты" stays "ты"), and no added or dropped words, prepositions included.
        """
    }

    /// `languageName` is the detected language in English ("Russian"), or nil
    /// when it could not be told; `english` picks the copy-editor rules.
    static func fill(_ prompt: String, languageName: String?, english: Bool) -> String {
        prompt
            .replacingOccurrences(of: languagePlaceholder,
                                  with: languageName ?? "the same language as the text")
            .replacingOccurrences(of: rulesPlaceholder, with: rules(english: english))
    }

    /// The stored prompt after the upgrade: an untouched old default becomes
    /// the new default; anything the person wrote is left alone.
    static func migrated(_ stored: String) -> String {
        stored == legacyDefaultPrompt ? defaultPrompt : stored
    }
}
