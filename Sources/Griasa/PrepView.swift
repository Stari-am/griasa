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

                if !brief.youPromised.isEmpty {
                    commitmentsBox(title: "You promised them", systemImage: "person.fill.checkmark",
                                   tint: .orange, items: brief.youPromised)
                }
                if !brief.theyPromised.isEmpty {
                    commitmentsBox(title: "They promised you", systemImage: "person.2",
                                   tint: .purple, items: brief.theyPromised, showOwner: true)
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

    private func commitmentsBox(title: String, systemImage: String, tint: Color,
                                items: [Commitment], showOwner: Bool = false) -> some View {
        HubCard(icon: systemImage, title: title, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
