import Foundation

// Checks for reading a long meeting in parts: the cuts, the transcript built
// without the model, and the rule that a promise must quote its source.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runLongMeetingChecks() -> Int {
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

func line(_ seconds: Int, _ speaker: String, _ text: String) -> String {
    "[\(RawLine.clock(seconds))] \(speaker): \(text)"
}

// A meeting of 400 lines, each about 60 characters, one every 15 seconds.
let lines = (0..<400).map { line($0 * 15, $0 % 3 == 0 ? "You" : "Them", "line number \($0) with some words to fill the space") }
let meeting = lines.joined(separator: "\n")

// A transcript that fits in one chunk is not touched.
do {
    let short = lines.prefix(10).joined(separator: "\n")
    let result = TranscriptChunker.chunks(short, maxChars: 20_000, overlapChars: 1_500)
    check(result.count == 1 && result[0].body == short && result[0].overlap.isEmpty
          && result[0].modelInput == short,
          rule: "a meeting that fits one chunk comes back as one chunk, unchanged",
          meaning: "short meetings keep today's single request; any rewrite here would change them",
          saw: "\(result.count) chunks, body equal: \(result.first?.body == short)")
}

// Cuts are at line boundaries, nothing is lost, nothing exceeds the size.
let chunks = TranscriptChunker.chunks(meeting, maxChars: 5_000, overlapChars: 500)
do {
    check(chunks.count > 3,
          rule: "a long meeting is cut into several chunks",
          meaning: "one request holding it all is what overflowed the local model",
          saw: "\(chunks.count) chunks")
    check(chunks.allSatisfy { $0.body.count <= 5_000 },
          rule: "no chunk is longer than the limit",
          meaning: "the limit is what keeps a chunk inside the model's context",
          saw: "longest \(chunks.map { $0.body.count }.max() ?? 0)")
    let rejoined = chunks.map(\.body).joined(separator: "\n")
    check(rejoined == meeting,
          rule: "the chunk bodies together are the whole transcript, in order, once",
          meaning: "a dropped line is a promise nobody sees; a repeated one is counted twice",
          saw: "rejoined \(rejoined.count) characters of \(meeting.count)")
    let allWhole = chunks.allSatisfy { chunk in chunk.body.components(separatedBy: "\n").allSatisfy { lines.contains($0) } }
    check(allWhole,
          rule: "chunks are cut only between lines",
          meaning: "a cut inside a line splits a sentence the model must read whole",
          saw: "a chunk holds a line that is not one of the originals")
}

// Overlap: the tail of the previous chunk, within budget, marked as context.
do {
    let second = chunks[1]
    check(chunks[0].overlap.isEmpty && !second.overlap.isEmpty && second.overlap.count <= 500
          && chunks[0].body.hasSuffix(second.overlap),
          rule: "each chunk after the first repeats the last lines of the one before, within 500 characters",
          meaning: "a sentence that crosses a cut would otherwise be lost or half-read",
          saw: "first overlap \(chunks[0].overlap.count), second \(second.overlap.count)")
    check(second.modelInput.hasPrefix(TranscriptChunk.contextOpen)
          && second.modelInput.contains(TranscriptChunk.contextClose)
          && second.modelInput.hasSuffix(second.body),
          rule: "the repeated part is marked \"context only\" before the new lines",
          meaning: "without the mark the model reports the repeated lines twice",
          saw: String(second.modelInput.prefix(80)))
}

// Time ranges.
do {
    check(chunks[0].startSeconds == 0 && chunks[0].endSeconds != nil
          && chunks[1].startSeconds! > chunks[0].startSeconds!
          && chunks.last!.endSeconds == 399 * 15
          && chunks[0].rangeLabel.hasPrefix("00:00–"),
          rule: "each chunk reports the time range of its new lines",
          meaning: "the merge step and the reader place each part of the notes in the meeting",
          saw: "\(chunks[0].rangeLabel), last ends \(chunks.last!.endSeconds.map(String.init) ?? "nil")")
}

// A typed note stays with the line before it. Lines are 93 characters and the
// note 90, with a 1,000-character limit, so the note lands exactly where a plain
// packer would put a cut.
do {
    let fixed = (0..<30).map { line($0 * 5, "You", String(repeating: "a", count: 80)) }
    let note = "[00:51] 📝 NOTE: " + String(repeating: "n", count: 73)
    var withNote = fixed
    withNote.insert(note, at: 10)
    let cut = TranscriptChunker.chunks(withNote.joined(separator: "\n"), maxChars: 1_000, overlapChars: 300)
    let starts = cut.filter { chunk in
        chunk.body.components(separatedBy: "\n").first.map { RawLine.isNote($0) } ?? false
    }.count
    check(starts == 0 && cut.contains { $0.body.contains(fixed[9] + "\n" + note) },
          rule: "a typed note is never the first line of a chunk; it stays with the line before it",
          meaning: "a note is the user's comment on the line before it; apart from that line it means nothing",
          saw: "\(starts) chunks start with a note")

    // And never the first line of the repeated context: its line is not there.
    var atEnd = Array(fixed.prefix(9))
    atEnd.append(note)
    atEnd += fixed.suffix(12)
    let cut2 = TranscriptChunker.chunks(atEnd.joined(separator: "\n"), maxChars: 1_000, overlapChars: 100)
    check(cut2.count >= 2 && cut2[0].body.hasSuffix(note)
          && !cut2[1].overlap.contains("NOTE") ,
          rule: "the repeated context never starts with a typed note",
          meaning: "the note comments on a line the context does not contain",
          saw: "overlap: \(cut2.count > 1 ? cut2[1].overlap.count : -1) characters, first line "
             + "\(cut2.count > 1 ? String(cut2[1].overlap.prefix(20)) : "-")")
}

