import Foundation

/// What the desktop widget shows, as a small file the app writes and the
/// widget reads.
///
/// The widget runs in its own sandbox and cannot read Griasa's stores, and it
/// should not: it needs a handful of lines, not the history. So the app writes
/// this snapshot — built from the morning brief, with no model and nothing
/// sent anywhere — into the app group's container, and the widget only ever
/// reads it. Compiled into both the app and the widget extension.
///
/// Foundation only.
struct WidgetSnapshot: Codable, Equatable {
    /// The app group both sides are signed with: the team id, then the app's id.
    static let groupID = "J3S39L8KJ9.am.stari.griasa"
    static let fileName = "widget.json"
    /// How many lines of each kind the largest widget can show.
    static let listLimit = 5

    struct Meeting: Codable, Equatable {
        var title: String
        var start: Date
        var attendees: [String]
        var youOwe: Int
        var theyOwe: Int
    }

    var generated: Date
    var day: Date
    var summary: String
    var meetings: [Meeting]
    var overdue: [String]
    var overdueCount: Int
    var dueToday: [String]
    var team: [String]
    var teamCount: Int
    var revisit: [String]

    /// The next meeting that has not ended by `now`.
    func next(after now: Date) -> Meeting? {
        meetings.first { $0.start.addingTimeInterval(30 * 60) > now }
    }

    /// The link a tap on the widget opens: `griasa://open/<tab>`.
    static func link(_ tab: String) -> URL { URL(string: "griasa://open/\(tab)")! }

    /// The hub tab a `griasa://open/<tab>` link names, if it is one.
    static func tab(in url: URL) -> String? {
        guard url.scheme == "griasa", url.host == "open" else { return nil }
        let name = url.pathComponents.dropFirst().first
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }
}
