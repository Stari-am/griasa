import Foundation

// Checks for capture from the iPhone: which files the iCloud inbox takes, who a
// note is about, and how the Reminders list and the promises keep in step.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runPhoneCaptureChecks() -> Int {
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

// The inbox.
do {
    check(PhoneInbox.kind(of: "Note.txt") == .text && PhoneInbox.kind(of: "New Recording 3.m4a") == .audio
          && PhoneInbox.kind(of: "Call.MP3") == .audio,
          rule: "text and the phone's audio formats are taken", meaning: "Voice Memos save .m4a", saw: "")
    check(PhoneInbox.kind(of: ".DS_Store") == .skip && PhoneInbox.kind(of: ".Memo.m4a.icloud") == .skip
          && PhoneInbox.kind(of: "photo.jpg") == .skip,
          rule: "hidden files, iCloud placeholders and other files are left alone",
          meaning: "a placeholder is not the recording yet", saw: "")
    check(PhoneInbox.placeholderTarget(".Memo 2.m4a.icloud") == "Memo 2.m4a" && PhoneInbox.placeholderTarget("Memo.m4a") == nil,
          rule: "a placeholder names the file to download", meaning: "the Mac asks iCloud for it", saw: "")
    let now = Date()
    check(!PhoneInbox.isSettled(modified: now.addingTimeInterval(-3), now: now)
          && PhoneInbox.isSettled(modified: now.addingTimeInterval(-30), now: now),
          rule: "a file still changing is not read yet", meaning: "half a recording would be filed as the whole", saw: "")
    check(PhoneInbox.freeName("Memo.m4a", taken: ["Memo.m4a", "Memo 2.m4a"]) == "Memo 3.m4a"
          && PhoneInbox.freeName("Memo.m4a", taken: []) == "Memo.m4a",
          rule: "a read file never replaces an earlier one", meaning: "Voice Memos reuse names", saw: "")
    check(PhoneInbox.folder(home: URL(fileURLWithPath: "/Users/x")).path
          == "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Griasa/Inbox",
          rule: "the inbox is iCloud Drive → Griasa → Inbox", meaning: "the phone saves there by that name", saw: "")
    let title = PhoneInbox.title(from: "Ivan will send the deck by Friday, and I owe Maya the budget numbers before the offsite next week")
    check(title.hasPrefix("📱 ") && title.count <= 63,
          rule: "a note's title is its first words, marked as from the phone", meaning: "History is a list to scan", saw: title)
}

// Who a note is about.
do {
    let known = ["Ivan Petrov", "Maya", "Al", "Žofia Nováková", "Анна Смирнова"]
    let found = PhoneInbox.mentionedPeople(in: "Call with ivan: he sends the deck; zofia novakova joins. Анна согласна.", known: known)
    check(found == ["Ivan Petrov", "Žofia Nováková", "Анна Смирнова"],
          rule: "colleagues are found by first or full name, ignoring case and accents",
          meaning: "the promises in a note must reach the right people's pages", saw: "\(found)")
    check(PhoneInbox.mentionedPeople(in: "Always call back", known: known).isEmpty,
          rule: "a short first name is not matched inside other words", meaning: "\"Al\" is in \"Always\"", saw: "")
    check(PhoneInbox.mentionedPeople(in: "Анна пришлёт отчёт", known: known) == ["Анна Смирнова"],
          rule: "names in other alphabets are found too", meaning: "notes are dictated in Russian as well", saw: "")
}

// Reminders, both ways.
do {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!
    func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: 12))! }
    let soon = Commitment(text: "Send the deck", owner: "Me", isMine: true, dueDate: day(5), sourceTitle: "1:1")
    let old = Commitment(text: "Old one", owner: "Me", isMine: true, dueDate: day(3) - 86_400 * 30, sourceTitle: "")
    let undated = Commitment(text: "Someday", owner: "Me", isMine: true, sourceTitle: "")
    let theirs = Commitment(text: "Ivan's", owner: "Ivan", isMine: false, dueDate: day(5), sourceTitle: "")
    let fresh = ReminderSync.plan(promises: [soon, old, undated, theirs], reminders: [], links: .init(), now: now,
                                  calendar: calendar)
    check(fresh == [.create(soon.id)],
          rule: "only your own dated promises go to Reminders, without last month's backlog",
          meaning: "turning it on must not fill the phone with old overdue items", saw: "\(fresh)")

    var links = ReminderSync.Links()
    links.byPromise[soon.id] = "r1"
    links.agreed[soon.id] = false
    let ticked = ReminderSync.Reminder(id: "r1", title: "Send the deck", completed: true, due: day(5))
    check(ReminderSync.plan(promises: [soon], reminders: [ticked], links: links, now: now, calendar: calendar) == [.close(soon.id)],
          rule: "ticked on the phone closes the promise", meaning: "closing on the go is the point", saw: "")

    var closed = soon
    closed.done = true
    let open = ReminderSync.Reminder(id: "r1", title: "Send the deck", completed: false, due: day(5))
    check(ReminderSync.plan(promises: [closed], reminders: [open], links: links, now: now, calendar: calendar)
          == [.complete(reminder: "r1")],
          rule: "closed in Griasa ticks the reminder", meaning: "the phone must not nag about what is done", saw: "")

    var agreedDone = links
    agreedDone.agreed[soon.id] = true
    check(ReminderSync.plan(promises: [soon], reminders: [ticked], links: agreedDone, now: now, calendar: calendar)
          == [.reopen(reminder: "r1")],
          rule: "reopened in Griasa reopens the reminder instead of being closed again",
          meaning: "the side that changed wins", saw: "")
    check(ReminderSync.plan(promises: [closed], reminders: [open], links: agreedDone, now: now, calendar: calendar)
          == [.open(soon.id)],
          rule: "unticked on the phone reopens the promise", meaning: "a mis-tap must be undoable", saw: "")

    check(ReminderSync.plan(promises: [soon], reminders: [], links: links, now: now, calendar: calendar) == [.drop(soon.id)],
          rule: "a deleted reminder stops the sync for that promise", meaning: "deleting it must not bring it back", saw: "")
    var dropped = ReminderSync.Links()
    dropped.dropped = [soon.id]
    check(ReminderSync.plan(promises: [soon], reminders: [], links: dropped, now: now, calendar: calendar).isEmpty,
          rule: "a dropped promise is not given another reminder", meaning: "same", saw: "")
    check(ReminderSync.plan(promises: [], reminders: [open], links: links, now: now, calendar: calendar) == [.unlink(soon.id)],
          rule: "a deleted promise only forgets its reminder", meaning: "Griasa does not delete things on the phone", saw: "")

    let siri = ReminderSync.Reminder(id: "r9", title: " Send Ivan the deck ", completed: false, due: nil)
    let done = ReminderSync.Reminder(id: "r8", title: "Old", completed: true, due: nil)
    check(ReminderSync.plan(promises: [], reminders: [siri, done], links: .init(), now: now, calendar: calendar)
          == [.adopt(reminder: "r9")],
          rule: "a new open reminder in the list becomes a promise, a finished one does not",
          meaning: "\"Hey Siri, add … to my Griasa list\" is how it gets there", saw: "")
    let adopted = ReminderSync.promise(from: siri, myName: "", now: now)
    check(adopted.text == "Send Ivan the deck" && adopted.isMine && adopted.owner == "You",
          rule: "an adopted reminder is your own promise, trimmed", meaning: "it was you who said it", saw: "\(adopted.text)")
}

return failures
}
