import Foundation

/// Ready-made requests an MCP client can offer as commands ("Prepare me for my
/// next call"), so the person doesn't have to know how to ask, and the assistant
/// is told which Griasa tools answer it. Foundation only: the list and the
/// wording are data, checked in test.sh.
enum MCPPrompts {
    struct Prompt {
        var name: String
        var title: String
        var description: String
        /// (name, description, required)
        var arguments: [(String, String, Bool)]
        var text: ([String: String]) -> String
    }

    static let all: [Prompt] = [
        Prompt(name: "prep_next_call", title: "Prepare me for my next call",
               description: "A short brief for the next calendar meeting: who is on it, what each side owes, what was said last time.",
               arguments: []) { _ in
            """
            Prepare me for my next call. Call get_next_meeting_brief; for each attendee Griasa \
            recognises, call get_context with their name. Then give me, briefly: who is on the \
            call, what I promised them and what they promised me (overdue first, with dates), \
            what we discussed last time, and two or three things worth raising. Answer in the \
            language I usually write in. Don't call get_transcript unless a summary is missing.
            """
        },
        Prompt(name: "weekly_review", title: "Weekly review",
               description: "What I owe, what I'm waiting on, what is overdue, and the meetings ahead this week.",
               arguments: [("days", "How many days ahead to look at meetings. Default 7.", false)]) { args in
            let days = args["days"].flatMap { Int($0) }.map { min(max($0, 1), 14) } ?? 7
            return """
            Give me my weekly review. Call list_commitments, then list_upcoming_meetings with \
            days \(days). Show: what is overdue, what I owe (grouped by person), what I'm \
            waiting on from others, and for each meeting ahead what I should bring to it. Keep \
            it to one screen. Don't change or close anything.
            """
        },
        Prompt(name: "follow_up", title: "Write the follow-up for a meeting",
               description: "A follow-up email draft for a meeting — for everyone, or only one person's promises. Nothing is sent.",
               arguments: [("meeting", "Words from the meeting's title. Default: the most recent meeting.", false),
                           ("person", "Only this participant's promises and mine, addressed to them.", false)]) { args in
            let which = args["meeting"].map { "Find the meeting with search_meetings using \"\($0)\"." }
                ?? "Use the most recent meeting from search_meetings."
            let who = args["person"].map { " Pass person \"\($0)\" to draft_followup." } ?? ""
            return """
            Write the follow-up for a meeting. \(which) Then call draft_followup with its id.\(who) \
            Show me the subject and body so I can edit them, and the mailto link. Do not send \
            anything yourself.
            """
        },
        Prompt(name: "what_do_i_owe", title: "What do I owe this person?",
               description: "Everything open between me and one colleague, and when we last spoke.",
               arguments: [("person", "The colleague's name, in any spelling.", true)]) { args in
            let person = args["person"] ?? "them"
            return """
            What is open between me and \(person)? Call get_context with about "\(person)" and \
            kind "person". List what I promised them and what they promised me, with dates and \
            the words each promise came from, then when we last met and what it was about.
            """
        },
    ]

    /// `prompts/list` entries.
    static var listings: [[String: Any]] {
        all.map { prompt in
            ["name": prompt.name, "title": prompt.title, "description": prompt.description,
             "arguments": prompt.arguments.map { ["name": $0.0, "description": $0.1, "required": $0.2] }]
        }
    }

    /// `prompts/get` result, or nil for an unknown prompt or a missing required argument.
    static func get(_ name: String, arguments: [String: String]) -> [String: Any]? {
        guard let prompt = all.first(where: { $0.name == name }) else { return nil }
        for (argument, _, required) in prompt.arguments where required {
            guard let value = arguments[argument], !value.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
        }
        return ["description": prompt.description,
                "messages": [["role": "user", "content": ["type": "text", "text": prompt.text(arguments)]]]]
    }
}
