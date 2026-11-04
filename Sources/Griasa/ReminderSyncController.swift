import EventKit
import Combine
import Foundation

/// Carries out `ReminderSync`'s plan against Apple Reminders: the list
/// "Griasa", made on first use in the same account as the default list, so it
/// reaches the iPhone the way the person's other reminders do.
@MainActor
final class ReminderSyncController: ObservableObject {
    static let shared = ReminderSyncController()
    static let enabledKey = "reminderSyncEnabled"

    @Published private(set) var problem: String?
    @Published private(set) var lastSync: Date?

    private let store = RemindersService.store
    private let linksURL = StoreRoot.file("reminder-links.json")
    private var timer: Timer?
    private var observers: [AnyCancellable] = []
    private var running = false
    private var again = false

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A promise closed in Griasa, or a reminder ticked on the phone that
        // iCloud has just brought over, is passed on within seconds.
        CommitmentStore.shared.$commitments
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.sync() } }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.sync() } }
            .store(in: &observers)
        Task { await sync() }
    }

    /// Turning it on asks for Reminders access once; without it the switch
    /// goes back off and says why.
    func setEnabled(_ on: Bool) async {
        guard on else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            problem = nil
            return
        }
        guard await RemindersService.requestAccess() else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            problem = "Griasa has no access to Reminders. Allow it in System Settings → Privacy & Security → Reminders."
            return
        }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        problem = nil
        await sync()
    }

    func sync() async {
        guard enabled, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            do {
                try await syncOnce()
                problem = nil
                lastSync = Date()
            } catch {
                problem = error.localizedDescription
            }
        } while again
    }

    private func syncOnce() async throws {
        let list = try griasaList()
        let fetched = await fetch(in: list)
        var byID: [String: EKReminder] = [:]
        for reminder in fetched { byID[reminder.calendarItemIdentifier] = reminder }
        let reminders = fetched.map { reminder in
            ReminderSync.Reminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                                  completed: reminder.isCompleted,
                                  due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
        }
        var links = loadLinks()
        let commitments = CommitmentStore.shared
        let now = Date()
        let actions = ReminderSync.plan(promises: commitments.commitments, reminders: reminders, links: links, now: now)
        guard !actions.isEmpty else { return }

        for action in actions {
            switch action {
            case .create(let id):
                guard let promise = commitments.commitments.first(where: { $0.id == id }) else { continue }
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = list
                reminder.title = promise.text
                if !promise.sourceTitle.isEmpty { reminder.notes = "From “\(promise.sourceTitle)” in Griasa" }
                if let due = promise.dueDate {
                    reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
                }
                try store.save(reminder, commit: false)
                links.byPromise[id] = reminder.calendarItemIdentifier
                links.agreed[id] = false
            case .complete(let reminderID), .reopen(let reminderID):
                guard let reminder = byID[reminderID],
                      let id = links.byPromise.first(where: { $0.value == reminderID })?.key else { continue }
                reminder.isCompleted = { if case .complete = action { return true } else { return false } }()
                try store.save(reminder, commit: false)
                links.agreed[id] = reminder.isCompleted
            case .close(let id), .open(let id):
                let done: Bool = { if case .close = action { return true } else { return false } }()
                if let promise = commitments.commitments.first(where: { $0.id == id }), promise.done != done {
                    commitments.toggleDone(id)
                }
                links.agreed[id] = done
            case .drop(let id):
                links.byPromise[id] = nil
                links.agreed[id] = nil
                links.dropped.insert(id)
            case .unlink(let id):
                links.byPromise[id] = nil
                links.agreed[id] = nil
            case .adopt(let reminderID):
                guard let reminder = reminders.first(where: { $0.id == reminderID }) else { continue }
                let promise = ReminderSync.promise(from: reminder, myName: ParticipantRoster.shared.myName, now: now)
                guard !promise.text.isEmpty else { continue }
                // Already on the list with the same words (it was added in
                // Griasa and on the phone): follow that one instead.
                let id: UUID
                if commitments.add(promise) {
                    id = promise.id
                } else if let existing = commitments.commitments.first(where: {
                    !$0.done && CommitmentStore.normalize($0.text) == CommitmentStore.normalize(promise.text)
                }), links.byPromise[existing.id] == nil {
                    id = existing.id
                } else { continue }
                links.byPromise[id] = reminderID
                links.agreed[id] = false
            }
        }
        try store.commit()
        saveLinks(links)
    }

    /// The list "Griasa", made in the default list's account when missing.
    private func griasaList() throws -> EKCalendar {
        if let list = store.calendars(for: .reminder).first(where: { $0.title == ReminderSync.listName }) { return list }
        guard let source = store.defaultCalendarForNewReminders()?.source else {
            throw NSError(domain: "Griasa", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "No Reminders account to make the “Griasa” list in. Open Reminders and make a list first."
            ])
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = ReminderSync.listName
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list
    }

    private func fetch(in list: EKCalendar) async -> [EKReminder] {
        let predicate = store.predicateForReminders(in: [list])
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func loadLinks() -> ReminderSync.Links {
        guard let data = try? Data(contentsOf: linksURL),
              let links = try? JSONDecoder().decode(ReminderSync.Links.self, from: data) else { return .init() }
        return links
    }

    private func saveLinks(_ links: ReminderSync.Links) {
        guard let data = try? JSONEncoder().encode(links) else { return }
        try? data.write(to: linksURL, options: [.atomic, .completeFileProtection])
    }
}
