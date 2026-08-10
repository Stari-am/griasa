import Foundation

/// Lifetime dictation counters — the number that shows what the app is
/// worth. Speaking runs ~150 wpm against ~40 wpm typing, so every dictated
/// word saves the difference.
@MainActor
final class UsageStats: ObservableObject {
    static let shared = UsageStats()

    @Published private(set) var words: Int
    @Published private(set) var sessions: Int

    private static let wordsKey = "statsWordsDictated"
    private static let sessionsKey = "statsDictationCount"
    private static let typingWPM = 40.0
    private static let speakingWPM = 150.0

    private init() {
        let defaults = UserDefaults.standard
        words = defaults.integer(forKey: Self.wordsKey)
        sessions = defaults.integer(forKey: Self.sessionsKey)
    }

    func recordDictation(_ text: String) {
        let count = text.split(whereSeparator: \.isWhitespace).count
        guard count > 0 else { return }
        words += count
        sessions += 1
        let defaults = UserDefaults.standard
        defaults.set(words, forKey: Self.wordsKey)
        defaults.set(sessions, forKey: Self.sessionsKey)
    }

    var minutesSaved: Double {
        Double(words) * (1 / Self.typingWPM - 1 / Self.speakingWPM)
    }

    /// e.g. "12,340 words dictated · ~4 h 5 min saved vs typing"
    var summary: String? {
        guard sessions > 0 else { return nil }
        let minutes = Int(minutesSaved.rounded())
        let time: String
        if minutes < 1 {
            time = "under a minute"
        } else if minutes < 60 {
            time = "\(minutes) min"
        } else {
            time = "\(minutes / 60) h \(minutes % 60) min"
        }
        return "\(words.formatted()) words dictated · ~\(time) saved vs typing"
    }
}
