import AppKit

/// Resolves the dynamic placeholders of a snippet template at insert time:
/// {date} {date+3d} {time} {time+2h} {clipboard} {meetlink} {slot}
/// {slots:3} {commitments} {commitments:mine} {commitments:theirs}
/// {ai: prompt}. Placeholders nest one level, so an {ai:} prompt can pull in
/// live context: {ai: Summarize in 3 bullets: {clipboard}}. Unknown braces
/// pass through untouched — they might be intentional text.
enum SnippetEngine {
    struct RenderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func render(_ template: String) async throws -> String {
        try await render(template, depth: 0)
    }

    /// Braces are matched balanced, so placeholders nest —
    /// `{ai: Summarize: {clipboard}}` resolves {clipboard} first, then asks
    /// the model. `depth` caps the nesting so {ai:} can't recurse into itself.
    private static func render(_ template: String, depth: Int) async throws -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = matchingClose(in: rest, from: open) else {
                result += rest[open...]
                return result
            }
            let token = String(rest[rest.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            if let value = try await resolve(token, depth: depth) {
                result += value
            } else {
                result += rest[open...close]  // unknown — keep the braces
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    /// Index of the `}` matching the `{` at `open`, honoring nesting.
    private static func matchingClose(in text: Substring, from open: Substring.Index) -> Substring.Index? {
        var level = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "{": level += 1
            case "}":
                level -= 1
                if level == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// nil = not a known placeholder.
    private static func resolve(_ token: String, depth: Int) async throws -> String? {
        if token == "date" {
            return Date().formatted(date: .abbreviated, time: .omitted)
        }
        if token == "time" {
            return Date().formatted(date: .omitted, time: .shortened)
        }
        if let days = offset(token, prefix: "date+", unit: "d") {
            let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        if let hours = offset(token, prefix: "time+", unit: "h") {
            let date = Calendar.current.date(byAdding: .hour, value: hours, to: Date()) ?? Date()
            return date.formatted(date: .omitted, time: .shortened)
        }
        if token == "clipboard" {
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
        if token == "meetlink" {
            let link = (UserDefaults.standard.string(forKey: "meetLink") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty else {
                throw RenderError(message: "{meetlink}: set your meeting-room link in Settings → Snippets.")
            }
            return link
        }
        if token == "slot" {
            let slots = try await FreeSlotFinder.nextSlots(1)
            guard let first = slots.first else {
                throw RenderError(message: "{slot}: no free slot found in the next 7 working days.")
            }
            return FreeSlotFinder.format(first)
        }
        if token.hasPrefix("slots:"), let count = Int(token.dropFirst("slots:".count)), count > 0 {
            let slots = try await FreeSlotFinder.nextSlots(min(count, 10))
            guard !slots.isEmpty else {
                throw RenderError(message: "{slots}: no free slots found in the next 7 working days.")
            }
            return slots.map(FreeSlotFinder.format).joined(separator: " / ")
        }
        if token == "commitments" || token.hasPrefix("commitments:") {
            let scope = token == "commitments" ? "all" : String(token.dropFirst("commitments:".count))
            let lines = await MainActor.run { () -> [String] in
                let store = CommitmentStore.shared
                let items: [Commitment]
                switch scope {
                case "mine": items = store.openMine
                case "theirs": items = store.openTheirs
                default: items = store.openMine + store.openTheirs
                }
                return items.map { item in
                    // "- text — «meeting», date (due …)"; other people's
                    // promises are prefixed with their name.
                    var line = "- "
                    if !item.isMine { line += "\(item.owner): " }
                    line += item.text
                    var reference: [String] = []
                    if !item.sourceTitle.isEmpty { reference.append("«\(item.sourceTitle)»") }
                    reference.append(item.date.formatted(date: .abbreviated, time: .omitted))
                    line += " — " + reference.joined(separator: ", ")
                    if let due = item.dueDate {
                        line += " (due \(due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))))"
                    } else if let hint = item.dueHint, !hint.isEmpty {
                        line += " (\(hint))"
                    }
                    return line
                }
            }
            guard !lines.isEmpty else {
                throw RenderError(message: "{commitments}: nothing open — the list fills up after recorded meetings (✅ Commitments tab).")
            }
            return lines.joined(separator: "\n")
        }
        if token.hasPrefix("ai:") {
            // One level only: an {ai:} inside another {ai:} prompt stays literal.
            guard depth == 0 else { return nil }
            var prompt = token.dropFirst("ai:".count).trimmingCharacters(in: .whitespaces)
            guard !prompt.isEmpty else { return "" }
            guard AIFormatter.isConfigured else {
                throw RenderError(message: "{ai:}: configure an AI provider in Settings → AI & Actions.")
            }
            // Resolve nested placeholders ({clipboard}, {date}…) so the
            // prompt can reference live context.
            prompt = try await render(prompt, depth: depth + 1)
            do {
                // No cloud-fallback consent dialog here — it would steal
                // focus from the field the user is typing into.
                return try await AIFormatter.complete(
                    system: Prompts.text(.snippetFragment),
                    user: prompt,
                    tier: .fast,
                    maxTokens: 1024,
                    timeout: 30,
                    allowCloudFallback: false)
            } catch {
                throw RenderError(message: "{ai:} failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// Parses "date+3d" → 3 for prefix "date+", unit "d".
    private static func offset(_ token: String, prefix: String, unit: String) -> Int? {
        guard token.hasPrefix(prefix), token.hasSuffix(unit) else { return nil }
        return Int(token.dropFirst(prefix.count).dropLast(unit.count))
    }
}
