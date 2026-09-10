import SwiftUI
import AppKit

/// The "📋 Prep" hub tab — the pre-meeting glance: who, what happened last
/// time, and who owes whom what.
struct PrepView: View {
    @ObservedObject private var watcher = MeetingPrepWatcher.shared
    @ObservedObject private var state = AppState.shared

    var body: some View {
        switch watcher.state {
        case .empty(let message):
            EmptyStateView(icon: "calendar.badge.clock", title: "Nothing to prep", message: message)
        case .brief(let brief):
            briefView(brief)
        }
    }

    private func briefView(_ brief: PrepBrief) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(brief)
                actions(brief)

                if !brief.attendees.isEmpty {
                    HubCard(icon: "person.2.fill", title: "Who's on the call", tint: .blue) {
                        VStack(spacing: 6) {
                            ForEach(brief.attendees) { attendee in
                                attendeeRow(attendee)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let last = brief.lastMeeting {
                    HubCard(icon: "clock.arrow.circlepath",
                            title: "Last time — «\(last.title)», \(last.date.formatted(.relative(presentation: .named)))",
                            tint: .teal) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let summary = last.summary {
                                Text(summary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let path = last.filePath {
                                Button("Open full transcript") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Grouped by why you are being shown them, in a fixed order,
                // rather than split into mine and theirs. Before a recurring
                // call, what was promised *in that call* last time matters more
                // than which direction it points, and a promise involving
                // nobody in the room is not here at all.
                ForEach(brief.buckets, id: \.bucket) { group in
                    commitmentsBox(title: title(for: group.bucket),
                                   systemImage: symbol(for: group.bucket),
                                   tint: tint(for: group.bucket),
                                   items: group.items,
                                   showOwner: true,
                                   footnote: footnote(for: group.bucket),
                                   limit: 6)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ brief: PrepBrief) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(brief.title)
                .font(.title2.weight(.semibold))
            // Live countdown; switches wording once the meeting has begun.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let minutes = Int(brief.start.timeIntervalSince(context.date) / 60)
                let countdown = minutes >= 1 ? "Starts in \(minutes) min"
                    : (brief.end > context.date ? "Happening now" : "Ended")
                Text("\(countdown) · \(brief.start.formatted(date: .omitted, time: .shortened))–\(brief.end.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(minutes < 1 && brief.end > context.date ? .red : .secondary)
            }
        }
    }

    private func actions(_ brief: PrepBrief) -> some View {
        HStack {
            if state.isRecording {
                Label("Recording…", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
            } else if let url = brief.videoURL {
                Button {
                    NSWorkspace.shared.open(url)
                    Task { await state.startRecording() }
                } label: {
                    Label("Join & Record", systemImage: "video.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .help("Opens the call link and starts recording in one go")
                Button("Just Record") {
                    Task { await state.startRecording() }
                }
                .controlSize(.large)
            } else {
                Button {
                    Task { await state.startRecording() }
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func attendeeRow(_ attendee: PrepBrief.Attendee) -> some View {
        HStack(spacing: 8) {
            PersonAvatar(name: attendee.name, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(attendee.name)
                if let notes = attendee.notesPreview {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if attendee.openCommitments > 0 {
                Text("\(attendee.openCommitments) open")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
                    .help("Open commitments — see the Commitments tab")
            }
            if attendee.knownName != nil {
                Button {
                    HubController.shared.open(.people)
                } label: {
                    Image(systemName: "person.text.rectangle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open their page")
            } else if let email = attendee.email {
                // An attendee the app could not place, and the one control that
                // fixes it permanently. Without this the brief is a list of
                // names: everything below it — the last meeting, both promise
                // lists — appears only for people who were recognised, so an
                // unrecognised row is the reason the rest of the tab is empty.
                Menu {
                    ForEach(watcher.linkableNames, id: \.self) { name in
                        Button(name) { watcher.link(email: email, to: name) }
                    }
                } label: {
                    Label("Who is this?", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Link this address to a colleague. Every later invitation from "
                    + "\(email) is then recognised without guessing at names.")
            }
        }
        .padding(.vertical, 2)
    }

    private func title(for bucket: CommitmentScope.Bucket) -> String {
        switch bucket {
        case .overdue: return "Overdue"
        case .thisMeeting: return "From this meeting before"
        case .personal: return "One to one"
        case .general: return "With these people, elsewhere"
        case .hidden: return ""
        }
    }

    private func symbol(for bucket: CommitmentScope.Bucket) -> String {
        switch bucket {
        case .overdue: return "exclamationmark.triangle"
        case .thisMeeting: return "arrow.triangle.2.circlepath"
        case .personal: return "person.fill.checkmark"
        case .general: return "person.2"
        case .hidden: return "eye.slash"
        }
    }

    private func tint(for bucket: CommitmentScope.Bucket) -> Color {
        switch bucket {
        case .overdue: return .red
        case .thisMeeting: return .blue
        case .personal: return .orange
        case .general: return .purple
        case .hidden: return .gray
        }
    }

    /// Says what a group is, once, under it — so the grouping does not have to
    /// be guessed from four headings.
    private func footnote(for bucket: CommitmentScope.Bucket) -> String? {
        switch bucket {
        case .overdue: return "Past its date, whichever meeting it came from."
        case .thisMeeting: return "Promised in an earlier meeting with exactly these people."
        case .personal: return "From a one-to-one with somebody on this call."
        case .general: return "Involves somebody on this call, from another meeting."
        case .hidden: return nil
        }
    }

    private func commitmentsBox(title: String, systemImage: String, tint: Color,
                                items: [Commitment], showOwner: Bool = false,
                                footnote: String? = nil, limit: Int? = nil) -> some View {
        // Capped, because grouping alone does not solve the problem it was
        // asked to solve. On a real store the overdue group came back with
        // fifteen rows and pushed every other group off the screen — which is
        // the same wall of text as before, just sorted. The full list is one
        // click away in Commitments; this is a brief.
        let shown = limit.map { Array(items.prefix($0)) } ?? items
        let hidden = items.count - shown.count
        return HubCard(icon: systemImage, title: title, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                if let footnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(shown) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button {
                            withAnimation(.snappy) { CommitmentStore.shared.toggleDone(item.id) }
                        } label: {
                            Image(systemName: "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Mark as done")
                        Text(showOwner ? "\(item.owner): \(item.text)" : item.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(item.date.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if hidden > 0 {
                    Button("\(hidden) more — open Commitments") {
                        HubController.shared.open(.commitments)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
