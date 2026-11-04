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
    @ObservedObject private var phone = PhoneInboxWatcher.shared
    @AppStorage(PhoneInboxWatcher.enabledKey) private var phoneOn = false
    @AppStorage(ReminderSyncController.enabledKey) private var remindersOn = false
    @AppStorage(WhatsNew.seenKey) private var whatsNewSeen = ""
    @AppStorage("startHereDismissed") private var startHereDismissed = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                whatsNew
                startHere
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

    /// Once after an update: what the new version adds, each with a way to it.
    @ViewBuilder
    private var whatsNew: some View {
        let firstInstall = whatsNewSeen.isEmpty && !history.entries.contains { $0.kind == .meeting }
        let items = WhatsNew.items(current: AppInfo.version, seen: whatsNewSeen.isEmpty ? nil : whatsNewSeen,
                                   firstInstall: firstInstall)
        if !items.isEmpty {
            HubCard(icon: "sparkles", title: "New in \(AppInfo.version)", tint: .pink) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items, id: \.name) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: item.symbol).foregroundStyle(.pink).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.callout.weight(.semibold))
                                Text(item.line).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            switch item.target {
                            case .settings: Button("Open") { openSettings() }.controlSize(.small)
                            case .tab(let name):
                                if let tab = HubTab(rawValue: name) {
                                    Button("Open") { HubController.shared.open(tab) }.controlSize(.small)
                                }
                            case .none: EmptyView()
                            }
                        }
                    }
                }
            } trailing: {
                Button("Got it") { whatsNewSeen = AppInfo.version }.controlSize(.small)
            }
        } else if firstInstall || whatsNewSeen.isEmpty {
            // Nothing to announce to a new install; later updates are measured from here.
            Color.clear.frame(height: 0).onAppear { whatsNewSeen = AppInfo.version }
        }
    }

    /// For a new install, until the first meeting is in: the three steps that
    /// make every other screen fill itself.
    @ViewBuilder
    private var startHere: some View {
        if !startHereDismissed, !history.entries.contains(where: { $0.kind == .meeting }) {
            HubCard(icon: "flag", title: "Start here", tint: .blue) {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Record a meeting, or import notes from Zoom, Meet or ChatGPT.",
                         action: ("Record", { Task { await state.startRecording() } }),
                         second: ("Import notes", { HubController.shared.open(.importNotes) }))
                    step(2, "Allow Calendar, so a brief appears minutes before each call.",
                         done: Permissions.calendarGranted, action: ("Allow…", { Task { await Access.calendar.request() } }))
                    step(3, "In People, switch on “Reports to me” for your team, so you see what they owe you.",
                         done: !people.directReports.isEmpty, action: ("Open People", { HubController.shared.open(.people) }))
                    Text("Promises, decisions and people's pages then fill themselves after every meeting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } trailing: {
                Button("Hide") { startHereDismissed = true }.controlSize(.small)
            }
        }
    }

    private func step(_ n: Int, _ text: String, done: Bool = false, action: (String, () -> Void),
                      second: (String, () -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.callout.weight(.bold).monospacedDigit()).foregroundStyle(.blue)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(action.0, action: action.1).controlSize(.small)
                if let second { Button(second.0, action: second.1).controlSize(.small) }
            }
        }
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
                tile("From iPhone", systemImage: "iphone", tint: .pink,
                     detail: phoneOn || remindersOn ? (phone.lastImported ?? "notes, memos, calls")
                                                    : "set up in Settings → iPhone") { openSettings() }
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
