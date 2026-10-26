import Foundation

/// The rules of the "Import Chats" sheet, kept out of the view so test.sh can
/// check them. Foundation only.
enum ConversationImportRules {
    static let defaultDays = 7
    static let defaultMessages = 200
    static let maxDays = 3_650
    static let maxMessages = 100_000

    /// The key `UserDefaults` keeps the person's own account under, per source.
    static func meKey(source: String) -> String { "conversationMe.\(source)" }

    static func key(_ ref: ChatRef) -> String { "\(ref.source)|\(ref.sourceChatID)" }

    /// A chat imported before is ticked again: the person is most likely
    /// topping it up. A chat with nothing to read is never ticked.
    static func preTicked(_ chat: ExportedChat, known: Set<String>) -> Bool {
        chat.messageCount > 0 && known.contains(key(chat.ref))
    }

    /// The window a typed number means: at least 1, and capped so a stray
    /// extra digit cannot ask for ten million days.
    static func window(days: Bool, amount: Int) -> Window {
        days ? .days(min(max(amount, 1), maxDays)) : .messages(min(max(amount, 1), maxMessages))
    }

    /// How many messages the window keeps, without building the trimmed chat:
    /// the sheet shows it for every row each time the window changes.
    static func keptCount(_ chat: ExportedChat, window: Window, now: Date) -> Int {
        switch window {
        case .messages(let n): return min(chat.messageCount, max(n, 0))
        case .days(let n):
            let cutoff = now.addingTimeInterval(-Double(max(n, 0)) * 86_400)
            return chat.messages.reduce(0) { $0 + ($1.sentAt >= cutoff ? 1 : 0) }
        }
    }

    enum Me: Equatable {
        case known(String)
        /// The export does not say who the person is; ask.
        case ask
    }

    /// Who "me" is: what the export says, else what the person answered before
    /// for this source — if that account appears in the export, otherwise the
    /// answer cannot be checked and the person is asked again.
    static func resolveMe(exportMe: String?, remembered: String?, participants: [String]) -> Me {
        if let exportMe, !exportMe.isEmpty { return .known(exportMe) }
        if let remembered, !remembered.isEmpty, participants.contains(remembered) { return .known(remembered) }
        return .ask
    }

    /// The accounts that wrote in the chats, most active first, forwards left out.
    static func participants(of chats: [ExportedChat]) -> [(id: String, name: String)] {
        var count: [String: Int] = [:], names: [String: String] = [:]
        for message in chats.flatMap(\.messages) where message.forwardedFrom == nil {
            guard let id = message.authorID, !id.isEmpty else { continue }
            count[id, default: 0] += 1
            names[id] = message.authorName
        }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (id: $0.key, name: names[$0.key] ?? $0.key) }
    }

    /// The chat as ingest batches of at most `ConversationIngest.maxMessages`
    /// messages, so a long window is not refused as one oversized request.
    /// `isMine` is decided here from `myID`; a forward is never mine.
    static func batches(_ chat: ExportedChat, myID: String?, source: String) -> [IngestBatch] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = chat.messages.sorted { $0.sentAt < $1.sentAt }.map { m in
            IngestBatch.Message(id: m.sourceMessageID, author_id: m.authorID, author: m.authorName,
                                at: formatter.string(from: m.sentAt), text: m.text,
                                is_mine: m.forwardedFrom == nil && myID != nil && m.authorID == myID,
                                forwarded_from: m.forwardedFrom)
        }
        let size = ConversationIngest.maxMessages
        return stride(from: 0, to: rows.count, by: size).map { start in
            IngestBatch(source: source,
                        chat: .init(id: chat.ref.sourceChatID, title: chat.ref.title, type: chat.ref.type),
                        me: myID, messages: Array(rows[start..<min(start + size, rows.count)]))
        }
    }
}
