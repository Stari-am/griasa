import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Measures how reliably synthetic keyboard events and Accessibility writes
/// land in a given app, so the live-typing engine can be designed from numbers
/// instead of guesses.
///
/// Results are verified through whichever channel the target actually supports.
/// Accessibility is preferred: where `AXValue` is readable it is ground truth,
/// costs one call, and can't be confused by selection behavior. The ⌘A ⌘C
/// pasteboard readback is the fallback for apps that expose no accessible text
/// — but it is fragile (⌘A means "select the whole scrollback" in a terminal,
/// and an app that ignores ⌘C is indistinguishable from an empty field), so it
/// is never used when Accessibility will answer.
@MainActor
final class TypingDiagnostics: ObservableObject {
    static let shared = TypingDiagnostics()

    enum Verdict: String {
        case pass, warn, fail, info, skip

        var symbol: String {
            switch self {
            case .pass: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .fail: return "xmark.circle.fill"
            case .info: return "info.circle"
            case .skip: return "minus.circle"
            }
        }

        var tint: Color {
            switch self {
            case .pass: return .green
            case .warn: return .orange
            case .fail: return .red
            case .info, .skip: return .secondary
            }
        }
    }

    struct Row: Identifiable {
        let id = UUID()
        let test: String
        let detail: String
        let verdict: Verdict
    }

    /// How the harness finds out what actually ended up in the field.
    private enum Readback {
        case accessibility
        case clipboard
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isRunning = false
    @Published private(set) var countdown = 0
    @Published private(set) var target = ""
    @Published private(set) var status = ""
    @Published private(set) var reportPath: URL?

    private var targetPID: pid_t = 0
    private var readback: Readback = .clipboard
    /// Set when the field stops coming back empty between tests: continuing
    /// would measure leftovers, and would keep typing into the user's content.
    private var stopped = false
    /// The pasteboard channel only needs one explicit clear — see `clearField`.
    private var didInitialClipboardClear = false
    /// The pasteboard is borrowed for the whole run and handed back once.
    private var savedPasteboard: [(NSPasteboard.PasteboardType, Data)] = []

    // MARK: - Run control

    func start() {
        guard !isRunning else { return }
        rows = []
        reportPath = nil
        target = ""
        stopped = false
        didInitialClipboardClear = false
        isRunning = true
        Task { @MainActor in
            for remaining in stride(from: 5, through: 1, by: -1) {
                countdown = remaining
                status = "Switch to the target app and put the caret in an empty text field…"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            countdown = 0
            await run()
            status = rows.isEmpty ? "" : "Done."
            isRunning = false
        }
    }

    private func run() async {
        guard !IsSecureEventInputEnabled() else {
            add("Preflight", "Secure input is active — something has a password field focused. Refusing to type.", .fail)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            add("Preflight", "No frontmost application.", .fail)
            return
        }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            add("Preflight", "Griasa is still frontmost — the countdown ran out before you switched apps. Press Start and switch away.", .fail)
            return
        }
        target = app.localizedName ?? "Unknown"
        targetPID = app.processIdentifier
        savePasteboard()

        add("Target", "\(target) — \(app.bundleIdentifier ?? "no bundle id"), pid \(targetPID)", .info)

        let element = await resolveElement()
        let axReadable = probeAccessibility(element)
        readback = axReadable ? .accessibility : .clipboard
        add("Readback channel",
            axReadable
                ? "Accessibility — AXValue is ground truth, no pasteboard round-trips needed"
                : "Pasteboard ⌘A ⌘C — this app exposes no accessible text, so results are less trustworthy",
            axReadable ? .pass : .warn)

        if await preflight() {
            if axReadable { await probeAXWrite() }
            await pacingSweep()
            await textIntegrity()
            await emojiIntegrity()
            await chunkBoundary()
            await backspaceGranularity()
            await asrReplay()
        }

        _ = await clearField()
        restorePasteboard()
        writeReport(app: app)
    }

    private func add(_ test: String, _ detail: String, _ verdict: Verdict) {
        rows.append(Row(test: test, detail: detail, verdict: verdict))
        status = test
    }

