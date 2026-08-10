import AppKit
import SwiftUI

/// What the user picked from the "remind me when?" menu.
enum RemindChoice {
    case at(Date)
    /// Claude infers the due date from the captured text (original behavior).
    case fromText
    /// Open the date-picker window.
    case custom
}

/// Small menu shown at the mouse cursor after text is captured, mirroring
/// Slack's "Remind me about this" options. Returns nil when dismissed (Esc /
/// click outside).
@MainActor
final class RemindMenu: NSObject {
    private var choice: RemindChoice?

    static func choose() -> RemindChoice? {
        let helper = RemindMenu()
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, _ choice: RemindChoice) {
            let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = helper
            item.representedObject = ChoiceBox(choice)
            menu.addItem(item)
        }

        let now = Date()
        add("In 20 minutes", .at(now.addingTimeInterval(20 * 60)))
        add("In 1 hour", .at(now.addingTimeInterval(60 * 60)))
        add("In 3 hours", .at(now.addingTimeInterval(3 * 60 * 60)))
        add("Tomorrow at 9:00", .at(tomorrow9))
        add("Next week (Mon 9:00)", .at(nextMonday9))
        menu.addItem(.separator())
        add("From the text (Claude detects the time)", .fromText)
        add("Custom…", .custom)

        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return helper.choice
    }

    @objc private func pick(_ sender: NSMenuItem) {
        choice = (sender.representedObject as? ChoiceBox)?.choice
    }

    /// NSMenuItem.representedObject needs a class.
    private final class ChoiceBox: NSObject {
        let choice: RemindChoice
        init(_ choice: RemindChoice) { self.choice = choice }
    }

    static var tomorrow9: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    static var nextMonday9: Date {
        let calendar = Calendar.current
        // Search from tomorrow so "next week" chosen on a Monday means the
        // following Monday, like Slack.
        let start = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return calendar.nextDate(after: start,
                                 matching: DateComponents(hour: 9, minute: 0, weekday: 2),
                                 matchingPolicy: .nextTime) ?? tomorrow9
    }
}

/// State behind the "Custom…" reminder tab in the hub: the captured text plus
/// a date picker for an exact reminder time.
@MainActor
final class ReminderComposer: ObservableObject {
    static let shared = ReminderComposer()

    @Published var text = ""
    @Published var due = RemindMenu.tomorrow9
    @Published var creating = false
    private var origin: ReminderSource?
    private var imageURL: URL?

    func show(text: String, origin: ReminderSource? = nil, imageURL: URL? = nil) {
        self.text = text
        self.origin = origin
        self.imageURL = imageURL
        due = RemindMenu.tomorrow9
        creating = false
        HubController.shared.open(.reminder)
    }

    /// Dismissed without creating — delete the saved region clip so it
    /// doesn't orphan.
    func cancel() {
        if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
        imageURL = nil
        origin = nil
        creating = false
        HubController.shared.close(.reminder)
    }

    func create() {
        guard !creating else { return }
        creating = true
        let source = text
        let picked = due
        let origin = origin
        let imageURL = imageURL
        Task { @MainActor in
            PopupController.shared.showLoading(title: "⏰ Remind me", canReplace: false,
                                               sourceApp: NSWorkspace.shared.frontmostApplication)
            await CaptureController.createReminder(from: source, dueOverride: picked,
                                                   origin: origin, imageURL: imageURL)
            self.origin = nil
            self.imageURL = nil
            self.creating = false
            HubController.shared.close(.reminder)
        }
    }
}

struct ReminderComposeView: View {
    @ObservedObject private var composer = ReminderComposer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(composer.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            DatePicker("Remind at", selection: $composer.due, in: Date()...)
            HStack {
                Spacer()
                Button("Cancel") { composer.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Reminder") { composer.create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(composer.creating)
            }
        }
        .padding(16)
        .frame(maxWidth: 420)
    }
}
