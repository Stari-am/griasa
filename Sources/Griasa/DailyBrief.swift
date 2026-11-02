import Foundation

/// The morning brief: one look at the day — today's meetings with what is owed
/// across each table, what is overdue on both sides, decisions due for another
/// look, and promises that seem to be done.
///
/// Built from what Griasa already keeps, with no model and nothing sent
/// anywhere, so it is instant and can be made at 8:00 on a train with no
/// network. When to show it is a rule here too, so both are checked without
/// the app.
///
/// Foundation only.
enum DailyBrief {
    struct Meeting: Equatable {
        var title: String
        var start: Date
        var end: Date
        var attendees: [String]
        /// Open promises the user owes these people, and they owe the user.
        var youOwe: Int
        var theyOwe: Int
        var videoURL: URL?
    }

    struct Day: Equatable {
        var date: Date
        var meetings: [Meeting]
        /// The user's own open promises past their date, oldest first.
        var overdueMine: [Commitment]
        /// The user's own open promises due today.
        var dueToday: [Commitment]
        /// Each report with their overdue promises to the user; only those with some.
        var overdueTeam: [(name: String, items: [Commitment])]
        var revisit: [Decision]
        var looksDone: [Commitment]

        static func == (a: Day, b: Day) -> Bool {
            a.date == b.date && a.meetings == b.meetings && a.overdueMine == b.overdueMine
                && a.dueToday == b.dueToday && a.revisit == b.revisit && a.looksDone == b.looksDone
                && a.overdueTeam.map(\.name) == b.overdueTeam.map(\.name)
                && a.overdueTeam.map(\.items) == b.overdueTeam.map(\.items)
        }

        var isEmpty: Bool {
            meetings.isEmpty && overdueMine.isEmpty && dueToday.isEmpty && overdueTeam.isEmpty
                && revisit.isEmpty && looksDone.isEmpty
        }
    }

    static func make(now: Date, meetings: [Meeting], commitments: [Commitment], reports: [String],
                     decisions: [Decision], calendar: Calendar = .current) -> Day {
        let today = calendar.startOfDay(for: now)
        let open = commitments.filter { !$0.done }
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        let mine = open.filter(\.isMine)
        let overdueMine = mine.filter { $0.dueDate.map { day($0) < today } ?? false }
            .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
        let dueToday = mine.filter { $0.dueDate.map { day($0) == today } ?? false }
        let team = TeamDigest.members(names: reports, commitments: open, lastMet: { _ in nil }, now: now)
            .compactMap { member -> (name: String, items: [Commitment])? in
                let late = member.owed.filter { TeamDigest.isOverdue($0, now: now, calendar: calendar) }
                return late.isEmpty ? nil : (member.name, late)
            }
        let todays = meetings
            .filter { day($0.start) == today && $0.end > now.addingTimeInterval(-15 * 60) }
            .sorted { $0.start < $1.start }
        return Day(date: today, meetings: todays, overdueMine: overdueMine, dueToday: dueToday,
                   overdueTeam: team, revisit: decisions.filter { $0.needsRevisit(on: now, calendar: calendar) },
                   looksDone: open.filter(\.hasClosureSuggestion))
    }

    /// The notification's one line: "3 meetings · 2 overdue · 1 decision to revisit".
    static func summary(_ day: Day) -> String {
        var parts: [String] = []
        func count(_ n: Int, _ one: String, _ many: String) {
            if n > 0 { parts.append("\(n) \(n == 1 ? one : many)") }
        }
        count(day.meetings.count, "meeting", "meetings")
        count(day.overdueMine.count, "overdue promise", "overdue promises")
        count(day.dueToday.count, "due today", "due today")
        count(day.overdueTeam.reduce(0) { $0 + $1.items.count }, "overdue from your team", "overdue from your team")
        count(day.revisit.count, "decision to revisit", "decisions to revisit")
        count(day.looksDone.count, "promise that looks done", "promises that look done")
        return parts.isEmpty ? "Nothing scheduled and nothing overdue." : parts.joined(separator: " · ")
    }

    /// Whether the brief is due now: on or after its time today, not shown
    /// today yet, and on a weekday when only weekdays are wanted. A Mac opened
    /// at 10:40 gets the brief then, once.
    static func isDue(now: Date, time: String, weekdaysOnly: Bool, lastShown: Date?,
                      calendar: Calendar = .current) -> Bool {
        if let lastShown, calendar.isDate(lastShown, inSameDayAs: now) { return false }
        if weekdaysOnly, calendar.isDateInWeekend(now) { return false }
        let (hour, minute) = clock(time)
        guard let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return false }
        return now >= at
    }

    /// "08:00" → (8, 0); anything unreadable is 8:00.
    static func clock(_ time: String) -> (Int, Int) {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return (8, 0) }
        return (parts[0], parts[1])
    }

    /// The brief as plain text, for a note: headings, then one line per item.
    static func text(_ day: Day, calendar: Calendar = .current) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeStyle = .short
        time.dateStyle = .none
        let heading = DateFormatter()
        heading.calendar = calendar
        heading.dateStyle = .full
        heading.timeStyle = .none
        var lines = ["Griasa — \(heading.string(from: day.date))", "", summary(day)]
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines += ["", title] + items.map { "• " + $0 }
        }
        section("Meetings", day.meetings.map { meeting in
            var line = "\(time.string(from: meeting.start)) \(meeting.title)"
            if !meeting.attendees.isEmpty { line += " — " + meeting.attendees.prefix(4).joined(separator: ", ") }
            if meeting.youOwe + meeting.theyOwe > 0 { line += " (you owe \(meeting.youOwe), they owe \(meeting.theyOwe))" }
            return line
        })
        section("Overdue", day.overdueMine.map(\.text))
        section("Due today", day.dueToday.map(\.text))
        section("Overdue from your team", day.overdueTeam.flatMap { member in member.items.map { "\(member.name): \($0.text)" } })
        section("Decisions to look at again", day.revisit.map(\.text))
        section("Looks done", day.looksDone.map(\.text))
        return lines.joined(separator: "\n")
    }
}

/// Built here rather than beside the type: the widget extension compiles
/// `WidgetSnapshot` alone, without the brief and the stores it reads.
extension WidgetSnapshot {
    init(from day: DailyBrief.Day, now: Date) {
        generated = now
        self.day = day.date
        summary = DailyBrief.summary(day)
        meetings = day.meetings.map {
            Meeting(title: $0.title, start: $0.start, attendees: Array($0.attendees.prefix(4)),
                    youOwe: $0.youOwe, theyOwe: $0.theyOwe)
        }
        overdue = day.overdueMine.prefix(Self.listLimit).map(\.text)
        overdueCount = day.overdueMine.count
        dueToday = day.dueToday.prefix(Self.listLimit).map(\.text)
        let late = day.overdueTeam.flatMap { member in member.items.map { "\(member.name): \($0.text)" } }
        team = Array(late.prefix(Self.listLimit))
        teamCount = late.count
        revisit = day.revisit.prefix(Self.listLimit).map(\.text)
    }
}
