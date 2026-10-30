import Foundation
import CryptoKit

/// How meeting pieces are stored as vectors and ranked against a query.
///
/// A vector is kept as one byte per dimension plus a scale: the largest
/// absolute value maps to 127. For a 1024-dimension model that is 1 KB a piece
/// instead of 4, and the ranking it gives is the same to the second decimal of
/// the cosine. Float16 would be the obvious choice, but it does not exist on
/// Intel Macs, which Griasa still builds for.
///
/// Foundation only, so the rule is checked without the app.
enum SearchVectors {
    struct Packed: Equatable {
        var scale: Float
        var values: [Int8]
    }

    static func pack(_ vector: [Float]) -> Packed {
        let largest = vector.reduce(0) { max($0, abs($1)) }
        guard largest > 0 else { return Packed(scale: 0, values: Array(repeating: 0, count: vector.count)) }
        let scale = largest / 127
        return Packed(scale: scale, values: vector.map { Int8(max(-127, min(127, ($0 / scale).rounded()))) })
    }

    /// The bytes stored: the scale (4 bytes, little-endian) then the values.
    static func encode(_ packed: Packed) -> Data {
        var data = Data()
        withUnsafeBytes(of: packed.scale.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        packed.values.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func decode(_ data: Data) -> Packed? {
        guard data.count >= 4 else { return nil }
        let bits = data.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        return Packed(scale: Float(bitPattern: bits), values: data.dropFirst(4).map { Int8(bitPattern: $0) })
    }

    /// The dot product of a full query vector with a packed piece.
    static func dot(_ query: [Float], _ piece: Packed) -> Float {
        var sum: Float = 0
        let n = min(query.count, piece.values.count)
        piece.values.withUnsafeBufferPointer { values in
            for i in 0..<n { sum += query[i] * Float(values[i]) }
        }
        return sum * piece.scale
    }

    /// What decides whether a meeting's pieces are stale: its text, hashed.
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct Piece {
        var entry: UUID
        var text: String
        var vector: Packed
    }

    /// Meetings ranked by their closest piece, best first, with that piece.
    /// Only meetings in `among` count, so a person or project filter applied
    /// before still holds.
    static func rankMeetings(_ query: [Float], pieces: [Piece], among: Set<UUID>,
                             limit: Int) -> [(entry: UUID, score: Float, piece: String)] {
        var best: [UUID: (score: Float, piece: String)] = [:]
        for piece in pieces where among.contains(piece.entry) {
            let score = dot(query, piece.vector)
            if score > best[piece.entry]?.score ?? -.infinity { best[piece.entry] = (score, piece.text) }
        }
        return best.map { (entry: $0.key, score: $0.value.score, piece: $0.value.piece) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.uuidString < $1.entry.uuidString }
            .prefix(limit)
            .map { $0 }
    }

    /// About 200 characters of a piece, from its start, cut at a space: shown
    /// as `matched` when the model, not a word, found the meeting.
    static func excerpt(_ piece: String) -> String {
        let flat = piece.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > 200 else { return flat }
        let head = flat.prefix(200)
        let cut = head.lastIndex(of: " ") ?? head.endIndex
        return String(head[..<cut]) + "…"
    }
}
