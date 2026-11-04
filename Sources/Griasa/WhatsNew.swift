import Foundation

/// What a new version adds, said once on the Today tab after the update, and
/// the first steps for somebody who has just installed Griasa.
///
/// The wording comes from docs/FEATURES.md, so the card, the README and the
/// release notes call each feature by the same name.
///
/// Foundation only.
enum WhatsNew {
    static let seenKey = "whatsNewSeenVersion"

    /// Where a line's button goes.
    enum Target: Equatable { case tab(String), settings, none }

    struct Item: Equatable {
        var symbol: String
        var name: String
        var line: String
        var target: Target
    }

    /// Kept to the latest release: an update from further back sees only the
    /// newest things, which is what fits on a card.
    static let releases: [(version: String, items: [Item])] = [
        ("1.0.26", [
            Item(symbol: "iphone", name: "Notes and recordings from the iPhone",
                 line: "Dictate in the car; it is waiting on the Mac as a meeting.", target: .settings),
            Item(symbol: "checklist", name: "Promises in Reminders",
                 line: "Your dated promises on the iPhone, Watch and CarPlay — both ways.", target: .settings),
            Item(symbol: "rectangle.on.rectangle", name: "Desktop widget",
                 line: "Right-click the desktop → Edit Widgets… → Griasa.", target: .none),
            Item(symbol: "checkmark.circle", name: "Close promises before the call",
                 line: "Tick a promise that is already done right on the brief.", target: .tab("prep")),
            Item(symbol: "lock.shield", name: "Every permission in one list",
                 line: "Settings → System → Permissions: what each one is for.", target: .settings),
        ]),
    ]

    /// What to show for `current`, given the version last acknowledged.
    /// Nothing on a first install — that is what the first steps are for —
    /// nothing once it is seen, and nothing for a version without notes.
    static func items(current: String, seen: String?, firstInstall: Bool) -> [Item] {
        guard !firstInstall, seen != current else { return [] }
        return releases.first { $0.version == current }?.items ?? []
    }
}