    // MARK: - Target resolution

    /// Chromium-based apps (Slack, Discord, VS Code, Claude Desktop) build no
    /// accessibility tree until an assistive client asks for one, so a first
    /// failed lookup is not proof that the app has nothing to offer.
    private func resolveElement() async -> AXUIElement? {
        if let element = focusedElement() { return element }

        let app = AXUIElementCreateApplication(targetPID)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
        try? await Task.sleep(nanoseconds: 700_000_000)

        if let element = focusedElement() {
            add("Accessibility", "Tree appeared only after AXManualAccessibility was set — Chromium/Electron app", .info)
            return element
        }
        add("Accessibility", "No focused element even after AXManualAccessibility — nothing accessible to work with", .fail)
        return nil
    }

    // MARK: - Accessibility probe

    /// Returns whether `AXValue` can be read, which is what decides the
    /// readback channel.
    private func probeAccessibility(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        add("Focused element", "role: \(axString(element, kAXRoleAttribute) ?? "unknown")", .info)

        let value = axString(element, kAXValueAttribute)
        add("AX read value",
            value == nil ? "AXValue not readable" : "AXValue readable (\(value!.count) chars)",
            value == nil ? .fail : .pass)

        if let range = axRange(element) {
            add("AX read caret", "AXSelectedTextRange readable — caret \(range.location), length \(range.length)", .pass)
        } else {
            add("AX read caret", "AXSelectedTextRange not readable — caret position is invisible to us", .fail)
        }

        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        add("AX declares writable",
            settable.boolValue
                ? "AXSelectedText declared settable"
                : "AXSelectedText declared read-only — atomic replacement is unavailable, keystrokes are the only path",
            settable.boolValue ? .pass : .warn)

        return value != nil
    }

    /// Declared-settable and actually-lands disagree often enough that the
    /// write is verified for real.
    private func probeAXWrite() async {
        guard let element = focusedElement() else { return }
        guard await clearField() else { return }
        let marker = "axwrite"
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, marker as CFTypeRef)
        guard status == .success else {
            add("AX write", "AXSelectedText write refused (AXError \(status.rawValue)) — keystroke fallback required here", .warn)
            return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let seen = await fieldValue().map(normalize)
        if seen == marker {
            add("AX write", "AXSelectedText write landed and verified — atomic replacement is available", .pass)
        } else {
            add("AX write",
                "Write reported success but the field holds \(describe(seen)) — reports success, does nothing",
                .warn)
        }
    }

    // MARK: - Preflight

    /// Two things have to hold before any measurement means anything: the field
    /// starts empty, and our keystrokes reach it. Getting these wrong is what
    /// made the first run of this harness unreadable — a non-empty field turned
    /// every comparison into noise, and the report blamed the app for it.
    private func preflight() async -> Bool {
        if readback == .accessibility {
            // Refuse rather than clear. A composer that reports its empty state
            // as "\n" (Claude Desktop, Slack) must still count as empty, but a
            // field with real content is the user's data — and in a terminal
            // AXValue is the whole scrollback, so "clearing" it would fire a
            // hundred backspaces at their shell.
            let existing = normalize(axValueNow() ?? "")
            guard existing.isEmpty else {
                add("Preflight — empty field",
                    "Field holds \(describe(existing)). Put the caret in an empty text field — not a browser address bar, a terminal, or a note with content.",
                    .fail)
                return false
            }
            add("Preflight — empty field", "Field is empty", .pass)
        } else {
            _ = await clearField()
        }

        let probe = "griasaprobe"
        await typeText(probe, pacing: 3000, chunking: .graphemeSafe(maxUnits: 16))
        let seen = await fieldValue().map(normalize)

        if seen == probe {
            add("Preflight — keystrokes land", "Typed text arrives intact and is readable back", .pass)
            return true
        }
        if let seen, seen.hasSuffix(probe) {
            let leftover = seen.count - probe.count
            add("Preflight — keystrokes land",
                "Typing worked, but \(leftover) character(s) of pre-existing content survived the clear — the field wasn't empty. Pick an empty field.",
                .fail)
            return false
        }
        if seen == nil || seen?.isEmpty == true {
            add("Preflight — keystrokes land",
                readback == .clipboard
                    ? "No answer to ⌘C. Either nothing was typed, or this app doesn't respond to ⌘A/⌘C — indistinguishable through this channel."
                    : "Field is still empty after typing — synthetic keystrokes are not reaching this app.",
                .fail)
            return false
        }
        add("Preflight — keystrokes land", "Field holds unrelated content: \(describe(seen))", .fail)
        return false
    }

