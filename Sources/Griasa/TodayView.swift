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

    /// Everything Griasa does, as small widgets: an icon, a name, and one live
    /// line — so the grid answers "what is there" and "how is it" at once.
    private var launcher: some View {
        let commitments = CommitmentStore.shared
        let decisions = DecisionStore.shared
        let mineOpen = commitments.openMine.count
        let overdue = brief.day?.overdueMine.count ?? 0
        let teamLate = brief.day?.overdueTeam.reduce(0) { $0 + $1.items.count } ?? 0
        let reports = PersonStore.shared.directReports.count
        let next = brief.day?.meetings.first { $0.start > Date() }
        let meetingCount = HistoryStore.shared.entries.filter { $0.kind == .meeting }.count
        return VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 4)
            Text("Griasa").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                widget(state.isRecording ? "Recording" : "Record",
                       detail: state.recordingStartedAt.map { "since \($0.formatted(date: .omitted, time: .shortened)) · stop" }
                           ?? "Mic + Mac audio",
                       systemImage: state.isRecording ? "stop.fill" : "record.circle", tint: .red) {
                    Task { state.isRecording ? await state.stopRecording() : await state.startRecording() }
                }
                widget("Next meeting",
                       detail: next.map { "\($0.start.formatted(date: .omitted, time: .shortened)) \($0.title)" } ?? "Brief before the call",
                       systemImage: "list.clipboard", tint: .blue) { MeetingPrepWatcher.shared.prepNextMeeting() }
                widget("Commitments", detail: overdue > 0 ? "\(mineOpen) open · \(overdue) overdue" : "\(mineOpen) open",
                       systemImage: "checklist", tint: overdue > 0 ? .red : .green) { HubController.shared.open(.commitments) }
                widget("Decisions",
                       detail: decisions.toRevisit.isEmpty ? "\(decisions.decisions.count) kept"
                           : "\(decisions.toRevisit.count) to look at again",
                       systemImage: "signpost.right.and.left", tint: .purple) { HubController.shared.open(.decisions) }
                widget("My team",
                       detail: reports == 0 ? "Mark who reports to you" : teamLate > 0 ? "\(teamLate) late from \(reports)" : "\(reports) people, nothing late",
                       systemImage: "person.3.fill", tint: .orange) { HubController.shared.open(.team) }
                widget("People", detail: "\(PersonStore.shared.allNames.count) known",
                       systemImage: "person.crop.rectangle.stack", tint: .teal) { HubController.shared.open(.people) }
                widget("Conversations", detail: "Chat promises",
                       systemImage: "bubble.left.and.bubble.right.fill", tint: .cyan) { HubController.shared.open(.conversations) }
                widget("Ask a project", detail: "\(ProjectStore.shared.projects.count) projects",
                       systemImage: "folder.badge.questionmark", tint: .indigo) { AskProjectWindowController.shared.show() }
                widget("Remind me", detail: "Text → reminder",
                       systemImage: "alarm.fill", tint: .yellow) { ReminderComposer.shared.show(text: "") }
                widget("New document", detail: "From a template",
                       systemImage: "doc.badge.plus", tint: .mint) { HubController.shared.open(.newDocument) }
                widget("Import notes", detail: "Zoom, Meet, Notion",
                       systemImage: "square.and.arrow.down.fill", tint: .brown) { HubController.shared.open(.importNotes) }
                widget("History", detail: "\(meetingCount) meetings",
                       systemImage: "clock.arrow.circlepath", tint: .gray) { HistoryWindowController.shared.show() }
                widget("Settings", detail: "Models, hotkeys",
                       systemImage: "gearshape.fill", tint: .gray) { openSettings() }
            }
            Text("Dictation: hold \(state.hotkeyChoice.displayName) and speak, in any app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func widget(_ title: String, detail: String, systemImage: String, tint: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(detail)
    }
}
