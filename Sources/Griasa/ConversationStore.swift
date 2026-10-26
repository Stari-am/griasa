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
              summary TEXT, processed_up_to TEXT, attempts INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY(chat_id, day));
            CREATE TABLE IF NOT EXISTS review(
              id INTEGER PRIMARY KEY, received_at REAL NOT NULL, entrance TEXT NOT NULL,
              payload BLOB NOT NULL, message_count INTEGER NOT NULL,
              source TEXT NOT NULL, source_chat_id TEXT NOT NULL);
            """)
        // Databases made before the pipeline counted attempts.
        let columns = try query("PRAGMA table_info(days)", []) { $0.string(1) ?? "" }
        if !columns.contains("attempts") {
            try exec("ALTER TABLE days ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0")
        }
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
            var earliest: [String: Double] = [:]
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
                    if added > 0 {
                        touched.insert(day)
                        earliest[day] = min(earliest[day] ?? .infinity, m.sentAt.timeIntervalSince1970)
                    }
                }
                for day in touched {
                    try run("""
                        INSERT INTO days(chat_id, day, state) VALUES (?,?,'pending')
                        ON CONFLICT(chat_id, day) DO UPDATE SET state = 'pending', attempts = 0
                        """, [.int(chat), .text(day)])
                    // A message older than what was already read (an earlier part
                    // of the history arriving later) must be read too: move the
                    // mark to just before it.
                    if let first = earliest[day] {
                        try run("""
                            UPDATE days SET processed_up_to = ?
                            WHERE chat_id = ? AND day = ? AND processed_up_to IS NOT NULL
                              AND CAST(processed_up_to AS REAL) >= ?
                            """, [.text(Self.mark(first - 0.001)), .int(chat), .text(day), .real(first)])
                    }
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
                  attempts = CASE WHEN excluded.state = 'done' THEN 0 ELSE attempts END,
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

    /// The chat as it was imported, for the pipeline that works a day at a time.
    func chat(_ id: Int64) throws -> (ref: ChatRef, myID: String?)? {
        try locked {
            try query("SELECT source, source_chat_id, title, type, my_id FROM chats WHERE id = ?",
                      [.int(id)]) { row in
                (ref: ChatRef(source: row.string(0) ?? "", sourceChatID: row.string(1) ?? "",
                              title: row.string(2) ?? "", type: row.string(3) ?? ""),
                 myID: row.string(4))
            }.first
        }
    }

    /// Up to `limit` messages of the chat sent before `date`, oldest first — what
    /// was said just before a day's new messages, for a model that needs to know
    /// what "yes, tomorrow" answers.
    func messages(chat: Int64, before date: Date, limit: Int) throws -> [StoredMessage] {
        try locked {
            try query("""
                SELECT source_message_id, author_id, author_name, sent_at, text, is_mine, forwarded_from
                FROM messages WHERE chat_id = ? AND sent_at < ? ORDER BY sent_at DESC, id DESC LIMIT ?
                """, [.int(chat), .real(date.timeIntervalSince1970), .int(Int64(limit))]) { row in
                StoredMessage(sourceMessageID: row.string(0) ?? "", authorID: row.string(1),
                              authorName: row.string(2) ?? "",
                              sentAt: Date(timeIntervalSince1970: row.double(3)),
                              text: row.string(4) ?? "", isMine: row.int(5) != 0,
                              forwardedFrom: row.string(6))
            }.reversed()
        }
    }

    /// Messages of the day sent after what the pipeline has read: all of them
    /// for a day never processed.
    func unprocessedMessages(chat: Int64, day: String) throws -> [StoredMessage] {
        let mark = try locked {
            try query("SELECT processed_up_to FROM days WHERE chat_id = ? AND day = ?",
                      [.int(chat), .text(day)]) { $0.string(0) }.first ?? nil
        }.flatMap { Double($0) }
        let all = try messages(chat: chat, day: day)
        guard let mark else { return all }
        return all.filter { $0.sentAt.timeIntervalSince1970 > mark }
    }

    /// The text `setDay(processedUpTo:)` stores for a moment.
    static func mark(_ time: Double) -> String { String(time) }
    static func mark(_ date: Date) -> String { mark(date.timeIntervalSince1970) }

    // MARK: Attempts

    /// A day is tried this many times before it stays `failed`.
    static let maxAttempts = 3

    /// Marks the day `processing` and counts the try. The count is made before
    /// the work, so a crash in the middle still costs an attempt: a day that
    /// crashes the app every time cannot loop forever.
    @discardableResult
    func beginAttempt(chat: Int64, day: String) throws -> Int {
        try locked {
            try run("UPDATE days SET state = 'processing', attempts = attempts + 1 WHERE chat_id = ? AND day = ?",
                    [.int(chat), .text(day)])
            return try query("SELECT attempts FROM days WHERE chat_id = ? AND day = ?",
                             [.int(chat), .text(day)]) { Int($0.int(0)) }.first ?? 0
        }
    }

    /// The try failed because there was no model to ask, which is nobody's
    /// fault: back to `pending` with the attempt given back.
    func releaseWithoutCounting(chat: Int64, day: String) throws {
        try locked {
            _ = try run("""
                UPDATE days SET state = 'pending', attempts = MAX(attempts - 1, 0)
                WHERE chat_id = ? AND day = ? AND state = 'processing'
                """, [.int(chat), .text(day)])
        }
    }

    /// Ends a successful try: summary and mark saved, day `done` — but only if
    /// it is still `processing`. A message imported meanwhile put the day back to
    /// `pending`; then nothing is written and the next pass reads it all again.
    /// Returns whether the day was completed.
    @discardableResult
    func complete(chat: Int64, day: String, summary: String?, processedUpTo: String?) throws -> Bool {
        try locked {
            try run("""
                UPDATE days SET state = 'done', attempts = 0,
                  summary = COALESCE(?, summary), processed_up_to = COALESCE(?, processed_up_to)
                WHERE chat_id = ? AND day = ? AND state = 'processing'
                """, [.optText(summary), .optText(processedUpTo), .int(chat), .text(day)]) > 0
        }
    }

    /// After a failed try: back to `pending` to be retried later, or `failed`
    /// once the attempts are used up. Returns the state the day is now in.
    @discardableResult
    func releaseAfterFailure(chat: Int64, day: String) throws -> DayState {
        try locked {
            try run("""
                UPDATE days SET state = CASE WHEN attempts >= ? THEN 'failed' ELSE 'pending' END
                WHERE chat_id = ? AND day = ?
                """, [.int(Int64(Self.maxAttempts)), .int(chat), .text(day)])
            let state = try query("SELECT state FROM days WHERE chat_id = ? AND day = ?",
                                  [.int(chat), .text(day)]) { $0.string(0) ?? "" }.first
            return state.flatMap { DayState(rawValue: $0) } ?? .failed
        }
    }

    /// At launch nothing is running, so a day still `processing` was cut off by
    /// a quit or a crash: it goes back to `pending`, unless its attempts are
    /// already used up. Returns how many days were put back.
    @discardableResult
    func resetInterrupted() throws -> Int {
        try locked {
            try run("UPDATE days SET state = 'failed' WHERE state = 'processing' AND attempts >= ?",
                    [.int(Int64(Self.maxAttempts))])
            return try run("UPDATE days SET state = 'pending' WHERE state = 'processing'", [])
        }
    }

    /// Days waiting for the pipeline, oldest first. A day left `processing` by a
    /// crash is put back by `resetInterrupted`; this does not guess.
    func pendingDays() throws -> [(chat: Int64, day: String)] {
        try locked {
            try query("SELECT chat_id, day FROM days WHERE state = 'pending' ORDER BY day, chat_id",
                      []) { (chat: $0.int(0), day: $0.string(1) ?? "") }
        }
    }

    // MARK: Browsing

    /// Every chat with its last message, newest first; what the hub's list shows.
    func chatList() throws -> [(id: Int64, ref: ChatRef, last: Date?)] {
        try locked {
            try query("""
                SELECT c.id, c.source, c.source_chat_id, c.title, c.type, MAX(m.sent_at)
                FROM chats c LEFT JOIN messages m ON m.chat_id = c.id
                GROUP BY c.id ORDER BY MAX(m.sent_at) DESC, c.id DESC
                """, []) { row in
                (id: row.int(0),
                 ref: ChatRef(source: row.string(1) ?? "", sourceChatID: row.string(2) ?? "",
                              title: row.string(3) ?? "", type: row.string(4) ?? ""),
                 last: sqlite3_column_type(row.stmt, 5) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: row.double(5)))
            }
        }
    }

    /// The chat's days, newest first, with the pipeline's state and summary.
    /// A day with messages but no row yet reads as `pending`.
    func days(chat: Int64) throws -> [(day: String, state: DayState, summary: String?, count: Int)] {
        try locked {
            try query("""
                SELECT m.day, COUNT(*), d.state, d.summary FROM messages m
                LEFT JOIN days d ON d.chat_id = m.chat_id AND d.day = m.day
                WHERE m.chat_id = ? GROUP BY m.day ORDER BY m.day DESC
                """, [.int(chat)]) { row in
                (day: row.string(0) ?? "", state: row.string(2).flatMap { DayState(rawValue: $0) } ?? .pending,
                 summary: row.string(3), count: Int(row.int(1)))
            }
        }
    }

    /// Who spoke in the chat, other than the person and forwards: one row per
    /// account id (or per name where a source has no ids).
    func authors(chat: Int64) throws -> [(id: String?, name: String)] {
        try locked {
            try query("""
                SELECT author_id, MAX(author_name) FROM messages
                WHERE chat_id = ? AND is_mine = 0 AND forwarded_from IS NULL
                GROUP BY COALESCE(author_id, author_name) ORDER BY MAX(author_name)
                """, [.int(chat)]) { (id: $0.string(0), name: $0.string(1) ?? "") }
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