    // MARK: - Pacing sweep

    private func pacingSweep() async {
        // Distinct rotating characters so a loss can be localized, and nothing
        // an app might interpret (no newline, no leading slash, no @).
        let sample = String(repeating: "abcdefghij0123456789", count: 6)
        // Slowest first: when a fast step fails, the threshold is already known.
        for pacing: UInt32 in [8000, 3000, 1000, 500, 0] {
            let label = pacing == 0 ? "no delay" : "\(Double(pacing) / 1000) ms"
            guard await ensureClear("Pacing — \(label)") else { return }
            await typeText(sample, pacing: pacing, chunking: .graphemeSafe(maxUnits: 16))
            let seen = normalize(await fieldValue() ?? "")
            let distance = Self.editDistance(sample, seen)
            let detail = distance == 0
                ? "120/120 characters landed"
                : "\(seen.count)/120 characters landed, edit distance \(distance)"
            add("Pacing — \(label)", detail, distance == 0 ? .pass : (distance <= 2 ? .warn : .fail))
        }
    }

    // MARK: - Unicode integrity

    /// Emoji are deliberately absent here. Rich-text composers (Telegram, Slack)
    /// turn them into inline objects and report them in `AXValue` as U+FFFC or
    /// as newlines, so mixing them in makes an otherwise clean result read as
    /// corruption. Emoji get their own test, with its own verdict rules.
    private func textIntegrity() async {
        let sample = "привет café cafe\u{0301} 日本語 ok"
        guard await ensureClear("Text integrity") else { return }
        await typeText(sample, pacing: 3000, chunking: .graphemeSafe(maxUnits: 16))
        let seen = normalize(await fieldValue() ?? "")
        if seen == sample {
            add("Text integrity", "Cyrillic, combining marks and CJK all survived exactly", .pass)
        } else if seen.precomposedStringWithCanonicalMapping == sample.precomposedStringWithCanonicalMapping {
            add("Text integrity",
                "Equal only after NFC normalization — this app rewrites what we type, so our model of the text drifts",
                .warn)
        } else {
            add("Text integrity", "Corrupted: got \(describe(seen))", .fail)
        }
    }

    private func emojiIntegrity() async {
        let sample = "x✅y👍🏽z"
        guard await ensureClear("Emoji integrity") else { return }
        await typeText(sample, pacing: 3000, chunking: .graphemeSafe(maxUnits: 16))
        let seen = normalize(await fieldValue() ?? "")
        if seen == sample {
            add("Emoji integrity", "Emoji, including one with a skin-tone modifier, survived exactly", .pass)
        } else if containsPlaceholder(seen) {
            add("Emoji integrity",
                "Inconclusive: this app reports emoji as placeholder objects in AXValue (\(describe(seen))), so emoji fidelity can't be judged through this channel",
                .warn)
        } else {
            add("Emoji integrity", "Corrupted: got \(describe(seen))", .fail)
        }
    }

    /// U+FFFC (object replacement) means the app swapped an inline object in —
    /// its own emoji rendering, not our damage. U+FFFD (replacement character)
    /// is the opposite: something genuinely arrived malformed.
    private func containsPlaceholder(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value == 0xFFFC || $0 == "\n" }
    }

    // MARK: - Chunk boundary

