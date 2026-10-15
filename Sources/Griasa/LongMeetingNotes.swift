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
    }

    static func make(raw: String, participants: [String], myName: String, hasNotes: Bool,
                     allowCloudFallback: Bool = true, requireLocal: Bool = false,
                     config: LLMConfig? = nil) async throws -> Output {
        let chunks = TranscriptChunker.chunks(raw)
        let system = Prompts.text(.longMeetingSystem)
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
                "known": LongMeetingMap.knownText(known),
            ])
            // Part first, instructions last: the engine keeps what it has read
            // of the part and only reads the instructions again.
            let user = chunk.modelInput + "\n\n" + instructions
            var result: LongMeetingMap.Result?
            for _ in 0..<2 where result == nil {
                let reply = try await AIFormatter.complete(
                    system: system, user: user, tier: .smart, maxTokens: 4096, timeout: 300,
                    allowCloudFallback: allowCloudFallback, requireLocal: requireLocal,
                    config: config, jsonSchema: LongMeetingMap.schema)
                result = LongMeetingMap.decode(reply)
            }
            guard let result else {
                throw NSError(domain: "Griasa", code: 12, userInfo: [NSLocalizedDescriptionKey:
                    "The local model's notes for part \(chunk.index + 1) of \(chunks.count) could not be read."])
            }
            let (believed, count) = LongMeetingMap.believed(result, chunkBody: chunk.body)
            dropped += count
            LongMeetingMap.merge(believed.speakers, into: &known)
            sections.append(LongMeetingMap.render(believed, part: chunk.index + 1, parts: chunks.count,
                                                  range: chunk.rangeLabel))
        }

        let reduce = Prompts.text(.meetingReduce).filling(["speakerRules": speakerRules])
        let merged = try await AIFormatter.complete(
            system: system, user: sections.joined(separator: "\n\n") + "\n\n" + reduce,
            tier: .smart, maxTokens: 6000, timeout: 300,
            allowCloudFallback: allowCloudFallback, requireLocal: requireLocal, config: config)
        let notes = LongMeetingMap.withoutTranscript(merged)
        let transcript = TranscriptAssembler.assemble(raw: raw, myName: myName)
        NSLog("Griasa: long meeting notes — %d parts, %d unquoted promises dropped", chunks.count, dropped)
        return Output(markdown: notes + "\n\n## Transcript\n\n" + transcript + "\n",
                      chunks: chunks.count, droppedActions: dropped)
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
