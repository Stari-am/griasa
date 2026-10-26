import Foundation
import SQLite3

/// One conversation as a messenger knows it: Telegram's chat id, a Slack channel.
/// `source` + `sourceChatID` is its identity; the title and type are only labels
/// and are refreshed on every import.
struct ChatRef: Hashable {
    var source: String
    var sourceChatID: String
    var title: String
    var type: String
}

struct StoredMessage: Equatable {
    /// The messenger's own id. With the chat, it is what makes re-importing the
    /// same export a no-op.
    var sourceMessageID: String
    var authorID: String?
    var authorName: String
    var sentAt: Date
    var text: String
    /// Whether the person wrote it — known from the source, never guessed by a
    /// model, because promises are owned by their author.
    var isMine: Bool
    var forwardedFrom: String?
}

/// Where a chat day is in the summary-and-promises pipeline.
enum DayState: String {
    case pending, processing, done, failed
}

/// Chats and their messages, in their own SQLite file.
///
/// History keeps 500 entries; a few chats would push every meeting out of it,
/// and search needs an index JSON cannot give. SQLite ships with macOS, so this
/// costs no dependency. Foundation and SQLite3 only, so test.sh can run the
/// idempotence rules against a temporary file.
///
/// Everything here is private data: the file is created 0600 and deleted rows
/// are overwritten (`secure_delete`), and no error carries message text.
final class ConversationStore {
    enum Failure: LocalizedError {
        case sqlite(String)
        var errorDescription: String? {
            switch self {
            case .sqlite(let why): return "The conversations database failed: \(why)"
            }
        }
    }

    private var db: OpaquePointer?
    /// One connection, many callers (the import, the queue, the MCP tools).
    private let lock = NSLock()
    /// False when this SQLite was built without FTS5; search then scans with LIKE.
    private(set) var hasFullTextSearch = false

