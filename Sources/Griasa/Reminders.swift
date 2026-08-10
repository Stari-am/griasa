import EventKit
import Foundation

/// Creates reminders in the macOS Reminders app via EventKit, so they sync to
/// the user's iPhone/Watch and fire native notifications.
enum RemindersService {
    static let store = EKEventStore()

    /// One-time access prompt on first use. Returns whether access is granted.
    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    static func create(title: String, notes: String?, due: Date?, url: URL? = nil) throws {
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw NSError(domain: "Griasa", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "No default Reminders list. Open the Reminders app and create a list first."
            ])
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.url = url
        reminder.calendar = calendar
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
    }
}