// A line longer than a chunk is split at a sentence or space and loses nothing.
do {
    let sentence = "This is a sentence that goes on for a while. "
    let long = "[00:10] Them: " + String(repeating: sentence, count: 40)   // 1,800+ characters
    let text = [line(0, "You", "hello"), long, line(30, "You", "bye")].joined(separator: "\n")
    let cut = TranscriptChunker.chunks(text, maxChars: 500, overlapChars: 100)
    let rejoined = cut.map(\.body).joined(separator: "\n")
    let squashed = { (s: String) in s.filter { !$0.isWhitespace } }
    check(cut.allSatisfy { $0.body.count <= 500 } && squashed(rejoined) == squashed(text),
          rule: "a line longer than a chunk is split and none of its text is lost",
          meaning: "one long monologue is exactly the part a summary must not skip",
          saw: "chunk sizes \(cut.map { $0.body.count }), text kept: \(squashed(rejoined) == squashed(text))")
    let pieces = TranscriptChunker.split(long, into: 500)
    check(pieces.joined() == long && pieces.dropLast().allSatisfy { $0.hasSuffix(". ") },
          rule: "a long line is split after a sentence end when there is one to split at",
          meaning: "a cut in the middle of a sentence reads as two sentences",
          saw: "\(pieces.count) pieces, rejoined equal: \(pieces.joined() == long)")
    let unbroken = String(repeating: "x", count: 1_300)
    check(TranscriptChunker.split(unbroken, into: 500).joined() == unbroken
          && TranscriptChunker.split(unbroken, into: 500).map(\.count) == [500, 500, 300],
          rule: "text with no space or full stop is cut at the limit, whole",
          meaning: "a recognizer that returns one endless word must not stall or lose text",
          saw: "\(TranscriptChunker.split(unbroken, into: 500).map(\.count))")
}

check(TranscriptChunker.shouldChunk(isLocal: true, characters: 20_001)
      && !TranscriptChunker.shouldChunk(isLocal: true, characters: 20_000)
      && !TranscriptChunker.shouldChunk(isLocal: false, characters: 900_000),
      rule: "only a local model reads a meeting in parts, and only past one chunk",
      meaning: "a cloud model reads the whole meeting in one request; a short meeting keeps today's single request",
      saw: "local 20,001: \(TranscriptChunker.shouldChunk(isLocal: true, characters: 20_001)), "
         + "cloud 900,000: \(TranscriptChunker.shouldChunk(isLocal: false, characters: 900_000))")

// MARK: the transcript built in code

do {
    let raw = """
    [00:05] You: Hello everyone.
    [00:09] You: Let's start.
    [00:12] Them: Hi.
    [00:20] 📝 NOTE: budget is open
    [00:25] Them: Sure.
    [03:10] You: Later point.
    [03:20] Them: Agreed
    """
    let out = TranscriptAssembler.assemble(raw: raw, myName: "Aik")
    check(out.contains("**Aik:** Hello everyone. Let's start."),
          rule: "consecutive lines from one speaker become one paragraph, with the user's name for \"You\"",
          meaning: "the transcript must read as speech, not as a log of recognizer fragments",
          saw: out)
    check(out.contains("> 📝 **Note [00:20]:** budget is open"),
          rule: "a typed note is a blockquote with its time",
          meaning: "the user's own words stand apart from what was said aloud",
          saw: out)
    check(out.hasPrefix("[00:05] ") && out.contains("[03:10] **Aik:** Later point.")
          && !out.contains("[00:12]") && !out.contains("[00:25]"),
          rule: "a time stamp appears about every three minutes, not on every paragraph",
          meaning: "stamps on every line bury the text; none at all lose the place in the meeting",
          saw: out)
    check(out.contains("**Them:** Sure.") && !out.contains("**Them:** Hi. Sure."),
          rule: "a note between two lines from one speaker keeps them apart",
          meaning: "the note was written at that moment; merging across it moves it",
          saw: out)
    check(TranscriptAssembler.assemble(raw: "[00:01] You: hi", myName: "").contains("**You:** hi"),
          rule: "without a known name \"You\" stays \"You\"",
          meaning: "an empty label would read as a bug",
          saw: TranscriptAssembler.assemble(raw: "[00:01] You: hi", myName: ""))
    let md = "# Meeting notes — X\n\n## Summary\n\ntext\n\n## Transcript\n\n[00:01] **A:** hi there\n"
    check(TranscriptAssembler.transcriptSection(of: md) == "[00:01] **A:** hi there"
          && TranscriptAssembler.transcriptSection(of: "just notes") == "just notes",
          rule: "the transcript section of finished notes is what follows its heading, or the whole text",
          meaning: "imported notes have no heading and must still be readable in parts",
          saw: TranscriptAssembler.transcriptSection(of: md))
}

// MARK: quotes

