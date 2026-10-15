import Foundation

/// One line of the raw merged transcript, as `MeetingTranscriber` writes it:
/// `[mm:ss] You: …`, `[mm:ss] Them: …`, or a typed note `[mm:ss] 📝 NOTE: …`.
/// Anything else (the continuation of a line that was cut for length, a blank
/// line) is `.other` and belongs to whatever came before it.
///
/// Foundation only, like the chunker and assembler that read it, so `test.sh`
/// can reach all three.
enum RawLine: Equatable {
    case speech(seconds: Int, speaker: String, text: String)
    case note(seconds: Int, text: String)
    case other(String)

    static func parse(_ line: String) -> RawLine {
        guard let seconds = timestamp(of: line), let close = line.firstIndex(of: "]") else { return .other(line) }
        let rest = line[line.index(after: close)...].drop { $0 == " " }
        if rest.hasPrefix("📝 NOTE:") {
            let text = rest.dropFirst("📝 NOTE:".count).trimmingCharacters(in: .whitespaces)
            return .note(seconds: seconds, text: text)
        }
        for speaker in ["You", "Them"] where rest.hasPrefix(speaker + ":") {
            let text = rest.dropFirst(speaker.count + 1).trimmingCharacters(in: .whitespaces)
            return .speech(seconds: seconds, speaker: speaker, text: text)
        }
        return .other(line)
    }

    /// The leading `[mm:ss]` (or `[h:mm:ss]`) of a line, in seconds.
    static func timestamp(of line: String) -> Int? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              line.distance(from: line.startIndex, to: close) <= 10 else { return nil }
        let parts = line[line.index(after: line.startIndex)..<close].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }

    static func isNote(_ line: String) -> Bool {
        if case .note = parse(line) { return true }
        return false
    }

    /// `mm:ss`, minutes growing past 59 for a long meeting, as the recorder writes it.
    static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct TranscriptChunk: Equatable {
    let index: Int
    /// The lines that are new in this chunk.
    let body: String
    /// The last lines of the previous chunk, for a sentence that crosses the
    /// cut. Empty for the first chunk.
    let overlap: String
    let startSeconds: Int?
    let endSeconds: Int?

    var rangeLabel: String {
        guard let startSeconds, let endSeconds else { return "" }
        return "\(RawLine.clock(startSeconds))–\(RawLine.clock(endSeconds))"
    }

    static let contextOpen = "[Already covered — context only. Do not report anything from this part again.]"
    static let contextClose = "[End of context. The new part of the meeting starts here.]"

    /// What the model reads: the overlap, marked, then the new lines. A chunk
    /// with no overlap is its body unchanged.
    var modelInput: String {
        overlap.isEmpty ? body : "\(Self.contextOpen)\n\(overlap)\n\(Self.contextClose)\n\(body)"
    }
}

/// Cuts a long transcript into pieces a small local model reads well.
///
/// A 9B model given 38,000 characters at once is slow and forgets the middle; the
/// same text in 20,000-character pieces, each followed by one merge, covers the
/// whole meeting — where the single pass kept only its end. The cuts are at
/// line boundaries, each piece repeats the tail of the one before it (marked as
/// context, so a sentence that crosses a cut is neither lost nor counted
/// twice), and a typed note stays with the line it was written beside.
enum TranscriptChunker {
    static let maxChars = 20_000
    static let overlapChars = 1_500

    /// The part size for a model whose request budget is `contextCharLimit`
    /// characters: the 20,000 default, smaller when the model's window is, leaving
    /// room for the overlap, the instructions and the reply.
    static func chunkSize(contextCharLimit: Int) -> Int {
        min(maxChars, max(4_000, contextCharLimit - 6_000))
    }

    /// Whether a transcript of this length is worth the map/reduce path: only on
    /// a local model, and only when one request would not hold it. Cloud models
    /// read the whole meeting in one request.
    static func shouldChunk(isLocal: Bool, characters: Int, maxChars: Int = TranscriptChunker.maxChars) -> Bool {
        isLocal && characters > maxChars
    }

