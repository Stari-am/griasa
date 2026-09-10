import Foundation

// Checks for the promise record's decoder. The file this guards holds every
// open promise the user has; a decoder that throws on one missing key loses all
// of them at once, because the array is decoded in a single call.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runCommitmentChecks() -> Int {
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

// The plain coders, deliberately: CommitmentStore uses `JSONDecoder()` and
// `JSONEncoder()` with no date strategy, so dates on disk are numbers. A check
// configured with .iso8601 passed every synthetic case and then failed on the
// real file — which is exactly the mistake this check exists to catch, made by
// the check itself.
let decoder = JSONDecoder()
let encoder = JSONEncoder()

// A file written before the closure fields existed — which is every file on
// every machine that has ever run this app.
do {
    let old = """
    [{"id":"6C7B5B4E-0000-4000-8000-000000000001","text":"Send the pricing model",
      "owner":"Petrov","isMine":false,"sourceTitle":"Pricing review",
      "date":778413600,"done":false}]
    """
    let items = try? decoder.decode([Commitment].self, from: Data(old.utf8))
    check(items?.count == 1 && items?.first?.suggestedDoneQuote == nil,
          rule: "a record saved before the closure fields existed still decodes",
          meaning: "the promises file is decoded as one array, so a decoder that throws on "
                 + "a missing key does not lose one record — it loses every record",
          saw: items == nil ? "decoding threw" : "decoded \(items!.count), quote "
             + "\(String(describing: items!.first?.suggestedDoneQuote))")
}

// Only `text` is genuinely required. Everything else has to survive absence,
// including fields that predate this change.
do {
    let sparse = #"[{"text":"Just the text"}]"#
    let items = try? decoder.decode([Commitment].self, from: Data(sparse.utf8))
    check(items?.count == 1 && items?.first?.isMine == true && items?.first?.done == false,
          rule: "a record with nothing but its text decodes to sensible defaults",
          meaning: "records have been written by four versions of this app; the decoder has "
                 + "to read all of them, not the newest shape",
          saw: items == nil ? "decoding threw" : "isMine \(items!.first!.isMine), "
             + "done \(items!.first!.done)")
}

// The evidence has to survive a round trip, or a detection is lost on quit and
// the same conversation gets re-analysed forever.
do {
    let item = Commitment(text: "Send the pricing model", owner: "Petrov", isMine: false,
                          sourceTitle: "Pricing review",
                          suggestedDoneQuote: "sent it this morning",
                          suggestedDoneAt: Date(timeIntervalSince1970: 1_800_000_000))
    let back = (try? encoder.encode(item)).flatMap {
        try? decoder.decode(Commitment.self, from: $0)
    }
    check(back?.suggestedDoneQuote == "sent it this morning"
          && back?.suggestedDoneAt == item.suggestedDoneAt,
          rule: "a detected closure and its quote survive being saved and read back",
          meaning: "the quote is the only thing that lets a person judge the detection in "
                 + "one glance; losing it turns the suggestion into an unexplained claim",
          saw: "quote \(String(describing: back?.suggestedDoneQuote))")
}

// A suggestion on an already-closed promise must not be offered again.
do {
    var item = Commitment(text: "x", owner: "Petrov", isMine: false, sourceTitle: "",
                          suggestedDoneQuote: "did it")
    let openHasIt = item.hasClosureSuggestion
    item.done = true
    check(openHasIt && !item.hasClosureSuggestion,
          rule: "a closed promise offers no closure suggestion",
          meaning: "otherwise a promise the user already ticked keeps asking to be ticked",
          saw: "open \(openHasIt), closed \(item.hasClosureSuggestion)")
}

// The real file, because a synthetic case proves the decoder handles the shape
// somebody imagined, and this one proves it handles the shape on disk.
do {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Griasa/commitments.json")
    if let data = try? Data(contentsOf: url) {
        let items = try? decoder.decode([Commitment].self, from: data)
        check(items != nil,
              rule: "the real commitments.json on this machine decodes",
              meaning: "this is the file the change is actually risking; a synthetic case "
                     + "only proves the shape somebody thought of",
              saw: items == nil ? "decoding threw" : "decoded \(items!.count)")
        if let items { print("  · the real commitments.json decodes: \(items.count) promises") }
    } else {
        print("  · no commitments.json on this machine — skipped the live decode")
    }
}

return failures
}
