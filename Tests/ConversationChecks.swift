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

/// Runs something that can throw inside a check: an error is a failed rule with
/// its own line, and the value falls back so the check beneath it reports too.
func got<T>(_ what: String, _ fallback: T, _ body: () throws -> T) -> T {
    do { return try body() } catch {
        failures += 1
        print("\n    ✗ \(what) threw\n      what happened:  \(error)")
        return fallback
    }
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
    check(got("dayState", nil) { try store.dayState(chat: chat, day: "2026-10-20") } == .pending,
          rule: "a day with new messages is pending",
          meaning: "the pipeline finds its work from the pending days",
          saw: "\(String(describing: got("dayState", nil) { try store.dayState(chat: chat, day: "2026-10-20") }))")

    try store.setDay(chat: chat, day: "2026-10-20", state: .done, summary: "gist", processedUpTo: "2")
    try store.setDay(chat: chat, day: "2026-10-20", state: .failed)
    check(got("pendingDays", []) { try store.pendingDays().map(\.day) } == ["2026-10-21"],
          rule: "only pending days are listed as pending",
          meaning: "a done or failed day must not run again by itself",
          saw: "\(got("pendingDays", []) { try store.pendingDays().map(\.day) })")
    check(got("dayState", nil) { try store.dayState(chat: chat, day: "2026-10-20") } == .failed
          && (got("daySummary", nil) { try store.daySummary(chat: chat, day: "2026-10-20") }) == "gist",
          rule: "a state change without a summary keeps the summary",
          meaning: "a failed retry must not erase the summary a day already has",
          saw: "\(String(describing: got("daySummary", nil) { try store.daySummary(chat: chat, day: "2026-10-20") }))")
    let late = try store.insert([msg("4", "2026-10-20T12:00:00Z", "late addition")], chat: chat, timeZone: tzUTC)
    check(late == ["2026-10-20"] && (got("dayState", nil) { try store.dayState(chat: chat, day: "2026-10-20") }) == .pending,
          rule: "a new message reopens a done day",
          meaning: "the day's summary is redone when it gains messages",
          saw: "\(late)")

    let hits = try store.search("схему", limit: 10)
    check(hits.count == 1 && hits.first?.messageID == "2" && hits.first?.day == "2026-10-20",
          rule: "search finds a message by a Cyrillic word",
          meaning: "the people using this write in Russian; search that cannot read it is useless",
          saw: "\(hits)")
    check(got("search", false) { try store.search("\"* OR", limit: 10).isEmpty },
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
    let perms = (got("attributes", nil) { try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber })?.intValue
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
    check(again.isEmpty && (got("messages", []) { try store.messages(chat: chat, day: "2026-10-20").map(\.sourceMessageID) }) == ["1", "a"]
          && (got("messages", []) { try store.messages(chat: chat, day: "2026-10-21").map(\.sourceMessageID) }) == ["b"],
          rule: "a re-insert under another time zone does not move a message",
          meaning: "travelling or changing the Mac's zone must not reshuffle history",
          saw: "\(again)")

    let removed = try store.deleteMessages(olderThan: utc("2026-10-21T00:00:00Z"))
    check(removed == 2 && (got("search", [(chat: 0, day: "", messageID: "")]) { try store.search("private", limit: 5) }).isEmpty,
          rule: "retention removes old messages and their search entries",
          meaning: "deleted text must not stay findable",
          saw: "removed \(removed)")

    try store.deleteChat(chat)
    check(got("messages", false) { try store.messages(chat: chat, day: "2026-10-21").isEmpty }
          && (got("dayState", .pending) { try store.dayState(chat: chat, day: "2026-10-21") }) == nil
          && (got("search", [(chat: 0, day: "", messageID: "")]) { try store.search("midnight", limit: 5) }).isEmpty,
          rule: "deleting a chat leaves nothing of it",
          meaning: "'delete' is a promise to the person",
          saw: "messages or days or index remain")
} catch {
    check(false, rule: "the store runs", meaning: "every store rule depends on it", saw: "\(error)")
}

do {
    let url = tmp.appendingPathComponent("purge.sqlite")
    let store = try ConversationStore(url: url)
    let chat = try store.upsertChat(chatRef, myID: nil)
    let other = try store.upsertChat(ChatRef(source: "telegram", sourceChatID: "43", title: "Other", type: "personal_chat"), myID: nil)
    _ = try store.insert([msg("1", "2026-10-20T10:00:00Z", "zyxwvutsrq quokkaplatypus")], chat: chat, timeZone: tzUTC)
    _ = try store.insert([msg("2", "2026-10-20T10:00:00Z", "keepme hedgehogword")], chat: other, timeZone: tzUTC)
    try store.addReview(entrance: "mcp", payload: Data("{}".utf8), messageCount: 1, source: "telegram",
                        sourceChatID: "42", receivedAt: utc("2026-10-20T10:00:00Z"))
    try store.addReview(entrance: "mcp", payload: Data("{}".utf8), messageCount: 1, source: "telegram",
                        sourceChatID: "43", receivedAt: utc("2026-10-20T10:00:00Z"))
    try store.deleteChat(chat)
    check(got("reviewCount", -1) { try store.reviewCount() } == 1,
          rule: "deleting a chat removes its waiting review batches",
          meaning: "a deleted chat must not come back through the review list", saw: "\(got("reviewCount", -1) { try store.reviewCount() })")
    let bytes = (try? Data(contentsOf: url)) ?? Data()
    func has(_ w: String) -> Bool { bytes.range(of: Data(w.utf8)) != nil }
    check(!has("quokkaplatypus") && !has("zyxwvutsrq") && has("hedgehogword"),
          rule: "deleted words are gone from the database file, others stay",
          meaning: "the full-text index must not keep what the person deleted",
          saw: "deleted word present: \(has("quokkaplatypus")), kept word present: \(has("hedgehogword"))")
    _ = try store.deleteMessages(olderThan: utc("2026-12-01T00:00:00Z"))
    let after = (try? Data(contentsOf: url)) ?? Data()
    check(after.range(of: Data("hedgehogword".utf8)) == nil,
          rule: "retention deletion also clears the index", meaning: "same promise as deleting a chat",
          saw: "word still in file")
} catch {
    check(false, rule: "the purge checks run", meaning: "deletion must be real", saw: "\(error)")
}

// MARK: Telegram export

let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("benchmark/conversations", isDirectory: true)
let fullURL = fixtures.appendingPathComponent("telegram-result.json")
let singleURL = fixtures.appendingPathComponent("telegram-single-chat.json")

do {
    let export = try TelegramExport.read(fullURL)
    check(export.chats.count == 2 && export.me?.id == "user1001" && export.me?.name == "Alex Doe",
          rule: "the full export yields its chats and who the account is",
          meaning: "the account's own messages are the person's promises",
          saw: "\(export.chats.count) chats, me \(String(describing: export.me))")
    guard let group = export.chats.first(where: { $0.ref.sourceChatID == "5550001" }) else {
        check(false, rule: "the fixture has its group chat", meaning: "the checks below read it", saw: "missing")
        throw TelegramExport.Failure.notAnExport
    }
    let ids = group.messages.map(\.sourceMessageID)
    check(ids == ["2", "3", "5", "6", "7", "8", "9", "10"],
          rule: "sticker and service lines are dropped, the photo's caption is kept",
          meaning: "only words someone wrote are messages",
          saw: "\(ids)")
    check(group.messages.first { $0.sourceMessageID == "3" }?.text == "I'll send you the updated deck by  Friday",
          rule: "text entities flatten to one string",
          meaning: "bold and links must not split or lose words",
          saw: "\(String(describing: group.messages.first { $0.sourceMessageID == "3" }?.text))")
    check(group.messages.first { $0.sourceMessageID == "6" }?.forwardedFrom == "Venue Desk"
          && group.messages.first { $0.sourceMessageID == "2" }?.forwardedFrom == nil,
          rule: "a forward keeps who it is from",
          meaning: "a forwarded line is never the forwarder's promise",
          saw: "forwarded_from wrong")
    check(group.messages.filter(\.isMine).map(\.sourceMessageID) == ["3", "7", "9"],
          rule: "with personal_information the account's own messages are mine",
          meaning: "ownership comes from the source, not from a model",
          saw: "\(group.messages.filter(\.isMine).map(\.sourceMessageID))")
    check(group.messages.first { $0.sourceMessageID == "10" }?.isMine == false
          && group.messages.first { $0.sourceMessageID == "10" }?.forwardedFrom == "Venue Desk",
          rule: "a message the account itself forwarded is not mine",
          meaning: "forwarding someone's words is not promising them",
          saw: "isMine \(String(describing: group.messages.first { $0.sourceMessageID == "10" }?.isMine))")
    check(group.messageCount == 8 && group.lastMessage == group.messages.map(\.sentAt).max(),
          rule: "the chat's count and last date describe its messages",
          meaning: "the picker shows them next to each chat",
          saw: "\(group.messageCount)")

    let now = utc("2026-10-27T00:00:00Z")
    let week = TelegramExport.limited(group, to: .days(7), now: now)
    check(week.messages.map(\.sourceMessageID) == ["5", "6", "7", "8", "9", "10"],
          rule: "limited(.days) keeps only the recent days",
          meaning: "a long chat is imported a slice at a time",
          saw: "\(week.messages.map(\.sourceMessageID))")
    let last3 = TelegramExport.limited(group, to: .messages(3), now: now)
    check(last3.messages.map(\.sourceMessageID) == ["8", "9", "10"] && last3.messageCount == 3,
          rule: "limited(.messages) keeps the last N",
          meaning: "the person can take just the latest part",
          saw: "\(last3.messages.map(\.sourceMessageID))")
} catch {
    check(false, rule: "the full export fixture reads", meaning: "everything below depends on it", saw: "\(error)")
}

do {
    let single = try TelegramExport.read(singleURL)
    check(single.me == nil && single.chats.count == 1 && single.chats[0].messages.allSatisfy { !$0.isMine },
          rule: "a single-chat export has no 'me'",
          meaning: "Griasa must ask once who the person is rather than guess",
          saw: "me \(String(describing: single.me))")
} catch {
    check(false, rule: "the single-chat fixture reads", meaning: "it is the other export shape", saw: "\(error)")
}

do {
    let data = try Data(contentsOf: fullURL)
    let cut = tmp.appendingPathComponent("cut.json")
    try data.prefix(data.count / 2).write(to: cut)
    do {
        _ = try TelegramExport.read(cut)
        check(false, rule: "a truncated export is refused", meaning: "half a chat must not import silently", saw: "no error")
    } catch let f as TelegramExport.Failure {
        check(f == .notAnExport, rule: "a truncated export is reported as not an export",
              meaning: "the person is told what to do", saw: "\(f)")
    }
    let other = tmp.appendingPathComponent("other.json")
    try Data("{\"hello\": 1}".utf8).write(to: other)
    do {
        _ = try TelegramExport.read(other)
        check(false, rule: "other JSON is refused", meaning: "a wrong file must not look like an empty import", saw: "no error")
    } catch let f as TelegramExport.Failure {
        check(f == .notAnExport, rule: "other JSON is not an export", meaning: "clear message", saw: "\(f)")
    }
    do {
        _ = try TelegramExport.read(fullURL, fileSize: { _ in (1 << 30) + 1 })
        check(false, rule: "an export over 1 GB is refused", meaning: "the file is parsed in memory", saw: "no error")
    } catch let f as TelegramExport.Failure {
        check(f == .tooLarge && !(f.errorDescription ?? "").isEmpty,
              rule: "an export over 1 GB is too large, with a readable message",
              meaning: "the person learns to export less", saw: "\(f)")
    }
    do {
        _ = try TelegramExport.read(tmp.appendingPathComponent("missing.json"))
        check(false, rule: "a missing file is refused", meaning: "no silent empty import", saw: "no error")
    } catch let f as TelegramExport.Failure {
        if case .unreadable = f {} else { check(false, rule: "a missing file is unreadable", meaning: "clear message", saw: "\(f)") }
    }
} catch {
    check(false, rule: "export error cases run", meaning: "fixture setup", saw: "\(error)")
}

// MARK: Ingest

func batch(source: String = "other", chat: String = "c1", messages: Int = 1,
           me: String? = nil, author: String = "Maya") -> IngestBatch {
    IngestBatch(source: source, chat: .init(id: chat, title: "T", type: nil), me: me,
                messages: (0..<messages).map {
                    .init(id: "m\($0)", author_id: nil, author: author, at: "2026-10-20T10:00:00Z",
                          text: "text \($0)", is_mine: nil, forwarded_from: nil)
                })
}
func failure(_ r: Result<[IngestBatch], IngestError>) -> IngestError? {
    if case .failure(let e) = r { return e }
    return nil
}

check(failure(ConversationIngest.validate((0..<51).map { batch(chat: "c\($0)") })) == .tooManyChats,
      rule: "51 chats in one request are refused", meaning: "the request limit", saw: "accepted")
check(failure(ConversationIngest.validate((0..<3).map { batch(chat: "c\($0)", messages: 667) })) == .tooManyMessages,
      rule: "more than 2,000 messages in one request are refused", meaning: "the request limit", saw: "accepted")
check(failure(ConversationIngest.validate([batch(messages: 2000)])) == nil,
      rule: "exactly 2,000 messages are accepted", meaning: "the limit is inclusive", saw: "refused")
check(failure(ConversationIngest.validate([batch(source: "fax")])) == .badSource,
      rule: "an unknown source is refused", meaning: "sources are a closed list", saw: "accepted")
do {
    var b = batch()
    b.messages[0].at = "yesterday"
    check(failure(ConversationIngest.validate([b])) == .badDate,
          rule: "a message date that is not ISO-8601 is refused", meaning: "days are computed from it", saw: "accepted")
    var blank = batch(messages: 2)
    blank.messages[1].text = "  \n"
    if case .success(let ok) = ConversationIngest.validate([blank]) {
        check(ok[0].messages.count == 1, rule: "a message with no text is skipped, not an error",
              meaning: "attachments have nothing to summarize", saw: "\(ok[0].messages.count)")
    } else { check(false, rule: "blank text is skipped", meaning: "not an error", saw: "refused") }
    b.messages[0].at = "2026-10-20T10:00:00"
    check(failure(ConversationIngest.validate([b])) == nil,
          rule: "a date without a zone is accepted", meaning: "chat tools often omit it", saw: "refused")
}
do {
    let byName = ConversationIngest.stored(batch(me: "maya")).1
    let other = ConversationIngest.stored(batch(me: "Alex")).1
    var forward = batch(me: "Maya")
    forward.messages[0].forwarded_from = "Someone"
    forward.messages[0].is_mine = true
    check(!ConversationIngest.stored(forward).1[0].isMine,
          rule: "a forwarded message is never mine, even if the caller says so",
          meaning: "the forwarder did not make the promise", saw: "mine")
    var explicit = batch(me: "Maya")
    explicit.messages[0].is_mine = false
    check(byName[0].isMine && !other[0].isMine && !ConversationIngest.stored(explicit).1[0].isMine,
          rule: "is_mine wins; otherwise the author matching `me` is mine",
          meaning: "promises belong to their author",
          saw: "\(byName[0].isMine) \(other[0].isMine)")
}

do {
    let store = try freshStore()
    let export = try TelegramExport.read(fullURL)
    guard let group = export.chats.first(where: { $0.ref.sourceChatID == "5550001" }) else { throw TelegramExport.Failure.notAnExport }
    let chat = try store.upsertChat(group.ref, myID: export.me?.id)
    let firstDays = try store.insert(group.messages, chat: chat, timeZone: tzUTC)
    let resend = IngestBatch(
        source: "telegram", chat: .init(id: "5550001", title: "Launch crew", type: "private_group"), me: nil,
        messages: group.messages.map {
            .init(id: $0.sourceMessageID, author_id: $0.authorID, author: $0.authorName,
                  at: ISO8601DateFormatter().string(from: $0.sentAt), text: $0.text,
                  is_mine: nil, forwarded_from: $0.forwardedFrom)
        })
    let added = try ConversationIngest.accept(into: store, batch: resend, timeZone: tzUTC)
    check(!firstDays.isEmpty && added.isEmpty,
          rule: "an assistant re-sending an imported chat adds no new days",
          meaning: "the same message must never be summarized twice",
          saw: "\(added.count) days")
    let fresh = batch(source: "telegram", chat: "5550001", messages: 1)
    let more = try ConversationIngest.accept(into: store, batch: fresh, timeZone: tzUTC)
    check(more.count == 1 && more[0].0 == chat,
          rule: "a new message in a known chat lands in that chat",
          meaning: "one chat, one row", saw: "\(more)")
} catch {
    check(false, rule: "ingest against the fixture runs", meaning: "idempotence across entrances", saw: "\(error)")
}

check(ConversationIngest.reviewAdmit(count: 199, messages: 0, newMessages: 1)
      && !ConversationIngest.reviewAdmit(count: 200, messages: 0, newMessages: 1),
      rule: "the review list holds at most 200 batches", meaning: "the 201st is refused", saw: "wrong")
check(ConversationIngest.reviewAdmit(count: 1, messages: 19_999, newMessages: 1)
      && !ConversationIngest.reviewAdmit(count: 1, messages: 20_000, newMessages: 1),
      rule: "the review list holds at most 20,000 messages", meaning: "the 20,001st is refused", saw: "wrong")
let received = utc("2026-10-01T00:00:00Z")
check(!ConversationIngest.expired(receivedAt: received, now: received.addingTimeInterval(14 * 86_400))
      && ConversationIngest.expired(receivedAt: received, now: received.addingTimeInterval(14 * 86_400 + 1)),
      rule: "a review batch expires after 14 days", meaning: "stale batches do not pile up", saw: "wrong")

// Who an author is. An id the person linked wins over any name; names are the
// fallback and an unclear one is reported, never guessed.
do {
    let ivan = (name: "Иван Петров", handles: ["telegram": "user42"])
    let sidorov = (name: "Иван Сидоров", handles: [String: String]())
    let renamed = ChatIdentity.person(forAuthorID: "user42", name: "Ваня Б.", source: "telegram", people: [ivan])
    check(renamed == .linked("Иван Петров"),
          rule: "a linked account id finds the person even after a display-name change",
          meaning: "people rename themselves in chats; the id is what stays the same",
          saw: "\(renamed)")

    let wrongSource = ChatIdentity.person(forAuthorID: "user42", name: "Zed", source: "signal", people: [ivan])
    check(wrongSource == .unknown,
          rule: "an id linked for one source does not match another",
          meaning: "ids from different services are unrelated numbers",
          saw: "\(wrongSource)")

    let idBeatsName = ChatIdentity.person(forAuthorID: "user42", name: "Иван Сидоров", source: "telegram",
                                          people: [sidorov, ivan])
    check(idBeatsName == .linked("Иван Петров"),
          rule: "the id wins over a name that fits somebody else",
          meaning: "a link the person made is stronger than a guess from spelling",
          saw: "\(idBeatsName)")

    let both = ChatIdentity.person(forAuthorID: nil, name: "Иван", source: "telegram", people: [ivan, sidorov])
    check(both == .ambiguous(["Иван Петров", "Иван Сидоров"]),
          rule: "a first name shared by two people is ambiguous",
          meaning: "attributing a promise to the wrong Ivan is worse than asking",
          saw: "\(both)")

    let vanya = ChatIdentity.person(forAuthorID: nil, name: "Ваня", source: "telegram",
                                    people: [(name: "Vanya Petrov", handles: [:])])
    check(vanya == .byName("Vanya Petrov"),
          rule: "Latin and Cyrillic spellings of a name match without an id",
          meaning: "the same person is written in both scripts across chats and meetings",
          saw: "\(vanya)")

    let nobody = ChatIdentity.person(forAuthorID: nil, name: "Мария", source: "telegram", people: [ivan])
    check(nobody == .unknown,
          rule: "an author nobody matches is unknown",
          meaning: "an unknown author must not be forced onto the nearest person",
          saw: "\(nobody)")
}

return failures
}
