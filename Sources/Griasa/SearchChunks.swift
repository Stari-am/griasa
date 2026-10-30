import Foundation

/// Cuts a meeting's text into the pieces search ranks.
///
/// A whole meeting is too coarse to embed: an hour of talk averages into a vector
/// that is close to nothing in particular. About 800 characters is a minute or
/// two of conversation — one topic, usually — and short enough for any
/// embedding model's context. Cuts fall between lines, never inside one, and
/// each piece repeats the last ~100 characters of lines before it, so a sentence
/// at a boundary is whole in at least one piece. A line longer than a piece — a
/// monologue the recogniser never broke — is first cut at spaces.
///
/// Foundation only, so the rule is checked without the app.
enum SearchChunks {
    static let target = 800
    static let overlap = 100

    static func split(_ text: String) -> [String] {
        var chunks: [String] = []
        var current: [Substring] = []
        var size = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).flatMap(shortened) {
            if size + line.count > target, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                var kept: [Substring] = []
                var keptSize = 0
                for previous in current.reversed() {
                    if keptSize + previous.count > overlap { break }
                    kept.insert(previous, at: 0)
                    keptSize += previous.count
                }
                current = kept
                size = keptSize
            }
            current.append(line)
            size += line.count + 1
        }
        let last = current.joined(separator: "\n")
        if !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(last) }
        return chunks
    }

    /// A line no longer than a piece, or the line cut at spaces into such parts
    /// (at the limit itself when a stretch has no space).
    private static func shortened(_ line: Substring) -> [Substring] {
        guard line.count > target else { return [line] }
        var parts: [Substring] = []
        var rest = line
        while rest.count > target {
            let limit = rest.index(rest.startIndex, offsetBy: target)
            let cut = rest[..<limit].lastIndex(of: " ") ?? limit
            parts.append(rest[..<cut])
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        if !rest.isEmpty { parts.append(rest) }
        return parts
    }
}