do {
    let input = "[00:12] You: Okay, I'll send the pricing deck to Maria by Friday.\n[00:20] Them: Great."
    let prepared = QuoteMatch.prepare(input)
    check(QuoteMatch.contains(prepared, quote: "I'll send the pricing deck to Maria by Friday"),
          rule: "a quote copied from the transcript is found",
          meaning: "a true promise must survive the check that exists to catch false ones",
          saw: prepared)
    check(QuoteMatch.contains(prepared, quote: "ok i will send")
          == false
          && QuoteMatch.contains(prepared, quote: "OKAY I'LL SEND THE PRICING DECK!!")
          && QuoteMatch.contains(prepared, quote: "send   the\npricing deck, to Maria"),
          rule: "case, punctuation and line breaks do not stop a quote matching; words do",
          meaning: "models re-wrap what they copy, but a changed word is a different sentence",
          saw: "—")
    check(!QuoteMatch.contains(prepared, quote: "I will send the budget to Maria on Monday"),
          rule: "a quote that is not in the transcript is not found",
          meaning: "this is the guard against invented promises",
          saw: "found")
    check(!QuoteMatch.contains(prepared, quote: "okay") && !QuoteMatch.contains(prepared, quote: ""),
          rule: "a quote of a word or two proves nothing and is refused",
          meaning: "\"okay\" is in every transcript",
          saw: "found")
    let across = QuoteMatch.prepare("[00:12] You: I'll send the deck\n[00:15] You: to Maria tomorrow")
    check(QuoteMatch.contains(across, quote: "I'll send the deck to Maria tomorrow"),
          rule: "a quote that runs across two lines of the transcript is found",
          meaning: "time and speaker markers are not speech; they must not break a sentence in two",
          saw: across)
    check(QuoteMatch.visibleTimestamp("00:12", in: input) == "00:12"
          && QuoteMatch.visibleTimestamp("[00:12]", in: input) == "00:12"
          && QuoteMatch.visibleTimestamp("07:07", in: input) == nil
          && QuoteMatch.visibleTimestamp("soon", in: input) == nil,
          rule: "a time is kept only if the text shows it",
          meaning: "a made-up time next to a real quote sends the reader to the wrong minute",
          saw: "—")
}

// MARK: the map step

do {
    let part = "[00:12] You: I'll send the pricing deck to Maria by Friday.\n[00:30] Them: I will review it."
    let reply = """
    Sure! {"points":["pricing"],"decisions":[],"actions":[
      {"owner":"Aik","task":"send the deck","due":"Friday","quote":"I'll send the pricing deck to Maria"},
      {"owner":"Maria","task":"book a venue","due":"","quote":"I will book the venue next week"},
      {"owner":"Maria","task":"no quote","due":"","quote":""}],
     "questions":[],"speakers":[{"name":"Maria","clue":"addressed by name"}]}
    """
    let decoded = LongMeetingMap.decode(reply)
    check(decoded?.actions?.count == 3,
          rule: "a reply wrapped in prose is still read as the JSON object it holds",
          meaning: "a model that adds a greeting must not cost a whole part of the meeting",
          saw: "\(String(describing: decoded))")
    let (kept, dropped) = LongMeetingMap.believed(decoded!, chunk: TranscriptChunk(index: 0, body: part, overlap: "", startSeconds: nil, endSeconds: nil))
    check(kept.actions?.map { $0.task ?? "" } == ["send the deck"] && dropped == 2,
          rule: "an action is kept only when its quote is in the part",
          meaning: "the notes must not carry a promise the transcript does not hold",
          saw: "kept \(kept.actions?.count ?? -1), dropped \(dropped)")
    check(LongMeetingMap.decode("{\"points\":[\"only this\"]}")?.points == ["only this"]
          && LongMeetingMap.decode("no json here") == nil,
          rule: "a reply missing keys is a part with none of those; text with no object is unreadable",
          meaning: "an empty list is a valid answer, unreadable is the model's failure and is retried",
          saw: "—")
    var known: [(name: String, clue: String)] = []
    LongMeetingMap.merge(decoded!.speakers, into: &known)
    LongMeetingMap.merge([LongMeetingMap.Speaker(name: "maria", clue: "introduced herself")], into: &known)
    check(known.count == 1 && known[0].clue == "introduced herself"
          && LongMeetingMap.knownText(known).contains("Maria"),
          rule: "speaker clues carry forward, one entry per person, the newest clue wins",
          meaning: "the next part is told who the \"Them\" speakers were, not a list that grows with repeats",
          saw: "\(known)")
    let rendered = LongMeetingMap.render(kept, part: 2, parts: 5, range: "20:00–39:55")
    check(rendered.hasPrefix("### Part 2 of 5 (20:00–39:55)") && rendered.contains("Aik: send the deck (due: Friday)"),
          rule: "a part's notes are written down with their position and time range",
          meaning: "the merge step reads parts in order and must know where each sits",
          saw: rendered)
    check(LongMeetingMap.withoutTranscript("# Meeting notes — A\n\n## Summary\nx\n\n## Transcript\nlong copy") == "# Meeting notes — A\n\n## Summary\nx",
          rule: "a transcript the merge step added anyway is removed",
          meaning: "the real transcript is built in code; a model's copy would be a second, worse one",
          saw: LongMeetingMap.withoutTranscript("# A\n## Transcript\nx"))
    let schema = (try? JSONSerialization.jsonObject(with: Data(LongMeetingMap.schema.utf8))) as? [String: Any]
    check((schema?["required"] as? [String])?.count == 5,
          rule: "the map schema is valid JSON and requires all five keys",
          meaning: "an invalid schema is rejected by the engine; a missing key lets a part skip a list",
          saw: "\(String(describing: schema?["required"]))")
}

// MARK: quote tolerance

