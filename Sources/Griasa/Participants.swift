import SwiftUI
import AppKit

/// Remembered participant names, so recurring colleagues are one click away.
@MainActor
final class ParticipantRoster: ObservableObject {
    static let shared = ParticipantRoster()

    @Published var names: [String] = [] { didSet { save() } }
    /// The user's own display name — used to label the "You" (mic) track.
    @Published var myName: String {
        didSet { UserDefaults.standard.set(myName, forKey: "myDisplayName") }
    }

    private static let key = "participantRoster"

    init() {
        myName = UserDefaults.standard.string(forKey: "myDisplayName") ?? ""
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            names = decoded
        }
    }

    func remember(_ newNames: [String]) {
        for name in newNames where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
    }

    func remove(_ name: String) { names.removeAll { $0 == name } }

    /// Part of the rename in `PersonStore.rename`; not meant to be called alone,
    /// or the roster disagrees with the history it came from. Deduplicates,
    /// because the new spelling may already be in the list.
    func rename(_ oldName: String, to newName: String) {
        var seen = Set<String>()
        names = names
            .map { $0.caseInsensitiveCompare(oldName) == .orderedSame ? newName : $0 }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// After a recording, asks which known people were on the call (plus any new
/// names). The chosen names are handed to Claude so it can attribute the
/// "Them" track to real speakers using conversational cues (self-intros,
/// people addressing each other by name) — content-based attribution, since
/// the two tracks are mic vs. everything-else, not per-speaker audio.
/// Runs the question as a hub tab. The completion always fires — Skip,
/// closing the tab, or closing the hub window all count as "no names" — so
/// the meeting pipeline never stalls waiting for an answer.
@MainActor
final class ParticipantsPrompt {
    static let shared = ParticipantsPrompt()
    private var completion: (([String]) -> Void)?

    func ask(completion: @escaping ([String]) -> Void) {
        self.completion = completion
        HubController.shared.open(.participants)
    }

    func finish(_ names: [String]) {
        HubController.shared.close(.participants)
        let done = completion
        completion = nil
        done?(names)
    }

    func skip() { finish([]) }
}

struct WhoIsWhoView: View {
    @ObservedObject var roster: ParticipantRoster
    let onDone: ([String]) -> Void

    @State private var selected: Set<String> = []
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select who took part — Claude will label the transcript with their names instead of “Them”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Your name (for the mic track)", text: $roster.myName)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            if roster.names.isEmpty {
                Text("No saved people yet — add the participants below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(roster.names, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { selected.contains(name) },
                                set: { on in
                                    if on { selected.insert(name) } else { selected.remove(name) }
                                }))
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            HStack {
                TextField("Add a name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addName)
                Button("Add", action: addName)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Spacer()
            Divider()
            HStack {
                Button("Skip") { onDone([]) }
                Spacer()
                Button("Transcribe") {
                    let mine = roster.myName.trimmingCharacters(in: .whitespaces)
                    var all = Array(selected)
                    if !mine.isEmpty { all.insert(mine, at: 0) }
                    onDone(all)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: 440, maxHeight: 460)
    }

    private func addName() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        roster.remember([trimmed])
        selected.insert(trimmed)
        newName = ""
    }
}
