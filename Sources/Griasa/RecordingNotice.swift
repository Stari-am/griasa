import Foundation

/// A reminder, as a recording starts, to tell the other people on the call.
///
/// Griasa records the other side of a call through the Mac's own audio, so
/// nobody else sees a recording indicator — only the person running it does.
/// Whether that needs consent depends on where everybody is, and a security
/// review pointed out that a recording made without it can be unusable, or
/// worse, as evidence. The app cannot decide that for anybody, but it can make
/// asking the easy thing to do: when this is on, starting a recording puts a
/// ready sentence in front of you with a Copy button, for the call's chat.
///
/// Off unless somebody turns it on. An organisation can turn it on for
/// everybody with an MDM profile (`recordingNotice`), and set the sentence
/// (`recordingNoticeText`).
///
/// Foundation only, so `test.sh` can reach it.
enum RecordingNotice {
    static let enabledKey = "recordingNotice"
    static let textKey = "recordingNoticeText"

    /// Says what is happening and offers a way out, which is what makes it a
    /// question rather than an announcement.
    static let defaultText = "Heads-up: I'm recording this call so I can take notes and keep track of what we agree. Tell me if you'd rather I didn't."

    /// Absent means off — the default for everybody. Present is read in the
    /// direction that is safe for a notice: the only reason to write this key
    /// is to turn it on, so a value that cannot be read as a clear "no" counts
    /// as on. A profile typo should produce one reminder too many, never a
    /// recording nobody was told about.
    static func isOn(_ raw: Any?) -> Bool {
        guard let raw else { return false }
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return !["false", "no", "0", "off"].contains(text)
        }
        return true
    }

    /// The sentence to offer; the default when none is set or it is blank.
    static func text(_ raw: Any?) -> String {
        let custom = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? defaultText : custom
    }
}