do {
    let text = "[05:03] Them: Мы пришлём всё на 1 000 человек, ещё до пятницы. Потом обсудим бюджет проекта и сроки."
    let hay = QuoteMatch.prepare(text)
    check(QuoteMatch.contains(hay, quote: "Мы пришлем все на 1000 человек, еще до пятницы"),
          rule: "ё and е, and the space inside 1 000, do not stop a quote matching",
          meaning: "recognizers and models disagree on both; the sentence is still the one that was said",
          saw: hay)
    check(QuoteMatch.contains(hay, quote: "Them: Мы пришлём всё на 1 000 человек ещё до пятницы")
          && QuoteMatch.contains(hay, quote: "Мария: Мы пришлём всё на 1 000 человек ещё до пятницы"),
          rule: "a speaker label at the start of a quote is ignored",
          meaning: "models copy the label with the sentence",
          saw: "—")
    check(QuoteMatch.contains(hay, quote: "Мы пришлём всё на 1 000 человек … Потом обсудим бюджет проекта")
          && QuoteMatch.contains(hay, quote: "Мы пришлём всё на [...] ещё до пятницы Потом")
          && !QuoteMatch.contains(hay, quote: "Потом обсудим бюджет … Мы пришлём всё на 1 000"),
          rule: "a quote with a gap marked … is found when each piece is, in order",
          meaning: "models skip words with an ellipsis; but pieces in the wrong order are not the text",
          saw: "—")
    check(!QuoteMatch.contains(hay, quote: "Мы пришлём … человек"),
          rule: "a piece of fewer than three words between gaps is refused",
          meaning: "two words match anywhere and prove nothing",
          saw: "found")
    check(QuoteMatch.contains(hay, quote: "Мы пришлём всё человек ещё до пятницы Потом обсудим бюджет")
          && !QuoteMatch.contains(hay, quote: "Мы отправим всё на 2 000 человек ещё после пятницы"),
          rule: "a copy missing a word or two still matches; a rewritten sentence does not",
          meaning: "80% of the words in order is a copy with slips; less is another sentence",
          saw: "—")
    check(!QuoteMatch.contains(hay, quote: "до пятницы") && !QuoteMatch.contains(hay, quote: "бюджет проекта"),
          rule: "a quote of fewer than four words is refused",
          meaning: "a few words are in every transcript",
          saw: "found")
    check(QuoteMatch.visibleTimestamp("5:03", in: text) == "05:03"
          && QuoteMatch.visibleTimestamp("05:03", in: text) == "05:03"
          && QuoteMatch.visibleTimestamp("5:04", in: text) == nil,
          rule: "\"5:03\" is the time \"[05:03]\" and is returned zero-padded",
          meaning: "models drop the zero; the time is still the one the transcript shows",
          saw: "—")
    // Overlap: a sentence only in the repeated context belongs to the part before.
    let overlap = "[10:00] You: I will send the final contract to the client tomorrow."
    let body = "[10:30] Them: Thanks. Then we agree on the timeline for the launch."
    let both = QuoteMatch.Haystack(overlap: overlap, body: body)
    check(!QuoteMatch.contains(both, quote: "I will send the final contract to the client tomorrow")
          && QuoteMatch.contains(both, quote: "we agree on the timeline for the launch")
          && QuoteMatch.contains(both, quote: "send the final contract to the client tomorrow Thanks Then we agree on"),
          rule: "a quote found only in the repeated context is refused; one that crosses into the new lines is kept",
          meaning: "the previous part already answered for the context; a sentence cut by the boundary must not be lost",
          saw: "—")
}

// MARK: duplicates, merging in groups, sizes, headings

do {
    let a = PromiseDuplicate.entry(text: "Send the pricing deck to Maria", owner: "Aik", quote: "I'll send the deck")
    check(PromiseDuplicate.isDuplicate(text: "Send the pricing deck to Maria today", owner: "aik", quote: nil, of: [a])
          && PromiseDuplicate.isDuplicate(text: "Send the deck to Maria", owner: "Bob", quote: "ill SEND the deck", of: [a])
          && !PromiseDuplicate.isDuplicate(text: "Send the pricing deck to Maria today", owner: "Bob", quote: nil, of: [a])
          && !PromiseDuplicate.isDuplicate(text: "Book the venue for the offsite", owner: "Aik", quote: "x", of: [a]),
          rule: "the same promise from two parts is one: same quote, or same owner and nearly the same words",
          meaning: "the repeated context makes two parts report one sentence; the list must show it once",
          saw: "—")
    let groups = LongMeetingMap.group(["aaaa", "bbbb", "cccc", "dddd"], budget: 12)
    check(groups == [["aaaa", "bbbb"], ["cccc", "dddd"]]
          && LongMeetingMap.group(["a", "b"], budget: 100).count == 1,
          rule: "part notes too long for one merge are split into ordered groups that each fit",
          meaning: "the merge request must fit the model's window like every other request",
          saw: "\(groups)")
    check(TranscriptChunker.chunkSize(contextCharLimit: 38_000) == 20_000
          && TranscriptChunker.chunkSize(contextCharLimit: 24_000) == 18_000
          && TranscriptChunker.chunkSize(contextCharLimit: 8_000) == 4_000
          && TranscriptChunker.chunkSize(contextCharLimit: 400_000) == 20_000,
          rule: "a part is 20,000 characters, or the model's window less 6,000 when that is smaller, never under 4,000",
          meaning: "a part plus its overlap, instructions and reply must fit the window",
          saw: "\(TranscriptChunker.chunkSize(contextCharLimit: 24_000))")
    let md = "# Meeting notes — X\n\nWe discussed the ## Transcript section.\n\n## Transcript\n\n[00:01] **A:** hi there\n"
    check(TranscriptAssembler.transcriptSection(of: md) == "[00:01] **A:** hi there"
          && LongMeetingMap.withoutTranscript(md).hasSuffix("section."),
          rule: "the transcript heading is a line of its own; the same words in a sentence are not it",
          meaning: "cutting at the sentence would lose the summary or split the transcript",
          saw: LongMeetingMap.withoutTranscript(md))
}

// MARK: whose promise it is

