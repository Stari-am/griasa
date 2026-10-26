import Foundation

/// Housekeeping for stored chats: the organisation's retention limit, and the
/// review list's own lifetime.
///
/// Foundation only, so `test.sh` can run it against a temporary database.
/// Deletion removes raw message text (and, with it, the full-text index entries
/// and the waiting batches older than the limit). It never touches day
/// summaries or promises: those are the person's list now, and the whole point
/// of a retention limit is keeping what was learned while letting the raw
/// conversation go.
enum ConversationRetention {
    struct Outcome: Equatable {
        var messages: Int
        var reviews: Int
    }

    /// `retentionDays` is `ManagedPolicy.conversationRetentionDays`: nil keeps
    /// every message. Review batches that nobody answered within
    /// `ConversationIngest.reviewLifetime` expire either way.
    @discardableResult
    static func run(store: ConversationStore, retentionDays: Int?, now: Date) throws -> Outcome {
        var removed = 0
        var expired = 0
        if let days = retentionDays, days > 0 {
            // `deleteMessages` also drops review batches older than the cutoff.
            let before = try store.reviewCount()
            removed = try store.deleteMessages(olderThan: ConversationIngest.retentionCutoff(retentionDays: days, now: now) ?? now)
            expired += before - (try store.reviewCount())
        }
        let swept = try store.expireReviews(now: now)
        expired += swept
        // Expired batches hold message text too; make it leave the file.
        if swept > 0 && removed == 0 { try store.compact() }
        return Outcome(messages: removed, reviews: expired)
    }
}
