import WidgetKit
import SwiftUI

/// Griasa's desktop widget: the morning brief at a glance.
///
/// It reads the snapshot the app writes into the shared app group container
/// (`WidgetSnapshot`) and nothing else: no network, no model, no store. A tap
/// opens Griasa on the tab the line belongs to.

struct BriefEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct BriefProvider: TimelineProvider {
    private func read() -> WidgetSnapshot? {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.groupID),
              let data = try? Data(contentsOf: folder.appendingPathComponent(WidgetSnapshot.fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func placeholder(in context: Context) -> BriefEntry { BriefEntry(date: .now, snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (BriefEntry) -> Void) {
        completion(BriefEntry(date: .now, snapshot: read()))
    }

    /// One entry now, and another when the next meeting starts, so "next" moves
    /// on by itself; the app also asks for a reload whenever the brief changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<BriefEntry>) -> Void) {
        let now = Date()
        let snapshot = read()
        var entries = [BriefEntry(date: now, snapshot: snapshot)]
        if let start = snapshot?.next(after: now)?.start, start > now {
            entries.append(BriefEntry(date: start.addingTimeInterval(30 * 60 + 1), snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

private extension Color {
    static let griasa = Color(red: 0.13, green: 0.45, blue: 0.62)
}

struct BriefView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BriefEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemSmall: small(snapshot)
                case .systemMedium: medium(snapshot)
                default: large(snapshot)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    Text("Open Griasa once and today's brief appears here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(WidgetSnapshot.link("today"))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "sun.max.fill").foregroundStyle(.orange)
            Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func nextMeeting(_ snapshot: WidgetSnapshot, compact: Bool) -> some View {
        if let next = snapshot.next(after: entry.date) {
            VStack(alignment: .leading, spacing: 1) {
                Text(next.start, style: .time).font(.caption.weight(.semibold)).foregroundStyle(Color.griasa)
                Text(next.title).font(compact ? .callout.weight(.semibold) : .headline).lineLimit(compact ? 2 : 1)
                if !compact, !next.attendees.isEmpty {
                    Text(next.attendees.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } else {
            Text("No more meetings today").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func count(_ n: Int, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(n > 0 ? tint : .secondary)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            nextMeeting(snapshot, compact: true)
            Spacer(minLength: 0)
            count(snapshot.overdueCount, "overdue", .red)
            if snapshot.teamCount > 0 { count(snapshot.teamCount, "late from team", .orange) }
        }
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                header
                nextMeeting(snapshot, compact: false)
                Spacer(minLength: 0)
                count(snapshot.overdueCount, "overdue", .red)
                if snapshot.teamCount > 0 { count(snapshot.teamCount, "late from team", .orange) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                lines(snapshot.overdue.isEmpty ? snapshot.dueToday : snapshot.overdue, limit: 3,
                      title: snapshot.overdue.isEmpty ? "Due today" : "Overdue", tint: .red, tab: "commitments")
                lines(snapshot.team, limit: 2, title: "Team", tint: .orange, tab: "team")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                header
                Spacer()
                Text(snapshot.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if !snapshot.meetings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(snapshot.meetings.prefix(4).enumerated()), id: \.offset) { _, meeting in
                        HStack(alignment: .firstTextBaseline) {
                            Text(meeting.start, style: .time).font(.caption.monospacedDigit()).foregroundStyle(Color.griasa)
                            Text(meeting.title).font(.callout).lineLimit(1)
                            Spacer(minLength: 0)
                            if meeting.youOwe + meeting.theyOwe > 0 {
                                Text("\(meeting.youOwe)↑ \(meeting.theyOwe)↓").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("No more meetings today").font(.callout).foregroundStyle(.secondary)
            }
            lines(snapshot.overdue, limit: 4, title: "Overdue", tint: .red, tab: "commitments")
            lines(snapshot.dueToday, limit: 3, title: "Due today", tint: .orange, tab: "commitments")
            lines(snapshot.team, limit: 4, title: "Late from your team", tint: .orange, tab: "team")
            lines(snapshot.revisit, limit: 3, title: "Decisions to look at again", tint: .purple, tab: "decisions")
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                stat(snapshot.overdueCount, "overdue", .red, tab: "commitments")
                stat(snapshot.dueToday.count, "due today", .orange, tab: "commitments")
                stat(snapshot.teamCount, "late from team", .orange, tab: "team")
                stat(snapshot.revisit.count, "to revisit", .purple, tab: "decisions")
            }
        }
    }

    /// A small tile for the large widget's bottom row: one number and what it counts.
    private func stat(_ n: Int, _ label: String, _ tint: Color, tab: String) -> some View {
        Link(destination: WidgetSnapshot.link(tab)) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(n)").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(n > 0 ? tint : .secondary)
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(n > 0 ? 0.10 : 0.04)))
        }
    }

    @ViewBuilder
    private func lines(_ items: [String], limit: Int, title: String, tint: Color, tab: String) -> some View {
        if !items.isEmpty {
            Link(destination: WidgetSnapshot.link(tab)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    ForEach(Array(items.prefix(limit).enumerated()), id: \.offset) { _, item in
                        Text("• " + item).font(.caption).lineLimit(1)
                    }
                }
            }
        }
    }
}

@main
struct GriasaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "am.stari.griasa.today", provider: BriefProvider()) { entry in
            BriefView(entry: entry)
        }
        .configurationDisplayName("Griasa — Today")
        .description("Your next meeting, what is overdue, and what your team owes you. From Griasa on this Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