do {
    let raw = """
    [00:05] You: Let's start, I will prepare the budget by Monday.
    [00:20] Them: I will send the contract to the client tomorrow morning.
    [00:40] Them: Also the specification is on me for next week.
    [01:00] 📝 NOTE: ask Maria about the venue
    """
    let people = ["Aik", "Maria", "Pavel"]
    let index = PromiseOwner.Index(text: raw, myName: "Aik")
    let mine = index.resolve(quote: "I will prepare the budget by Monday", modelOwner: "Aik", participants: people)
    let mineUnknown = index.resolve(quote: "I will prepare the budget by Monday", modelOwner: nil, participants: people)
    let handed = index.resolve(quote: "I will prepare the budget by Monday", modelOwner: "Maria", participants: people)
    check(mine.isMine && mine.owner == "Aik" && mine.at == "00:05" && mineUnknown.isMine
          && !handed.isMine && handed.owner == "Maria",
          rule: "a quote from a \"You\" line is the user's promise when the model says the user or does not know; another participant named is an assignment",
          meaning: "the microphone track is the user, but the user also hands out tasks",
          saw: "\(mine) / \(handed)")
    let lead = PromiseOwner.Index(text: "[00:05] You: Pavel, please review the contract draft by Friday.\n[00:09] Them: Okay.", myName: "Aik")
    let assigned = lead.resolve(quote: "Pavel, please review the contract draft by Friday", modelOwner: nil, participants: people)
    let assignedMe = lead.resolve(quote: "Pavel, please review the contract draft by Friday", modelOwner: "Aik", participants: people)
    check(!assigned.isMine && assigned.owner == "Pavel" && assignedMe.isMine,
          rule: "on a \"You\" line a participant addressed by name gets the task when the owner is unknown",
          meaning: "a lead who says \"Pavel, review this\" is not promising to do it; 13 of 17 promises came back as the user's",
          saw: "\(assigned) / \(assignedMe)")
    let ru = PromiseOwner.Index(text: "[00:05] You: Вика, посмотри договор до пятницы.", myName: "Аик")
    let vika = ru.resolve(quote: "Вика, посмотри договор до пятницы", modelOwner: "", participants: ["Аик", "Вика"])
    check(!vika.isMine && vika.owner == "Вика",
          rule: "a participant's name is found in the line whatever its form",
          meaning: "Russian names change endings; \"Вике\" and \"Вику\" are Вика",
          saw: "\(vika)")
    let called = PromiseOwner.Index(text: "[00:05] Them: Aik, send the invoice today please.", myName: "Aik")
    let c1 = called.resolve(quote: "Aik, send the invoice today please", modelOwner: "Aik", participants: people)
    let c2 = called.resolve(quote: "Aik, send the invoice today please", modelOwner: "Maria", participants: people)
    check(c1.isMine && !c2.isMine && c2.owner == "Maria",
          rule: "a \"Them\" line is the user's only if it names the user and the model says the user",
          meaning: "someone asking the user to do something is a task for the user; anything else said by them is not",
          saw: "\(c1) / \(c2)")
    let theirs = index.resolve(quote: "I will send the contract to the client tomorrow", modelOwner: "Aik", participants: people)
    check(!theirs.isMine && theirs.owner == "Them" && theirs.at == "00:20",
          rule: "a quote from a \"Them\" line is never the user's, and the owner is \"Them\" unless the model named another participant",
          meaning: "a model that cannot tell the speakers apart defaults to the user",
          saw: "\(theirs)")
    let named = index.resolve(quote: "the specification is on me for next week", modelOwner: "Pavel", participants: people)
    check(!named.isMine && named.owner == "Pavel"
          && !index.resolve(quote: "the specification is on me for next week", modelOwner: "Stranger", participants: people).isMine
          && index.resolve(quote: "the specification is on me for next week", modelOwner: "Stranger", participants: people).owner == "Them",
          rule: "for a \"Them\" line the model's owner is used only if it is a participant other than the user",
          meaning: "an invented or user name on someone else's sentence is wrong either way",
          saw: "\(named)")
    let note = index.resolve(quote: "ask Maria about the venue", modelOwner: "Aik", participants: people)
    check(note.isMine, rule: "a typed note is the user's own words",
          meaning: "the user wrote it; a promise in it is theirs", saw: "\(note)")
    let across = index.resolve(quote: "prepare the budget by Monday I will send the contract to the client tomorrow morning", modelOwner: "Aik", participants: people)
    let acrossOther = index.resolve(quote: "prepare the budget by Monday I will send the contract to the client tomorrow morning", modelOwner: "Maria", participants: people)
    check(across.isMine && !acrossOther.isMine && acrossOther.owner == "Maria",
          rule: "a quote across both speakers is the user's only if the model says so",
          meaning: "the user spoke in it, but so did someone else; the model's word decides",
          saw: "\(across) / \(acrossOther)")
    let legacy = index.resolve(quote: nil, modelOwner: "Maria", participants: people)
    check(!legacy.isMine && legacy.owner == "Maria" && index.resolve(quote: nil, modelOwner: "Aik", participants: people).isMine
          && !index.resolve(quote: nil, modelOwner: nil, participants: people).isMine,
          rule: "with no quote the promise is the user's only if the model's owner is the user",
          meaning: "an unverified claim must not default to the user",
          saw: "\(legacy)")
    let notes = "## Summary\n\nStuff.\n\n## Transcript\n\n[00:05] **Aik:** I will prepare the budget by Monday.\n\n**Maria:** I will send the contract tomorrow morning to the client.\n\n**Speaker:** Maybe the venue gets booked."
    let labelled = PromiseOwner.Index(text: notes, myName: "Aik")
    let a = labelled.resolve(quote: "I will prepare the budget by Monday", modelOwner: "Aik", participants: people)
    let b = labelled.resolve(quote: "I will send the contract tomorrow morning to the client", modelOwner: "Aik", participants: people)
    check(a.isMine && !b.isMine && b.owner == "Maria" && a.at == "00:05",
          rule: "in finished notes the speaker label of the quoted line decides: the user's name is the user, another name is that person",
          meaning: "cloud notes carry real names; the promise belongs to the one who said it",
          saw: "\(a) / \(b)")
}

// MARK: the language of the meeting

