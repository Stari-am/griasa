import Foundation
import AppKit

/// Shows the morning brief once a day: at its time (8:00 on weekdays unless
/// changed), or the first minute after it that the Mac is awake. A banner says
/// what the day holds and opens the Today tab; the tab itself opens quietly,
/// without taking focus. Optionally the brief is also written to a note in
/// Apple Notes, so it is on the phone.
@MainActor
final class DailyBriefController: ObservableObject {
    static let shared = DailyBriefController()

    static let enabledKey = "dailyBriefEnabled"
    static let timeKey = "dailyBriefTime"
    static let weekdaysOnlyKey = "dailyBriefWeekdaysOnly"
    static let notesKey = "dailyBriefToNotes"
    static let lastShownKey = "dailyBriefLastShown"

    @Published private(set) var day: DailyBrief.Day?
    @Published private(set) var notesError: String?

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.enabledKey) as? Bool ?? true else { return }
        let now = Date()
        guard DailyBrief.isDue(now: now, time: defaults.string(forKey: Self.timeKey) ?? "08:00",
                               weekdaysOnly: defaults.object(forKey: Self.weekdaysOnlyKey) as? Bool ?? true,
                               lastShown: defaults.object(forKey: Self.lastShownKey) as? Date) else { return }
        defaults.set(now, forKey: Self.lastShownKey)
        let built = refresh()
        Notifier.post(title: "Your day", body: DailyBrief.summary(built), opens: .today)
        HubController.shared.open(.today, activate: false)
        if defaults.object(forKey: Self.notesKey) as? Bool ?? true { writeToNotes(built) }
    }

    /// Builds the day from what Griasa keeps now.
    @discardableResult
    func refresh() -> DailyBrief.Day {
        let now = Date()
        let meetings = (MeetingPrepWatcher.shared.upcomingBriefs(days: 1, limit: 20) ?? []).map { brief in
            DailyBrief.Meeting(title: brief.title, start: brief.start, end: brief.end,
                               attendees: brief.attendees.map { $0.knownName ?? $0.name },
                               youOwe: brief.youPromised.count, theyOwe: brief.theyPromised.count,
                               videoURL: brief.videoURL)
        }
        let built = DailyBrief.make(now: now, meetings: meetings, commitments: CommitmentStore.shared.commitments,
                                    reports: PersonStore.shared.directReports.map(\.name),
                                    decisions: DecisionStore.shared.decisions)
        day = built
        return built
    }

    /// Writes this brief into the note "Griasa — Today" in the Notes folder
    /// "Griasa", creating both the first time and overwriting the note after. Notes asks for permission the first time; a refusal leaves
    /// the brief in Griasa only, and Settings says why.
    func writeToNotes(_ day: DailyBrief.Day) {
        let html = DailyBrief.text(day)
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let body = "<h1>Griasa — Today</h1>" + html
        let script = """
            tell application "Notes"
                if not (exists folder "Griasa") then make new folder with properties {name:"Griasa"}
                set target to folder "Griasa"
                set briefBody to "\(body.replacingOccurrences(of: "\\", with: "\\\\"))"
                set existing to (notes of target whose name is "Griasa — Today")
                if (count of existing) > 0 then
                    set body of (item 1 of existing) to briefBody
                else
                    make new note at target with properties {body:briefBody}
                end if
            end tell
            """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        notesError = error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "Notes refused the brief." }
    }
}
