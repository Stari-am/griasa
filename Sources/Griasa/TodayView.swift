import SwiftUI
import AppKit

/// The "Today" hub tab: the morning brief, and every part of Griasa one click
/// away. It is the screen to open when there is no particular reason to open
/// another — what the day holds on top, and below it the things Griasa can do,
/// most of which otherwise hide behind a hotkey or a menu item.
struct TodayView: View {
    @ObservedObject private var brief = DailyBriefController.shared
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var commitments = CommitmentStore.shared
    @ObservedObject private var decisions = DecisionStore.shared
    @ObservedObject private var people = PersonStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var projects = ProjectStore.shared
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

    /// Everything Griasa does, as a grid of small cards: each says what is in
    /// it right now, so the grid is worth a look on its own.
    private var launcher: some View {
        let now = Date()
        let open = commitments.commitments.filter { !$0.done }
        let overdue = open.filter { $0.isMine && TeamDigest.isOverdue($0, now: now) }.count
        let reports = people.directReports.map(\.name)
        let late = TeamDigest.members(names: reports, commitments: open, lastMet: { _ in nil }, now: now)
            .reduce(0) { $0 + $1.owed.filter { TeamDigest.isOverdue($0, now: now) }.count }
        let revisit = decisions.decisions.filter { $0.needsRevisit(on: now) }.count
        let meetings = history.entries.filter { $0.kind == .meeting }
        let next = brief.day?.meetings.first { $0.end > now }
        return VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 4)
            Text("Griasa").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                if state.isRecording {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        tile("Stop recording", systemImage: "stop.circle.fill", tint: .red,
                             value: elapsed(since: state.recordingStartedAt, now: context.date), detail: "recording now") {
                            Task { await state.stopRecording() }
                        }
                    }
                } else {
                    tile("Record a meeting", systemImage: "record.circle", tint: .red,
                         value: "\(meetings.count)", detail: meetings.first.map { "last " + relative($0.date, now) } ?? "none yet") {
                        Task { await state.startRecording() }
                    }
                }
                tile("Prep next meeting", systemImage: "list.clipboard", tint: .blue,
                     value: next.map { $0.start.formatted(date: .omitted, time: .shortened) } ?? "—",
                     detail: next?.title ?? "no more meetings today") { MeetingPrepWatcher.shared.prepNextMeeting() }
                tile("Commitments", systemImage: "checklist", tint: overdue > 0 ? .red : .green,
                     value: "\(open.count)", detail: overdue > 0 ? "open · \(overdue) overdue" : "open") {
                    HubController.shared.open(.commitments)
                }
                tile("Decisions", systemImage: "signpost.right.and.left", tint: .purple,
                     value: "\(decisions.decisions.count)", detail: revisit > 0 ? "\(revisit) to look at again" : "recorded") {
                    HubController.shared.open(.decisions)
                }
                tile("My team", systemImage: "person.3", tint: .orange,
                     value: "\(reports.count)",
                     detail: reports.isEmpty ? "mark your reports in People" : late > 0 ? "reports · \(late) late" : "reports") {
                    HubController.shared.open(.team)
                }
                tile("People", systemImage: "person.crop.rectangle.stack", tint: .teal,
                     value: "\(people.people.count)", detail: "colleagues known") { HubController.shared.open(.people) }
                tile("Ask a project", systemImage: "folder.badge.questionmark", tint: .indigo,
                     value: "\(projects.projects.count)", detail: "projects to ask") { AskProjectWindowController.shared.show() }
                tile("History", systemImage: "clock.arrow.circlepath", tint: .gray,
                     value: "\(history.entries.count)",
                     detail: history.entries.first.map { "last " + relative($0.date, now) } ?? "nothing yet") {
                    HistoryWindowController.shared.show()
                }
                tile("Conversations", systemImage: "bubble.left.and.bubble.right", tint: .cyan,
                     detail: "chats you imported") { HubController.shared.open(.conversations) }
                tile("Remind me", systemImage: "alarm", tint: .orange, detail: "a note at a time you pick") {
                    ReminderComposer.shared.show(text: "")
                }
                tile("New document", systemImage: "doc.badge.plus", tint: .blue, detail: "PRD, RFC, postmortem…") {
                    HubController.shared.open(.newDocument)
                }
                tile("Import notes", systemImage: "square.and.arrow.down", tint: .green, detail: "from Zoom, Meet, ChatGPT") {
                    HubController.shared.open(.importNotes)
                }
                tile("Settings", systemImage: "gearshape", tint: .gray, detail: "models, hotkey, brief") { openSettings() }
            }
            Text("Dictation: hold \(state.hotkeyChoice.displayName) and speak, in any app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func relative(_ date: Date, _ now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private func elapsed(since start: Date?, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start ?? now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// One card: an icon, the name, and — when there is one — a number or a
    /// time with a line saying what it counts.
    private func tile(_ title: String, systemImage: String, tint: Color, value: String? = nil, detail: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage).foregroundStyle(tint)
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let value {
                    Text(value).font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(tint).lineLimit(1)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.18)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
