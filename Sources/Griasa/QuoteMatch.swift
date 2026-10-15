import Foundation

/// Whether the words a model says it is quoting are really in the text it read.
///
/// A promise with no real source is the costliest thing this app can invent —
/// somebody is then told they owe something nobody asked of them — so a
/// promise is kept only when its quote is found in the input. The comparison
/// ignores case, punctuation and line breaks, because the model re-wraps what it
/// copies; it does not ignore words.
enum QuoteMatch {
    /// Shorter than this is a word or two that matches anywhere.
    static let minLength = 8

    /// Lower case, letters and digits only, one space between words.
    /// Apostrophes vanish ("don't" = "dont"); every other mark is a space.
    static func normalize(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else if ch == "'" || ch == "\u{2019}" {
                continue
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// The text a quote is looked for in, prepared once per input: speaker and
    /// time markers (`[12:30] You:`, `**Name:**`) are not speech, so a quote that
    /// runs across two lines still matches.
    static func prepare(_ text: String) -> String {
        normalize(stripMarkers(text))
    }

    static func contains(_ preparedText: String, quote: String) -> Bool {
        let wanted = normalize(stripMarkers(quote))
        guard wanted.count >= minLength else { return false }
        return preparedText.contains(wanted)
    }

    /// A timestamp the model gave, kept only if the input really shows it.
    static func visibleTimestamp(_ claimed: String?, in text: String) -> String? {
        guard let claimed = claimed?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")),
              claimed.range(of: #"^\d{1,3}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil,
              text.contains("[\(claimed)]") else { return nil }
        return claimed
    }

    private static func stripMarkers(_ text: String) -> String {
        var out = text
        for pattern in [#"\[\d{1,3}:\d{2}(:\d{2})?\]\s*(You:|Them:|📝 NOTE:)?"#, #"\*\*[^*\n]{1,40}:\*\*"#] {
            out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return out
    }
}
