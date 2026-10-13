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

    /// Promises for `id` were collected outside the catch-up (History's
    /// Re-summarize or Find commitments). A meeting that owed only its
    /// promises is then done; one still waiting for its summary stays, since
    /// promises found in raw text do not replace the summary.
    mutating func promisesCollected(_ id: UUID) {
        if extractionOwed.contains(id) { remove(id) }
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

    /// How long a meeting queued in this session is left alone. It was queued
    /// because its summary just failed, often on a slow, short-of-memory
    /// engine that is still busy with the same meeting's closure detection;
    /// retrying at once would compete with it for the one slot.
    static let freshGrace: TimeInterval = 600

    /// Whether a meeting queued at `queuedAt` is passed over this round.
    /// Meetings with no time (queued in an earlier session) are never skipped.
    static func isFresh(queuedAt: Date?, now: Date, grace: TimeInterval = freshGrace) -> Bool {
        guard let queuedAt else { return false }
        return now.timeIntervalSince(queuedAt) < grace
    }

    static func load(from data: Data?) -> PendingSummaries {
        data.flatMap { try? JSONDecoder().decode(PendingSummaries.self, from: $0) } ?? PendingSummaries(ids: [])
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
