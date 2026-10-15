import Foundation
import NaturalLanguage

/// The dominant language of a meeting, by name in English ("Russian"), for the
/// instruction that tells the model what to write in.
enum MeetingLanguage {
    static func name(of text: String) -> String? {
        // The time and speaker markers are English-looking noise.
        let sample = String(text.prefix(20_000))
            .replacingOccurrences(of: #"\[\d{1,3}:\d{2}(:\d{2})?\]|\b(You|Them):|📝 NOTE:|\*\*|#"#, with: " ",
                                  options: .regularExpression)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.5 else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue)
    }
}
