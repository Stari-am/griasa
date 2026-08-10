import Foundation

/// Post-recording pipeline: transcribe both tracks on-device, interleave them
/// by timestamp into a "You"/"Them" dialogue, then have the configured AI
/// provider turn that raw dialogue into a clean meeting transcript with a
/// summary and action items. Speech-to-text always happens locally; only the
/// resulting text is sent to the provider.
enum MeetingTranscriber {
    /// Returns the URL of the finished transcript markdown, or nil if there
    /// was nothing to transcribe.
    static func process(folder: URL, localeIdentifiers: [String], vocabulary: [String],
                        participants: [String] = [], myName: String = "",
                        notes: [LiveNote] = []) async -> URL? {
        let micURL = folder.appendingPathComponent("microphone.caf")
        let systemURL = folder.appendingPathComponent("system-audio.caf")

        let mic: [TranscriptSegment]
        let system: [TranscriptSegment]
        if WhisperTranscriber.isAvailable {
            // Whisper detects the language itself and is far more accurate than
            // the Apple recognizer. Run the tracks sequentially — each process
            // loads the full model into memory.
            mic = await WhisperTranscriber.transcribeSegments(audio: micURL, vocabulary: vocabulary)
            system = await WhisperTranscriber.transcribeSegments(audio: systemURL, vocabulary: vocabulary)
        } else {
            async let micTask = FileTranscriber.transcribeSegments(
                audio: micURL, localeIdentifiers: localeIdentifiers, vocabulary: vocabulary)
            async let systemTask = FileTranscriber.transcribeSegments(
                audio: systemURL, localeIdentifiers: localeIdentifiers, vocabulary: vocabulary)
            mic = await micTask
            system = await systemTask
        }
        guard !mic.isEmpty || !system.isEmpty else { return nil }

        // Interleave both tracks chronologically.
        let merged = (mic.map { (speaker: "You", segment: $0) } +
                      system.map { (speaker: "Them", segment: $0) })
            .sorted { $0.segment.start < $1.segment.start }

        // Weave the user's typed notes into the dialogue at their timecodes.
        let rawLines = (merged.map { entry in
            (time: entry.segment.start,
             line: "[\(timestamp(entry.segment.start))] \(entry.speaker): \(entry.segment.text)")
        } + notes.map { note in
            (time: note.time, line: "[\(timestamp(note.time))] 📝 NOTE: \(note.text)")
        })
        .sorted { $0.time < $1.time }
        .map(\.line)
        let raw = rawLines.joined(separator: "\n")
        try? raw.write(to: folder.appendingPathComponent("transcript-raw.txt"),
                       atomically: true, encoding: .utf8)

        let output = folder.appendingPathComponent("meeting-transcript.md")
        if AIFormatter.isConfigured {
            do {
                let formatted = try await aiFormat(raw: raw, participants: participants,
                                                   myName: myName, hasNotes: !notes.isEmpty)
                try formatted.write(to: output, atomically: true, encoding: .utf8)
                return output
            } catch {
                NSLog("Griasa: transcript formatting failed: %@", error.localizedDescription)
            }
        }

        // No provider (or the call failed): still deliver the raw merged transcript.
        let fallback = "# Meeting transcript (raw)\n\n_Configure an AI provider in Griasa Settings to get a cleaned-up transcript with summary and action items._\n\n```\n\(raw)\n```\n"
        try? fallback.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    /// Re-runs the AI summary for a meeting whose transcript is already on
    /// disk — used when the first attempt had no provider (or the call failed)
    /// and left only the raw fallback. Reads the saved raw dialogue next to the
    /// transcript file, rewrites the markdown in place, and returns it. Throws
    /// if the raw file is gone or the provider errors.
    static func reformat(transcriptFile: URL, participants: [String],
                         myName: String) async throws -> String {
        let rawURL = transcriptFile.deletingLastPathComponent()
            .appendingPathComponent("transcript-raw.txt")
        guard let raw = try? String(contentsOf: rawURL, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Griasa", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "The raw transcript for this meeting isn't on disk anymore, so it can't be re-summarized."
            ])
        }
        let formatted = try await aiFormat(raw: raw, participants: participants,
                                           myName: myName, hasNotes: raw.contains("📝 NOTE:"))
        try formatted.write(to: transcriptFile, atomically: true, encoding: .utf8)
        return formatted
    }

    /// Extracts the "# Meeting notes — Title" line for history labeling.
    static func title(fromMarkdown text: String) -> String {
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# ") {
                return line.dropFirst(2)
                    .replacingOccurrences(of: "Meeting notes — ", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return "Meeting"
    }

    private static func aiFormat(raw: String, participants: [String], myName: String,
                                 hasNotes: Bool) async throws -> String {
        // Very long meetings: keep the request under the provider's context
        // limit rather than failing. Cloud models have 1M-token windows
        // (~400k chars barely dents them); local models get the much smaller
        // configurable budget.
        var transcript = raw
        let limit = LLMConfig.current().contextCharLimit
        if transcript.count > limit {
            transcript = String(transcript.suffix(limit))
            transcript = "[…earlier part of the meeting truncated to fit the model's context…]\n" + transcript
        }

        var speakerRules = """
        The two speaker labels mean: "You" is the user's microphone, "Them" is everything the \
        computer played (all remote participants, mixed into one track).
        """
        if !participants.isEmpty {
            let mine = myName.isEmpty ? "the user" : myName
            speakerRules += """


            Participants on this call: \(participants.joined(separator: ", ")).
            Attribute speakers to these real names in the Transcript:
            - Label the "You" track as \(mine).
            - Split the "Them" track among the other participants using conversational cues — \
            self-introductions, people addressing each other by name (e.g. "Вань, расскажешь…" → the \
            next "Them" speaker is Ваня), topic ownership, and turn-taking. Use "**Name:**" labels.
            - When you genuinely cannot tell which participant is speaking, use "**Speaker:**" rather \
            than guessing. Never invent names beyond the provided list.
            In Action items, attribute owners to these names too.
            """
        }

        var noteRules = ""
        if hasNotes {
            noteRules = """


            Lines in the form "[mm:ss] 📝 NOTE: …" are notes the user typed by hand during the \
            meeting — their own words, not recognized speech, so they are highly reliable. \
            Reflect their content prominently in Summary, Key points and Action items, and keep \
            each one in the Transcript at its place as a Markdown blockquote: \
            "> 📝 **Note [mm:ss]:** …".
            """
        }

        let system = Prompts.text(.meetingNotes)
            .filling(["speakerRules": speakerRules, "noteRules": noteRules])

        return try await AIFormatter.complete(system: system, user: transcript,
                                              tier: .smart, maxTokens: 16000, timeout: 300)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
