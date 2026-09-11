import Foundation

// Checks for guessing, from the calendar, who was on a recording. A wrong
// answer here ticks boxes on somebody's behalf, and a box the user did not tick
// and did not notice puts a name on a transcript that was never on the call.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runAttendanceChecks() -> Int {
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

typealias Attendance = MeetingAttendance
let noon = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ minutes: Double) -> Date { noon.addingTimeInterval(minutes * 60) }
func event(_ title: String, _ from: Double, _ to: Double,
           _ attendees: [Attendance.Event.Attendee] = []) -> Attendance.Event {
    Attendance.Event(title: title, start: at(from), end: at(to), attendees: attendees)
}

// ── Which event the recording belongs to ─────────────────────────────────────

do {
    let recording = at(0)...at(30)
    let chosen = Attendance.event(for: recording, among: [
        event("mostly elsewhere", -60, 5),
        event("the one", -2, 32),
        event("later", 28, 90),
    ])
    check(chosen?.title == "the one",
          rule: "the event sharing the most time with the recording wins",
          meaning: "a recording usually starts a little late and runs a little over, so the "
                 + "right event is the one it overlaps most, not the one that starts nearest",
          saw: "chose \(chosen?.title ?? "nothing")")
}

// A meeting that ended as this one began overlaps by seconds. Without a floor
// it can still win, and then the panel ticks the wrong people entirely.
do {
    let recording = at(0)...at(30)
    let chosen = Attendance.event(for: recording, among: [event("just ended", -60, 0.5)])
    check(chosen == nil,
          rule: "a few seconds of overlap is not enough to claim the recording",
          meaning: "back-to-back calls are normal; attributing a recording to the meeting "
                 + "that just finished would tick a completely different set of names",
          saw: "chose \(chosen?.title ?? "nothing")")
}

// The boundary of that floor, from both sides, because it is the number that
// decides between two plausible meetings.
do {
    let recording = at(0)...at(30)
    let exactly = Attendance.event(for: recording, among: [event("x", -60, 1)])
    let under = Attendance.event(for: recording, among: [event("x", -60, 0.9)])
    check(exactly != nil && under == nil,
          rule: "the overlap floor is exactly a minute, not approximately",
          meaning: "the constant is the whole defence against picking the previous meeting; "
                 + "if it drifts the defence is imaginary",
          saw: "at the floor: \(exactly != nil), just under: \(under != nil)")
}

// Two events with identical overlap must not depend on the order EventKit
// happened to return them in.
do {
    let recording = at(0)...at(30)
    let a = event("earlier", 0, 10)
    let b = event("later", 20, 30)
    let one = Attendance.event(for: recording, among: [a, b])
    let other = Attendance.event(for: recording, among: [b, a])
    check(one == other && one?.title == "earlier",
          rule: "an exact tie is broken the same way whichever order the events arrive in",
          meaning: "otherwise the same recording ticks different names on different runs, "
                 + "and nobody can tell why",
          saw: "\(one?.title ?? "nothing") vs \(other?.title ?? "nothing")")
}

do {
    check(Attendance.event(for: at(0)...at(30), among: []) == nil,
          rule: "with no events there is no guess",
          meaning: "a recording started from the menu bar has no calendar behind it, and the "
                 + "panel must then behave exactly as it always did",
          saw: "\(String(describing: Attendance.event(for: at(0)...at(30), among: [])))")
}

// ── Who gets ticked ──────────────────────────────────────────────────────────

let roster = [
    PersonIdentity.Candidate(name: "Ivan Petrov", emails: ["petrov@corp.com"]),
    PersonIdentity.Candidate(name: "Anna Sidorova"),
    PersonIdentity.Candidate(name: "Oleg Kuznetsov"),
]

do {
    let call = event("standup", 0, 30, [
        .init(name: nil, email: "petrov@corp.com"),
        .init(name: "Anna Sidorova", email: nil),
        .init(name: "Someone External", email: "external@elsewhere.com"),
    ])
    let ticked = Attendance.preselected(from: call, roster: roster)
    check(ticked == ["Ivan Petrov", "Anna Sidorova"],
          rule: "attendees already on the roster are ticked, by address or by name",
          meaning: "this is the whole feature: the people you would have ticked by hand are "
                 + "ticked, and the address is what makes it reliable when the calendar "
                 + "spells a name differently from the roster",
          saw: "\(ticked)")
}

// The decision taken deliberately: an attendee nobody recognises is dropped, not
// offered. Large meetings carry long lists of people never worth remembering.
do {
    let crowd = event("all hands", 0, 30, (1...40).map {
        .init(name: "Guest \($0)", email: "guest\($0)@elsewhere.com")
    })
    check(Attendance.preselected(from: crowd, roster: roster).isEmpty,
          rule: "attendees who are not on the roster are not added to the panel",
          meaning: "a forty-person invitation would otherwise fill the question with names "
                 + "that were never worth keeping, making it harder to answer, not easier",
          saw: "\(Attendance.preselected(from: crowd, roster: roster))")
}

// Order follows the roster, so ticks appear where the list already puts them.
do {
    let call = event("review", 0, 30, [
        .init(name: "Oleg Kuznetsov", email: nil),
        .init(name: "Ivan Petrov", email: nil),
    ])
    check(Attendance.preselected(from: call, roster: roster) == ["Ivan Petrov", "Oleg Kuznetsov"],
          rule: "ticked names come back in roster order, not invitation order",
          meaning: "the panel lists the roster; returning a different order would make the "
                 + "result look shuffled against the list the user is reading",
          saw: "\(Attendance.preselected(from: call, roster: roster))")
}

// One person invited twice — by name on one line and by address on another — is
// still one person.
do {
    let call = event("review", 0, 30, [
        .init(name: "Ivan Petrov", email: nil),
        .init(name: nil, email: "PETROV@corp.com"),
    ])
    check(Attendance.preselected(from: call, roster: roster) == ["Ivan Petrov"],
          rule: "the same person on two invitation lines is ticked once",
          meaning: "calendars do list somebody twice, and a duplicate tick would look like "
                 + "the guess is confused about who was there",
          saw: "\(Attendance.preselected(from: call, roster: roster))")
}

return failures
}
