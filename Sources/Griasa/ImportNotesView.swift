import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The "📥 Import Notes" hub tab: meeting notes made by another tool become a
/// Griasa meeting — promises, people, the brief, the project.
struct ImportNotesView: View {
    @State private var notes = ""
    @State private var title = ""
    /// The title the app last filled in; anything else in the field was typed.
    @State private var autoTitle = ""
    @State private var source = ""
    @State private var when = Date()
    @State private var status = ""
    @State private var dropTargeted = false

    private var cleaned: String { ImportedNotes.clean(notes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes from another tool — ChatGPT Record, a Zoom or Meet summary, or your own — become a meeting here: who promised what, a page for each person who was there, and the brief before your next call with them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("From").foregroundStyle(.secondary)
                    TextField("", text: $source, prompt: Text("ChatGPT Record, Zoom, Meet…"))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("When").foregroundStyle(.secondary)
                    DatePicker("", selection: $when, in: ...Date().addingTimeInterval(3600))
                        .labelsHidden()
                        .help("When the meeting happened. Deadlines like \"by Friday\" are worked out from this date, and the calendar is checked at this time for who was invited.")
                }
                GridRow {
                    Text("Title").foregroundStyle(.secondary)
                    TextField("", text: $title, prompt: Text("Taken from the notes"))
                        .textFieldStyle(.roundedBorder)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                                      lineWidth: dropTargeted ? 2 : 1))
                    .onChange(of: notes) { _, new in
                        // Follows the notes until somebody types their own.
                        guard title.isEmpty || title == autoTitle else { return }
                        autoTitle = ImportedNotes.title(from: new)
                        title = autoTitle
                    }
                if notes.isEmpty {
                    Text("Paste the notes here, or drop a .md or .txt file.")
                        .foregroundStyle(.tertiary)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 220)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in load(url) }
                }
                return true
            }

            HStack {
                Button("Open File…", action: openFile)
                Spacer()
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Button("Import…", action: startImport)
                    .buttonStyle(.borderedProminent)
                    .disabled(cleaned.isEmpty)
            }
        }
        .padding(16)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func load(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            status = "Couldn't read \(url.lastPathComponent) as text."
            return
        }
        notes = text
        if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified < when {
            when = modified  // a file's own date is a better guess than now
        }
        status = ""
    }

    private func startImport() {
        let body = cleaned + ImportedNotes.provenance(source: source)
        let finalTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? ImportedNotes.title(from: cleaned) : title
        let date = when
        status = "Who was there?"
        // The same question a recording asks, with the calendar consulted for
        // the hour the meeting happened.
        ParticipantsPrompt.shared.ask(recording: date...date.addingTimeInterval(3600)) { names in
            MeetingImport.file(body: body, title: finalTitle, date: date, participants: names)
            notes = ""; title = ""; autoTitle = ""; source = ""; status = ""
            HubController.shared.close(.importNotes)
            HubController.shared.open(.history)
        }
    }
}

/// What happens to an imported meeting once its participants are known — the
/// same steps a finished recording goes through.
@MainActor
enum MeetingImport {
    static func file(body: String, title: String, date: Date, participants names: [String]) {
        let newestOther = HistoryStore.shared.entries.filter { $0.kind == .meeting }.map(\.date).max()
        guard let id = HistoryStore.shared.add(kind: .meeting, title: title, text: body,
                                               participants: names.isEmpty ? nil : names,
                                               date: date) else { return }
        let myName = ParticipantRoster.shared.myName
        Task {
            _ = try? await CommitmentExtractor.extract(
                markdown: body, participants: names, myName: myName,
                sourceTitle: title, sourceEntryID: id, meetingDate: date)
            if ImportedNotes.mayDetectClosures(meetingDate: date, newestOtherMeeting: newestOther) {
                await CommitmentExtractor.detectClosures(markdown: body, participants: names)
            }
        }
    }
}
