import Foundation

/// Turns the recognizers' unstable partial results into text that only ever
/// grows, so live dictation never deletes a character it has already typed.
///
/// The rule is **local agreement**: a word is typed once two consecutive
/// hypotheses agree on it, and once typed it is never revised. That is the
/// LocalAgreement-2 policy from `ufal/whisper_streaming` — of the streaming
/// policies evaluated for IWSLT, agreement across two consecutive hypotheses
/// was the most effective, and it is the same idea Amazon Transcribe sells as
/// "partial results stabilization".
///
/// The previous design froze words by *position* — a word became final once two
/// more words followed it — and emitted the frozen prefix plus whatever the
/// current hypothesis said after it. Apple's recognizer re-segments constantly
/// and routinely returns a hypothesis *shorter* than the one before, at which
/// point that tail was empty and the output collapsed back to the frozen
/// prefix. The trace caught it deleting 12 characters mid-sentence: exactly the
/// "text disappears while I'm talking" the whole redesign was meant to end.
///
/// The cost of the fix is latency, not churn: the last word or two of an
/// utterance stay uncommitted until more audio confirms them, so the live text
/// trails the voice slightly. The polished transcription that lands on hotkey
/// release completes and corrects it in one edit — which is also why committed
/// words don't need to chase every capitalization and comma the recognizer
/// changes its mind about.
struct PartialStabilizer {
    /// The chosen language leg. Switching legs mid-utterance would rewrite the
    /// whole line, so the first leg to produce agreed text keeps it.
    private(set) var lockedLocale: String?
    /// Words that two hypotheses have agreed on. Append-only.
    private var committed: [String] = []
    /// Each leg's previous hypothesis, to compare the next one against.
    private var previous: [String: [String]] = [:]
    private var lastEmitted = ""
    /// True while the recognizer's hypothesis contradicts text already typed, so
    /// nothing more can be committed this utterance. Surfaced for the trace —
    /// "live typing stopped early" and "the recognizer changed its mind about
    /// the opening words" should not look the same when diagnosing.
    private(set) var diverged = false

    mutating func reset() {
        lockedLocale = nil
        committed = []
        previous = [:]
        lastEmitted = ""
        diverged = false
    }

    /// Feeds in every leg's current text and returns what should now be on
    /// screen, or nil when nothing new is stable yet.
    mutating func absorb(legs: [(locale: String, text: String)]) -> String? {
        var best: (locale: String, words: [String], agreed: Int)?

        for leg in legs where !leg.text.isEmpty {
            // After the lock, the other recognizers are still running (their
            // result decides the final transcript) but they no longer steer
            // what's on screen.
            if let lockedLocale, leg.locale != lockedLocale { continue }
            let words = leg.text.split(separator: " ").map(String.init)
            let agreed = Self.agreedWordCount(previous[leg.locale] ?? [], words)
            previous[leg.locale] = words
            let better = best.map { agreed > $0.agreed || (agreed == $0.agreed && words.count > $0.words.count) } ?? true
            if better { best = (leg.locale, words, agreed) }
        }

        guard let best else { return nil }
        // A hypothesis that has re-worded the beginning of the utterance is not
        // allowed to extend the end of it. Splicing its fifth word onto our
        // second produces text nobody said — worse than text that lags, because
        // lag corrects itself on release and a dropped word doesn't announce
        // itself at all.
        diverged = Self.agreedWordCount(committed, best.words) < committed.count
        if best.agreed > committed.count {
            // Take the newest hypothesis's spelling of the words being
            // committed — it has the most audio behind it — but only for words
            // crossing the line now. Re-spelling a word already on screen is a
            // delete-and-retype, and no punctuation is worth that.
            committed += best.words[committed.count..<best.agreed]
            lockedLocale = best.locale
        }

        let output = committed.joined(separator: " ")
        guard !output.isEmpty, output != lastEmitted else { return nil }
        lastEmitted = output
        return output
    }

    /// How many leading words two hypotheses agree on, ignoring case and edge
    /// punctuation. Apple flips "сделай"/"Сделай" and adds commas as context
    /// grows; treating those as disagreement would stall commitment on a word
    /// the recognizer is actually sure about.
    static func agreedWordCount(_ previous: [String], _ current: [String]) -> Int {
        var count = 0
        while count < previous.count && count < current.count
            && key(previous[count]) == key(current[count]) {
            count += 1
        }
        return count
    }

    private static func key(_ word: String) -> String {
        word.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}
