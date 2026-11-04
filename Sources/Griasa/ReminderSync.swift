import Foundation

/// Your promises in Apple Reminders, in a list called "Griasa", both ways.
///
/// A promise of yours with a date appears there, so it is on the iPhone, the
/// Watch and CarPlay's Siri. Ticking it there closes it in Griasa; closing it
/// in Griasa ticks it there. And a reminder added to the list — "Hey Siri, add
/// send Ivan the deck to my Griasa list", in the car — becomes a promise.
///
/// What to do is decided here, from plain values, so it is tested without
/// EventKit; `ReminderSyncController` only carries the actions out.
///
/// Foundation only.
enum ReminderSync {
    static let listName = "Griasa"
    /// Overdue promises older than this stay off the phone: turning the sync
    /// on must not fill Reminders with a backlog of last quarter's promises.
    static let backlogDays = 7

    struct Reminder: Equatable {
        var id: String
        var title: String
        var completed: Bool
        var due: Date?
    }

    /// Which promise each reminder belongs to, and the promises whose reminder
    /// was deleted on purpose, which are not given another one.
    struct Links: Codable, Equatable {
        var byPromise: [UUID: String] = [:]
        var dropped: Set<UUID> = []
        /// Whether each linked pair was done when both sides last agreed. A
        /// difference on one side only says which side changed: a promise
        /// reopened in Griasa must reopen the reminder, not be closed again by
        /// the reminder that is still ticked.
        var agreed: [UUID: Bool] = [:]
    }

    enum Action: Equatable {
        /// Make a reminder for this promise.
        case create(UUID)
        /// The promise was closed in Griasa.
        case complete(reminder: String)
        /// The promise was reopened in Griasa.
        case reopen(reminder: String)
        /// The reminder was ticked on the phone.
        case close(UUID)
        /// The reminder was unticked on the phone.
        case open(UUID)
        /// The reminder was deleted: stop following this promise.
        case drop(UUID)
        /// The promise was deleted: forget the link, leave the reminder be.
        case unlink(UUID)
        /// A reminder added to the list by hand or by Siri: make it a promise.
        case adopt(reminder: String)
    }

    static func plan(promises: [Commitment], reminders: [Reminder], links: Links, now: Date,
                     calendar: Calendar = .current) -> [Action] {
        var actions: [Action] = []
        let byID = Dictionary(promises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remindersByID = Dictionary(reminders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let linkedReminders = Set(links.byPromise.values)

        for (promiseID, reminderID) in links.byPromise.sorted(by: { $0.value < $1.value }) {
            guard let promise = byID[promiseID] else { actions.append(.unlink(promiseID)); continue }
            guard let reminder = remindersByID[reminderID] else { actions.append(.drop(promiseID)); continue }
            guard promise.done != reminder.completed else { continue }
            let before = links.agreed[promiseID] ?? false
            if promise.done != before {
                actions.append(promise.done ? .complete(reminder: reminderID) : .reopen(reminder: reminderID))
            } else {
                actions.append(reminder.completed ? .close(promiseID) : .open(promiseID))
            }
        }

        let oldest = calendar.date(byAdding: .day, value: -backlogDays, to: calendar.startOfDay(for: now)) ?? now
        for promise in promises where promise.isMine && !promise.done
            && links.byPromise[promise.id] == nil && !links.dropped.contains(promise.id) {
            guard let due = promise.dueDate, due >= oldest else { continue }
            actions.append(.create(promise.id))
        }

        for reminder in reminders where !reminder.completed && !linkedReminders.contains(reminder.id) {
            actions.append(.adopt(reminder: reminder.id))
        }
        return actions
    }

    /// The promise a reminder from the list becomes: the user's own, with the
    /// reminder's date when it has one.
    static func promise(from reminder: Reminder, myName: String, now: Date) -> Commitment {
        Commitment(text: reminder.title.trimmingCharacters(in: .whitespacesAndNewlines),
                   owner: myName.isEmpty ? "You" : myName, isMine: true,
                   dueDate: reminder.due, sourceTitle: "Reminders", date: now)
    }
}
