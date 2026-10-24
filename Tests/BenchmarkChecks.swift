import Foundation

// Checks for the public benchmark: the scorer's matching rules, and that the
// meetings under benchmark/ are what they claim to be — every file reads, every
// line is a line the recorder could have written, every gold quote is really
// in its transcript.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runBenchmarkChecks() -> Int {
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

typealias Gold = BenchmarkScore.Gold
typealias Prediction = BenchmarkScore.Prediction

let meta = BenchmarkScore.Meta(title: "t", language: "en", myName: "Alex",
                               participants: ["Maya", "Иван"], aliases: ["Иван": ["Ваня"]])
let gold = [
    Gold(owner: "Alex", isMine: true, task: "Send the pricing draft to Maya",
         due: "by Friday", quote: "I'll send you the pricing draft by Friday"),
    Gold(owner: "Maya", isMine: false, task: "Book the room for the offsite",
         due: nil, quote: "okay, I'll book the room for the offsite"),
]

// The model's quote is the same words, though tidied: a match.
do {
    let predicted = [Prediction(owner: "You", isMine: true, task: "pricing",
                                quote: "I will send you the pricing draft by Friday.")]
    let r = BenchmarkScore.score(gold: gold, predicted: predicted, meta: meta)
    check(r.matched == 1 && r.pairs.first?.gold == 0 && r.pairs.first?.byQuote == true,
          rule: "a prediction quoting the gold words matches, whatever its task says",
          meaning: "the quote is the evidence the app shows the user; a short task title is not a miss",
          saw: "\(r.pairs)")
}

// No quote, same owner, the task in other words: a match.
do {
    let predicted = [Prediction(owner: "Maya", isMine: false, task: "Maya books the offsite room", quote: nil)]
    let r = BenchmarkScore.score(gold: gold, predicted: predicted, meta: meta)
    check(r.matched == 1 && r.pairs.first?.gold == 1 && r.pairs.first?.byQuote == false,
          rule: "the same owner and a paraphrased task match",
          meaning: "a model that rewords a promise still found it",
          saw: "\(r.pairs)")
    check(r.recall == 0.5 && r.precision == 1 && r.mineAccuracy == 1,
          rule: "recall, precision and mine/theirs accuracy follow from the counts",
          meaning: "the table reports these three numbers",
          saw: "recall \(String(describing: r.recall)), precision \(String(describing: r.precision))")
}

// The same task for someone else: no match.
do {
    let predicted = [Prediction(owner: "Daniel", isMine: false, task: "Book the room for the offsite", quote: nil)]
    let r = BenchmarkScore.score(gold: gold, predicted: predicted, meta: meta)
    check(r.matched == 0,
          rule: "a task matched to the wrong owner is not a match",
          meaning: "a promise on the wrong person's list is the error that costs most",
          saw: "\(r.matched) matched")
}

// Names across scripts and aliases.
do {
    let g = [Gold(owner: "Иван", isMine: false, task: "Переписать retry для вебхуков", due: nil,
                  quote: "ладно, я перепишу retry для вебхуков")]
    for owner in ["Ваня", "Ivan", "Иван"] {
        let r = BenchmarkScore.score(gold: g, predicted: [Prediction(owner: owner, isMine: false,
                                     task: "Переписать retry вебхуков", quote: nil)], meta: meta)
        check(r.matched == 1,
              rule: "an owner in another script or by a listed alias is the same person",
              meaning: "the model writes the name it heard; that is not a different person",
              saw: "\(owner): \(r.matched) matched")
    }
    let mine = BenchmarkScore.score(gold: [gold[0]], predicted: [Prediction(owner: "You", isMine: true,
                                    task: "send pricing draft to Maya", quote: nil)], meta: meta)
    check(mine.matched == 1,
          rule: "\"You\" and the user's name are one owner",
          meaning: "the app writes either for the user's own promises",
          saw: "\(mine.matched) matched")
}

