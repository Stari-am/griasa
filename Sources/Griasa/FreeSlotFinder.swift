import EventKit
import Foundation

/// Finds free calendar slots for the {slot}/{slots:N} snippet placeholders.
/// Read-only EventKit access, requested lazily on first use.
enum FreeSlotFinder {
    private static let store = EKEventStore()
    private static let horizonDays = 7

    struct AccessError: LocalizedError {
        var errorDescription: String? {
            "{slot}: Calendar access is needed to find free time. Grant it in System Settings → Privacy & Security → Calendars. Every other snippet works without it."
        }
    }

    // MARK: - Settings (Settings → Snippets)

    static var workStart: Int {  // hour, 0–23
        UserDefaults.standard.object(forKey: "snippetWorkStart") as? Int ?? 10
    }
    static var workEnd: Int {
        UserDefaults.standard.object(forKey: "snippetWorkEnd") as? Int ?? 18
    }
    static var minMinutes: Int {
        UserDefaults.standard.object(forKey: "snippetMinSlotMinutes") as? Int ?? 30
    }
    static var weekdaysOnly: Bool {
        UserDefaults.standard.object(forKey: "snippetWeekdaysOnly") as? Bool ?? true
    }

    /// Start times of the next `count` free slots — at most one per day when
    /// several are requested, so a proposal offers real alternatives.
    static func nextSlots(_ count: Int) async throws -> [Date] {
        guard (try? await store.requestFullAccessToEvents()) == true else {
            throw AccessError()
        }

        let calendar = Calendar.current
        let now = Date()
        let searchEnd = calendar.date(byAdding: .day, value: horizonDays, to: now)!

        // Busy intervals: every non-all-day event that actually blocks time.
        let predicate = store.predicateForEvents(withStart: now, end: searchEnd, calendars: nil)
        let busy = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.availability != .free }
            .map { ($0.startDate!, $0.endDate!) }
            .sorted { $0.0 < $1.0 }
        let merged = mergeIntervals(busy)

        // Don't propose anything sooner than an hour out, and start on a
        // clean half-hour boundary.
        let earliest = roundUpToHalfHour(now.addingTimeInterval(3600))
        let slotLength = TimeInterval(minMinutes * 60)

        var slots: [Date] = []
        for dayOffset in 0...horizonDays {
            guard slots.count < count else { break }
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { continue }
            if weekdaysOnly && calendar.isDateInWeekend(day) { continue }

            guard let windowStartRaw = calendar.date(bySettingHour: workStart, minute: 0, second: 0, of: day),
                  let windowEnd = calendar.date(bySettingHour: workEnd, minute: 0, second: 0, of: day)
            else { continue }
            var cursor = max(windowStartRaw, earliest)
            guard cursor.addingTimeInterval(slotLength) <= windowEnd else { continue }

            var found: Date?
            for (busyStart, busyEnd) in merged where busyEnd > cursor {
                if busyStart >= windowEnd { break }
                if busyStart.timeIntervalSince(cursor) >= slotLength {
                    found = cursor
                    break
                }
                cursor = max(cursor, roundUpToHalfHour(busyEnd))
                if cursor.addingTimeInterval(slotLength) > windowEnd { break }
            }
            if found == nil, cursor.addingTimeInterval(slotLength) <= windowEnd {
                found = cursor
            }
            if let found {
                slots.append(found)
                // With a single requested slot we're done; with several,
                // move on to the next day for variety.
            }
        }
        return slots
    }

    /// "вт 21 июл, 15:00" / "Tue, Jul 21, 3:00 PM" — locale-aware.
    static func format(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
            .hour().minute())
    }

    private static func mergeIntervals(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        var merged: [(Date, Date)] = []
        for interval in intervals {
            if var last = merged.last, interval.0 <= last.1 {
                last.1 = max(last.1, interval.1)
                merged[merged.count - 1] = last
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func roundUpToHalfHour(_ date: Date) -> Date {
        let interval: TimeInterval = 1800
        return Date(timeIntervalSinceReferenceDate:
            (date.timeIntervalSinceReferenceDate / interval).rounded(.up) * interval)
    }
}