do {
    let russian = """
    [00:05] You: Привет, давайте начнём. Сегодня обсуждаем деплой нового релиза и стейкинг.
    [00:12] Them: Да, я проверил GitHub, пулл-реквест уже смержили, осталось только прогнать тесты на мейннете.
    [00:25] You: Хорошо, Вика, посмотри, пожалуйста, договор до пятницы и пришли мне.
    [00:41] Them: Договорились, я отправлю вам обновлённый документ завтра утром.
    [01:02] 📝 NOTE: спросить про бюджет
    """
    let name = MeetingLanguage.name(of: russian, dictationLocales: [])
    check(name == "Russian",
          rule: "a Russian transcript with English tech terms is recognized as Russian",
          meaning: "an unconstrained recognizer said Kazakh and the notes and promises came back in Kazakh",
          saw: "\(String(describing: name))")
    let short = MeetingLanguage.name(of: "[00:05] You: Скинь пожалуйста ссылку на документ.\n[00:09] Them: Хорошо, сейчас пришлю.", dictationLocales: [])
    let ukrainian = MeetingLanguage.name(of: "[00:05] You: Скинь будь ласка посилання на документ, який ми їхні.", dictationLocales: [])
    check(short == "Russian" && ukrainian == "Ukrainian",
          rule: "a short Russian exchange is Russian, and Ukrainian text with its own letters is Ukrainian",
          meaning: "the recognizer called short Russian Ukrainian and long Russian Kazakh",
          saw: "\(String(describing: short)) / \(String(describing: ukrainian))")
    check(MeetingLanguage.name(of: "[00:05] 1234 5678 -- 42", dictationLocales: []) == nil
          && MeetingLanguage.allowed(dictationLocales: ["fr-FR, es"]).contains("fr")
          && MeetingLanguage.allowed(dictationLocales: []).sorted() == ["de", "en", "hy", "ru", "uk"]
          && Prompts.languageLine(nil).contains("the language the speakers use"),
          rule: "with no clear language nothing is named; the supported set grows with the dictation locales",
          meaning: "a wrong name is worse than none: the model writes everything in it",
          saw: "\(String(describing: MeetingLanguage.name(of: "[00:05] 1234 5678 -- 42", dictationLocales: [])))")
}

// MARK: review fixes

