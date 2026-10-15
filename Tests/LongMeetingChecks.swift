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
    let (kept, dropped) = LongMeetingMap.believed(decoded!, chunkBody: part)
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
