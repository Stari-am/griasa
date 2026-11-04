import Foundation

/// Notes, voice memos and call recordings sent from the iPhone, through a
/// folder in iCloud Drive.
///
/// There is no Griasa for the iPhone, and none is needed for this: iCloud
/// Drive is already on both. A Siri Shortcut saves what was dictated in the
/// car as a text file there; Voice Memos and the call recordings Notes keeps
/// reach it through Share → Save to Files. The Mac picks each file up, turns
/// audio into text on the Mac, and files the result as a meeting, so the
/// promises in it land in Commitments like any other.
///
/// Foundation only, so `test.sh` can reach the rules.
enum PhoneInbox {
    enum Kind: Equatable { case text, audio, skip }

    static let textExtensions: Set<String> = ["txt", "md", "markdown", "text"]
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aac", "aif", "aiff", "mp4", "qta"]
    /// Where files go once read, inside the inbox, so nothing on the phone
    /// side is deleted.
    static let importedFolder = "Imported"
    static let failedFolder = "Not imported"
    /// Longer than this, a recording is a conversation rather than a note, and
    /// gets a summary as a meeting would.
    static let conversationSeconds: TimeInterval = 180

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Griasa/Inbox`, which is
    /// iCloud Drive → Griasa → Inbox on the phone.
    static func folder(home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Griasa/Inbox", isDirectory: true)
    }

    /// What a file in the inbox is. Hidden files, iCloud placeholders and
    /// anything not text or audio are left where they are.
    static func kind(of name: String) -> Kind {
        guard !name.hasPrefix("."), !name.hasSuffix(".icloud") else { return .skip }
        let ext = (name as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { return .text }
        if audioExtensions.contains(ext) { return .audio }
        return .skip
    }

    /// A file still arriving from iCloud keeps changing: wait until it has
    /// been still for a little while.
    static func isSettled(modified: Date, now: Date) -> Bool {
        now.timeIntervalSince(modified) >= 10
    }

    /// The file an iCloud placeholder stands for: `.Memo.m4a.icloud` → `Memo.m4a`.
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let inner = String(name.dropFirst().dropLast(".icloud".count))
        return inner.isEmpty ? nil : inner
    }

    /// Known colleagues the text names, by full name or by a first name of
    /// three letters or more, as a whole word and ignoring case and accents.
    /// These become the meeting's participants, so the promises find the right
    /// people without a question — there is nobody at the Mac to answer one.
    static func mentionedPeople(in text: String, known: [String]) -> [String] {
        let words = Set(tokens(text))
        let folded = " " + tokens(text).joined(separator: " ") + " "
        var found: [String] = []
        for name in known where !found.contains(name) {
            let parts = tokens(name)
            guard let first = parts.first else { continue }
            let full = " " + parts.joined(separator: " ") + " "
            if (parts.count > 1 && folded.contains(full)) || (first.count >= 3 && words.contains(first)) {
                found.append(name)
            }
        }
        return found
    }

    private static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// "📱 " and the note's first words, short enough for a list.
    static func title(from text: String) -> String {
        let base = ImportedNotes.title(from: text, fallback: "Note from iPhone")
        let short = base.count > 60 ? String(base.prefix(59)) + "…" : base
        return "📱 " + short
    }

    /// A name for `name` inside `folder` that is not taken yet: "Memo.m4a",
    /// then "Memo 2.m4a", "Memo 3.m4a"…
    static func freeName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}