    private func chunkBoundary() async {
        // 15 ASCII characters put the emoji's surrogate pair astride the
        // 16-unit boundary that `LiveTyper.type` chunks on today.
        let head = String(repeating: "a", count: 15)
        let tail = "tail"
        let sample = head + "😀" + tail
        for policy in [LiveTyper.ChunkPolicy.fixedUTF16(16), .graphemeSafe(maxUnits: 16)] {
            let name: String
            if case .fixedUTF16 = policy {
                name = "Chunking — fixed 16 units (old behavior)"
            } else {
                name = "Chunking — grapheme-safe (shipping)"
            }
            guard await ensureClear(name) else { return }
            await typeText(sample, pacing: 3000, chunking: policy)
            let seen = normalize(await fieldValue() ?? "")

            // Judged structurally, not by equality: an app that renders the
            // emoji as an inline object reports a placeholder here even when
            // nothing was lost. What matters is whether text disappeared.
            guard seen == sample || (seen.hasPrefix(head) && seen.hasSuffix(tail)) else {
                add(name, "Text lost after the boundary: got \(describe(seen))", .fail)
                continue
            }
            let middle = String(seen.dropFirst(head.count).dropLast(tail.count))
            if middle == "😀" {
                add(name, "Surrogate pair survived the boundary intact", .pass)
            } else if middle.unicodeScalars.contains(where: { $0.value == 0xFFFD }) {
                add(name, "Surrogate pair was split — a replacement character arrived instead", .fail)
            } else {
                add(name,
                    "No text lost, but the app substituted \(middle.debugDescription) for the emoji, so pair integrity can't be judged through this channel",
                    .warn)
            }
        }
    }

    // MARK: - Backspace granularity

