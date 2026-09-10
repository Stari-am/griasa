import SwiftUI

// `Commitment` itself lives in CommitmentModel.swift, which imports nothing
// but Foundation, so its decoder is reachable from test.sh — the file it reads
// is the one whose loss would take every promise with it.

/// Persistent list of commitments, extracted from meetings or added by hand.
@MainActor
final class CommitmentStore: ObservableObject {
    static let shared = CommitmentStore()

    @Published private(set) var commitments: [Commitment] = []

    private let fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Griasa/commitments.json")

    init() { load() }

    var openMine: [Commitment] { commitments.filter { !$0.done && $0.isMine } }
    var openTheirs: [Commitment] { commitments.filter { !$0.done && !$0.isMine } }
    var finished: [Commitment] {
        commitments.filter(\.done).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }
    var openCount: Int { commitments.filter { !$0.done }.count }

    func open(for owner: String) -> [Commitment] {
        commitments.filter { !$0.done && $0.owner.caseInsensitiveCompare(owner) == .orderedSame }
    }

    /// Returns true if the commitment was added — false when a still-open one
    /// with the same text is already on the list (so callers can report how
    /// many are genuinely new).
    @discardableResult
    func add(_ commitment: Commitment) -> Bool {
        // The same promise often shows up again when a topic is revisited in
        // the next meeting — don't duplicate what's already on the list.
        let normalized = Self.normalize(commitment.text)
        guard !commitments.contains(where: { !$0.done && Self.normalize($0.text) == normalized }) else { return false }
        commitments.insert(commitment, at: 0)
        save()
        return true
    }

    /// Promises a later conversation appears to have closed, newest first.
    var suggestedDone: [Commitment] {
        commitments.filter(\.hasClosureSuggestion)
            .sorted { ($0.suggestedDoneAt ?? .distantPast) > ($1.suggestedDoneAt ?? .distantPast) }
    }

    /// Records that a conversation says this promise is finished, with the
    /// sentence that says so. Does not close it: see `acceptSuggestion`.
    func suggestClosure(_ id: UUID, quote: String) {
        guard let index = commitments.firstIndex(where: { $0.id == id }),
              !commitments[index].done else { return }
        commitments[index].suggestedDoneQuote = quote
        commitments[index].suggestedDoneAt = Date()
        save()
    }

    func acceptSuggestion(_ id: UUID) {
        guard let index = commitments.firstIndex(where: { $0.id == id }) else { return }
        commitments[index].done = true
        commitments[index].doneAt = Date()
        // The quote stays: it is the record of why this was closed, and the only
        // way to tell a decision from a mistake a month later.
        save()
    }

    /// The user disagrees. The suggestion is cleared rather than remembered as
    /// rejected — the next meeting is allowed to make the case again, and
    /// keeping a "do not ask" flag would need a reason this doesn't have.
    func dismissSuggestion(_ id: UUID) {
        guard let index = commitments.firstIndex(where: { $0.id == id }) else { return }
        commitments[index].suggestedDoneQuote = nil
        commitments[index].suggestedDoneAt = nil
        save()
    }

    func toggleDone(_ id: UUID) {
        guard let index = commitments.firstIndex(where: { $0.id == id }) else { return }
        commitments[index].done.toggle()
        commitments[index].doneAt = commitments[index].done ? Date() : nil
        save()
    }

    func delete(_ id: UUID) {
        commitments.removeAll { $0.id == id }
        save()
    }

    /// Part of the rename in `PersonStore.rename`. Only `owner` moves —
    /// `sourceTitle` is the name of the meeting the promise came from, not a
    /// person, and rewriting the promise text would edit what someone said.
    /// Returns how many promises were reassigned.
    @discardableResult
    func renameOwner(_ oldName: String, to newName: String) -> Int {
        var touched = 0
        for index in commitments.indices
        where commitments[index].owner.caseInsensitiveCompare(oldName) == .orderedSame {
            commitments[index].owner = newName
            touched += 1
        }
        if touched > 0 { save() }
        return touched
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Commitment].self, from: data) else { return }
        commitments = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(commitments)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Griasa: failed to save commitments: %@", error.localizedDescription)
        }
    }
}

/// Turns commitments into paste-ready text for other tools.
enum CommitmentExport {
    /// `- [ ] text — «meeting», date (due …)` — for Notion, Obsidian,
    /// GitHub issues, anywhere Markdown checklists render.
    static func markdownChecklist(_ items: [Commitment]) -> String {
        items.map { item in
            var line = "- [ ] "
            if !item.isMine { line += "\(item.owner): " }
            line += item.text
            var reference: [String] = []
            if !item.sourceTitle.isEmpty { reference.append("«\(item.sourceTitle)»") }
            reference.append(item.date.formatted(date: .abbreviated, time: .omitted))
            line += " — " + reference.joined(separator: ", ")
            if let due = dueText(item) { line += " (\(due))" }
            return line
        }.joined(separator: "\n")
    }

