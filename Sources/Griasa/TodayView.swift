import SwiftUI
import AppKit

/// The "Today" hub tab: the morning brief, and every part of Griasa one click
/// away. It is the screen to open when there is no particular reason to open
/// another — what the day holds on top, and below it the things Griasa can do,
/// most of which otherwise hide behind a hotkey or a menu item.
struct TodayView: View {
    @ObservedObject private var brief = DailyBriefController.shared
    @ObservedObject private var state = AppState.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let day = brief.day {
                    Text(day.date.formatted(date: .complete, time: .omitted)).font(.title2.bold())
                    Text(DailyBrief.summary(day)).foregroundStyle(.secondary)
                    meetings(day.meetings)
                    list("Overdue", systemImage: "exclamationmark.circle", tint: .red, items: day.overdueMine.map(\.text),
                         open: .commitments)
                    list("Due today", systemImage: "calendar", tint: .orange, items: day.dueToday.map(\.text), open: .commitments)
                    list("Overdue from your team", systemImage: "person.3", tint: .orange,
                         items: day.overdueTeam.flatMap { member in member.items.map { "\(member.name): \($0.text)" } },
                         open: .team)
                    list("Decisions to look at again", systemImage: "calendar.badge.clock", tint: .purple,
                         items: day.revisit.map(\.text), open: .decisions)
                    list("Looks done", systemImage: "checkmark.circle", tint: .green, items: day.looksDone.map(\.text),
                         open: .commitments)
                }
                launcher
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { brief.refresh() }
    }

    @ViewBuilder
    private func meetings(_ meetings: [DailyBrief.Meeting]) -> some View {
        if !meetings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Meetings", systemImage: "person.2").font(.headline).foregroundStyle(.blue)
                ForEach(meetings, id: \.start) { meeting in
                    HStack(alignment: .firstTextBaseline) {
                        Text(meeting.start.formatted(date: .omitted, time: .shortened))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.title)
                            if !meeting.attendees.isEmpty {
                                Text(meeting.attendees.prefix(5).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if meeting.youOwe + meeting.theyOwe > 0 {
                            Text("you owe \(meeting.youOwe) · they owe \(meeting.theyOwe)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let url = meeting.videoURL {
                            Button("Join") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Button("Prepare for the next one") { MeetingPrepWatcher.shared.prepNextMeeting() }
                    .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private func list(_ title: String, systemImage: String, tint: Color, items: [String], open tab: HubTab) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    HubController.shared.open(tab)
                } label: {
                    Label("\(title) · \(items.count)", systemImage: systemImage).font(.headline).foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { _, item in
                    Text("• " + item).fixedSize(horizontal: false, vertical: true)
                }
                if items.count > 6 {
                    Button("\(items.count - 6) more…") { HubController.shared.open(tab) }.buttonStyle(.link)
                }
            }
        }
    }

    /// Everything Griasa does, as a grid of buttons.
    private var launcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 4)
            Text("Griasa").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                tile(state.isRecording ? "Stop recording" : "Record a meeting",
                     systemImage: state.isRecording ? "stop.circle" : "record.circle") {
                    Task { state.isRecording ? await state.stopRecording() : await state.startRecording() }
                }
                tile("Prep next meeting", systemImage: "list.clipboard") { MeetingPrepWatcher.shared.prepNextMeeting() }
                tile("Commitments", systemImage: "checklist") { HubController.shared.open(.commitments) }
                tile("Decisions", systemImage: "signpost.right.and.left") { HubController.shared.open(.decisions) }
                tile("My team", systemImage: "person.3") { HubController.shared.open(.team) }
                tile("People", systemImage: "person.crop.rectangle.stack") { HubController.shared.open(.people) }
                tile("Conversations", systemImage: "bubble.left.and.bubble.right") { HubController.shared.open(.conversations) }
                tile("Ask a project", systemImage: "folder.badge.questionmark") { AskProjectWindowController.shared.show() }
                tile("Remind me", systemImage: "alarm") { ReminderComposer.shared.show(text: "") }
                tile("New document", systemImage: "doc.badge.plus") { HubController.shared.open(.newDocument) }
                tile("Import notes", systemImage: "square.and.arrow.down") { HubController.shared.open(.importNotes) }
                tile("History", systemImage: "clock.arrow.circlepath") { HistoryWindowController.shared.show() }
                tile("Settings", systemImage: "gearshape") { openSettings() }
            }
            Text("Dictation: hold \(state.hotkeyChoice.displayName) and speak, in any app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