    private func backspaceGranularity() async {
        // A decomposed grapheme distinguishes the two cases cleanly: deleting a
        // cluster leaves "ab", deleting one UTF-16 unit leaves "abe".
        guard await ensureClear("Backspace granularity") else { return }
        await typeText("abe\u{0301}", pacing: 3000, chunking: .graphemeSafe(maxUnits: 16))
        let setup = normalize(await fieldValue() ?? "").precomposedStringWithCanonicalMapping
        guard setup == "abé" else {
            add("Backspace granularity",
                "Could not set up the test — the combining sequence typed as \(describe(setup))",
                .skip)
            return
        }
        // A pasteboard read ends with everything selected, so the next Delete
        // would wipe the lot instead of one grapheme. The Accessibility channel
        // never touches the selection.
        if readback == .clipboard { await collapseToEnd() }
        await deleteBackwards(1, pacing: 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let after = normalize(await fieldValue() ?? "").precomposedStringWithCanonicalMapping
        switch after {
        case "ab":
            add("Backspace granularity", "One Delete removes a whole grapheme cluster — count backspaces in characters", .pass)
        case "abe":
            add("Backspace granularity",
                "One Delete removes a single UTF-16 unit — a backspace count computed in characters under-deletes here, leaving fragments of any multi-unit grapheme",
                .fail)
        default:
            add("Backspace granularity", "Unexpected result: \(describe(after))", .warn)
        }
    }

    // MARK: - ASR replay

    private func asrReplay() async {
        let partials = ["привет", "привет как", "привет как дела"]
        let polished = "Привет, как дела?"
        guard await ensureClear("ASR replay (shipping algorithm)") else { return }

        var typedSoFar = ""
        for partial in partials {
            await applyProductionDiff(from: typedSoFar, to: partial)
            typedSoFar = partial
            try? await Task.sleep(nanoseconds: 300_000_000)  // realistic partial cadence
        }

        // The headline cost: what the post-release correction actually sends.
        let common = commonPrefixLength(typedSoFar, polished)
        let backspaces = typedSoFar.count - common
        let retyped = polished.count - common
        let started = Date()
        await applyProductionDiff(from: typedSoFar, to: polished)
        let elapsed = Date().timeIntervalSince(started)

        try? await Task.sleep(nanoseconds: 300_000_000)
        let seen = normalize(await fieldValue() ?? "")
        let correct = seen == polished
        let detail = "Final correction sent \(backspaces) backspaces + \(retyped) characters "
            + "to change \(typedSoFar.count) characters into \(polished.count), in \(String(format: "%.2f", elapsed)) s. "
            + (correct ? "End state correct." : "End state WRONG: \(describe(seen))")
        add("ASR replay (shipping algorithm)", detail, correct ? .warn : .fail)
    }

    // MARK: - Typing primitives

    /// Runs off the main actor so pacing can use `usleep`, which is accurate
    /// below a millisecond where `Task.sleep` is not.
    private func typeText(_ text: String, pacing: UInt32, chunking: LiveTyper.ChunkPolicy) async {
        await Task.detached(priority: .userInitiated) {
            LiveTyper.typeBlocking(text, pacingMicros: pacing, chunking: chunking)
        }.value
        try? await Task.sleep(nanoseconds: 300_000_000)  // let the target drain its event queue
    }

    private func deleteBackwards(_ count: Int, pacing: UInt32) async {
        await Task.detached(priority: .userInitiated) {
            LiveTyper.backspaceBlocking(count, pacingMicros: pacing)
        }.value
    }

    /// Exactly what production does today — measured, not reimplemented.
    private func applyProductionDiff(from old: String, to new: String) async {
        await Task.detached(priority: .userInitiated) {
            LiveTyper.applyDiff(from: old, to: new)
        }.value
    }

    // MARK: - Field access

    /// Clears the field with backspaces only, and confirms it.
    ///
    /// ⌘A is deliberately absent from this path. In Slack and Telegram ⌘A in a
    /// composer selects something other than the composer's text, and the
    /// Delete that follows moves focus out of the field — after which no
    /// synthetic keystroke lands at all. That is exactly what made the second
    /// run of this harness unreadable: Telegram typed fine until the first
    /// clear and reported 0/120 characters on every test after it.
    private func clearField() async -> Bool {
        switch readback {
        case .accessibility:
            // Backspace counts may not match character counts (that's test 7),
            // so converge instead of assuming.
            for _ in 0..<3 {
                let current = normalize(axValueNow() ?? "")
                if current.isEmpty { return true }
                await deleteBackwards(current.count + 2, pacing: 2000)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return normalize(axValueNow() ?? "").isEmpty
        case .clipboard:
            // A pasteboard read ends with everything selected, so whatever we
            // type next replaces it. Only the very first pass needs an explicit
            // clear, and that one has no reading to piggyback on.
            if !didInitialClipboardClear {
                didInitialClipboardClear = true
                sendCommand(kVK_ANSI_A)
                try? await Task.sleep(nanoseconds: 200_000_000)
                await deleteBackwards(1, pacing: 0)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return true  // unverifiable through this channel; the probe gate catches leftovers
        }
    }

    /// Clears before a test, and stops the run rather than reporting nonsense
    /// when the field won't come back empty.
    private func ensureClear(_ test: String) async -> Bool {
        if stopped { return false }
        if await clearField() { return true }
        stopped = true
        add(test, "Stopped: the field no longer clears between tests, so any further measurement would be reading leftovers.", .skip)
        return false
    }

    private func fieldValue() async -> String? {
        switch readback {
        case .accessibility: return axValueNow()
        case .clipboard: return await clipboardValue()
        }
    }

    /// The focused element is re-fetched every time: apps recreate their text
    /// views, and a stale AXUIElement silently answers about a dead view.
    private func axValueNow() -> String? {
        guard let element = focusedElement() else { return nil }
        return axString(element, kAXValueAttribute)
    }

    /// Byte-exact pasteboard readback. `SelectionGrabber.grab()` can't be
    /// reused: it trims whitespace and maps empty to nil, both of which destroy
    /// measurements.
    private func clipboardValue() async -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        sendCommand(kVK_ANSI_A)
        try? await Task.sleep(nanoseconds: 200_000_000)
        sendCommand(kVK_ANSI_C)
        for _ in 0..<20 {  // up to ~1 s for slow apps
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != before {
                return pasteboard.string(forType: .string)
            }
        }
        return nil  // empty field, or the app doesn't answer ⌘C
    }

    private func collapseToEnd() async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_RightArrow)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    private func sendCommand(_ keyCode: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func savePasteboard() {
        let pasteboard = NSPasteboard.general
        savedPasteboard = pasteboard.pasteboardItems?.compactMap { item in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        } ?? []
    }

    private func restorePasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        for (type, data) in savedPasteboard {
            pasteboard.setData(data, forType: type)
        }
        savedPasteboard = []
    }

    // MARK: - Accessibility helpers

    private func focusedElement() -> AXUIElement? {
        let app = AXUIElementCreateApplication(targetPID)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)  // type checked above
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String
        else { return nil }
        return text
    }