    static func chunks(_ text: String, maxChars: Int = TranscriptChunker.maxChars,
                       overlapChars: Int = TranscriptChunker.overlapChars) -> [TranscriptChunk] {
        let maxChars = max(maxChars, 2)
        let overlapChars = min(overlapChars, maxChars / 4)
        guard text.count > maxChars else {
            return [make(index: 0, lines: [text], overlap: [], whole: text)]
        }
        // A single line longer than a chunk is cut at a sentence end or a space;
        // no text is dropped.
        let pieces = text.components(separatedBy: "\n").flatMap { line in
            line.count > maxChars ? split(line, into: maxChars) : [line]
        }
        // A typed note travels with the line before it, unless that would not fit.
        var units: [[String]] = []
        for piece in pieces {
            if RawLine.isNote(piece), let last = units.last,
               size(of: last) + 1 + piece.count <= maxChars {
                units[units.count - 1].append(piece)
            } else {
                units.append([piece])
            }
        }
        var bodies: [[String]] = []
        var current: [String] = []
        for unit in units {
            if !current.isEmpty, size(of: current) + 1 + size(of: unit) > maxChars {
                bodies.append(current)
                current = []
            }
            current += unit
        }
        if !current.isEmpty { bodies.append(current) }

        return bodies.enumerated().map { index, lines in
            make(index: index, lines: lines,
                 overlap: index == 0 ? [] : tail(of: bodies[index - 1], upTo: overlapChars), whole: nil)
        }
    }

    private static func make(index: Int, lines: [String], overlap: [String], whole: String?) -> TranscriptChunk {
        let times = lines.compactMap { RawLine.timestamp(of: $0) }
        return TranscriptChunk(index: index, body: whole ?? lines.joined(separator: "\n"),
                               overlap: overlap.joined(separator: "\n"),
                               startSeconds: times.first, endSeconds: times.last)
    }

    private static func size(of lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.count } + max(lines.count - 1, 0)
    }

    /// The last whole lines of a chunk that fit the overlap budget. A note
    /// at the very start is dropped: its line is not here. When even the last
    /// line is too long, its end is used from a word boundary.
    private static func tail(of lines: [String], upTo budget: Int) -> [String] {
        var taken: [String] = []
        for line in lines.reversed() {
            if size(of: [line] + taken) > budget { break }
            taken.insert(line, at: 0)
        }
        if taken.isEmpty, let last = lines.last, budget > 0, !RawLine.isNote(last) {
            var end = String(last.suffix(budget))
            if end.count < last.count, let space = end.firstIndex(of: " ") {
                end = String(end[end.index(after: space)...])
            }
            return end.isEmpty ? [] : [end]
        }
        while let first = taken.first, RawLine.isNote(first) { taken.removeFirst() }
        return taken
    }

    /// Splits one long line into pieces of at most `limit` characters, at the
    /// last sentence end in the second half of the window, else the last space,
    /// else exactly at the limit. The pieces joined are the original line.
    static func split(_ line: String, into limit: Int) -> [String] {
        var out: [String] = []
        var rest = Substring(line)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let half = window.index(window.startIndex, offsetBy: limit / 2)
            var cut = window.endIndex
            if let end = sentenceEnd(in: window, from: half) {
                cut = end
            } else if let space = window.lastIndex(of: " "), space > window.startIndex {
                cut = window.index(after: space)
            }
            out.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }

    private static func sentenceEnd(in window: Substring, from half: Substring.Index) -> Substring.Index? {
        var index = window.endIndex
        while index > half {
            index = window.index(before: index)
            guard ".!?…。".contains(window[index]) else { continue }
            let next = window.index(after: index)
            if next < window.endIndex, window[next] == " " { return window.index(after: next) }
        }
        return nil
    }
}
