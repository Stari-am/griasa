import Foundation

/// A deadline in words — "до пятницы", "завтра в 15:00", "by Friday", "через 2 часа" —
/// turned into a date by code, against the day it was said.
///
/// A small model is unreliable at calendar arithmetic: asked on Monday 26 October
/// for "до пятницы" it answered Monday 2 November. Weekdays, tomorrow, "in N
/// days" and times of day are rules, so they are resolved here, and the model's
/// own date is only a fallback for phrasing these rules do not cover.
enum DueDate {
    struct Resolved: Equatable {
        let date: Date
        /// The phrase named a time of day ("в 15:00", "вечером", "in 2 hours").
        let hasTime: Bool
    }

    /// Nil when the phrase has no deadline these rules understand.
    static func resolve(_ phrase: String, from reference: Date,
                        calendar: Calendar = .current) -> Resolved? {
        let text = " " + phrase.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^\p{L}\p{N}:' ]+"#, with: " ", options: .regularExpression) + " "
        let startOfToday = calendar.startOfDay(for: reference)

        // Relative amounts first: "через 2 часа", "in 3 days".
        if let (amount, unit) = relativeAmount(in: text),
           let date = calendar.date(byAdding: unit, value: amount, to: reference) {
            return Resolved(date: date, hasTime: unit == .hour || unit == .minute)
        }

        var day: Date?
        if has(text, ["послезавтра", "післязавтра", "day after tomorrow"]) {
            day = calendar.date(byAdding: .day, value: 2, to: startOfToday)
        } else if has(text, ["завтра", "tomorrow"]) {
            day = calendar.date(byAdding: .day, value: 1, to: startOfToday)
        } else if has(text, ["сегодня", "сьогодні", "today", "tonight", "end of day", "eod"]) {
            day = startOfToday
        } else if has(text, ["конец недели", "конца недели", "концу недели", "кінця тижня", "кінець тижня",
                             "end of the week", "end of week"]) {
            day = next(weekday: 6, after: startOfToday, calendar: calendar, allowToday: true)
        } else if has(text, ["конец месяца", "конца месяца", "концу месяца", "кінця місяця", "end of the month",
                             "end of month"]),
                  let interval = calendar.dateInterval(of: .month, for: startOfToday) {
            day = calendar.date(byAdding: .day, value: -1, to: interval.end)
        } else if let weekday = weekday(in: text) {
            var found = next(weekday: weekday, after: startOfToday, calendar: calendar, allowToday: false)
            if has(text, ["следующ", "наступн", "next "]), let plain = found,
               let thisWeek = calendar.dateInterval(of: .weekOfYear, for: startOfToday),
               plain < thisWeek.end {
                found = calendar.date(byAdding: .day, value: 7, to: plain)
            }
            day = found
        } else if has(text, ["через неделю", "через тиждень", "in a week", "next week"]) {
            day = calendar.date(byAdding: .day, value: 7, to: startOfToday)
        }
        guard let day else { return nil }

        if let (hour, minute) = timeOfDay(in: text),
           let timed = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) {
            return Resolved(date: timed, hasTime: true)
        }
        return Resolved(date: day, hasTime: false)
    }

    /// The deadline to store: the spoken words resolved by rule when they can be,
    /// the model's own date otherwise.
    static func best(spoken: String?, model: Date?, said: Date, calendar: Calendar = .current) -> Date? {
        if let spoken, !spoken.isEmpty, let resolved = resolve(spoken, from: said, calendar: calendar) {
            return resolved.date
        }
        return model
    }

    /// Calendar.weekday numbering: 1 Sunday … 7 Saturday.
    private static let weekdayStems: [(String, Int)] = [
        ("понедельн", 2), ("понеділ", 2), ("monday", 2), (" mon ", 2), (" пн ", 2),
        ("вторник", 3), ("вівтор", 3), ("tuesday", 3), (" tue ", 3), (" вт ", 3),
        // Whole words: "середи" (uk, of Wednesday) is also the start of "середине".
        ("среду ", 4), ("среда ", 4), ("среды ", 4), ("среде ", 4), ("середу ", 4), ("середа ", 4), ("середи ", 4),
        ("wednesday", 4), (" wed ", 4), (" ср ", 4),
        ("четверг", 5), ("четвер", 5), ("thursday", 5), (" thu ", 5), (" чт ", 5),
        ("пятниц", 6), ("п'ятниц", 6), ("пʼятниц", 6), ("friday", 6), (" fri ", 6), (" пт ", 6),
        ("суббот", 7), ("субот", 7), ("saturday", 7), (" sat ", 7), (" сб ", 7),
        ("воскресен", 1), ("неділ", 1), ("sunday", 1), (" sun ", 1), (" вс ", 1),
    ]

    private static func weekday(in text: String) -> Int? {
        // "среду" must not be read inside "середина"-like words: stems are matched
        // at a word start.
        for (stem, day) in weekdayStems {
            if stem.hasPrefix(" ") { if text.contains(stem) { return day } }
            else if text.range(of: " " + stem) != nil { return day }
        }
        return nil
    }

    private static func next(weekday: Int, after start: Date, calendar: Calendar, allowToday: Bool) -> Date? {
        if allowToday, calendar.component(.weekday, from: start) == weekday { return start }
        return calendar.nextDate(after: start, matching: DateComponents(weekday: weekday),
                                 matchingPolicy: .nextTime)
    }

    private static func has(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains(" " + $0) }
    }

    private static let numberWords: [String: Int] = [
        "один": 1, "одну": 1, "одна": 1, "a": 1, "an": 1, "one": 1, "два": 2, "две": 2, "дві": 2, "two": 2,
        "три": 3, "three": 3, "четыре": 4, "чотири": 4, "four": 4, "пять": 5, "п'ять": 5, "five": 5,
        "полчаса": 0,
    ]

    private static func relativeAmount(in text: String) -> (Int, Calendar.Component)? {
        if text.contains(" полчаса") || text.contains(" half an hour") { return (30, .minute) }
        let pattern = #"(?:через|за|in)\s+(\d+|[\p{L}']+)?\s*(минут\p{L}*|хвилин\p{L}*|minutes?|mins?|час\p{L}*|годин\p{L}*|hours?|дн\p{L}*|день|днів|days?|недел\p{L}*|тижн\p{L}*|тиждень|weeks?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let unitRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let unitWord = String(text[unitRange])
        var amount = 1
        if let numberRange = Range(match.range(at: 1), in: text) {
            let word = String(text[numberRange])
            guard let value = Int(word) ?? numberWords[word] else { return nil }
            amount = value
        }
        // "за" alone is "by", not "in": "за неделю" (a week before) is not a deadline.
        if text.contains(" за "), !text.contains(" через "), !text.contains(" in ") { return nil }
        switch unitWord.prefix(3) {
        case "мин", "хви", "min": return (amount, .minute)
        case "час", "год", "hou": return (amount, .hour)
        case "дн", "ден", "дні", "day": return (amount, .day)
        default:
            if unitWord.hasPrefix("дн") || unitWord.hasPrefix("ден") { return (amount, .day) }
            return (amount * 7, .day)
        }
    }

    private static func timeOfDay(in text: String) -> (Int, Int)? {
        if let regex = try? NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let h = Range(match.range(at: 1), in: text), let m = Range(match.range(at: 2), in: text),
           let hour = Int(text[h]), let minute = Int(text[m]), hour < 24, minute < 60 {
            return (hour, minute)
        }
        if let regex = try? NSRegularExpression(pattern: #"(\d{1,2})\s*(am|pm)"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let h = Range(match.range(at: 1), in: text), let ap = Range(match.range(at: 2), in: text),
           var hour = Int(text[h]), hour >= 1, hour <= 12 {
            if text[ap] == "pm", hour != 12 { hour += 12 }
            if text[ap] == "am", hour == 12 { hour = 0 }
            return (hour, 0)
        }
        if has(text, ["утром", "зранку", "вранці", "morning"]) { return (9, 0) }
        if has(text, ["днем", "вдень", "afternoon"]) { return (14, 0) }
        if has(text, ["вечером", "ввечері", "evening", "tonight"]) { return (18, 0) }
        return nil
    }
}
