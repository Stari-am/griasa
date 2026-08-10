import Foundation

/// Collapses the repetition loops Whisper falls into.
///
/// Whisper's decoder can get stuck emitting the same phrase over and over —
/// documented at length in `ggml-org/whisper.cpp` (#1507, #412, and #1017,
/// where a persistent `--prompt` is the trigger). Decoder settings make it
/// rarer; they cannot make it impossible. Nothing upstream of this is allowed
/// to decide whether the user's document receives seven copies of a sentence
/// they said once, so the guarantee lives here, in code that can be tested.
///
/// Deliberately conservative: only *consecutive* repeats collapse, and only
/// from the third occurrence on. People really do say "да, да, да" and "no no",
/// and losing that is a worse failure than leaving one extra copy behind.
enum SpeechRepetition {
    /// Number of back-to-back copies that stops being emphasis and starts being
    /// a decoder loop.
    private static let loopThreshold = 3
    /// Longest phrase, in words, checked for looping.
    private static let maxBlockWords = 12

    /// How many back-to-back copies survive. Emphasis in speech is almost always
    /// a single word — "да да да", "no no no" — and flattening that changes what
    /// the speaker said. A whole phrase repeated three times is not emphasis; it
    /// is the decoder stuck in a loop, and one copy is the honest transcript.
    private static func copiesToKeep(words: Int) -> Int { words >= 2 ? 1 : 2 }

    private static func copiesToKeep(wordsIn sentence: String) -> Int {
        copiesToKeep(words: sentence.split(separator: " ").count)
    }

    /// Returns the text with loops collapsed, and how many copies were dropped.
    static func collapse(_ text: String) -> (text: String, dropped: Int) {
        let sentences = split(text)
        guard sentences.count > 1 else { return collapseWordBlocks(text) }

        var kept: [String] = []
        var dropped = 0
        var run = 1
        var previous: String?
        for sentence in sentences {
            if let previous, similar(previous, sentence) {
                run += 1
                if run > copiesToKeep(wordsIn: sentence) {
                    dropped += 1
                    continue  // `previous` stays put: the loop is still running.
                }
            } else {
                run = 1
            }
            kept.append(sentence)
            previous = sentence
        }

        let joined = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = collapseWordBlocks(joined)
        return (blocks.text, dropped + blocks.dropped)
    }

    /// Whisper's loop usually alternates between near-identical renderings —
    /// "Тестирую набор данных." / "Тестиру набор данных." — rather than repeating
    /// one exact string, so exact comparison sees no repetition at all. A word
    /// dropped here or a comma added there still has to count as the same copy.
    private static func similar(_ a: String, _ b: String) -> Bool {
        let left = key(a), right = key(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let shorter = min(left.count, right.count)
        // A repeat that differs by more than an eighth of its length is a
        // different sentence, not a stutter.
        let budget = max(1, shorter / 8)
        guard abs(left.count - right.count) <= budget else { return false }
        return editDistance(Array(left), Array(right), limit: budget) <= budget
    }

    /// Levenshtein, abandoned as soon as it exceeds `limit`.
    private static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowBest = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
                rowBest = min(rowBest, current[j])
            }
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Catches loops with no sentence punctuation at all: the same run of words
    /// repeated back to back.
    private static func collapseWordBlocks(_ text: String) -> (text: String, dropped: Int) {
        var words = text.split(separator: " ").map(String.init)
        var dropped = 0
        var changed = true
        while changed {
            changed = false
            // Longest block first: collapsing "a b a b a b" as a 2-word loop is
            // right, as three 1-word loops is wrong.
            for size in stride(from: min(maxBlockWords, words.count / loopThreshold), through: 1, by: -1) {
                guard let start = loopStart(in: words, blockSize: size) else { continue }
                let blockEnd = start + size
                var cursor = blockEnd
                while cursor + size <= words.count,
                      keys(Array(words[cursor..<cursor + size])) == keys(Array(words[start..<blockEnd])) {
                    cursor += size
                }
                let keepEnd = min(start + size * copiesToKeep(words: size), cursor)
                guard keepEnd < cursor else { continue }
                dropped += (cursor - keepEnd) / size
                words.removeSubrange(keepEnd..<cursor)
                changed = true
                break
            }
        }
        return (words.joined(separator: " "), dropped)
    }

    /// First index where a block of `blockSize` words repeats `loopThreshold`
    /// times in a row.
    private static func loopStart(in words: [String], blockSize: Int) -> Int? {
        guard blockSize > 0, words.count >= blockSize * loopThreshold else { return nil }
        for start in 0...(words.count - blockSize * loopThreshold) {
            let block = keys(Array(words[start..<start + blockSize]))
            guard !block.allSatisfy(\.isEmpty) else { continue }
            var repeats = 1
            var cursor = start + blockSize
            while cursor + blockSize <= words.count,
                  keys(Array(words[cursor..<cursor + blockSize])) == block {
                repeats += 1
                cursor += blockSize
            }
            if repeats >= loopThreshold { return start }
        }
        return nil
    }

    private static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?…\n".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        return sentences
    }

    private static func keys(_ words: [String]) -> [String] { words.map(key) }

    /// Whisper's copies differ in punctuation and case, and sometimes by a
    /// dropped letter; comparing loosely is what lets the loop be seen at all.
    private static func key(_ text: String) -> String {
        text.lowercased().filter { !$0.isPunctuation && !$0.isWhitespace }
    }
}
