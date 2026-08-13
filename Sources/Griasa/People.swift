import SwiftUI
import AppKit

/// Initials in a colored circle. The color is a stable hash of the name, so a
/// person keeps their color across launches (Swift's Hashable is seeded per
/// run — don't use it here).
struct PersonAvatar: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            Text(initials)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    private var color: Color {
        var hash: UInt64 = 5381
        for scalar in name.unicodeScalars { hash = hash &* 33 &+ UInt64(scalar.value) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}

/// Everything Griasa knows about a colleague beyond the meeting transcripts:
/// the user's own notes and an AI-written dossier.
struct Person: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var notes: String = ""
    var dossier: String?
    var dossierDate: Date?
}

@MainActor
final class PersonStore: ObservableObject {
    static let shared = PersonStore()

    @Published private(set) var people: [Person] = []
    /// Names currently generating a dossier, for inline spinners.
    @Published var generating: Set<String> = []

    private let fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Griasa/people.json")

    init() { load() }

    /// The People list = everyone from the meetings roster plus anyone with a
    /// stored page, so pages appear without any setup step.
    var allNames: [String] {
        var names = ParticipantRoster.shared.names
        for person in people where !names.contains(where: { $0.caseInsensitiveCompare(person.name) == .orderedSame }) {
            names.append(person.name)
        }
        return names
    }

    func person(named name: String) -> Person? {
        people.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Records are created lazily on first edit — browsing pages stores nothing.
    private func upsert(name: String, mutate: (inout Person) -> Void) {
        if let index = people.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            mutate(&people[index])
        } else {
            var person = Person(name: name)
            mutate(&person)
            people.append(person)
        }
        save()
    }

    func setNotes(_ notes: String, for name: String) {
        upsert(name: name) { $0.notes = notes }
    }

    func setDossier(_ dossier: String, for name: String) {
        upsert(name: name) {
            $0.dossier = dossier
            $0.dossierDate = Date()
        }
    }

    /// Why a person can be renamed at all: the names come from a question asked
    /// the moment a recording stops, typed in a hurry, sometimes from what a
    /// recognizer heard. Typos are certain, and until now there was no way to
    /// fix one — the misspelling stayed in the roster and was offered again
    /// after the next call.
    enum RenameResult {
        case renamed(meetings: Int, commitments: Int)
        case unchanged
        /// The target name already belongs to someone else. Merging two people
        /// means deciding what happens to two sets of notes and two dossiers,
        /// which is a different operation — so this refuses instead of guessing.
        case nameTaken
        case emptyName
    }

    /// Renames a person everywhere at once. It has to be everywhere: the four
    /// stores are joined only by the name string, so renaming in one of them
    /// silently detaches the rest — the page loses its meetings, the open-promise
    /// count drops to zero, and the old spelling still comes back next time the
    /// roster is offered.
    func rename(_ oldName: String, to proposed: String) -> RenameResult {
        let newName = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return .emptyName }
        guard newName != oldName else { return .unchanged }

        // A change of case or spacing on the same person is a rename, not a
        // collision with themselves.
        let sameNameDifferently = newName.caseInsensitiveCompare(oldName) == .orderedSame
        if !sameNameDifferently {
            let taken = allNames.contains { $0.caseInsensitiveCompare(newName) == .orderedSame }
            if taken { return .nameTaken }
        }

        if let index = people.firstIndex(where: {
            $0.name.caseInsensitiveCompare(oldName) == .orderedSame
        }) {
            people[index].name = newName
            save()
        }
        let meetings = HistoryStore.shared.renameParticipant(oldName, to: newName)
        let commitments = CommitmentStore.shared.renameOwner(oldName, to: newName)
        ParticipantRoster.shared.rename(oldName, to: newName)

        return .renamed(meetings: meetings, commitments: commitments)
    }

    // MARK: - Derived from history

    /// Meetings this person took part in — tagged entries first, plus a text
    /// match fallback for meetings recorded before participants were stored.
    func meetings(with name: String) -> [HistoryEntry] {
        HistoryStore.shared.entries.filter { entry in
            guard entry.kind == .meeting else { return false }
            if let participants = entry.participants {
                return participants.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            return entry.text.localizedCaseInsensitiveContains(name)
        }
    }

    func lastMet(_ name: String) -> Date? {
        meetings(with: name).map(\.date).max()
    }

    /// Writes an AI dossier from every transcript the person appears in.
    func generateDossier(for name: String) {
        guard !generating.contains(name) else { return }
        let sources = meetings(with: name)
        guard !sources.isEmpty, AIFormatter.isConfigured else { return }
        generating.insert(name)

        Task { @MainActor in
            defer { generating.remove(name) }
            var corpus = ""
            for entry in sources {  // newest first, as stored
                corpus += "\n\n--- Meeting «\(entry.title)», \(entry.date.formatted(date: .abbreviated, time: .omitted)) ---\n"
                corpus += entry.text
                if corpus.count > 100_000 { break }
            }
            if corpus.count > 100_000 { corpus = String(corpus.prefix(100_000)) }

            let system = Prompts.text(.personDossier).filling(["name": name])
            if let dossier = try? await AIFormatter.complete(
                system: system, user: corpus, tier: .smart, maxTokens: 2048, timeout: 120) {
                setDossier(dossier.trimmingCharacters(in: .whitespacesAndNewlines), for: name)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Person].self, from: data) else { return }
        people = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(people)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Griasa: failed to save people: %@", error.localizedDescription)
        }
    }
}
