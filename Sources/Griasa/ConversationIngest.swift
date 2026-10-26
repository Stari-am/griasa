import Foundation

/// What an assistant or the local endpoint hands Griasa: one chat and some of
/// its messages. Property names are the wire names, so the Codable shape is the
/// documented shape.
struct IngestBatch: Codable {
    struct Chat: Codable {
        var id: String
        var title: String
        var type: String?
    }
    struct Message: Codable {
        var id: String
        var author_id: String?
        var author: String
        /// ISO-8601, with or without a time zone (without: the Mac's).
        var at: String
        var text: String
        var is_mine: Bool?
        var forwarded_from: String?
    }
    var source: String
    var chat: Chat
    /// The person's own name or id in this chat, for sources that cannot mark
    /// each message.
    var me: String?
    var messages: [Message]
}

enum IngestError: LocalizedError, Equatable {
    case tooManyChats
    case tooManyMessages
    case badSource
    case badDate
    case missingChat

    var errorDescription: String? {
        switch self {
        case .tooManyChats: return "Too many chats in one request (the limit is \(ConversationIngest.maxChats))."
        case .tooManyMessages: return "Too many messages in one request (the limit is \(ConversationIngest.maxMessages))."
        case .badSource: return "The source must be one of: \(ConversationIngest.sources.joined(separator: ", "))."
        case .badDate: return "A message has a date that is not ISO-8601 (for example 2026-10-26T14:30:00Z)."
        case .missingChat: return "A chat needs an id."
        }
    }
}

/// The one door every conversation goes through, whichever way it arrived:
/// check it, turn it into stored messages, and say which days are new work.
enum ConversationIngest {
    static let sources = ["telegram", "slack", "whatsapp", "imessage", "other"]
    static let maxChats = 50
    static let maxMessages = 2_000

    // Pending review list: past these, new batches are refused rather than
    // letting anything on the machine fill the disk or push out the older ones.
    static let maxReviewBatches = 200
    static let maxReviewMessages = 20_000
    static let reviewLifetime: TimeInterval = 14 * 86_400

    /// Checks the limits and shapes, and drops messages with no text (a sticker
    /// has nothing to summarize; that is not an error). The limits count what
    /// was sent, so a request cannot hide its size in blank messages.
    static func validate(_ batches: [IngestBatch]) -> Result<[IngestBatch], IngestError> {
        if batches.count > maxChats { return .failure(.tooManyChats) }
        if batches.reduce(0, { $0 + $1.messages.count }) > maxMessages { return .failure(.tooManyMessages) }

        var cleaned: [IngestBatch] = []
        for var batch in batches {
            guard sources.contains(batch.source) else { return .failure(.badSource) }
            guard !batch.chat.id.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.missingChat) }
            batch.messages = batch.messages.filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            for m in batch.messages where date(m.at) == nil { return .failure(.badDate) }
            cleaned.append(batch)
        }
        return .success(cleaned)
    }

    /// A validated batch as the store keeps it. `isMine` is the caller's word if
    /// given, otherwise "the author is `me`", by id or by name.
    static func stored(_ batch: IngestBatch) -> (ChatRef, [StoredMessage]) {
        let ref = ChatRef(source: batch.source, sourceChatID: batch.chat.id,
                          title: batch.chat.title, type: batch.chat.type ?? "unknown")
        let me = batch.me?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func same(_ a: String?) -> Bool {
            guard let me, !me.isEmpty, let a else { return false }
            return a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == me
        }
        let messages = batch.messages.compactMap { m -> StoredMessage? in
            guard let sentAt = date(m.at) else { return nil }
            return StoredMessage(sourceMessageID: m.id, authorID: m.author_id, authorName: m.author,
                                 sentAt: sentAt, text: m.text,
                                 isMine: m.is_mine ?? (same(m.author_id) || same(m.author)),
                                 forwardedFrom: m.forwarded_from)
        }
        return (ref, messages)
    }

    /// Stores a validated batch; returns (chat id, day) for each day with new
    /// messages. Messages already stored add nothing, so offering the same chat
    /// again (a re-import, an assistant re-sending) costs no model work.
    static func accept(into store: ConversationStore, batch: IngestBatch,
                       timeZone: TimeZone) throws -> [(Int64, String)] {
        let (ref, messages) = stored(batch)
        let chat = try store.upsertChat(ref, myID: batch.me)
        return try store.insert(messages, chat: chat, timeZone: timeZone).map { (chat, $0) }
    }

    /// Whether the review list has room for a batch of `newMessages`, given
    /// what it holds now.
    static func reviewAdmit(count: Int, messages: Int, newMessages: Int) -> Bool {
        count < maxReviewBatches && messages + newMessages <= maxReviewMessages
    }

    static func expired(receivedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(receivedAt) > reviewLifetime
    }

    private static func date(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        // No zone given: the Mac's own.
        let local = ISO8601DateFormatter()
        local.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        local.timeZone = .current
        return local.date(from: s)
    }
}