    init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created with its permissions rather than chmod-ed afterwards, so the
        // file is never readable by anyone else even for an instant.
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil,
                                attributes: [.posixPermissions: 0o600]) else {
                throw Failure.sqlite("the file could not be created")
            }
        } else {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let why = message()
            sqlite3_close(db)
            throw Failure.sqlite(why)
        }
        do { try migrate() } catch { sqlite3_close(db); throw error }
    }

    deinit { sqlite3_close(db) }

    static func live() throws -> ConversationStore {
        try ConversationStore(url: StoreRoot.file("conversations.sqlite"))
    }

    // MARK: Schema

    private func migrate() throws {
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA secure_delete = ON")
        try exec("""
            CREATE TABLE IF NOT EXISTS chats(
              id INTEGER PRIMARY KEY, source TEXT NOT NULL, source_chat_id TEXT NOT NULL,
              title TEXT NOT NULL, type TEXT NOT NULL, my_id TEXT,
              UNIQUE(source, source_chat_id));
            CREATE TABLE IF NOT EXISTS messages(
              id INTEGER PRIMARY KEY, chat_id INTEGER NOT NULL, source_message_id TEXT NOT NULL,
              author_id TEXT, author_name TEXT NOT NULL, sent_at REAL NOT NULL, day TEXT NOT NULL,
              text TEXT NOT NULL, is_mine INTEGER NOT NULL, forwarded_from TEXT,
              UNIQUE(chat_id, source_message_id));
            CREATE INDEX IF NOT EXISTS messages_by_day ON messages(chat_id, day, sent_at);
            CREATE TABLE IF NOT EXISTS days(
              chat_id INTEGER NOT NULL, day TEXT NOT NULL, state TEXT NOT NULL,
              summary TEXT, processed_up_to TEXT, PRIMARY KEY(chat_id, day));
            CREATE TABLE IF NOT EXISTS review(
              id INTEGER PRIMARY KEY, received_at REAL NOT NULL, entrance TEXT NOT NULL,
              payload BLOB NOT NULL, message_count INTEGER NOT NULL,
              source TEXT NOT NULL, source_chat_id TEXT NOT NULL);
            """)
        // The index is a copy of `messages.text`, kept in step by triggers so no
        // code path can forget it. If this build has no FTS5 the statement
        // fails, and that is the whole feature check.
        do {
            try exec("""
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                  text, content='messages', content_rowid='id');
                CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
                  INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
                END;
                CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
                  INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.id, old.text);
                END;
                """)
            hasFullTextSearch = true
        } catch {
            hasFullTextSearch = false
        }
    }

    // MARK: Chats and messages

    @discardableResult
    func upsertChat(_ chat: ChatRef, myID: String?) throws -> Int64 {
        try locked {
            // A later import that knows who "me" is fills it in; one that does
            // not (a single-chat export) must not erase what an earlier one found.
            try run("""
                INSERT INTO chats(source, source_chat_id, title, type, my_id) VALUES (?,?,?,?,?)
                ON CONFLICT(source, source_chat_id) DO UPDATE SET
                  title = excluded.title, type = excluded.type, my_id = COALESCE(excluded.my_id, my_id)
                """, [.text(chat.source), .text(chat.sourceChatID), .text(chat.title),
                      .text(chat.type), .optText(myID)])
            let rows = try query("SELECT id FROM chats WHERE source = ? AND source_chat_id = ?",
                                 [.text(chat.source), .text(chat.sourceChatID)]) { $0.int(0) }
            guard let id = rows.first else { throw Failure.sqlite("the chat was not saved") }
            return id
        }
    }

    /// Stores what is new and returns the days (`yyyy-MM-dd`) that got something,
    /// each now `pending` so the pipeline looks at it again.
    ///
    /// The day is worked out here, once, in `timeZone`, and stored. A later
    /// import from another time zone finds the message already there and
    /// leaves it where it was: a message never moves to a different day.
    func insert(_ messages: [StoredMessage], chat: Int64, timeZone: TimeZone) throws -> [String] {
        try locked {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.calendar = Calendar(identifier: .gregorian)
            format.timeZone = timeZone
            format.dateFormat = "yyyy-MM-dd"

            var touched = Set<String>()
            try exec("BEGIN")
            do {
                for m in messages {
                    let day = format.string(from: m.sentAt)
                    let added = try run("""
                        INSERT OR IGNORE INTO messages(chat_id, source_message_id, author_id, author_name,
                          sent_at, day, text, is_mine, forwarded_from) VALUES (?,?,?,?,?,?,?,?,?)
                        """, [.int(chat), .text(m.sourceMessageID), .optText(m.authorID), .text(m.authorName),
                              .real(m.sentAt.timeIntervalSince1970), .text(day), .text(m.text),
                              .int(m.isMine ? 1 : 0), .optText(m.forwardedFrom)])
                    if added > 0 { touched.insert(day) }
                }
                for day in touched {
                    try run("""
                        INSERT INTO days(chat_id, day, state) VALUES (?,?,'pending')
                        ON CONFLICT(chat_id, day) DO UPDATE SET state = 'pending'
                        """, [.int(chat), .text(day)])
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
            return touched.sorted()
        }
    }

    func messages(chat: Int64, day: String) throws -> [StoredMessage] {
        try locked {
            try query("""
                SELECT source_message_id, author_id, author_name, sent_at, text, is_mine, forwarded_from
                FROM messages WHERE chat_id = ? AND day = ? ORDER BY sent_at, id
                """, [.int(chat), .text(day)]) { row in
                StoredMessage(sourceMessageID: row.string(0) ?? "", authorID: row.string(1),
                              authorName: row.string(2) ?? "",
                              sentAt: Date(timeIntervalSince1970: row.double(3)),
                              text: row.string(4) ?? "", isMine: row.int(5) != 0,
                              forwardedFrom: row.string(6))
            }
        }
    }

    // MARK: Days

    func dayState(chat: Int64, day: String) throws -> DayState? {
        try locked {
            try query("SELECT state FROM days WHERE chat_id = ? AND day = ?",
                      [.int(chat), .text(day)]) { $0.string(0) ?? "" }
                .first.flatMap { DayState(rawValue: $0) }
        }
    }

    /// A nil `summary` or `processedUpTo` leaves what is stored: a day that
    /// fails or is retried must not lose the summary it already has.
    func setDay(chat: Int64, day: String, state: DayState,
                summary: String? = nil, processedUpTo: String? = nil) throws {
        try locked {
            _ = try run("""
                INSERT INTO days(chat_id, day, state, summary, processed_up_to) VALUES (?,?,?,?,?)
                ON CONFLICT(chat_id, day) DO UPDATE SET state = excluded.state,
                  summary = COALESCE(excluded.summary, summary),
                  processed_up_to = COALESCE(excluded.processed_up_to, processed_up_to)
                """, [.int(chat), .text(day), .text(state.rawValue),
                      .optText(summary), .optText(processedUpTo)])
        }
    }

    func daySummary(chat: Int64, day: String) throws -> String? {
        try locked {
            try query("SELECT summary FROM days WHERE chat_id = ? AND day = ?",
                      [.int(chat), .text(day)]) { $0.string(0) }.first ?? nil
        }
    }

    /// Days waiting for the pipeline, oldest first. A day left `processing` by a
    /// crash is the queue's to reset; this does not guess.
    func pendingDays() throws -> [(chat: Int64, day: String)] {
        try locked {
            try query("SELECT chat_id, day FROM days WHERE state = 'pending' ORDER BY day, chat_id",
                      []) { (chat: $0.int(0), day: $0.string(1) ?? "") }
        }
    }

    // MARK: Search

    /// Messages containing every word of `query`, newest day first. Words are
    /// matched as whole tokens (FTS5, unicode-aware, so Cyrillic works); without
    /// FTS5 it falls back to a substring scan.
    func search(_ query: String, limit: Int) throws -> [(chat: Int64, day: String, messageID: String)] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, limit > 0 else { return [] }
        return try locked {
            if hasFullTextSearch {
                // Each word becomes a quoted FTS5 string, so operators typed in
                // the box ("-", "OR", "*") are searched for, not interpreted.
                let match = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                    .joined(separator: " ")
                return try self.query("""
                    SELECT m.chat_id, m.day, m.source_message_id FROM messages_fts
                    JOIN messages m ON m.id = messages_fts.rowid
                    WHERE messages_fts MATCH ? ORDER BY m.day DESC, m.sent_at DESC LIMIT ?
                    """, [.text(match), .int(Int64(limit))]) {
                    (chat: $0.int(0), day: $0.string(1) ?? "", messageID: $0.string(2) ?? "")
                }
            }
            let clause = words.map { _ in "text LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            let binds = words.map { w -> Bind in
                let escaped = w.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                return .text("%" + escaped + "%")
            }
            return try self.query("""
                SELECT chat_id, day, source_message_id FROM messages WHERE \(clause)
                ORDER BY day DESC, sent_at DESC LIMIT ?
                """, binds + [.int(Int64(limit))]) {
                (chat: $0.int(0), day: $0.string(1) ?? "", messageID: $0.string(2) ?? "")
            }
        }
    }

    // MARK: Deleting

    /// Removes the chat and everything kept about it, then VACUUMs so the freed
    /// pages do not keep the text on disk.
    func deleteChat(_ chat: Int64) throws {
        try locked {
            let ref = try query("SELECT source, source_chat_id FROM chats WHERE id = ?", [.int(chat)]) {
                (source: $0.string(0) ?? "", id: $0.string(1) ?? "")
            }.first
            try exec("BEGIN")
            do {
                try run("DELETE FROM messages WHERE chat_id = ?", [.int(chat)])
                try run("DELETE FROM days WHERE chat_id = ?", [.int(chat)])
                if let ref {
                    try run("DELETE FROM review WHERE source = ? AND source_chat_id = ?",
                            [.text(ref.source), .text(ref.id)])
                }
                try run("DELETE FROM chats WHERE id = ?", [.int(chat)])
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
            try purge()
        }
    }

    /// Retention: drops messages (and waiting review batches, which count the same)
    /// older than `date`. Summaries and promises are kept; only the raw text goes.
    /// Returns how many messages were removed.
    @discardableResult
    func deleteMessages(olderThan date: Date) throws -> Int {
        try locked {
            let cutoff = date.timeIntervalSince1970
            try exec("BEGIN")
            let removed: Int
            do {
                removed = try run("DELETE FROM messages WHERE sent_at < ?", [.real(cutoff)])
                try run("DELETE FROM review WHERE received_at < ?", [.real(cutoff)])
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
            if removed > 0 { try purge() }
            return removed
        }
    }

    /// Makes deleted text really leave the file. The FTS5 'delete' trigger only
    /// writes tombstones and VACUUM keeps index segments, so the index is rebuilt
    /// from the remaining rows first.
    private func purge() throws {
        if hasFullTextSearch { try exec("INSERT INTO messages_fts(messages_fts) VALUES('rebuild')") }
        try exec("VACUUM")
    }

    // MARK: Review

    /// Queues a batch from an assistant or the endpoint for the person to
    /// accept. The chat it names is stored in the clear so `deleteChat` can
    /// remove it; the limits (`ConversationIngest.reviewAdmit`) are the caller's.
    func addReview(entrance: String, payload: Data, messageCount: Int,
                   source: String, sourceChatID: String, receivedAt: Date) throws {
        try locked {
            _ = try run("""
                INSERT INTO review(received_at, entrance, payload, message_count, source, source_chat_id)
                VALUES (?,?,?,?,?,?)
                """, [.real(receivedAt.timeIntervalSince1970), .text(entrance),
                      .blob(payload), .int(Int64(messageCount)),
                      .text(source), .text(sourceChatID)])
        }
    }

    func reviewCount() throws -> Int {
        try locked { try query("SELECT COUNT(*) FROM review", []) { Int($0.int(0)) }.first ?? 0 }
    }

    // MARK: SQLite plumbing

    private enum Bind {
        case text(String), optText(String?), int(Int64), real(Double), blob(Data)
    }

    private struct Row {
        let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func string(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func message() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let why = err.map { String(cString: $0) } ?? message()
            sqlite3_free(err)
            throw Failure.sqlite(why)
        }
    }

    private func prepare(_ sql: String, _ binds: [Bind]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure.sqlite(message())
        }
        // SQLITE_TRANSIENT: SQLite copies the string, Swift's buffer is temporary.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let n = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, transient)
            case .optText(let s):
                if let s { sqlite3_bind_text(stmt, n, s, -1, transient) } else { sqlite3_bind_null(stmt, n) }
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .real(let v): sqlite3_bind_double(stmt, n, v)
            case .blob(let d):
                _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(d.count), transient) }
            }
        }
        return stmt
    }

    /// Runs a statement that changes rows; returns how many it changed.
    @discardableResult
    private func run(_ sql: String, _ binds: [Bind]) throws -> Int {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.sqlite(message()) }
        return Int(sqlite3_changes(db))
    }

    private func query<T>(_ sql: String, _ binds: [Bind], _ read: (Row) -> T) throws -> [T] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: out.append(read(Row(stmt: stmt)))
            case SQLITE_DONE: return out
            default: throw Failure.sqlite(message())
            }
        }
    }
}
