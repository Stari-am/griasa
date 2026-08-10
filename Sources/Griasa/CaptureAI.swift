import Foundation

/// AI calls behind the capture actions: parsing a reminder out of free text
/// and drafting a chat reply from an OCR'd conversation. Both use the fast
/// model tier for snappy, in-the-flow responses.
enum CaptureAI {
    struct ParsedReminder {
        let title: String
        let notes: String?
        let due: Date?
    }

    static func parseReminder(text: String) async -> ParsedReminder? {
        let now = localTimestamp(Date())
        let system = Prompts.text(.reminderParse).filling(["now": now])
        guard let raw = try? await AIFormatter.complete(
            system: system, user: text, tier: .fast, maxTokens: 512)
        else { return nil }
        return parse(raw)
    }

    static func draftReply(transcript: String) async -> String? {
        let system = Prompts.text(.chatReply)
        // The most recent messages sit at the bottom, so keep the tail if long.
        let input = transcript.count > 12_000 ? String(transcript.suffix(12_000)) : transcript
        return try? await AIFormatter.complete(
            system: system, user: input, tier: .fast, maxTokens: 1024)
    }

    // MARK: - Parsing

    private static func parse(_ raw: String) -> ParsedReminder? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else { return nil }
        let jsonString = String(raw[start...end])
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }

        let notes = (obj["notes"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        var due: Date?
        if let iso = obj["dueDateISO"] as? String, !iso.isEmpty {
            due = parseDate(iso)
        }
        return ParsedReminder(title: title, notes: notes, due: due)
    }

    private static func localTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss (EEEE)"
        return formatter.string(from: date)
    }

    /// Tolerant parse: Claude usually returns a timezone-less local datetime,
    /// but sometimes a full ISO-8601 or a date-only value.
    private static func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
