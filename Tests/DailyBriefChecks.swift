import Foundation

// Checks for the morning brief: what goes into the day, the one-line summary,
// and when it is due.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runDailyBriefChecks() -> Int {
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

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    // November 2026: the 2nd is a Monday, the 7th a Saturday.
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

// What goes in.
do {
    let now = at(2, 8)
    let meetings = [
        DailyBrief.Meeting(title: "Standup", start: at(2, 10), end: at(2, 10, 15), attendees: ["Maya"], youOwe: 1, theyOwe: 0),
        DailyBrief.Meeting(title: "Yesterday's", start: at(1, 15), end: at(1, 16), attendees: [], youOwe: 0, theyOwe: 0),
        DailyBrief.Meeting(title: "Tomorrow's", start: at(3, 9), end: at(3, 10), attendees: [], youOwe: 0, theyOwe: 0),
        DailyBrief.Meeting(title: "1:1 Ivan", start: at(2, 9), end: at(2, 9, 30), attendees: ["Ivan"], youOwe: 0, theyOwe: 2),
    ]
    var closing = Commitment(text: "Ship the export", owner: "Me", isMine: true, sourceTitle: "")
    closing.proposeClosure(quote: "export is live")
    let commitments = [
        Commitment(text: "Late one", owner: "Me", isMine: true, dueDate: at(1, 12) - 86_400 * 3, sourceTitle: ""),
        Commitment(text: "Today's", owner: "Me", isMine: true, dueDate: at(2, 18), sourceTitle: ""),
        Commitment(text: "Later", owner: "Me", isMine: true, dueDate: at(9, 12), sourceTitle: ""),
        Commitment(text: "Ivan's late", owner: "Ivan", isMine: false, dueDate: at(1, 12), sourceTitle: ""),
        Commitment(text: "Not on team", owner: "Olena", isMine: false, dueDate: at(1, 12), sourceTitle: ""),
        Commitment(text: "Done late", owner: "Me", isMine: true, dueDate: at(1, 12), sourceTitle: "", done: true),
        closing,
    ]
    let decisions = [Decision(text: "Revisit pricing", sourceTitle: "", revisitDate: at(2, 0)),
                     Decision(text: "Later", sourceTitle: "", revisitDate: at(20, 0))]
    let day = DailyBrief.make(now: now, meetings: meetings, commitments: commitments, reports: ["Ivan"],
                              decisions: decisions, calendar: calendar)
    check(day.meetings.map(\.title) == ["1:1 Ivan", "Standup"],
          rule: "only today's meetings, in order of time",
          meaning: "the brief is about this day", saw: "\(day.meetings.map(\.title))")
    check(day.overdueMine.map(\.text) == ["Late one"] && day.dueToday.map(\.text) == ["Today's"],
          rule: "overdue and due-today are the user's own open promises, apart",
          meaning: "a finished or later promise is not news at 8:00", saw: "\(day.overdueMine.map(\.text)) \(day.dueToday.map(\.text))")
    check(day.overdueTeam.map(\.name) == ["Ivan"] && day.overdueTeam.first?.items.map(\.text) == ["Ivan's late"],
          rule: "the team section is reports with overdue promises to the user",
          meaning: "someone not on the team is not the user's to chase", saw: "\(day.overdueTeam.map(\.name))")
    check(day.revisit.map(\.text) == ["Revisit pricing"] && day.looksDone.map(\.text) == ["Ship the export"],
          rule: "decisions due for a look and promises that look done are listed",
          meaning: "both need a minute of the user's attention today", saw: "")
    let summary = DailyBrief.summary(day)
    check(summary == "2 meetings · 1 overdue promise · 1 due today · 1 overdue from your team · 1 decision to revisit · 1 promise that looks done",
          rule: "the summary counts each part in one line", meaning: "it is the notification's body", saw: summary)
    let text = DailyBrief.text(day, calendar: calendar)
    check(text.contains("Meetings") && text.contains("1:1 Ivan — Ivan (you owe 0, they owe 2)") && text.contains("• Ivan: Ivan's late"),
          rule: "the note lists each section with one line per item",
          meaning: "it is read on a phone", saw: text)
    let empty = DailyBrief.make(now: now, meetings: [], commitments: [], reports: [], decisions: [], calendar: calendar)
    check(empty.isEmpty && DailyBrief.summary(empty) == "Nothing scheduled and nothing overdue.",
          rule: "an empty day says so", meaning: "a blank notification looks broken", saw: DailyBrief.summary(empty))
}

