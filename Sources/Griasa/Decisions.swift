import Foundation
import SwiftUI

/// The decisions taken in meetings, kept like promises: one JSON file in the
/// store, newest first.
@MainActor
final class DecisionStore: ObservableObject {
    static let shared = DecisionStore()

    @Published private(set) var decisions: [Decision] = []

    private let fileURL = StoreRoot.file("decisions.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Decision].self, from: data) {
            decisions = saved
        }
    }

    /// Decisions due to be looked at again today or earlier.
    var toRevisit: [Decision] { decisions.filter { $0.needsRevisit(on: Date()) } }

    func forEntry(_ id: UUID) -> [Decision] { decisions.filter { $0.sourceEntryID == id } }

    /// Adds a decision unless the same one is already kept for that meeting.
    @discardableResult
    func add(_ decision: Decision) -> Bool {
        guard !DecisionRules.isDuplicate(decision, of: decisions) else { return false }
        decisions.insert(decision, at: 0)
        save()
        return true
    }

    func setReversed(_ decision: Decision, _ reversed: Bool, note: String? = nil) {
        guard let i = decisions.firstIndex(where: { $0.id == decision.id }) else { return }
        decisions[i].reversed = reversed
        decisions[i].reversedNote = reversed ? note : nil
        save()
    }

    func setRevisit(_ decision: Decision, _ date: Date?) {
        guard let i = decisions.firstIndex(where: { $0.id == decision.id }) else { return }
        decisions[i].revisitDate = date
        save()
    }

    func update(_ decision: Decision, text: String, why: String?) {
        guard let i = decisions.firstIndex(where: { $0.id == decision.id }) else { return }
        decisions[i].text = text
        decisions[i].why = why
        save()
    }

    func delete(_ decision: Decision) {
        decisions.removeAll { $0.id == decision.id }
        save()
    }

    /// A meeting deleted from the history takes its decisions with it.
    func removeAll(forEntry id: UUID) {
        let before = decisions.count
        decisions.removeAll { $0.sourceEntryID == id }
        if decisions.count != before { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(decisions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Pulls the decisions out of a finished meeting. Runs after the promises, with
/// the same rule: a decision is kept only if the words the model says it was
/// taken in are in the text it was shown.
enum DecisionExtractor {
    private struct Item: Decodable {
        let type: String?
        let text: String
        let why: String?
        let by: String?
        let alternatives: [String]?
        let revisit: String?
        let reversed: Bool?
        let quote: String?
        let at: String?
    }

    /// The reply's shape, given to a local engine as a grammar so the answer is
    /// always a list that can be read; cloud providers ignore it.
    static let schema = """
    {"type":"array","items":{"type":"object","additionalProperties":false,
     "required":["type","text","why","by","alternatives","revisit","reversed","quote","at"],
     "properties":{
      "type":{"type":"string","enum":["decision","task"]},
      "text":{"type":"string"},
      "why":{"type":["string","null"]},
      "by":{"type":["string","null"]},
      "alternatives":{"type":"array","items":{"type":"string"}},
      "revisit":{"type":["string","null"]},
      "reversed":{"type":"boolean"},
      "quote":{"type":"string"},
      "at":{"type":["string","null"]}}}}
    """

    struct Found {
        var decisions: [Decision] = []
        var requests = 0
        var proposed = 0
        var unquoted = 0
        var unreadable = 0
        /// Items dropped as tasks: marked so by the model, or repeating a promise.
        var tasks = 0
    }

    /// Extracts and saves; returns how many were new. Never throws: a meeting
    /// whose decisions could not be read still has its notes and promises.
    @discardableResult
    static func extract(markdown: String, rawTranscript: String?, participants: [String], myName: String,
                        sourceTitle: String, sourceEntryID: UUID?, meetingDate: Date,
                        requireLocal: Bool, promises: [String] = []) async -> Int {
        guard let found = try? await findDecisions(
            markdown: markdown, rawTranscript: rawTranscript, promises: promises,
            participants: participants, myName: myName,
            sourceTitle: sourceTitle, sourceEntryID: sourceEntryID, meetingDate: meetingDate,
            requireLocal: requireLocal), !found.decisions.isEmpty else { return 0 }
        return await MainActor.run {
            found.decisions.reduce(0) { DecisionStore.shared.add($1) ? $0 + 1 : $0 }
        }
    }

    /// The extraction itself, without saving, for the benchmark.
    /// `promises`: the texts of promises found in the same meeting; a
    /// "decision" that repeats one is a task and is dropped.
    static func findDecisions(markdown: String, rawTranscript: String? = nil, promises: [String] = [],
                              timeout: TimeInterval? = nil,
                              participants: [String], myName: String,
                              sourceTitle: String, sourceEntryID: UUID?,
                              meetingDate: Date = Date(), requireLocal: Bool = false,
                              config: LLMConfig? = nil, inParts: Bool? = nil) async throws -> Found {
        let resolved = config ?? LLMConfig.current()
        guard resolved.isConfigured else {
            throw NSError(domain: "Griasa", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "No AI provider configured (Settings → AI & Actions)."
            ])
        }
        let mine = myName.isEmpty ? "You" : myName
        let today = meetingDate.formatted(.iso8601.year().month().day())
        let people = participants.isEmpty ? mine : participants.joined(separator: ", ")
        let language = Prompts.languageLine(MeetingLanguage.name(of: rawTranscript ?? markdown))
        var instructions = Prompts.text(.decisions) + Prompts.decisionQuoteRules + language

        var requests: [(system: String, user: String, shown: String, haystack: QuoteMatch.Haystack, timeout: TimeInterval)] = []
        let parts = inParts ?? (resolved.runsOnThisMac && markdown.count > resolved.contextCharLimit)
        if parts {
            instructions += Prompts.decisionPartRules
            instructions = instructions.filling(["today": today, "me": mine, "participants": people])
            let source = rawTranscript ?? TranscriptAssembler.transcriptSection(of: markdown)
            let size = TranscriptChunker.chunkSize(contextCharLimit: resolved.contextCharLimit)
            for chunk in TranscriptChunker.chunks(source, maxChars: size) {
                requests.append((Prompts.text(.longMeetingSystem), chunk.modelInput + "\n\n" + instructions,
                                 chunk.modelInput, QuoteMatch.Haystack(overlap: chunk.overlap, body: chunk.body),
                                 timeout ?? 120))
            }
        } else {
            instructions = instructions.filling(["today": today, "me": mine, "participants": people])
            // The notes when they hold the meeting; the transcript beside them
            // says it in the words used, which is what a quote must match.
            var text = rawTranscript ?? markdown
            if text.count > 60_000 { text = String(text.prefix(60_000)) }
            // A long meeting read whole takes a cloud model longer than a minute.
            requests.append((instructions, text, text, QuoteMatch.Haystack(body: text),
                             timeout ?? (text.count > 30_000 ? 180 : 60)))
        }

        var found = Found()
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withFullDate]
        for request in requests {
            let reply = try await AIFormatter.complete(
                system: request.system, user: request.user, tier: .fast, maxTokens: 4096,
                timeout: request.timeout, allowCloudFallback: false, allowApple: false,
                requireLocal: requireLocal, config: config, jsonSchema: schema)
            found.requests += 1
            guard let items = LongMeetingMap.arrayCandidates(reply).lazy
                .compactMap({ try? JSONDecoder().decode([Item].self, from: $0) }).first else {
                found.unreadable += 1
                continue
            }
            for item in items {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                found.proposed += 1
                // The model's own word that this is someone's task, not a choice.
                if let type = item.type?.lowercased(), type != "decision" {
                    found.tasks += 1
                    continue
                }
                // "Ivan will send the logs": a sentence about one person doing
                // something is their task, whatever the model called it.
                if DecisionRules.startsWithPerson(text, names: participants + [mine, "I", "Я"]) {
                    found.tasks += 1
                    continue
                }
                // A promise found in the same meeting, said again as a decision.
                if promises.contains(where: { BenchmarkScore.jaccard($0, text) >= 0.5 }) {
                    found.tasks += 1
                    continue
                }
                guard let quote = item.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty,
                      QuoteMatch.contains(request.haystack, quote: quote) else {
                    found.unquoted += 1
                    continue
                }
                let by = item.by?.trimmingCharacters(in: .whitespacesAndNewlines)
                let decision = Decision(
                    text: text,
                    why: item.why.flatMap { $0.isEmpty ? nil : $0 },
                    decidedBy: (by?.isEmpty ?? true) ? nil : by,
                    alternatives: (item.alternatives ?? []).filter { !$0.isEmpty },
                    quote: quote,
                    at: QuoteMatch.visibleTimestamp(item.at, in: request.shown),
                    sourceTitle: sourceTitle, sourceEntryID: sourceEntryID, date: meetingDate,
                    revisitDate: item.revisit.flatMap { dateParser.date(from: $0) },
                    reversed: item.reversed ?? false)
                guard !DecisionRules.isDuplicate(decision, of: found.decisions) else { continue }
                found.decisions.append(decision)
            }
        }
        return found
    }
}
