import Foundation
import NaturalLanguage

/// The dominant language of a meeting, by name in English ("Russian"), for the
/// instruction that tells the model what to write in.
///
/// An unconstrained recognizer read Russian meetings as Kazakh, and the notes
/// came back in Kazakh. So it chooses only among the languages Griasa supports
/// and the ones the person dictates in, and below 0.6 confidence nothing is
/// named: the instruction then says "the language the speakers use".
enum MeetingLanguage {
    static let supported = ["en", "ru", "uk", "de", "hy"]

    /// Language codes from a locale list such as "ru-RU, en-US".
    static func codes(fromLocales text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ", ;\n"))
            .compactMap { $0.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } }
            .filter { $0.count == 2 || $0.count == 3 }
    }

    static func allowed(dictationLocales: [String]) -> [String] {
        var seen = Set<String>()
        return (supported + dictationLocales.flatMap(codes(fromLocales:))).filter { seen.insert($0).inserted }
    }

    /// Speech without the time, speaker and note markers.
    static func speech(_ text: String) -> String {
        var out = String(text.prefix(20_000))
        for pattern in [#"\[\d{1,3}:\d{2}(:\d{2})?\]"#, #"\*\*[^*\n]{1,40}:\*\*"#, #"(?m)^\s*(You|Them):"#, #"📝 NOTE:|\*\*|^#+ "#] {
            out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return out
    }

    static func name(of text: String, dictationLocales: [String]? = nil) -> String? {
        let locales = dictationLocales ?? ["dictationLocales", "dictationLocale"]
            .compactMap { UserDefaults.standard.string(forKey: $0) }
        let codes = allowed(dictationLocales: locales)
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = codes.map { NLLanguage(rawValue: $0) }
        recognizer.languageHints = [.russian: 0.4, .english: 0.3]
        recognizer.processString(speech(text))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.6, codes.contains(language.rawValue) else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue)
    }
}