    /// One clean task per line — task trackers (Todoist, Things, Linear)
    /// create one item per line on multi-line paste, and their quick-add
    /// parsers pick up the trailing due date.
    static func taskLines(_ items: [Commitment]) -> String {
        items.map { item in
            var line = ""
            if !item.isMine { line += "\(item.owner): " }
            line += item.text
            if let due = dueText(item) { line += " (\(due))" }
            return line
        }.joined(separator: "\n")
    }

    private static func dueText(_ item: Commitment) -> String? {
        if let due = item.dueDate {
            return "due \(due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
        }
        if let hint = item.dueHint, !hint.isEmpty { return hint }
        return nil
    }
}

/// Pulls concrete promises out of finished meeting notes. Runs quietly at the
/// end of the meeting pipeline — a failure just means no new items appear.
enum CommitmentExtractor {
    private struct ExtractedItem: Decodable {
        let text: String
        let owner: String?
        let mine: Bool?
        let due: String?
        let dueHint: String?
    }

    /// Extracts commitments and adds the genuinely new ones to the store,
    /// returning how many were added. Throws on a provider error so callers on
    /// the typing/UI path can report it (the account alert fires via
    /// AIFormatter); the background auto-extract calls this with `try?`.
    @discardableResult
    static func extract(markdown: String, participants: [String], myName: String,
                        sourceTitle: String, sourceEntryID: UUID?) async throws -> Int {
        guard AIFormatter.isConfigured else {
            throw NSError(domain: "Griasa", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "No AI provider configured (Settings → AI & Actions)."
            ])
        }

        let mine = myName.isEmpty ? "You" : myName
        let today = Date().formatted(.iso8601.year().month().day())
        let people = participants.isEmpty ? mine : participants.joined(separator: ", ")

        let system = Prompts.text(.commitments)
            .filling(["today": today, "me": mine, "participants": people])

        var notes = markdown
        if notes.count > 60_000 { notes = String(notes.prefix(60_000)) }

        let reply = try await AIFormatter.complete(
            system: system, user: notes, tier: .fast, maxTokens: 2048,
            timeout: 60, allowCloudFallback: false)

        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"),
              start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let items = try? JSONDecoder().decode([ExtractedItem].self, from: data) else { return 0 }

        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withFullDate]
        let parsed: [Commitment] = items.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Commitment(
                text: text,
                owner: item.owner?.isEmpty == false ? item.owner! : mine,
                isMine: item.mine ?? true,
                dueHint: item.dueHint,
                dueDate: item.due.flatMap { dateParser.date(from: $0) },
                sourceTitle: sourceTitle,
                sourceEntryID: sourceEntryID)
        }
        guard !parsed.isEmpty else { return 0 }

        return await MainActor.run {
            withAnimation(.snappy) {
                parsed.reduce(0) { CommitmentStore.shared.add($1) ? $0 + 1 : $0 }
            }
        }
    }

    private struct ClosedItem: Decodable {
        let n: Int
        let quote: String
    }

    /// Asks which of the currently open promises this meeting says are finished,
    /// and records each answer as a suggestion with the sentence that supports it.
    ///
    /// Returns how many were flagged. Runs after extraction, off the path that
    /// produces the transcript, so a failure here costs nothing that was needed.
    ///
    /// The model is asked to answer with the *number* of a commitment rather
    /// than its id: a UUID echoed back through a language model is a UUID that
    /// comes back subtly wrong, and a wrong id here would attach one promise's
    /// evidence to another.
    @discardableResult
    static func detectClosures(markdown: String) async -> Int {
        guard AIFormatter.isConfigured else { return 0 }
        let open = await MainActor.run { CommitmentStore.shared.commitments.filter { !$0.done } }
        guard !open.isEmpty else { return 0 }

        // Newest first, capped: the list goes in the prompt, and a store with
        // hundreds of open promises would crowd out the notes being read.
        let candidates = Array(open.sorted { $0.date > $1.date }.prefix(60))
        let numbered = candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element.owner): \($0.element.text)" }
            .joined(separator: "\n")

        var notes = markdown
        if notes.count > 60_000 { notes = String(notes.prefix(60_000)) }

        let system = Prompts.text(.commitmentsDone).filling(["items": numbered])
        guard let reply = try? await AIFormatter.complete(
            system: system, user: notes, tier: .smart, maxTokens: 1024,
            timeout: 90, allowCloudFallback: false) else { return 0 }

        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"),
              start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let closed = try? JSONDecoder().decode([ClosedItem].self, from: data) else {
            return 0
        }

        let lowerNotes = notes.lowercased()
        var flagged = 0
        for item in closed {
            guard item.n >= 1, item.n <= candidates.count else { continue }
            let quote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            // The quote has to be in the notes. Without this the evidence can be
            // a plausible sentence the model wrote itself, which is the one
            // thing that would make a suggestion impossible to judge.
            guard quote.count >= 8, lowerNotes.contains(quote.lowercased()) else { continue }
            let id = candidates[item.n - 1].id
            await MainActor.run { CommitmentStore.shared.suggestClosure(id, quote: quote) }
            flagged += 1
        }
        return flagged
    }
}