// Russian and Ukrainian endings: the same task in another case is the same task.
do {
    let oleg = BenchmarkScore.Meta(title: "t", language: "ru", myName: "Alex", participants: ["Олег"], aliases: nil)
    let g = [Gold(owner: "Олег", isMine: false, task: "Сделать в мобильном приложении экран технических работ",
                  due: nil, quote: "Я сделаю экран технических работ в этом спринте")]
    let found = Prediction(owner: "Олег", isMine: false,
                           task: "Добавить в мобильное приложение экран «Технические работы» по специальному ответу backend",
                           quote: nil)
    let r = BenchmarkScore.score(gold: g, predicted: [found], meta: oleg)
    check(r.matched == 1,
          rule: "a task matches across inflections (мобильном/мобильное, технических/Технические)",
          meaning: "a Russian or Ukrainian paraphrase changes word endings; a whole-word comparison calls it a miss",
          saw: "jaccard \(BenchmarkScore.jaccard(found.task, g[0].task)), \(r.matched) matched")
    check(BenchmarkScore.taskWords("Ещё «Экран», ТЕХНИЧЕСКИХ работ!") == BenchmarkScore.taskWords("еще экран технические работы"),
          rule: "task words ignore case, ё/е, quotes and punctuation, and compare by stem",
          meaning: "a model's tidying of a task is not a different task",
          saw: "\(BenchmarkScore.taskWords("Ещё «Экран», ТЕХНИЧЕСКИХ работ!"))")

    let otherOwner = BenchmarkScore.score(gold: g, predicted: [Prediction(owner: "Иван", isMine: false,
                                          task: found.task, quote: nil)], meta: oleg)
    check(otherOwner.matched == 0,
          rule: "the inflected task with a different owner is still not a match",
          meaning: "stems widen the task comparison, never the owner",
          saw: "\(otherOwner.matched) matched")
    let unrelated = Prediction(owner: "Олег", isMine: false,
                               task: "Сделать мобильную часть новых пушей: формат, тихие часы, миграция настроек", quote: nil)
    let sameOwner = BenchmarkScore.score(gold: g, predicted: [unrelated], meta: oleg)
    check(sameOwner.matched == 0,
          rule: "the same owner with an unrelated task is not a match, though both start \"сделать … мобильн…\"",
          meaning: "stems must not make every promise of one person match every other",
          saw: "jaccard \(BenchmarkScore.jaccard(unrelated.task, g[0].task)), \(sameOwner.matched) matched")

    // The best pair wins, not the first gold promise to look.
    let two = [Gold(owner: "Олег", isMine: false, task: "Сделать мобильную часть пушей", due: nil, quote: "aaaa bbbb cccc dddd"),
               Gold(owner: "Олег", isMine: false, task: "Сделать мобильную часть пушей и тихие часы", due: nil,
                    quote: "eeee ffff gggg hhhh")]
    let best = BenchmarkScore.score(gold: two, predicted: [Prediction(owner: "Олег", isMine: false,
                                    task: "Мобильная часть пушей, тихие часы", quote: nil)], meta: oleg)
    check(best.pairs.first?.gold == 1,
          rule: "a prediction goes to the gold promise it is most similar to",
          meaning: "a weaker match taking it first leaves the right promise counted as missed",
          saw: "\(best.pairs)")
}

// One prediction cannot be two promises.
do {
    let twice = [
        Gold(owner: "Maya", isMine: false, task: "Book the room", due: nil, quote: "okay, I'll book the room for the offsite"),
        Gold(owner: "Maya", isMine: false, task: "Book the room", due: nil, quote: "okay, I'll book the room for the offsite"),
    ]
    let r = BenchmarkScore.score(gold: twice, predicted: [Prediction(owner: "Maya", isMine: false,
                                 task: "Book the room", quote: "I'll book the room for the offsite")], meta: meta)
    check(r.matched == 1 && r.recall == 0.5,
          rule: "one prediction matches one gold promise at most",
          meaning: "otherwise a single vague promise could score a whole meeting",
          saw: "\(r.matched) matched")
}

// Mine against theirs is scored among the matches.
do {
    let predicted = [Prediction(owner: "Maya", isMine: true, task: "x", quote: "I'll book the room for the offsite")]
    let r = BenchmarkScore.score(gold: gold, predicted: predicted, meta: meta)
    check(r.matched == 1 && r.mineCorrect == 0 && r.mineAccuracy == 0 && r.ownerAccuracy == 1,
          rule: "a match with the wrong mine/theirs flag counts against mine/theirs accuracy, not owner accuracy",
          meaning: "the user's own list is what this flag decides; the owner name is scored on its own",
          saw: "matched \(r.matched), mine correct \(r.mineCorrect), owner correct \(r.ownerCorrect)")
    let wrongOwner = BenchmarkScore.score(gold: gold, predicted: [Prediction(owner: "Alex", isMine: true, task: "x",
                                          quote: "I'll book the room for the offsite")], meta: meta)
    check(wrongOwner.matched == 1 && wrongOwner.ownerAccuracy == 0,
          rule: "a quote match with the wrong owner still matches, and counts against owner accuracy",
          meaning: "finding the promise and naming its owner are two different skills",
          saw: "matched \(wrongOwner.matched), owner correct \(wrongOwner.ownerCorrect)")
}

