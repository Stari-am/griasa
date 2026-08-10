import Foundation
import Speech

/// The dictation languages this Mac can actually recognize.
///
/// The setting used to be a free-text field, which is how it ended up empty and
/// left dictation with no recognizer at all. Offering only what
/// `SFSpeechRecognizer` reports as supported removes both failure modes at once:
/// a typo'd locale code and an empty list.
enum SpeechLocales {
    struct Choice: Identifiable, Hashable {
        let id: String    // hyphenated, e.g. "en-US"
        let name: String  // localized, e.g. "English (United States)"
    }

    /// Stored and passed around with hyphens. `Locale.identifier` yields
    /// underscores ("en_US"), and while the recognizer accepts either, mixing
    /// the two forms would break every comparison against a stored value.
    static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    static let available: [Choice] = {
        let display = Locale.current
        return SFSpeechRecognizer.supportedLocales()
            .map { locale in
                let id = normalize(locale.identifier)
                return Choice(id: id,
                              name: display.localizedString(forIdentifier: locale.identifier) ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// A display name for a stored identifier, including ones this Mac no longer
    /// supports — a language that disappeared shouldn't vanish silently from the
    /// settings summary.
    static func name(for identifier: String) -> String {
        let id = normalize(identifier)
        if let match = available.first(where: { $0.id == id }) { return match.name }
        return Locale.current.localizedString(forIdentifier: identifier) ?? id
    }

    static func isSupported(_ identifier: String) -> Bool {
        available.contains { $0.id == normalize(identifier) }
    }
}
