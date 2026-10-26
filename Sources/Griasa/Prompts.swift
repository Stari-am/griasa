import Foundation

/// Every system prompt Griasa sends to an LLM, in one place.
///
/// They used to be inline string literals scattered across ten files, which
/// made the app's actual behavior impossible to review or adjust without
/// hunting through the source. Reading them here should be enough to know what
/// the app asks a model to do.
///
/// **Placeholders.** A prompt can't use Swift interpolation, because these
/// strings are also loadable from a JSON file at runtime. Runtime values are
/// written `{{name}}` and filled by the call site with `filling(_:)`. A
/// placeholder the call site doesn't supply is left in the text rather than
/// silently blanked — a visible `{{today}}` in a reply is a much better bug
/// report than a prompt that quietly lost its date.
///
/// **Editing without rebuilding.** Settings → AI & Actions → Prompts writes the
/// current set to `~/Documents/Griasa Prompts.json`; any key present there wins
/// over the default below. Delete a key (or the file) to go back to the shipped
/// wording.
///
/// The prompt-preset library (PromptPresets.swift) is deliberately not here:
/// those are user-owned documents edited in Settings and persisted per user, not
/// app behavior.
enum Prompts {
    enum Key: String, CaseIterable {
        /// Dictation cleanup — the fast pass over recognized speech.
        case dictationCleanup
        /// Meeting transcript → polished notes.
        case meetingNotes
        /// Running summary of a meeting still in progress.
        case liveSummary
        /// Appended to `liveSummary` when the user typed manual notes.
        case liveSummaryNotes
        /// Mining commitments out of meeting notes.
        case commitments
        /// Deciding which already-open commitments this conversation says are done.
        case commitmentsDone
        /// One part of a long meeting (local model): the part first, the task last.
        case meetingChunk
        /// Merging the notes of every part into one set of meeting notes.
        case meetingReduce
        /// The short shared system message of the long-meeting requests, so the
        /// model's cached prefix is the same for every question about a part.
        case longMeetingSystem
        /// Working dossier about one colleague.
        case personDossier
        /// Filing a note into one of the user's projects.
        case projectClassify
        /// Answering a question from a project's knowledge base.
        case projectAsk
        /// Drafting a document from a template plus a brief.
        case documentDraft
        /// Free text → reminder fields.
        case reminderParse
        /// OCR'd chat window → the reply to send next.
        case chatReply
        /// The `{ai: …}` snippet placeholder.
        case snippetFragment
        /// The `;ai … ;;` inline question typed straight into any app.
        case inlineAsk
        /// Provider connection test.
        case connectionTest
    }

    // MARK: - Reading

