import Foundation

/// Meetings that ended before the local model was ready, waiting to be
/// summarized when it is. Kept in preferences so a download that outlasts the
/// session still catches up afterwards.
///
/// Foundation only, so `test.sh` can reach it.
struct PendingSummaries: Codable, Equatable {
    private(set) var ids: [UUID]
    /// Meetings whose summary was saved but whose promises were not collected
    /// (the extraction failed after the summary was written). Their History
    /// text is no longer raw, so without this they would look done and their
    /// promises would never be looked for.
    private(set) var extractionOwed: [UUID]
    static let defaultsKey = "pendingSummaries"

    init(ids: [UUID], extractionOwed: [UUID] = []) {
        self.ids = ids
        self.extractionOwed = extractionOwed
    }

    private enum CodingKeys: String, CodingKey { case ids, extractionOwed }

    /// A queue saved before `extractionOwed` existed still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ids = try container.decode([UUID].self, forKey: .ids)
        extractionOwed = try container.decodeIfPresent([UUID].self, forKey: .extractionOwed) ?? []
    }

    mutating func add(_ id: UUID) { if !ids.contains(id) { ids.append(id) } }
    mutating func remove(_ id: UUID) {
        ids.removeAll { $0 == id }
        extractionOwed.removeAll { $0 == id }
    }

    /// The summary of `id` is saved; only its promises are still owed.
    mutating func summarySaved(_ id: UUID) {
        if ids.contains(id), !extractionOwed.contains(id) { extractionOwed.append(id) }
    }

    /// Whether the next run for `id` collects promises only (its summary is in History).
    func needsOnlyExtraction(_ id: UUID, alreadySummarized: Set<UUID>) -> Bool {
        extractionOwed.contains(id) && alreadySummarized.contains(id)
    }

    /// The oldest meeting still to do. `skipping` holds ids passed over this
    /// round (one already being worked on by hand), so the rest still run.
    func next(existing: Set<UUID>, alreadySummarized: Set<UUID>, skipping: Set<UUID> = []) -> UUID? {
        ids.first {
            existing.contains($0) && !skipping.contains($0)
                && (!alreadySummarized.contains($0) || extractionOwed.contains($0))
        }
    }

    /// Drops meetings that are gone, and ones summarized meanwhile (by hand)
    /// with nothing owed — never one whose promises are still owed.
    mutating func prune(existing: Set<UUID>, alreadySummarized: Set<UUID>) {
        for id in ids where !existing.contains(id) || (alreadySummarized.contains(id) && !extractionOwed.contains(id)) {
            remove(id)
        }
        extractionOwed.removeAll { !ids.contains($0) }
    }

    static func load(from data: Data?) -> PendingSummaries {
        data.flatMap { try? JSONDecoder().decode(PendingSummaries.self, from: $0) } ?? PendingSummaries(ids: [])
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
