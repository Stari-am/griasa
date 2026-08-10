import Foundation

/// Defense-in-depth against Whisper hallucinations: even with VAD enabled,
/// occasional stuck-loop repeats or training-data artifacts ("Спасибо за
/// субтитры…", "Thanks for watching") can slip through on near-silent audio.
enum TranscriptCleaner {
    /// Phrases Whisper is known to hallucinate on silence (learned from
    /// YouTube subtitle credits and outros). Matched case-insensitively
    /// against normalized segment text.
    private static let hallucinationMarkers: [String] = [
        "спасибо за субтитры",
        "субтитры сделал",
        "субтитры делал",
        "субтитры создавал",
        "редактор субтитров",
        "корректор субтитров",
        "продолжение следует",
        "подписывайтесь на канал",
        "ставьте лайк",
        "dimatorzok",
        "thank you for watching",
        "thanks for watching",
        "please subscribe",
        "see you in the next video",
    ]

    static func clean(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            let norm = normalize(segment.text)
            // Empty / punctuation-only ("...") segments.
            guard !norm.isEmpty else { continue }
            // Known silence hallucinations.
            if hallucinationMarkers.contains(where: { norm.contains($0) }) { continue }
            // Collapse consecutive repeats of the same phrase — a stuck
            // decoder emits the identical line dozens of times in a row;
            // real speech virtually never does.
            if let last = result.last, normalize(last.text) == norm { continue }
            result.append(segment)
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