    private func axRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }  // type checked above
        return range
    }

    // MARK: - Comparison helpers

    /// Trims surrounding whitespace and newlines. Rich-text composers report an
    /// empty box as "\n" (Claude Desktop, Slack) and often keep a trailing
    /// newline after text is typed, so raw equality would fail on a field that
    /// is behaving perfectly. None of the test samples begin or end with
    /// whitespace, so this cannot hide a lost character.
    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func describe(_ text: String?) -> String {
        guard let text else { return "nothing (empty or unreadable)" }
        if text.isEmpty { return "an empty field" }
        let shown = text.count > 60 ? String(text.prefix(60)) + "…" : text
        return "\"\(shown)\" (\(text.count) chars, \(text.utf16.count) UTF-16 units)"
    }

    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        var common = 0
        while common < aChars.count && common < bChars.count && aChars[common] == bChars[common] { common += 1 }
        return common
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                current[j] = min(previous[j] + 1,
                                 current[j - 1] + 1,
                                 previous[j - 1] + (aChars[i - 1] == bChars[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }

    // MARK: - Report

    var reportMarkdown: String {
        var lines = ["# Typing diagnostics — \(target)", "",
                     Date().formatted(date: .long, time: .standard), "",
                     "| Verdict | Test | Detail |", "| --- | --- | --- |"]
        for row in rows {
            let detail = row.detail.replacingOccurrences(of: "|", with: "\\|")
            lines.append("| \(row.verdict.rawValue) | \(row.test) | \(detail) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func writeReport(app: NSRunningApplication) {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Griasa Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeName = (app.localizedName ?? "app").replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent("typing-\(safeName)-\(formatter.string(from: Date())).md")
        do {
            try reportMarkdown.write(to: url, atomically: true, encoding: .utf8)
            reportPath = url
        } catch {
            NSLog("Griasa: failed to write typing diagnostics report: %@", error.localizedDescription)
        }
    }
}

// MARK: - View

struct TypingDiagnosticsView: View {
    @ObservedObject private var diagnostics = TypingDiagnostics.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HubCard(icon: "keyboard", title: "Typing reliability test", tint: .blue) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Measures how much of what Griasa types actually arrives in another app, and whether that app allows atomic text replacement. Run it once per app you care about.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 4) {
                            Label("Press Start, then switch to the target app within 5 seconds.", systemImage: "1.circle")
                            Label("Put the caret in an EMPTY text field — its contents get cleared repeatedly.", systemImage: "2.circle")
                            Label("Don't touch the keyboard until the results stop appearing.", systemImage: "3.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text("Good targets: a chat message box, an empty note, a blank TextEdit document. Bad targets: a browser address bar (it autocompletes), a terminal (⌘A selects the whole scrollback), or any field that already has text.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button("Start") { diagnostics.start() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(diagnostics.isRunning)
                            if diagnostics.countdown > 0 {
                                Text("\(diagnostics.countdown)")
                                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.orange)
                                    .contentTransition(.numericText())
                            } else if diagnostics.isRunning {
                                ProgressView().controlSize(.small)
                            }
                            if !diagnostics.status.isEmpty {
                                Text(diagnostics.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }

                if !diagnostics.rows.isEmpty {
                    HubCard(icon: "list.bullet.rectangle", title: "Results — \(diagnostics.target)", tint: .purple) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(diagnostics.rows) { row in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: row.verdict.symbol)
                                        .foregroundStyle(row.verdict.tint)
                                        .font(.caption)
                                        .frame(width: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.test).font(.callout.weight(.medium))
                                        Text(row.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    } trailing: {
                        HStack(spacing: 6) {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(diagnostics.reportMarkdown, forType: .string)
                            }
                            if let path = diagnostics.reportPath {
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([path])
                                }
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(16)
        }
    }
}