// A prediction on a trap is counted.
do {
    let traps = [BenchmarkScore.Trap(quote: "I'll write to their support today", note: "cancelled later")]
    let predicted = [Prediction(owner: "Alex", isMine: true, task: "Write to support",
                                quote: "I'll write to their support today")]
    let r = BenchmarkScore.score(gold: gold, predicted: predicted, traps: traps, meta: meta)
    check(r.matched == 0 && r.trapsHit == 1 && r.precision == 0,
          rule: "a prediction quoting a trap is unmatched and counted as a trap hit",
          meaning: "a cancelled or declined promise in the user's list is a false promise",
          saw: "matched \(r.matched), traps hit \(r.trapsHit)")
}

// Nothing on either side.
do {
    let none = BenchmarkScore.score(gold: [], predicted: [], meta: meta)
    check(none.matched == 0 && none.recall == nil && none.precision == nil && none.mineAccuracy == nil,
          rule: "empty inputs score nothing and divide by nothing",
          meaning: "a meeting where a variant failed must not crash the probe or report 100%",
          saw: "\(none)")
    let noPredictions = BenchmarkScore.score(gold: gold, predicted: [], meta: meta)
    check(noPredictions.recall == 0 && noPredictions.precision == nil,
          rule: "no predictions is zero recall and no precision",
          meaning: "finding nothing is a miss, not a perfect precision",
          saw: "\(noPredictions)")
}

// The dataset itself.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("benchmark/meetings", isDirectory: true)
let ids = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    .filter { !$0.hasPrefix(".") }.sorted()
check(ids.count == 6,
      rule: "the benchmark has its six meetings",
      meaning: "the published numbers are over these meetings; a lost folder changes them silently",
      saw: "\(ids)")
for id in ids {
    let folder = root.appendingPathComponent(id, isDirectory: true)
    guard let raw = try? String(contentsOf: folder.appendingPathComponent("transcript-raw.txt"), encoding: .utf8),
          let metaData = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
          let goldData = try? Data(contentsOf: folder.appendingPathComponent("gold.json")) else {
        check(false, rule: "every meeting has transcript-raw.txt, meta.json and gold.json",
              meaning: "the probe reads all three", saw: "\(id) is missing one")
        continue
    }
    let meta = try? JSONDecoder().decode(BenchmarkScore.Meta.self, from: metaData)
    let file = try? JSONDecoder().decode(BenchmarkScore.GoldFile.self, from: goldData)
    check(meta != nil && file != nil,
          rule: "meta.json and gold.json decode",
          meaning: "a file the probe cannot read is a meeting silently left out",
          saw: "\(id): meta \(meta != nil), gold \(file != nil)")
    guard let meta, let file else { continue }

    var last = -1
    var bad: [String] = []
    for line in raw.components(separatedBy: "\n") where !line.isEmpty {
        let seconds: Int
        switch RawLine.parse(line) {
        case let .speech(s, _, text) where !text.isEmpty: seconds = s
        case let .note(s, text) where !text.isEmpty: seconds = s
        default: bad.append(String(line.prefix(40))); continue
        }
        if seconds < last { bad.append("time goes back: " + String(line.prefix(12))) }
        last = seconds
    }
    check(bad.isEmpty && last > 0,
          rule: "every transcript line is a `[mm:ss] You:`, `Them:` or `📝 NOTE:` line, in time order",
          meaning: "the benchmark is only fair if it is exactly what the recorder writes",
          saw: "\(id): \(bad.prefix(3))")

    check(file.promises.count >= 8 && !file.traps.isEmpty,
          rule: "each meeting has at least 8 gold promises and at least one trap",
          meaning: "fewer makes recall a coin toss; traps are what precision is tested on",
          saw: "\(id): \(file.promises.count) promises, \(file.traps.count) traps")

    let prepared = QuoteMatch.prepare(raw)
    for item in file.promises {
        check(raw.contains(item.quote) && QuoteMatch.contains(prepared, quote: item.quote),
              rule: "every gold quote is exact words of its transcript, and QuoteMatch finds it",
              meaning: "a gold promise the app could never quote can never be matched by quote",
              saw: "\(id): \(item.quote)")
        let mine = PromiseOwner.isMe(item.owner, myName: meta.myName)
        let known = mine || meta.participants.contains { PromiseOwner.sameName($0, item.owner) }
        check(mine == item.isMine && known,
              rule: "a gold owner is the user exactly when isMine, and is on the participant list",
              meaning: "mine/theirs accuracy is scored against this flag",
              saw: "\(id): \(item.owner) isMine \(item.isMine)")
    }
    for trap in file.traps {
        check(raw.contains(trap.quote),
              rule: "every trap quote is exact words of its transcript",
              meaning: "a trap the transcript does not contain tests nothing",
              saw: "\(id): \(trap.quote)")
        check(!file.promises.contains { BenchmarkScore.sameQuote($0.quote, trap.quote) },
              rule: "a trap is not also a gold promise",
              meaning: "the same words cannot be both a promise and not one",
              saw: "\(id): \(trap.quote)")
    }
}

return failures
}
