import AppKit
import Carbon.HIToolbox

/// Watches typing everywhere and expands snippet abbreviations in place:
/// the typed trigger is erased with synthetic backspaces and the rendered
/// template is pasted. Uses the same NSEvent global monitors as hotkeys
/// (Accessibility permission), delivered on the main thread.
@MainActor
final class SnippetExpander {
    static let shared = SnippetExpander()

    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var clickMonitor: Any?
    private var buffer = ""
    /// True while we're erasing/pasting — our own synthetic keystrokes must
    /// not feed the buffer or retrigger a match.
    private var expanding = false

    // MARK: - Inline ask (`;ai … ;;`)

    /// Opens an inline question. Unlike a stored snippet, which fires the moment
    /// its abbreviation is typed, this one has to keep reading — the question
    /// comes *after* the trigger — so it needs a terminator.
    static let askOpener = ";ai"
    static let askCloser = ";;"
    /// The physical keys behind `;ai` and `;;`. Matching the *characters* tied
    /// the trigger to a Latin layout, which is backwards for a feature whose
    /// whole point is asking a question in the language you're already typing:
    /// on a Russian layout those same keys produce "жфи" and "жж", so `;ai`
    /// could only ever be reached by switching layout twice mid-question.
    private static let askOpenerCodes = [kVK_ANSI_Semicolon, kVK_ANSI_A, kVK_ANSI_I]
    private static let askCloserCodes = [kVK_ANSI_Semicolon, kVK_ANSI_Semicolon]
    /// The key codes behind `buffer`, so the trigger can be recognized by the
    /// keys pressed rather than the letters they happened to produce.
    private var codes: [Int] = []
    /// Everything typed since the opener, terminator included. nil when not
    /// capturing.
    private var asking: String?
    /// A question long enough to hit this is a mistake, not a question.
    private let askLimit = 4000
    /// Only ever logged as a count — enough to tell "the monitor is dead" from
    /// "the trigger didn't match", without writing what was typed to disk.
    private var strokeCount = 0

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "snippetExpansionEnabled") as? Bool ?? true
    }

    /// The parts of a keystroke this class reasons about, captured off the
    /// NSEvent so it can cross to the main actor as a value.
    struct Keystroke: Sendable {
        let keyCode: Int
        let characters: String
        let hasCommandOrControl: Bool

        init(_ event: NSEvent) {
            keyCode = Int(event.keyCode)
            characters = event.characters ?? ""
            hasCommandOrControl = !event.modifierFlags.intersection([.command, .control]).isEmpty
        }
    }

    /// Keystrokes reach the monitor already in order, on the main thread.
    /// Parking them here preserves that order across the hop to the main actor
    /// — which `Task { @MainActor in … }` per event does **not** guarantee.
    /// Without this the buffer assembled out of order, so ";ai" could arrive as
    /// "a;i" and never match, and a captured question came out scrambled.
    private final class KeystrokeQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Keystroke] = []

        func append(_ item: Keystroke) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        func next() -> Keystroke? {
            lock.lock()
            defer { lock.unlock() }
            return items.isEmpty ? nil : items.removeFirst()
        }
    }

    private let strokes = KeystrokeQueue()
    private var draining = false

    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.enqueue(event)
        }
        // Typing into Griasa's own windows (hub, settings) — observe only;
        // never swallow the event.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.enqueue(event)
            return event
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.abandon(reason: "click") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.abandon(reason: "app switch") }
        }
        TypingTrace.log("snippet expander armed, enabled=\(Self.isEnabled)")
    }

    /// The caret has moved somewhere we can't reason about. Clearing the buffer
    /// isn't enough: a capture left open here would erase three characters that
    /// were never typed in whatever field the user landed in.
    private func abandon(reason: String) {
        guard !expanding else { return }
        reset(reason: reason)
    }

    private nonisolated func enqueue(_ event: NSEvent) {
        strokes.append(Keystroke(event))
        Task { @MainActor in self.drainStrokes() }
    }

    /// Order is carried by the queue, not by task scheduling, so it survives
    /// however the main actor happens to interleave the drains.
    private func drainStrokes() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while let stroke = strokes.next() {
            handle(stroke)
        }
    }

    private func handle(_ stroke: Keystroke) {
        strokeCount += 1
        if strokeCount == 1 || strokeCount % 100 == 0 {
            TypingTrace.log("snippet expander saw \(strokeCount) keystrokes")
        }
        guard Self.isEnabled, !expanding else { return }
        // Live dictation types synthetic keystrokes — they'd pollute the
        // buffer and could even spell an abbreviation.
        guard AppState.shared.dictationStatus == .idle else {
            reset(reason: "dictation active")
            return
        }
        if stroke.hasCommandOrControl {
            // Switching input source is ⌃Space (or ⌘Space) — the one shortcut a
            // bilingual user has to press *inside* a question. Treating it like
            // ⌘V and dropping the capture is what made `;ai` look broken.
            if stroke.keyCode == kVK_Space { return }
            reset(reason: "⌘/⌃ shortcut")
            return
        }
        switch stroke.keyCode {
        case kVK_Delete:
            if asking != nil {
                // Backspacing past the opener abandons the question.
                if asking!.isEmpty { cancelAsk(quietly: true, reason: "backspaced past opener") }
                else { asking!.removeLast() }
            } else if !buffer.isEmpty {
                buffer.removeLast()
            }
            if !codes.isEmpty { codes.removeLast() }
            return
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            // Moving the caret breaks the assumption that what we'd erase sits
            // immediately behind it, so the capture can't survive it.
            reset(reason: "caret moved")
            return
        default:
            break
        }
        let chars = stroke.characters
        guard !chars.isEmpty,
              !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return }

        codes.append(stroke.keyCode)
        if codes.count > 8 { codes.removeFirst(codes.count - 8) }

        if asking != nil {
            asking! += chars
            if asking!.count > askLimit {
                cancelAsk(quietly: false, reason: "question too long")
                return
            }
            if codes.hasSuffix(Self.askCloserCodes) { fireAsk() }
            return
        }

        buffer += chars
        if buffer.count > 64 { buffer.removeFirst(buffer.count - 64) }

        if codes.hasSuffix(Self.askOpenerCodes) {
            beginAsk()
            return
        }

        for snippet in SnippetStore.shared.active
        where !snippet.abbreviation.isEmpty && buffer.hasSuffix(snippet.abbreviation) {
            expand(snippet)
            return
        }
    }

    private func reset(reason: String) {
        // Dropping a live capture in silence is what turned every one of these
        // cases into "the ;ai snippet doesn't work".
        if asking != nil { cancelAsk(quietly: false, reason: reason) }
        buffer = ""
        codes = []
    }

    // MARK: - Inline ask

    private func beginAsk() {
        buffer = ""
        codes = []
        guard AIFormatter.isConfigured else {
            // Say so now rather than after the user has typed out a question.
            TypingTrace.log("ask refused — no AI provider configured")
            SnippetHUD.shared.flash("✗ \(Self.askOpener) needs an AI provider — Settings → AI & Actions", seconds: 3)
            return
        }
        asking = ""
        TypingTrace.log("ask opened")
        SnippetHUD.shared.show("✨ \(Self.askOpener) — type your question, end with \(Self.askCloser)")
    }

    private func cancelAsk(quietly: Bool, reason: String) {
        TypingTrace.log("ask canceled — \(reason)")
        asking = nil
        if quietly {
            SnippetHUD.shared.hide()
        } else {
            SnippetHUD.shared.flash("\(Self.askOpener) canceled — \(reason)", seconds: 2)
        }
    }

    /// The closer has just been typed: erase the whole `;ai … ;;` run and put
    /// the answer in its place.
    private func fireAsk() {
        guard let typed = asking else { return }
        asking = nil
        let question = String(typed.dropLast(Self.askCloser.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let eraseCount = Self.askOpener.count + typed.count

        guard !question.isEmpty else {
            cancelAsk(quietly: false, reason: "no question typed")
            return
        }

        expanding = true
        buffer = ""
        codes = []
        TypingTrace.log("ask firing — question=\(question.count) chars, erasing \(eraseCount)")
        Task { @MainActor in
            await Self.sendBackspaces(eraseCount)
            SnippetHUD.shared.show("✨ Thinking…")
            do {
                let answer = try await AIFormatter.complete(
                    system: Prompts.text(.inlineAsk),
                    user: question,
                    tier: .fast,
                    maxTokens: 1024,
                    timeout: 60,
                    // A consent dialog would steal focus from the field the
                    // answer is about to land in.
                    allowCloudFallback: false)
                SnippetHUD.shared.hide()
                let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                TypingTrace.log("ask answered \(text.count) chars")
                // An empty answer must still put back what was erased.
                TextInserter.insert(text.isEmpty ? Self.askOpener + typed : text)
            } catch {
                TypingTrace.log("ask FAILED — \(error.localizedDescription)")
                SnippetHUD.shared.flash("✗ \(Self.askOpener) failed — \(error.localizedDescription)", seconds: 4)
                TextInserter.insert(Self.askOpener + typed)
                AppState.shared.lastError = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            expanding = false
        }
    }

    private func expand(_ snippet: Snippet) {
        expanding = true
        buffer = ""
        codes = []
        let eraseCount = snippet.abbreviation.count
        TypingTrace.log("snippet expanding \(snippet.abbreviation)")
        Task { @MainActor in
            await Self.sendBackspaces(eraseCount)
            // AI-backed renders can take seconds after the trigger is already
            // erased — show the HUD only once the wait becomes noticeable.
            let hud = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                SnippetHUD.shared.show("✨ Expanding \(snippet.abbreviation)…")
            }
            do {
                let text = try await SnippetEngine.render(snippet.template)
                hud.cancel()
                SnippetHUD.shared.hide()
                TypingTrace.log("snippet \(snippet.abbreviation) rendered \(text.count) chars")
                TextInserter.insert(text)
            } catch {
                hud.cancel()
                TypingTrace.log("snippet \(snippet.abbreviation) failed: \(error.localizedDescription)")
                // Put the typed trigger back so nothing is lost, and say why.
                SnippetHUD.shared.flash("✗ \(snippet.abbreviation) couldn't expand")
                TextInserter.insert(snippet.abbreviation)
                AppState.shared.lastError = error.localizedDescription
            }
            // TextInserter's paste + pasteboard restore need a beat before we
            // start listening again.
            try? await Task.sleep(nanoseconds: 400_000_000)
            expanding = false
        }
    }

    private static func sendBackspaces(_ count: Int) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_Delete)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            else { continue }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
        // Let the target app apply the last erase before the paste lands.
        try? await Task.sleep(nanoseconds: 60_000_000)
    }
}

private extension Array where Element == Int {
    func hasSuffix(_ tail: [Int]) -> Bool {
        count >= tail.count && Array(suffix(tail.count)) == tail
    }
}
