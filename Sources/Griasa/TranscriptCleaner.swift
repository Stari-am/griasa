import Foundation

/// One recognised stretch of speech, positioned on the recording's timeline.
struct TranscriptSegment {
    let start: TimeInterval
    let text: String
}

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

    /// What Whisper produces for a short burst of noise — a cough, a keyboard,
    /// a chair — that the voice detector let through as speech. Measured on a
    /// real meeting: sub-second regions of the system-audio track, each sent to
    /// the server on its own, came back as exactly "Thank you." while nobody
    /// had said it. Neither of the server's confidence signals could tell them
    /// from real speech — `no_speech_prob` was 0.000 on every region, genuine or
    /// not, and `avg_logprob` overlapped completely.
    ///
    /// So the rule is about the *whole* segment, never a substring: a region
    /// whose entire text is one of these. "Okay, thank you, next item" is left
    /// alone. That still drops the occasional real, isolated "thank you", and
    /// that is the right trade — it carries no fact, no decision and no promise,
    /// while a transcript punctuated by people thanking nobody is exactly the
    /// thing that makes it unreadable.
    private static let bareCourtesy: Set<String> = [
        "thank you",
        "thank you very much",
        "thanks",
        "спасибо",
        "спасибо большое",
    ]

    /// - Parameter meeting: true for a recorded meeting, where a region is cut
    ///   out of a long recording by a voice detector and so can be pure noise.
    ///   False for dictation, where "thank you" is very often exactly what the
    ///   person meant to type into a chat, and must arrive.
    static func clean(_ segments: [TranscriptSegment], meeting: Bool = false) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            let norm = normalize(segment.text)
            // Empty / punctuation-only ("...") segments.
            guard !norm.isEmpty else { continue }
            // Known silence hallucinations.
            if hallucinationMarkers.contains(where: { norm.contains($0) }) { continue }
            // Noise decoded as a pleasantry — meetings only, whole segment only.
            if meeting, bareCourtesy.contains(norm) { continue }
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
