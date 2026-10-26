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
            removed = try store.deleteMessages(olderThan: now.addingTimeInterval(-Double(days) * 86_400))
            expired += before - (try store.reviewCount())
        }
        let swept = try store.expireReviews(now: now)
        expired += swept
        // Expired batches hold message text too; make it leave the file.
        if swept > 0 && removed == 0 { try store.compact() }
        return Outcome(messages: removed, reviews: expired)
    }

    /// At launch and once a day, off the main thread: a VACUUM on a large
    /// database is not instant.
    static func runLive(now: Date = Date()) {
        let days = ManagedPolicy.live.conversationRetentionDays
        Task.detached(priority: .utility) {
            guard let store = try? ConversationStore.live() else { return }
            if let outcome = try? run(store: store, retentionDays: days, now: now),
               outcome.messages > 0 || outcome.reviews > 0 {
                NSLog("Griasa: conversation retention removed %d message(s) and %d waiting batch(es)",
                      outcome.messages, outcome.reviews)
            }
        }
    }
}
