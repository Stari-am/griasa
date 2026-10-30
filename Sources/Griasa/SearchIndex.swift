import Foundation
import SQLite3

/// The meeting pieces search ranks, with their vectors, in one SQLite file.
///
/// It holds copies of meeting text, so it is kept like the conversations
/// database: created 0600, deleted rows overwritten (`secure_delete`), and no
/// error carries text. A meeting's pieces are replaced together, keyed by the
/// hash of the text they came from, so an edited summary or a re-processed
/// meeting is indexed again and a deleted one leaves nothing behind.
final class SearchIndex {
    enum Failure: LocalizedError {
        case sqlite(String)
        var errorDescription: String? {
            switch self {
            case .sqlite(let why): return "The search index failed: \(why)"
            }
        }
    }

    private var db: OpaquePointer?
    private let lock = NSLock()

    init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
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
        sqlite3_busy_timeout(db, 3_000)
        do {
            try exec("PRAGMA secure_delete = ON")
            try exec("""
                CREATE TABLE IF NOT EXISTS entries(entry TEXT PRIMARY KEY, hash TEXT NOT NULL, model TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS pieces(
                  entry TEXT NOT NULL, ord INTEGER NOT NULL, text TEXT NOT NULL, vector BLOB NOT NULL,
                  PRIMARY KEY(entry, ord));
                """)
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    static func live() throws -> SearchIndex {
        try SearchIndex(url: StoreRoot.file("search.sqlite"))
    }

    /// Entry id → the text hash and model its pieces were made with.
    func indexed() throws -> [UUID: (hash: String, model: String)] {
        try locked {
            var out: [UUID: (String, String)] = [:]
            for row in try query("SELECT entry, hash, model FROM entries", [], { ($0.string(0), $0.string(1), $0.string(2)) }) {
                if let id = row.0.flatMap(UUID.init(uuidString:)) { out[id] = (row.1 ?? "", row.2 ?? "") }
            }
            return out
        }
    }

    /// Replaces a meeting's pieces in one transaction.
    func replace(entry: UUID, hash: String, model: String, pieces: [(text: String, vector: SearchVectors.Packed)]) throws {
        try locked {
            try exec("BEGIN IMMEDIATE")
            do {
                try run("DELETE FROM pieces WHERE entry = ?", [.text(entry.uuidString)])
                for (ord, piece) in pieces.enumerated() {
                    try run("INSERT INTO pieces(entry, ord, text, vector) VALUES(?, ?, ?, ?)",
                            [.text(entry.uuidString), .int(Int64(ord)), .text(piece.text),
                             .blob(SearchVectors.encode(piece.vector))])
                }
                try run("INSERT OR REPLACE INTO entries(entry, hash, model) VALUES(?, ?, ?)",
                        [.text(entry.uuidString), .text(hash), .text(model)])
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    func remove(_ entries: [UUID]) throws {
        try locked {
            for entry in entries {
                try run("DELETE FROM pieces WHERE entry = ?", [.text(entry.uuidString)])
                try run("DELETE FROM entries WHERE entry = ?", [.text(entry.uuidString)])
            }
        }
    }

    func removeAll() throws {
        try locked { try exec("DELETE FROM pieces; DELETE FROM entries;") }
    }

    func pieces() throws -> [SearchVectors.Piece] {
        try locked {
            try query("SELECT entry, text, vector FROM pieces ORDER BY entry, ord", []) { row -> SearchVectors.Piece? in
                guard let id = row.string(0).flatMap(UUID.init(uuidString:)),
                      let vector = SearchVectors.decode(row.blob(2)) else { return nil }
                return SearchVectors.Piece(entry: id, text: row.string(1) ?? "", vector: vector)
            }.compactMap { $0 }
        }
    }

    // MARK: SQLite plumbing (the same shape as ConversationStore's)

    private enum Bind {
        case text(String), int(Int64), blob(Data)
    }

    private struct Row {
        let stmt: OpaquePointer
        func blob(_ i: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
        }
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
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let n = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, transient)
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .blob(let d):
                _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(d.count), transient) }
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ binds: [Bind]) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.sqlite(message()) }
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
