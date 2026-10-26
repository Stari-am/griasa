import Foundation

/// One chat read out of a Telegram Desktop export, before anything is stored.
struct ExportedChat {
    var ref: ChatRef
    var messageCount: Int
    var lastMessage: Date?
    var messages: [StoredMessage]
}

/// How much of a chat to take: the person chooses this per chat before importing,
/// because a ten-year group chat is not something to feed a model by default.
enum Window: Equatable {
    case days(Int)
    case messages(Int)
}

/// Reads "Export chat history" from Telegram Desktop (JSON).
///
/// Two shapes exist: the full export (`personal_information` plus
/// `chats.list`), which says who the account is, and the single-chat export,
/// which is the chat object alone and does not. Only text becomes a message.
/// Stickers, voice notes and files have none, a photo keeps its caption, and
/// service lines ("Maya joined the group") are not anyone's words.
enum TelegramExport {
    enum Failure: LocalizedError, Equatable {
        case tooLarge
        case notAnExport
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "This export is larger than 1 GB. Export a shorter period or fewer chats from Telegram and try again."
            case .notAnExport:
                return "This doesn't look like a Telegram export. Choose the result.json that Telegram Desktop wrote with the JSON format."
            case .unreadable(let why):
                return "The file could not be read: \(why)"
            }
        }
    }

    /// The whole file is parsed in memory, so the size is capped.
    static let sizeLimit: Int64 = 1 << 30

    /// `fileSize` is a parameter so the limit can be tested without a 1 GB file.
    static func read(_ url: URL,
                     fileSize: (URL) -> Int64? = defaultFileSize) throws
        -> (me: (id: String, name: String)?, chats: [ExportedChat]) {
        if let size = fileSize(url), size > sizeLimit { throw Failure.tooLarge }

        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw Failure.unreadable((error as NSError).localizedDescription) }

        // A cut-off copy is the common failure (an interrupted copy or download);
        // it fails to parse and is reported as not an export rather than half-read.
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.notAnExport
        }

        var me: (id: String, name: String)?
        var chatObjects: [[String: Any]] = []
        if let list = (root["chats"] as? [String: Any])?["list"] as? [[String: Any]] {
            chatObjects = list
            if let info = root["personal_information"] as? [String: Any], let id = int(info["user_id"]) {
                let name = [info["first_name"], info["last_name"]]
                    .compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " ")
                me = (id: "user\(id)", name: name)
            }
        } else if root["messages"] is [Any], root["id"] != nil {
            chatObjects = [root]
        } else {
            throw Failure.notAnExport
        }

        let chats = chatObjects.compactMap { chat(from: $0, myID: me?.id) }
        return (me, chats)
    }

    /// The last part of a chat, by time or by count, so a big chat can be
    /// imported a week at a time. The count and last date follow what is kept.
    static func limited(_ chat: ExportedChat, to window: Window, now: Date) -> ExportedChat {
        var out = chat
        let ordered = chat.messages.sorted { $0.sentAt < $1.sentAt }
        switch window {
        case .days(let n):
            let cutoff = now.addingTimeInterval(-Double(max(n, 0)) * 86_400)
            out.messages = ordered.filter { $0.sentAt >= cutoff }
        case .messages(let n):
            out.messages = Array(ordered.suffix(max(n, 0)))
        }
        out.messageCount = out.messages.count
        out.lastMessage = out.messages.last?.sentAt
        return out
    }

    // MARK: Parsing

    private static func defaultFileSize(_ url: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    private static func chat(from object: [String: Any], myID: String?) -> ExportedChat? {
        guard let id = int(object["id"]), let raw = object["messages"] as? [[String: Any]] else { return nil }
        let type = object["type"] as? String ?? "unknown"
        let title = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (type == "saved_messages" ? "Saved messages" : "Untitled chat")

        let messages = raw.compactMap { message(from: $0, myID: myID) }
        return ExportedChat(ref: ChatRef(source: "telegram", sourceChatID: String(id), title: title, type: type),
                            messageCount: messages.count,
                            lastMessage: messages.map(\.sentAt).max(),
                            messages: messages)
    }

    private static func message(from m: [String: Any], myID: String?) -> StoredMessage? {
        guard (m["type"] as? String ?? "message") == "message",
              let id = int(m["id"]), let sentAt = date(m) else { return nil }
        // Sticker, voice note or file with no caption: nothing was said in words.
        let text = flatten(m["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        let authorID = m["from_id"] as? String
        var forwarded: String?
        if let value = m["forwarded_from"] {
            // Hidden senders export as null; the message is still a forward.
            forwarded = (value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        }
        return StoredMessage(sourceMessageID: String(id), authorID: authorID,
                             authorName: m["from"] as? String ?? "Unknown",
                             sentAt: sentAt, text: text,
                             // Forwarding someone else's words is not saying them, even from the
                             // account's own chat: never the forwarder's promise.
                             isMine: forwarded == nil && myID != nil && authorID == myID,
                             forwardedFrom: forwarded)
    }

    /// `text` is a string, or an array mixing strings and `{type, text}` entities
    /// (bold, links, mentions); either way the person wrote one piece of text.
    private static func flatten(_ value: Any?) -> String {
        if let s = value as? String { return s }
        guard let parts = value as? [Any] else { return "" }
        return parts.map { part -> String in
            if let s = part as? String { return s }
            return (part as? [String: Any])?["text"] as? String ?? ""
        }.joined()
    }

    private static func date(_ m: [String: Any]) -> Date? {
        if let s = m["date_unixtime"] as? String, let t = TimeInterval(s) { return Date(timeIntervalSince1970: t) }
        if let n = m["date_unixtime"] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        // Older exports have only the local wall-clock string.
        guard let s = m["date"] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)
    }

    /// Ids are numbers in `chats[].id` and `personal_information`, strings
    /// (`"user123"`) in `from_id`.
    private static func int(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}