do {
    let raw = "[00:05] You: Вика, посмотри договор до пятницы.\n[00:09] Them: Хорошо."
    let idx = PromiseOwner.Index(text: raw, myName: "Aik Sargsian")
    let q = "Вика, посмотри договор до пятницы"
    let viaCalendar = idx.resolve(quote: q, modelOwner: "Вика", participants: ["Aik Sargsian", "Victoria Petrova"])
    let noRoster = idx.resolve(quote: q, modelOwner: "Вика", participants: [])
    check(!viaCalendar.isMine && viaCalendar.owner == "Вика" && !noRoster.isMine && noRoster.owner == "Вика",
          rule: "on a \"You\" line a name the model gives for someone else is kept, listed or not",
          meaning: "a calendar says Victoria and the speaker says Вика; with no roster at all the assignment is still not the user's",
          saw: "\(viaCalendar) / \(noRoster)")
    let typed = PromiseOwner.Index(text: "[00:30] 📝 NOTE: Pavel to send the invoice", myName: "Aik")
        .resolve(quote: "Pavel to send the invoice", modelOwner: "Pavel", participants: [])
    check(!typed.isMine && typed.owner == "Pavel",
          rule: "a typed note that names someone else's task is not the user's",
          meaning: "the user wrote it down; it was not them who promised it",
          saw: "\(typed)")
    let legacy = idx.resolve(quote: nil, modelOwner: "Вика", participants: [])
    check(!legacy.isMine && legacy.owner == "Вика",
          rule: "with no quote the model's own name for the owner is kept",
          meaning: "\"Them\" in place of a name the model gave loses information that was there",
          saw: "\(legacy)")
    let talk = [PromiseDuplicate.entry(text: "Подготовить оффер для кандидата А через HR до пятницы", owner: "Alex", quote: nil),
                PromiseDuplicate.entry(text: "Сделать группировку пушей на бэкенде", owner: "Them", quote: nil),
                PromiseDuplicate.entry(text: "Сгруппировать уведомления на бэкенде", owner: "Иван", quote: nil)]
    check(PromiseDuplicate.restatement(text: "Отправить оффер кандидату А", of: talk, skipping: []) == 0
          && PromiseDuplicate.restatement(text: "Группировка пушей на бэкенде", of: talk, skipping: []) == 1
          && PromiseDuplicate.restatement(text: "Группировка пушей на бэкенде", of: talk, skipping: [1]) == nil
          && PromiseDuplicate.restatement(text: "Экран технических работ", of: talk, skipping: []) == nil,
          rule: "an item of a read-back matches the promise as it was made, whoever the read-back names; "
              + "items of the same read-back never match each other",
          meaning: "the recap is one line the model splits among people and misattributes — "
                 + "the offer read back under Ivan's name was counted as a second promise",
          saw: "")
    let captured = "Иван: скину схему до пятницы\nМайя: ок, спасибо"
    let noDate: (String) -> Date? = { _ in nil }
    let theirs = CapturedPromise.from(["owner": "Иван", "task": "Скинуть схему", "due": "до пятницы",
                                       "quote": "скину схему до пятницы"],
                                      capturedText: captured, myName: "Aik", parseDate: noDate)
    let mineCaptured = CapturedPromise.from(["owner": "me", "task": "Send the deck", "quote": "I'll send the deck"],
                                            capturedText: "Sure, I'll send the deck tonight", myName: "Aik", parseDate: noDate)
    let invented = CapturedPromise.from(["owner": "Иван", "task": "Скинуть схему", "quote": "скину схему сегодня вечером"],
                                        capturedText: captured, myName: "Aik", parseDate: noDate)
    check(theirs?.owner == "Иван" && theirs?.isMine == false && theirs?.dueHint == "до пятницы"
          && mineCaptured?.isMine == true && mineCaptured?.owner == "Aik"
          && invented == nil
          && CapturedPromise.from(nil, capturedText: captured, myName: "Aik", parseDate: noDate) == nil,
          rule: "a promise found in captured text keeps its owner, is mine when the model says me, "
              + "and is dropped when its quote is not in the text",
          meaning: "Remind me only offers what was really written; an invented quote would put a promise "
                 + "nobody made into the list with one click",
          saw: "\(String(describing: theirs)) \(String(describing: mineCaptured)) \(String(describing: invented))")
    check(PromiseOwner.sameName("Аня", "Anya") && PromiseOwner.sameName("Ваня", "Vanya")
          && PromiseOwner.sameName("Даня", "Danya") && PromiseOwner.sameName("Мария", "Maria")
          && PromiseOwner.sameName("Юля", "Julia") && !PromiseOwner.sameName("Аня", "Ваня"),
          rule: "a Cyrillic name with я or ю is the same name as its usual Latin spelling",
          meaning: "the system transliteration makes \"Аня\" \"Ânâ\", so Anya's promises in a mixed meeting became a stranger's",
          saw: "\(PromiseOwner.fold("Аня")) \(PromiseOwner.fold("Anya")) \(PromiseOwner.fold("Мария"))")
    check(PromiseOwner.normalizeOwner("[55:35] Alex") == "Alex" && PromiseOwner.normalizeOwner("**Майя**") == "Майя"
          && PromiseOwner.normalizeOwner("[1:02:03] Tom") == "Tom",
          rule: "a timestamp or bold copied along with an owner's name is dropped",
          meaning: "\"[55:35] Alex\" is nobody, so the user's promise was filed under a name no one has",
          saw: PromiseOwner.normalizeOwner("[55:35] Alex"))
    let recapSeen = [PromiseDuplicate.entry(
        text: "Подготовить письменный план миграции Postgres с шагами, проверками и планом отката",
        owner: "Them", quote: "План миграции с шагами, проверками и планом отката я подготовлю к следующему четвергу.")]
    check(PromiseDuplicate.duplicate(text: "Сделать план миграции Postgres с откатом", owner: "Даня",
                                     quote: "Даня — план миграции с откатом к следующему четвергу", of: recapSeen) == 0
          && PromiseDuplicate.duplicate(text: "Сделать постмортем по инцидентам", owner: "Alex", quote: nil,
                                        of: [PromiseDuplicate.entry(text: "Написать постмортем по инциденту поиска до пятницы",
                                                                    owner: "Alex", quote: nil)]) == 0,
          rule: "the recap at the end of a meeting is the same promise, and names an unnamed earlier copy's owner",
          meaning: "every promise read back in the recap was counted twice — once as \"Them\" from the talk, once by name",
          saw: "")
    check(PromiseDuplicate.duplicate(text: "Написать тест-план для bulk edit", owner: "Аня", quote: nil,
                                     of: [PromiseDuplicate.entry(text: "Написать базовый API для bulk edit", owner: "Ваня", quote: nil)]) == nil
          && PromiseDuplicate.duplicate(text: "Сделать раскатку фича-флага для пушей", owner: "Олег", quote: nil,
                                        of: [PromiseDuplicate.entry(text: "Сделать мобильную часть пушей", owner: "Олег", quote: nil)]) == nil
          && PromiseDuplicate.duplicate(text: "Написать тест-план для bulk edit", owner: "Аня", quote: nil,
                                        of: [PromiseDuplicate.entry(text: "Написать базовый API для bulk edit", owner: "Them", quote: nil)]) == nil,
          rule: "different work stays two promises, even for the same person or an unnamed one",
          meaning: "merging on shared topic words would silently drop real promises",
          saw: "")
    check(PromiseOwner.isMe("You", myName: "Aik") && PromiseOwner.isMe("me", myName: "Aik")
          && PromiseOwner.isMe("Алекс", myName: "Alex") && PromiseOwner.sameName("Max", "Макс")
          && !PromiseOwner.isMe("Yuri", myName: "Aik"),
          rule: "\"You\" is the user, and a Cyrillic spelling with кс is the same name as one with x",
          meaning: "fold reads y as i, so a literal \"you\" never matched; and \"Алекс\" folded to \"aleks\", "
                 + "so the user's own promises in a Russian meeting were filed as someone else's",
          saw: "\(PromiseOwner.fold("You")) \(PromiseOwner.fold("Алекс")) \(PromiseOwner.fold("Alex"))")
    check(PromiseOwner.isMe("Айк", myName: "Aik Sargsian") && PromiseOwner.isMe("Aik", myName: "Aik Sargsian")
          && PromiseOwner.isMe("AÏK", myName: "Aik") && !PromiseOwner.isMe("Maria", myName: "Aik Sargsian"),
          rule: "the user's name is recognised in another script, by first name alone, and without accents",
          meaning: "a Cyrillic \"Айк\" label for \"Aik Sargsian\" otherwise reads as a stranger and the user's promises go to someone else",
          saw: "—")
    let cyr = PromiseOwner.Index(text: "[00:05] **Айк:** I will send the budget today for sure.", myName: "Aik Sargsian")
    let r = cyr.resolve(quote: "I will send the budget today for sure", modelOwner: "Aik", participants: ["Aik Sargsian", "Айк"])
    check(r.isMine, rule: "a Cyrillic label of the user's own name is the user, and is not another participant",
          meaning: "the speaker label decides whose promise it is", saw: "\(r)")
    let call = PromiseOwner.Index(text: "[00:05] Them: Please send the invoice today.", myName: "Aik")
    check(call.resolve(quote: "Please send the invoice today", modelOwner: "Aik", participants: ["Aik", "Maria"]).isMine
          && !call.resolve(quote: "Please send the invoice today", modelOwner: "Aik", participants: ["Aik", "Maria", "Pavel"]).isMine,
          rule: "in a call of two, a request on the other person's line that the model gives to the user is the user's",
          meaning: "with one other person there is nobody else it can be asked of; with more, the line must name the user",
          saw: "—")
    let echo = PromiseOwner.Index(text: "## Action items\n\n- Aik: I will send the budget today for sure\n\n## Transcript\n\n[00:05] **Maria:** I will send the budget today for sure.", myName: "Aik")
    let e = echo.resolve(quote: "I will send the budget today for sure", modelOwner: "Aik", participants: ["Aik", "Maria", "Pavel"])
    check(!e.isMine && e.owner == "Maria",
          rule: "a quote is located in the transcript line, not in a summary line that repeats it",
          meaning: "the summary names no speaker; the transcript says who spoke",
          saw: "\(e)")
    let cut = "Sure: [{\"text\":\"a\"},{\"text\":\"b\"},{\"text\":\"c"
    let salvaged = LongMeetingMap.arrayCandidates(cut).compactMap {
        try? JSONSerialization.jsonObject(with: $0) as? [[String: String]]
    }.first
    check(salvaged?.count == 2,
          rule: "a list cut off by the token limit keeps its complete elements",
          meaning: "losing the whole list for one half-written promise loses every promise before it",
          saw: "\(String(describing: salvaged))")
    let d1 = PromiseDuplicate.entry(text: "Send the budget to Maria", owner: "Aik", quote: "I will send the budget")
    check(!PromiseDuplicate.isDuplicate(text: "Send the budget to Maria", owner: "Pavel", quote: nil, of: [d1])
          && !PromiseDuplicate.isDuplicate(text: "Book a hotel", owner: "Pavel", quote: "I will send the budget", of: [d1])
          && PromiseDuplicate.duplicate(text: "Send budget to Maria", owner: "Aik", quote: "i will send the budget", of: [d1]) == 0,
          rule: "the same words for another owner are another promise; a shared quote also needs similar wording",
          meaning: "two people can each owe the same task, and one sentence can hold two promises",
          saw: "—")
}

