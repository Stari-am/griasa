import AppKit
import Carbon.HIToolbox

/// Types and deletes text in the frontmost app via synthetic keyboard events —
/// used by live dictation to stream words as they're recognized and then
/// correct them in place, instead of pasting everything at the end.
enum LiveTyper {
    /// Replaces previously typed text with new text, touching only the tail
    /// that actually differs (backspace over the divergent part, type the rest).
    static func applyDiff(from old: String, to new: String) {
        let oldChars = Array(old)
        let newChars = Array(new)
        var common = 0
        while common < oldChars.count && common < newChars.count && oldChars[common] == newChars[common] {
            common += 1
        }
        backspace(oldChars.count - common)
        type(String(newChars[common...]))
    }

    /// Stamped onto every event Griasa posts. `TypingSession` watches for the
    /// user interrupting a dictation, and without this marker it would see
    /// Griasa's own typing and abandon every session immediately.
    static let syntheticMarker: Int64 = 0x4D75_726D  // "Murm"

    /// Whether an observed event is one Griasa posted. An event with no backing
    /// `CGEvent` is treated as ours; `TypingSession`'s frontmost-PID check is
    /// the independent guard that doesn't depend on this.
    static func isSynthetic(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else { return true }
        return cgEvent.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }

    private static func taggedSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = syntheticMarker
        return source
    }

    static func type(_ text: String) {
        // Grapheme-safe, not the fixed 16 UTF-16 units this used to send: the
        // diagnostics harness caught that boundary splitting a surrogate pair in
        // Telegram into U+FFFD and dropping the four characters after it.
        typeBlocking(text, pacingMicros: 0, chunking: .graphemeSafe(maxUnits: 16))
    }

    static func backspace(_ count: Int) {
        backspaceBlocking(count, pacingMicros: 0)
    }

    // MARK: - Instrumented variants (used by the typing diagnostics)

    /// How a string is split across `keyboardSetUnicodeString` calls, which
    /// truncates long strings and so has to be chunked either way.
    enum ChunkPolicy: Sendable {
        /// Fixed number of UTF-16 units, boundary-blind — what `type(_:)` ships
        /// today. A surrogate pair or combining sequence landing on a boundary
        /// is split across two events.
        case fixedUTF16(Int)
        /// Never splits a grapheme cluster: characters are packed up to the
        /// limit, and one oversized character gets an event of its own.
        case graphemeSafe(maxUnits: Int)
    }

    /// Splits `text` into the UTF-16 payloads of individual key events.
    static func chunks(of text: String, policy: ChunkPolicy) -> [[UniChar]] {
        switch policy {
        case .fixedUTF16(let size):
            let utf16 = Array(text.utf16)
            var result: [[UniChar]] = []
            var index = 0
            while index < utf16.count {
                result.append(Array(utf16[index..<min(index + size, utf16.count)]))
                index += size
            }
            return result
        case .graphemeSafe(let maxUnits):
            var result: [[UniChar]] = []
            var current: [UniChar] = []
            for character in text {
                let units = Array(String(character).utf16)
                if !current.isEmpty && current.count + units.count > maxUnits {
                    result.append(current)
                    current = []
                }
                current.append(contentsOf: units)
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
    }

    /// Types `text` with an explicit delay between key events. Blocking on
    /// purpose: `usleep` is accurate below a millisecond where `Task.sleep`
    /// isn't, so callers run this off the main actor via `Task.detached`.
    static func typeBlocking(_ text: String, pacingMicros: UInt32, chunking: ChunkPolicy) {
        guard !text.isEmpty else { return }
        let source = taggedSource()
        for chunk in chunks(of: text, policy: chunking) {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            if pacingMicros > 0 { usleep(pacingMicros) }
        }
    }

    /// Deletes backwards `count` times with an explicit delay between events.
    /// See `typeBlocking` on why this blocks.
    static func backspaceBlocking(_ count: Int, pacingMicros: UInt32) {
        guard count > 0 else { return }
        let source = taggedSource()
        let key = CGKeyCode(kVK_Delete)
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            if pacingMicros > 0 { usleep(pacingMicros) }
        }
    }
}