    static func text(_ key: Key) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let override = overrides[key.rawValue], !override.isEmpty { return override }
        return shipped(key)
    }

    // MARK: - Overrides file

    static var overrideFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Griasa Prompts.json")
    }

    private static let lock = NSLock()
    private static var overrides: [String: String] = load()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: overrideFileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        // Unknown keys are kept out rather than ignored silently at read time,
        // so `exportForEditing` can round-trip without accumulating cruft.
        return decoded.filter { key, _ in Key(rawValue: key) != nil }
    }

    /// Re-reads the file, so an edit takes effect without relaunching.
    @discardableResult
    static func reload() -> Int {
        lock.lock()
        overrides = load()
        let count = overrides.count
        lock.unlock()
        return count
    }

    /// Writes every prompt currently in effect to the override file, so editing
    /// starts from the real wording instead of a blank page.
    static func exportForEditing() throws -> URL {
        var dictionary: [String: String] = [:]
        for key in Key.allCases { dictionary[key.rawValue] = text(key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(dictionary).write(to: overrideFileURL, options: .atomic)
        return overrideFileURL
    }

    // MARK: - Shipped wording

    /// Appended to `.commitments` in code, outside the text a person can edit: the
    /// quote is what lets a promise be checked, so an edited prompts file cannot
    /// lose it.
    static let commitmentQuoteRules = """

    Every element must also carry these two keys:
      "quote": the exact words from the input where the promise was made, copied word for \
    word exactly as they stand — never translated, corrected or tidied up,
      "at": "mm:ss" of the nearest [mm:ss] timestamp before the quote if the input shows one, else null
    A promise you cannot quote is dropped. Text marked "context only" is already covered: \
    do not extract from it.
    """

    /// Added when the input is one part of a longer transcript, where "You" and "Them" are tracks.
    static let commitmentPartRules = """

    The input is one part of a longer meeting transcript, not finished notes. "You" is the \
    user's microphone ({{me}}); "Them" is everything the computer played — the other \
    participants ({{participants}}). Attribute each promise to the person who made it; set \
    "mine" to true only when the speaker is "You". When you cannot tell who a "Them" speaker \
    is, use "Them" as the owner and set "mine" to false.
    """

    /// An explicit line naming the language of the meeting; a model left to guess
    /// answers in English for a Russian meeting. When it is not known the line says "the language the speakers use".
    static func languageLine(_ language: String?) -> String {
        let name = (language?.isEmpty == false) ? language! : "the language the speakers use"
        return "\nThe meeting is in \(name). Write everything in \(name); keep English tech terms as spoken."
    }

    /// The language rules of `.meetingNotes`, shared by the long-meeting prompts.
    private static let languageRules = """
    Language rules:
    - The meeting may be in any language and may switch languages. Never translate the \
    content into another language.
    - Speakers often mix in English technology and crypto terms (GitHub, deploy, staking, \
    jetton, seed phrase, mainnet…). Keep those terms in English exactly as spoken — do not \
    translate or transliterate them — and fix ones the recognizer mangled or transliterated \
    phonetically (e.g. "гит хаб" → "GitHub").
    """

    // swiftlint:disable function_body_length
    private static func shipped(_ key: Key) -> String {
        switch key {
        case .dictationCleanup:
            return """
            You clean up dictated speech. Rules:
            - Remove filler words (um, uh, like, you know) and false starts.
            - Fix punctuation, capitalization, and obvious dictation errors.
            - Apply spoken formatting commands: "new line", "new paragraph", "comma", "period", "question mark", "quote ... unquote", "bullet point", "numbered list".
            - Keep the speaker's wording and meaning; do not summarize, expand, or add anything.
            - Keep the speaker's language — never translate. The dictation may be in any language \
            and may mix in English tech/crypto terms (GitHub, deploy, staking, jetton…); keep those \
            in English, and fix ones the recognizer transliterated phonetically (e.g. "гит хаб" → "GitHub").
            - {{appContext}}
            Output ONLY the cleaned text, no commentary.
            """

        case .meetingNotes:
            return """
            You turn raw meeting transcripts into polished meeting notes. The input is an \
            automatically merged transcript of two audio tracks. {{speakerRules}}{{noteRules}} Timestamps mark \
            30-second chunks, so adjacent lines from the same speaker often belong together and \
            speech recognition errors are common — fix obvious mis-transcriptions from context.

            Language rules:
            - The meeting may be in any language and may switch languages; write the notes and \
            cleaned transcript in the language that dominates the conversation. Never translate \
            the content into another language.
            - Speakers often mix in English technology and crypto terms (GitHub, deploy, staking, \
            jetton, seed phrase, mainnet…). Keep those terms in English exactly as spoken — do not \
            translate or transliterate them — and fix ones the recognizer mangled or transliterated \
            phonetically (e.g. "гит хаб" → "GitHub", "стейкинг" → "staking" when clearly the English \
            term was meant as a term of art).

            Produce a Markdown document with exactly these sections:
            # Meeting notes — <infer a short title>
            ## Summary            (3-6 sentences)
            ## Key points         (bulleted)
            ## Action items       (bulleted, with owner "You"/"Them" when clear; write "None" if there are none)
            ## Transcript         (cleaned dialogue with "**Speaker:**" labels per the speaker rules above, \
            merge consecutive lines from one speaker, keep a [mm:ss] timestamp roughly every few minutes)

            Do not invent content that is not supported by the transcript.
            """

        case .liveSummary:
            return """
            This is a live, in-progress meeting transcript that grows over time. Produce a running \
            summary in the transcript's language, formatted for a side panel with inline Markdown only:
            - A one-line **bold** headline of what's being discussed right now.
            - 3–6 "• " bullets of decisions and key points so far (**bold** key terms).
            - A "• Open questions:" bullet if any are unresolved.
            - A "• Action items:" bullet list if any have come up (with owner when clear).
            Keep tech/crypto terms in English. No headers (#). Output only the summary.
            """

        case .liveSummaryNotes:
            return """
            Lines in the form "📝 NOTE: …" are notes the user typed by hand during the meeting — \
            their own words, not recognized speech. Treat them as high-signal: make sure their \
            content is reflected in the summary.
            """

        case .commitmentsDone:
            return """
            You decide which of a list of outstanding commitments a meeting says are
            already finished. You do not invent, reword or add commitments.

            You are given numbered commitments and then the notes of a meeting.

            Return ONLY a JSON array, no prose, no markdown fences. Each element:
            {"n": <the number of the commitment>, "quote": "the exact sentence from the
             notes that says it is done"}

            Rules:
            - The quote must appear in the notes, word for word. If you cannot quote it,
              leave the commitment out.
            - "Done" means finished, delivered, sent, merged, cancelled or no longer
              needed. Progress is not done: "I started on it", "almost ready",
              "will finish tomorrow" are all still open.
            - A commitment being mentioned, discussed or re-promised is not done.
            - Return an empty array if nothing was finished. That is the common answer
              and it is the right one.

            Outstanding commitments:
            {{items}}
            """

        case .commitments:
            return """
            You extract concrete commitments (promises to do something) from meeting notes.
            Today is {{today}}. The user of this app is "{{me}}". Participants: {{participants}}.

            Return ONLY a JSON array, no prose, no markdown fences. Each element:
            {"text": "what was promised, short imperative phrase in the language of the notes",
             "owner": "name of who promised it (from the participants; use "{{me}}" for the user)",
             "mine": true if the user promised it, false otherwise,
             "due": "YYYY-MM-DD" resolved from phrases like "by Friday" relative to today, or null,
             "dueHint": "the deadline exactly as phrased, or null"}

            Rules:
            - Only real, actionable promises a person explicitly took on. Skip vague intentions,
              group decisions with no owner, and things already done.
            - Keep each text self-contained (a week later it must still make sense on its own).
            - 0 items is a valid answer: return [].
            """

        case .longMeetingSystem:
            return """
            You work on one meeting transcript. The text comes first; what to do with it comes \
            after it, at the end. Do only what the final instructions ask.
            """

        case .meetingChunk:
            return """
            =====
            The text above is part {{part}} of {{parts}} of a meeting transcript{{range}}. {{speakerRules}}{{noteRules}} \
            Speech recognition errors are common — read obvious mis-transcriptions from context. \
            A part marked "context only" at the start repeats the end of the previous part so that \
            a sentence is not cut in half: use it to understand, but do not report anything from it.
            {{known}}
            \(languageRules)

            Write down what happened in THIS part, in the language that dominates it. Return ONLY \
            a JSON object with these keys (empty lists are fine):
            - "points": the substantive things discussed, one short sentence each.
            - "decisions": what was decided or agreed.
            - "actions": tasks someone is to do AFTER this call that produce or change something \
            outside it (send, prepare, fix, check, schedule, pay, decide) — promised, taken on, \
            assigned, or agreed as a next step. List each such task separately. Each: {"owner": who \
            is to do it, "task": what, "due": the deadline as spoken or "", "date": that deadline as \
            YYYY-MM-DD counted from the meeting date {{today}}, or "", "quote": the exact words from \
            the transcript where it was said, copied exactly as it stands in the transcript — do not \
            correct, translate or tidy it, even if a word looks mis-recognised}. Do NOT list: requests \
            answered inside the meeting itself ("tell me more", "repeat that", "explain", "share your \
            screen", "go on"), questions, conversational moves, anything already done during the call, \
            or wishes nobody took on. Test: would it still make sense on a to-do list a week later, and \
            was it not finished before the call ended? If unsure whether a real deliverable was \
            promised, include it.
            - "questions": questions left open.
            - "speakers": clues about who the "Them" speakers are, e.g. someone addressed by name \
            or introducing themselves. Each: {"name": the person, "clue": the words that tell}.

            Never invent anything that is not in this part of the transcript.
            """

        case .meetingReduce:
            return """
            =====
            Above are notes taken part by part from one meeting, in order, each with its time \
            range. {{speakerRules}}

            Merge them into one set of meeting notes, in the language that dominates them. \
            Produce a Markdown document with exactly these sections and no others:
            # Meeting notes — <infer a short title>
            ## Summary            (3-6 sentences covering the whole meeting, beginning to end)
            ## Key points         (bulleted, merged, in the order they came up)
            ## Action items       (bulleted, with owner when clear; write "None" if there are none)

            Rules:
            - Merge duplicates: the same point or promise reported by two parts appears once.
            - Action items: every item listed under "Actions" in the parts must be in Action items. \
            Drop one only when another entry is the same task; never drop one to make the list shorter.
            - When a later part changes an earlier decision, keep the later one and say it changed.
            - Do not add the transcript. Never add anything that is not in the notes above.
            \(languageRules)
            """

        case .personDossier:
            return """
            You write a short working dossier about one colleague, "{{name}}", from meeting \
            transcripts they took part in. Write in the language that dominates the transcripts.

            Structure (plain markdown, ## headings, keep the whole thing under 300 words):
            ## Role & ownership — what they work on and are responsible for, judging by the meetings
            ## Commitments & follow-through — what they promised, what got done
            ## Working style — how they communicate and decide (only if the transcripts show it)
            ## Recent topics — the last few things discussed with them

            Only state what the transcripts support. If a section has nothing, write "—".
            """

        case .projectClassify:
            return """
            You file a note into one of the user's projects. The projects:
            {{projects}}
            - {{inbox}} — anything that doesn't clearly belong to a project above

            Reply with EXACTLY one project name from the list (or "{{inbox}}"), nothing else.
            Notes may be in Russian or English and mix in English tech/crypto terms.
            """

        case .projectAsk:
            return """
            Answer the user's question using their project knowledge base below — their
            dictations, meeting notes, and attached project files. Rules:
            - Answer in the language of the question; keep English tech/crypto terms in English.
            - Mention which note or file the answer comes from when it helps.
            - If the knowledge base doesn't contain the answer, say so briefly.
            - Format with inline Markdown only (**bold**, "• " bullets) for a small window.

            KNOWLEDGE BASE:
            {{knowledgeBase}}
            """

        case .documentDraft:
            return """
            You draft working documents for a product/engineering lead. Fill in the template \
            below using ONLY the brief the user provides.

            Rules:
            - Keep the template's heading structure exactly; replace {placeholders} with real content.
            - The <!-- comments --> describe what each section needs — follow them, then REMOVE them. \
            No HTML comments may remain in the output.
            - Write the document in the language of the brief.
            - Be concrete and terse; a busy reader should get it in one pass.
            - Where the brief simply doesn't cover a section, write "TBD — " plus one pointed \
            question that would fill it. Never invent facts, numbers, or names.
            - Output the finished markdown document only — no preamble, no fences.

            Template:
            {{skeleton}}
            """

        case .reminderParse:
            return """
            You turn a note into a reminder. The current local date-time is {{now}}. The user is \
            {{me}}.
            Return ONLY minified JSON, no markdown or commentary:
            {"title": string, "notes": string|null, "dueDateISO": string|null, "promise": object|null}
            - title: a short imperative reminder (max ~8 words), in the note's own language.
            - notes: any useful supporting detail, or null.
            - dueDateISO: a local ISO-8601 datetime like 2026-07-13T15:00:00 when the note implies a \
            time ("tomorrow 3pm", "in 2 hours", "Monday morning"); resolve it against the current \
            date-time above. Use null when no time is implied.
            - promise: when the note shows someone committing to do something ("I'll send it by \
            Friday", "Иван: скину схему завтра"), {"owner": who committed — "me" if it is the user, \
            otherwise their name as written, "task": what they will do, in the note's language, \
            "due": the deadline in their words or null, "dueDateISO": that deadline resolved like \
            dueDateISO or null, "quote": the exact words of the commitment copied from the note}. \
            A request nobody accepted, a wish, or a plan without an owner is not a promise: use null.
            """

        case .chatReply:
            return """
            You help the user reply in a chat. Below is OCR text scraped from their screen — a
            messaging/chat window whose line order and speaker attribution may be imperfect. Infer
            the ongoing conversation and draft the single reply the user would most naturally send next.
            Rules:
            - Output ONLY the reply text — no preamble, quotes, labels, or explanation.
            - Match the conversation's language (Russian or English) and register (casual vs. formal).
            - Keep it concise and natural; keep English tech/crypto terms in English.
            """

        case .snippetFragment:
            return """
            You generate a short text fragment to be inserted inline while the user types.
            Follow the user's instruction exactly. Output ONLY the fragment — no commentary,
            no quotes, no trailing newline.
            """

        case .inlineAsk:
            return """
            The user typed a question or instruction directly into whatever they were writing, and \
            your answer replaces it in place. Answer it.
            Rules:
            - Output ONLY the answer — no preamble, no restating the question, no quotes, no \
            trailing newline, no markdown fences.
            - Answer in the language the user wrote in; keep English tech/crypto terms in English.
            - Be brief by default: a phrase or a sentence or two, unless the request clearly calls \
            for more. This is going inline into a message or document, not into a chat window.
            - If it's an instruction to write something ("напиши…", "draft a…"), write that thing \
            rather than talking about it.
            """

        case .connectionTest:
            return "Reply with exactly: OK"
        }
    }
    // swiftlint:enable function_body_length
}

extension String {
    /// Substitutes `{{name}}` placeholders. Anything the caller doesn't supply
    /// is left as-is: a stray `{{today}}` showing up in output is a far better
    /// bug report than a prompt that quietly lost its date.
    func filling(_ values: [String: String]) -> String {
        var result = self
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
    }
}