// MARK: owner strings the model returns

do {
    check(PromiseOwner.normalizeOwner("Саша (Саша Файн, ведущий)") == "Саша"
          && PromiseOwner.normalizeOwner("Все участники (команда)") == "Them"
          && PromiseOwner.normalizeOwner("everyone") == "Them"
          && PromiseOwner.normalizeOwner("Неопределенно (из контекста)") == ""
          && PromiseOwner.normalizeOwner("Unknown (nobody said)") == ""
          && PromiseOwner.normalizeOwner("—") == "" && PromiseOwner.normalizeOwner(nil) == "",
          rule: "an owner string loses its trailing parenthetical; groups become \"Them\"; \"unknown\" in any form is unknown",
          meaning: "models write \"Саша (Саша Файн…)\" and \"Все участники (…)\"; those are not names to store",
          saw: PromiseOwner.normalizeOwner("Саша (Саша Файн, ведущий)"))
    let raw = "[00:05] You: Саша, посмотри договор до пятницы.\n[00:09] Them: Хорошо."
    let idx = PromiseOwner.Index(text: raw, myName: "Aik")
    let q = "Саша, посмотри договор до пятницы"
    let people = ["Aik", "Aleksandr Fain"]
    let a = idx.resolve(quote: q, modelOwner: "Александр (Саша Файн)", participants: people)
    let b = idx.resolve(quote: q, modelOwner: "Все участники (все)", participants: people)
    let c = idx.resolve(quote: q, modelOwner: "Неопределенно (нет)", participants: ["Aik", "Саша"])
    check(!a.isMine && a.owner == "Aleksandr Fain",
          rule: "a participant named in the model's own spelling gets their canonical name",
          meaning: "\"Александр\" and \"Aleksandr Fain\" are one person; two spellings would be two owners",
          saw: "\(a)")
    check(b.isMine && c.owner == "Саша" && !c.isMine,
          rule: "a group or unknown owner on a You line follows the unknown rules: addressee if named, else the user",
          meaning: "\"Все участники\" is not a person and must not be stored as one",
          saw: "\(b) / \(c)")
}

// MARK: the record and the request

do {
    let old = #"[{"text":"Send the deck","owner":"Aik","isMine":true,"sourceTitle":"Pricing"}]"#
    let items = try? JSONDecoder().decode([Commitment].self, from: Data(old.utf8))
    check(items?.count == 1 && items?.first?.sourceQuote == nil && items?.first?.sourceAt == nil,
          rule: "a record saved before promises kept their quote still decodes, with none",
          meaning: "the promises file is one array; a decoder that needs the new key loses every promise",
          saw: items == nil ? "decoding threw" : "decoded")
    let item = Commitment(text: "Send the deck", owner: "Aik", isMine: true, sourceTitle: "Pricing",
                          sourceQuote: "I'll send the deck", sourceAt: "12:30")
    let back = (try? JSONEncoder().encode([item])).flatMap { try? JSONDecoder().decode([Commitment].self, from: $0) }
    check(back?.first?.sourceQuote == "I'll send the deck" && back?.first?.sourceAt == "12:30",
          rule: "a promise's quote and time survive being saved and read back",
          meaning: "the quote is the evidence; lost on quit it protects nobody",
          saw: "\(String(describing: back?.first?.sourceQuote))")
    let plain = OllamaRequest.chatBody(model: "m", system: "s", user: "u", maxTokens: 10)
    let shaped = OllamaRequest.chatBody(model: "m", system: "s", user: "u", maxTokens: 10,
                                        schema: ["type": "object"])
    check(plain["format"] == nil && (shaped["format"] as? [String: String]) == ["type": "object"],
          rule: "Ollama is given a JSON schema as `format` only when one is asked for",
          meaning: "a format on a free-text request would force JSON on every summary",
          saw: "plain \(String(describing: plain["format"])), shaped \(String(describing: shaped["format"]))")
}

return failures
}
