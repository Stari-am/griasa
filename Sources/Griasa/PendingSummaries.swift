import Foundation

/// Meetings that ended before the local model was ready, waiting to be
/// summarized when it is. Kept in preferences so a download that outlasts the
/// session still catches up afterwards.
///
/// Foundation only, so `test.sh` can reach it.
struct PendingSummaries: Codable, Equatable {
    private(set) var ids: [UUID]
    static let defaultsKey = "pendingSummaries"

    init(ids: [UUID]) { self.ids = ids }

    mutating func add(_ id: UUID) { if !ids.contains(id) { ids.append(id) } }
    mutating func remove(_ id: UUID) { ids.removeAll { $0 == id } }

    func next(existing: Set<UUID>, alreadySummarized: Set<UUID>) -> UUID? {
        ids.first { existing.contains($0) && !alreadySummarized.contains($0) }
    }

    static func load(from data: Data?) -> PendingSummaries {
        data.flatMap { try? JSONDecoder().decode(PendingSummaries.self, from: $0) } ?? PendingSummaries(ids: [])
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
