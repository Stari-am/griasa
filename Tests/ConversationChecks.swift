import Foundation

// Checks for conversations: the SQLite store's idempotence and privacy rules,
// the Telegram export parser, and the ingest limits. Fixtures under
// benchmark/conversations/ are invented.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runConversationChecks() -> Int {
var failures = 0

func check(_ passed: Bool, rule: String, meaning: String, saw: String) {
    if passed { return }
    failures += 1
    print("""

    ✗ \(rule)
      why it matters: \(meaning)
      what happened:  \(saw)
    """)
}

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("griasa-conv-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func freshStore() throws -> ConversationStore {
    try ConversationStore(url: tmp.appendingPathComponent("\(UUID().uuidString).sqlite"))
}
func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
let tzUTC = TimeZone(identifier: "UTC")!
let tzTokyo = TimeZone(identifier: "Asia/Tokyo")!
let chatRef = ChatRef(source: "telegram", sourceChatID: "42", title: "Launch crew", type: "private_group")
func msg(_ id: String, _ at: String, _ text: String) -> StoredMessage {
    StoredMessage(sourceMessageID: id, authorID: "user1", authorName: "Maya", sentAt: utc(at),
                  text: text, isMine: false, forwardedFrom: nil)
}

// MARK: Store

do {
    let store = try freshStore()
    let chat = try store.upsertChat(chatRef, myID: nil)
    let batch = [msg("1", "2026-10-20T10:00:00Z", "first"),
                 msg("2", "2026-10-20T11:00:00Z", "второе про схему доставки"),
                 msg("3", "2026-10-21T09:00:00Z", "third")]
    let first = try store.insert(batch, chat: chat, timeZone: tzUTC)
    let second = try store.insert(batch, chat: chat, timeZone: tzUTC)
    check(first == ["2026-10-20", "2026-10-21"] && second.isEmpty,
          rule: "inserting the same messages twice reports new days once",
          meaning: "a re-import must not queue a day for another summary",
          saw: "first \(first), second \(second)")
    check(try! store.dayState(chat: chat, day: "2026-10-20") == .pending,
          rule: "a day with new messages is pending",
          meaning: "the pipeline finds its work from the pending days",
          saw: "\(String(describing: try! store.dayState(chat: chat, day: "2026-10-20")))")

    try store.setDay(chat: chat, day: "2026-10-20", state: .done, summary: "gist", processedUpTo: "2")
    try store.setDay(chat: chat, day: "2026-10-20", state: .failed)
    check(try! store.pendingDays().map(\.day) == ["2026-10-21"],
          rule: "only pending days are listed as pending",
          meaning: "a done or failed day must not run again by itself",
          saw: "\(try! store.pendingDays())")
    check(try! store.dayState(chat: chat, day: "2026-10-20") == .failed
          && (try! store.daySummary(chat: chat, day: "2026-10-20")) == "gist",
          rule: "a state change without a summary keeps the summary",
          meaning: "a failed retry must not erase the summary a day already has",
          saw: "\(String(describing: try! store.daySummary(chat: chat, day: "2026-10-20")))")
    let late = try store.insert([msg("4", "2026-10-20T12:00:00Z", "late addition")], chat: chat, timeZone: tzUTC)
    check(late == ["2026-10-20"] && (try! store.dayState(chat: chat, day: "2026-10-20")) == .pending,
          rule: "a new message reopens a done day",
          meaning: "the day's summary is redone when it gains messages",
          saw: "\(late)")

    let hits = try store.search("схему", limit: 10)
    check(hits.count == 1 && hits.first?.messageID == "2" && hits.first?.day == "2026-10-20",
          rule: "search finds a message by a Cyrillic word",
          meaning: "the people using this write in Russian; search that cannot read it is useless",
          saw: "\(hits)")
    check(try! store.search("\"* OR", limit: 10).isEmpty,
          rule: "search operators typed in the box do not break the query",
          meaning: "a person's search is text, not FTS syntax",
          saw: "threw or matched")

} catch {
    check(false, rule: "the store runs", meaning: "every store rule depends on it", saw: "\(error)")
}

do {
    let url = tmp.appendingPathComponent("perm.sqlite")
    let store = try ConversationStore(url: url)
    let chat = try store.upsertChat(chatRef, myID: nil)
    _ = try store.insert([msg("1", "2026-10-20T10:00:00Z", "private words")], chat: chat, timeZone: tzUTC)
    let perms = (try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    check(perms == 0o600,
          rule: "the database file is readable by its owner only",
          meaning: "it holds other people's messages",
          saw: String(perms ?? -1, radix: 8))

    // The day key is stored at insert, so another time zone cannot move it.
    let a = msg("a", "2026-10-20T23:30:00Z", "before midnight")
    let b = msg("b", "2026-10-21T00:10:00Z", "after midnight")
    let days = try store.insert([a, b], chat: chat, timeZone: tzUTC)
    check(days == ["2026-10-20", "2026-10-21"],
          rule: "23:30 and 00:10 land on two days",
          meaning: "summaries are per calendar day",
          saw: "\(days)")
    let again = try store.insert([a, b], chat: chat, timeZone: tzTokyo)
    check(again.isEmpty && (try! store.messages(chat: chat, day: "2026-10-20").map(\.sourceMessageID)) == ["1", "a"]
          && (try! store.messages(chat: chat, day: "2026-10-21").map(\.sourceMessageID)) == ["b"],
          rule: "a re-insert under another time zone does not move a message",
          meaning: "travelling or changing the Mac's zone must not reshuffle history",
          saw: "\(again)")

    let removed = try store.deleteMessages(olderThan: utc("2026-10-21T00:00:00Z"))
    check(removed == 2 && (try! store.search("private", limit: 5)).isEmpty,
          rule: "retention removes old messages and their search entries",
          meaning: "deleted text must not stay findable",
          saw: "removed \(removed)")

    try store.deleteChat(chat)
    check(try! store.messages(chat: chat, day: "2026-10-21").isEmpty
          && (try! store.dayState(chat: chat, day: "2026-10-21")) == nil
          && (try! store.search("midnight", limit: 5)).isEmpty,
          rule: "deleting a chat leaves nothing of it",
          meaning: "'delete' is a promise to the person",
          saw: "messages or days or index remain")
} catch {
    check(false, rule: "the store runs", meaning: "every store rule depends on it", saw: "\(error)")
}

return failures
}
