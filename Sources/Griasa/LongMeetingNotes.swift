import Foundation

/// Meeting notes for a meeting too long for one request to a local model:
/// each 20,000-character part of the transcript is summarised on its own (a
/// JSON reply, constrained to a schema), the parts' notes are merged in one
/// more request, and the `## Transcript` section is built in code. See
/// docs in `TranscriptChunker`, `LongMeetingMap` and `TranscriptAssembler`.
enum LongMeetingNotes {
    struct Output {
        var markdown: String
        var chunks: Int
        /// Promises the model reported whose quote is not in the transcript.
        var droppedActions: Int
        /// Every promise reported by the parts, verified and attributed in code.
        var actions: [LongMeetingMap.MapAction] = []
        /// What each part reported, as the merge step read it (for the probe).
        var partNotes: [String] = []
    }

    private struct MapDraft { let text: String; let owner: String; let quote: String? }

    /// Where the promises of a long meeting are saved beside its notes.
    static func actionsFile(besideNotes notes: URL) -> URL {
        notes.deletingLastPathComponent().appendingPathComponent("map-actions.json")
    }

    static func make(raw: String, participants: [String], myName: String, hasNotes: Bool,
                     allowCloudFallback: Bool = true, requireLocal: Bool = false,
                     config: LLMConfig? = nil, meetingDate: Date = Date(),
                     timeout: TimeInterval = 300) async throws -> Output {
        let limit = (config ?? LLMConfig.current()).contextCharLimit
        let chunks = TranscriptChunker.chunks(raw, maxChars: TranscriptChunker.chunkSize(contextCharLimit: limit))
        let system = Prompts.text(.longMeetingSystem)
        let language = Prompts.languageLine(MeetingLanguage.name(of: raw))
        let today = meetingDate.formatted(.iso8601.year().month().day())
        let ownerIndex: [Int: PromiseOwner.Index] = Dictionary(uniqueKeysWithValues: chunks.map {
            ($0.index, PromiseOwner.Index(text: $0.modelInput, myName: myName)) })
        var actions: [LongMeetingMap.MapAction] = []
        var seen: [PromiseDuplicate.Seen] = []
        let speakerRules = speakerRules(participants: participants, myName: myName)
        let noteRules = hasNotes
            ? " Lines in the form \"[mm:ss] 📝 NOTE: …\" are notes the user typed by hand during the meeting — their own words, not recognized speech, so they are highly reliable; reflect their content prominently."
            : ""

        var known: [(name: String, clue: String)] = []
        var sections: [String] = []
        var dropped = 0
        for chunk in chunks {
            let instructions = Prompts.text(.meetingChunk).filling([
                "part": "\(chunk.index + 1)", "parts": "\(chunks.count)",
                "range": chunk.rangeLabel.isEmpty ? "" : " (\(chunk.rangeLabel))",
                "speakerRules": speakerRules, "noteRules": noteRules,
                "known": LongMeetingMap.knownText(known), "today": today,
            ]) + language
            // Part first, instructions last: the engine keeps what it has read
            // of the part and only reads the instructions again.
            let user = chunk.modelInput + "\n\n" + instructions
            var result: LongMeetingMap.Result?
            for _ in 0..<2 where result == nil {
                let reply = try await AIFormatter.complete(
                    system: system, user: user, tier: .smart, maxTokens: 4096, timeout: timeout,
                    allowCloudFallback: false, requireLocal: requireLocal,
                    config: config, jsonSchema: LongMeetingMap.schema)
                result = LongMeetingMap.decode(reply)
            }
            guard let result else {
                throw NSError(domain: "Griasa", code: 12, userInfo: [NSLocalizedDescriptionKey:
                    "The local model's notes for part \(chunk.index + 1) of \(chunks.count) could not be read."])
            }
            let (checked, count) = LongMeetingMap.believed(result, chunk: chunk)
            var believed = checked
            // Whose each promise is comes from who spoke the quoted line, not from the model.
            let index = ownerIndex[chunk.index]!
            var attributed: [LongMeetingMap.Action] = []
            for action in believed.actions ?? [] {
                let who = index.resolve(quote: action.quote, modelOwner: action.owner, participants: participants)
                var tagged = action
                tagged.owner = who.owner
                let task = (action.task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let entry = MapDraft(text: task, owner: who.owner, quote: action.quote)
                if let earlier = PromiseDuplicate.duplicate(text: task, owner: who.owner, quote: action.quote, of: seen) {
                    // The copy on the user's own line wins; a recap that names
                    // whose it is names the earlier copy too.
                    if who.isMine, who.located, !actions[earlier].isMine {
                        actions[earlier].isMine = true
                        actions[earlier].owner = who.owner
                    } else if PromiseDuplicate.isUnnamed(actions[earlier].owner), !PromiseDuplicate.isUnnamed(who.owner) {
                        actions[earlier].owner = who.owner
                        seen[earlier] = PromiseDuplicate.entry(text: actions[earlier].text, owner: who.owner,
                                                               quote: actions[earlier].quote)
                    }
                    continue
                }
                seen.append(PromiseDuplicate.entry(text: entry.text, owner: entry.owner, quote: entry.quote))
                attributed.append(tagged)
                actions.append(.init(
                    text: task, owner: who.owner, isMine: who.isMine,
                    dueDate: (action.date ?? "").range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? action.date : nil,
                    dueHint: (action.due ?? "").isEmpty ? nil : action.due,
                    quote: (action.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    at: who.at))
            }
            believed.actions = attributed
            dropped += count
            LongMeetingMap.merge(believed.speakers, into: &known)
            sections.append(LongMeetingMap.render(believed, part: chunk.index + 1, parts: chunks.count,
                                                  range: chunk.rangeLabel))
        }

        // All the parts' notes in one request when they fit; otherwise merged in
        // groups first, and the groups' notes merged again.
        let reduce = Prompts.text(.meetingReduce).filling(["speakerRules": speakerRules]) + language
        func merge(_ parts: [String]) async throws -> String {
            let reply = try await AIFormatter.complete(
                system: system, user: parts.joined(separator: "\n\n") + "\n\n" + reduce,
                tier: .smart, maxTokens: 6000, timeout: timeout,
                allowCloudFallback: false, requireLocal: requireLocal, config: config)
            return LongMeetingMap.withoutTranscript(reply)
        }
        let budget = max(limit - 8_000, TranscriptChunker.chunkSize(contextCharLimit: limit))
        var level = sections
        var merged = ""
        while true {
            let groups = LongMeetingMap.group(level, budget: budget)
            if groups.count <= 1 {
                merged = try await merge(groups.first ?? level)
                break
            }
            var next: [String] = []
            for (index, group) in groups.enumerated() {
                next.append("### Group \(index + 1) of \(groups.count)\n" + (try await merge(group)))
            }
            level = next
        }
        let notes = LongMeetingMap.withoutTranscript(merged)
        let transcript = TranscriptAssembler.assemble(raw: raw, myName: myName)
        NSLog("Griasa: long meeting notes — %d parts, %d unquoted promises dropped", chunks.count, dropped)
        return Output(markdown: notes + "\n\n## Transcript\n\n" + transcript + "\n",
                      chunks: chunks.count, droppedActions: dropped, actions: actions, partNotes: sections)
    }

    private static func speakerRules(participants: [String], myName: String) -> String {
        var rules = "\"You\" is the user's microphone; \"Them\" is everything the computer played (all remote participants, mixed into one track)."
        if !participants.isEmpty {
            let mine = myName.isEmpty ? "the user" : myName
            rules += " Participants on this call: \(participants.joined(separator: ", ")). \"You\" is \(mine). Name the owner of each promise from this list; tell the \"Them\" speakers apart by what they say — introductions, people addressing each other by name. Never invent names beyond the list."
        }
        return rules
    }
}
