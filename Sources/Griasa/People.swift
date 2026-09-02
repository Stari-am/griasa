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

// `Person` itself lives in PersonIdentity.swift, which imports nothing but
// Foundation so the model and the matching rules are reachable from test.sh.

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

    /// Everyone who can be matched against, with whatever addresses are known.
    /// Roster names with no stored record still appear, so a calendar attendee
    /// resolves to them by name even before anything has been typed about them.
    var candidates: [PersonIdentity.Candidate] {
        allNames.map { name in
            PersonIdentity.Candidate(name: name, emails: person(named: name)?.emails ?? [])
        }
    }

    /// Records an address discovered elsewhere — a calendar attendee, later a
    /// tracker row. Appends; never replaces. An address the user typed by hand is
    /// the one they meant, and a discovered one must not quietly displace it.
    func addEmail(_ email: String, for name: String) {
        let wanted = PersonIdentity.normalize(email: email)
        guard !wanted.isEmpty else { return }
        if let existing = person(named: name),
           existing.emails.contains(where: { PersonIdentity.normalize(email: $0) == wanted }) {
            return
        }
        upsert(name: name) { $0.emails.append(wanted) }
    }

    func removeEmail(_ email: String, for name: String) {
        let wanted = PersonIdentity.normalize(email: email)
        upsert(name: name) {
            $0.emails.removeAll { PersonIdentity.normalize(email: $0) == wanted }
        }
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

    // MARK: - Merging and removing

    enum MergeResult {
        case merged(meetings: Int, commitments: Int)
        /// The name to merge into is not one this app knows.
        case unknownTarget
        case samePerson
    }

    /// Folds one person into another: the duplicate's meetings, promises,
    /// addresses and notes move across, and the duplicate stops existing.
    ///
    /// This is the operation `rename` refuses to guess at, and it exists because
    /// two entries for one human is an ordinary accident here — the names are
    /// typed in a hurry the moment a call ends, so a second spelling makes a
    /// second person. Before this, the only way out was to delete one entry and
    /// lose its half of the history with it.
    func merge(_ name: String, into target: String) -> MergeResult {
        guard let canonical = allNames.first(where: {
            $0.caseInsensitiveCompare(target) == .orderedSame
        }) else { return .unknownTarget }
        guard name.caseInsensitiveCompare(canonical) != .orderedSame else { return .samePerson }

        // The records are combined first, while both still exist. `absorbing`
        // decides what survives; the rules are in PersonIdentity, where they are
        // checked, because this step is the destructive one.
        if let source = person(named: name) {
            let survivor = (person(named: canonical) ?? Person(name: canonical)).absorbing(source)
            people.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let index = people.firstIndex(where: {
                $0.name.caseInsensitiveCompare(canonical) == .orderedSame
            }) {
                people[index] = survivor
            } else {
                people.append(survivor)
            }
            save()
        }

        // Then everything joined only by the name string. Same three stores as
        // `rename`, and for the same reason: miss one and the surviving page
        // loses the meetings or the promises that came with the duplicate.
        let meetings = HistoryStore.shared.renameParticipant(name, to: canonical)
        let commitments = CommitmentStore.shared.renameOwner(name, to: canonical)
        ParticipantRoster.shared.rename(name, to: canonical)
        return .merged(meetings: meetings, commitments: commitments)
    }

    /// What a deletion would leave behind, so the dialog can say it out loud
    /// rather than let the user find out afterwards.
    func footprint(of name: String) -> (meetings: Int, commitments: Int) {
        let owned = CommitmentStore.shared.commitments.filter {
            $0.owner.caseInsensitiveCompare(name) == .orderedSame
        }
        return (meetings(with: name).count, owned.count)
    }

    /// Removes the page and the roster entry, and nothing else.
    ///
    /// Deliberately does not touch the meetings or the promises. Who was in a
    /// meeting is a fact about that meeting, and a promise whose owner has been
    /// erased is worse than a promise owned by somebody without a page — it
    /// stops being anybody's. Moving those is what `merge` is for, which is why
    /// the dialog offers it first.
    func delete(_ name: String) {
        people.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        ParticipantRoster.shared.remove(name)
        save()
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
