import Foundation

/// Which language a piece of text is in, for prompts that must name it.
///
/// NaturalLanguage alone gets the Cyrillic languages wrong too often to put
/// its answer in a prompt: it called whole Russian meetings Kazakh, and a short
/// "Скинь пожалуйста ссылку…" Ukrainian, and a small model then wrote its reply
/// in that language. Cyrillic is therefore decided by letters that only one
/// language uses; NaturalLanguage, constrained to the languages Griasa
/// supports, is asked only about Latin-script text.
enum LanguageGuess {
    /// English names, for prompts.
    static let names = ["en": "English", "ru": "Russian", "uk": "Ukrainian",
                        "de": "German", "hy": "Armenian"]

    /// Letters Ukrainian has and Russian does not.
    private static let ukrainianOnly: Set<Character> = ["і", "ї", "є", "ґ", "І", "Ї", "Є", "Ґ"]
    /// Letters Russian has and Ukrainian does not.
    private static let russianOnly: Set<Character> = ["ы", "э", "ъ", "ё", "Ы", "Э", "Ъ", "Ё"]

    /// The script-level decision, Foundation only. Returns a language code for
    /// Cyrillic and Armenian text, `nil` for anything else (the caller asks
    /// NaturalLanguage about Latin text). Labels, timestamps and markup do not
    /// matter: only letters are counted.
    static func byScript(_ text: String) -> String? {
        var cyrillic = 0, armenian = 0, latin = 0, uk = 0, ru = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0530...0x058F: armenian += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            default: break
            }
        }
        for character in text {
            if ukrainianOnly.contains(character) { uk += 1 }
            if russianOnly.contains(character) { ru += 1 }
        }
        if armenian > max(cyrillic, latin) { return "hy" }
        guard cyrillic > latin else { return nil }
        // Mixed Russian and Ukrainian: the language with more of its own letters.
        return uk > ru ? "uk" : "ru"
    }
}