// When.
do {
    check(!DailyBrief.isDue(now: at(2, 7, 59), time: "08:00", weekdaysOnly: true, lastShown: nil, calendar: calendar)
          && DailyBrief.isDue(now: at(2, 8), time: "08:00", weekdaysOnly: true, lastShown: nil, calendar: calendar),
          rule: "the brief is due from its time on", meaning: "not a minute early", saw: "")
    check(DailyBrief.isDue(now: at(2, 10, 40), time: "08:00", weekdaysOnly: true, lastShown: at(1, 8), calendar: calendar),
          rule: "a Mac opened late still gets the day's brief",
          meaning: "a laptop closed at 8:00 must not skip the day", saw: "")
    check(!DailyBrief.isDue(now: at(2, 12), time: "08:00", weekdaysOnly: true, lastShown: at(2, 8, 1), calendar: calendar),
          rule: "once a day", meaning: "the timer ticks every minute", saw: "")
    check(!DailyBrief.isDue(now: at(7, 9), time: "08:00", weekdaysOnly: true, lastShown: nil, calendar: calendar)
          && DailyBrief.isDue(now: at(7, 9), time: "08:00", weekdaysOnly: false, lastShown: nil, calendar: calendar),
          rule: "weekends are skipped only when weekdays-only is on", meaning: "the person chose", saw: "")
    check(DailyBrief.clock("07:30") == (7, 30) && DailyBrief.clock("25:00") == (8, 0) && DailyBrief.clock("x") == (8, 0),
          rule: "a stored time reads as hours and minutes, anything else as 8:00",
          meaning: "a broken preference must not stop the brief", saw: "")
}

// The desktop widget's snapshot and its links.
do {
    let now = at(2, 8)
    let meetings = [
        DailyBrief.Meeting(title: "1:1 Ivan", start: at(2, 9), end: at(2, 9, 30), attendees: ["Ivan", "A", "B", "C", "D"],
                           youOwe: 0, theyOwe: 2),
        DailyBrief.Meeting(title: "Standup", start: at(2, 10), end: at(2, 10, 15), attendees: [], youOwe: 1, theyOwe: 0),
    ]
    let late = (1...7).map { Commitment(text: "Late \($0)", owner: "Me", isMine: true, dueDate: at(1, 12), sourceTitle: "") }
    let day = DailyBrief.make(now: now, meetings: meetings, commitments: late, reports: [], decisions: [], calendar: calendar)
    let snapshot = WidgetSnapshot(from: day, now: now)
    check(snapshot.overdue.count == WidgetSnapshot.listLimit && snapshot.overdueCount == 7,
          rule: "the widget gets a few lines and the full count",
          meaning: "the file stays small, and the number shown is still the real one",
          saw: "\(snapshot.overdue.count) lines, count \(snapshot.overdueCount)")
    check(snapshot.meetings.first?.attendees.count == 4,
          rule: "a meeting carries at most four names", meaning: "the widget has room for one line", saw: "\(snapshot.meetings.first?.attendees ?? [])")
    check(snapshot.next(after: at(2, 9, 10))?.title == "1:1 Ivan" && snapshot.next(after: at(2, 9, 31))?.title == "Standup"
          && snapshot.next(after: at(2, 11)) == nil,
          rule: "the next meeting stays on screen for half an hour after it starts",
          meaning: "a meeting in progress is still the one that matters", saw: "")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let round = try? decoder.decode(WidgetSnapshot.self, from: encoder.encode(snapshot))
    check(round == snapshot, rule: "the snapshot reads back as written",
          meaning: "the app writes it and the widget reads it, in different processes", saw: "\(String(describing: round))")
    check(WidgetSnapshot.tab(in: WidgetSnapshot.link("team")) == "team"
          && WidgetSnapshot.tab(in: URL(string: "griasa://open/")!) == nil
          && WidgetSnapshot.tab(in: URL(string: "https://open/team")!) == nil
          && WidgetSnapshot.tab(in: URL(string: "griasa://other/team")!) == nil,
          rule: "only griasa://open/<tab> names a tab", meaning: "any app can open a griasa:// link", saw: "")
}

return failures
}
