import Foundation

// Checks for the language-aware "Fix grammar & spelling" prompt. A small local
// model edits English too timidly when told to change little, and rewrites or
// translates Russian when told to make it fluent, so the prompt must name the
// language and pick the rules for it.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runGrammarChecks() -> Int {
var failures = 0

func check(_ passed: Bool, rule: String, meaning: String, saw: String) {
    if passed { return }
    failures += 1
    print("""

    ✗ \(rule)
      why it matters: \(meaning)
      what happened:  \(saw)
    """)
}

let russian = GrammarPrompt.fill(GrammarPrompt.defaultPrompt, languageName: "Russian", english: false)
check(russian.contains("The text is in Russian; write the corrected text in Russian")
        && !russian.contains("{{"),
      rule: "the prompt names the detected language and leaves no placeholder behind",
      meaning: "told nothing, the local model sometimes answers a Russian message in English",
      saw: russian)
check(russian.contains("\"ты\" stays \"ты\"") && !russian.contains("copy editor"),
      rule: "a non-English text gets the careful rules, not the copy editor's",
      meaning: "the copy-editor rules made the model swap words and turn \"ты\" into \"вы\" in Russian",
      saw: russian)

let english = GrammarPrompt.fill(GrammarPrompt.defaultPrompt, languageName: "English", english: true)
check(english.contains("copy editor") && english.contains("fluent native speaker"),
      rule: "an English text gets the copy-editor rules",
      meaning: "with \"change as little as possible\" the model left errors like \"as soon as it will be available\"",
      saw: english)

let unknown = GrammarPrompt.fill(GrammarPrompt.defaultPrompt, languageName: nil, english: false)
check(unknown.contains("the same language as the text"),
      rule: "an undetected language still forbids translation",
      meaning: "a short or mixed selection must not come back in another language",
      saw: unknown)

check(GrammarPrompt.migrated(GrammarPrompt.legacyDefaultPrompt) == GrammarPrompt.defaultPrompt,
      rule: "the untouched old default prompt is upgraded",
      meaning: "presets are stored, so without this every existing install keeps the timid prompt",
      saw: GrammarPrompt.migrated(GrammarPrompt.legacyDefaultPrompt))
let edited = GrammarPrompt.legacyDefaultPrompt + "\nAlways use British spelling."
check(GrammarPrompt.migrated(edited) == edited,
      rule: "a prompt the person edited is left alone",
      meaning: "overwriting someone's own instructions on upgrade would silently undo their work",
      saw: GrammarPrompt.migrated(edited))

let custom = "Rewrite the user's text politely."
check(GrammarPrompt.fill(custom, languageName: "Russian", english: false) == custom,
      rule: "a prompt without placeholders is sent unchanged",
      meaning: "the language rules belong only to presets that ask for them",
      saw: GrammarPrompt.fill(custom, languageName: "Russian", english: false))

for (text, expected, why) in [
    ("Скинь пожалуйста ссылку на дашборд, я не могу его найти в конфлюенсе", "ru",
     "NaturalLanguage called this Ukrainian; the reply then came back in Ukrainian"),
    ("[00:12] You: ок, давай deploy завтра\n[00:15] Them: да, PR уже готов", "ru",
     "a Russian meeting with English terms and labels was called Kazakh"),
    ("Привіт, можеш скинути посилання на дашборд?", "uk",
     "Ukrainian must still be recognised by its own letters"),
    ("Բարև, վաղը կհանդիպենք", "hy", "Armenian has its own script"),
] {
    let got = LanguageGuess.byScript(text)
    check(got == expected,
          rule: "\(expected) text is recognised by its letters",
          meaning: why,
          saw: got ?? "nil")
}
check(LanguageGuess.byScript("I will sent you the docs tomorow") == nil,
      rule: "Latin-script text is left to NaturalLanguage",
      meaning: "letter counting can't tell English from German; the recogniser can",
      saw: LanguageGuess.byScript("I will sent you the docs tomorow") ?? "nil")

return failures
}
