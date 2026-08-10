import AppKit

/// Owns the live-dictation edit stream: what Griasa believes it has typed into
/// the target app, in what order edits are applied, and when to stop touching
/// the text because the user has moved on.
///
/// Ordering used to be left to `Task { @MainActor }` per partial, which has no
/// FIFO guarantee — once two partials were transposed, Griasa's model of the
/// field no longer described the field, and every later diff was computed
/// against a fiction. Here order is carried by an array under a lock, not by the
/// scheduler, so it can't be lost. The drain applies only the *latest* queued
/// text: safe because `PartialStabilizer` guarantees monotonic growth, and
/// cheaper, since a burst of partials collapses into one edit.
///
/// The type is main-actor isolated, and the two members that genuinely are not
/// say so individually: `submit(_:)`, which the recognizer calls from its own
/// queue, and the state that call touches. Marking the class instead of each
/// property means the compiler — not a convention — enforces that everything
/// else stays on the main actor.
@MainActor
final class TypingSession {
    /// `nonisolated` so the recognizer's callback can reach the instance without
    /// hopping actors first. Safe without the `unsafe` spelling: a main-actor
    /// class is implicitly Sendable, and this is an immutable reference.
    nonisolated static let shared = TypingSession()

    /// Creating the session touches nothing but its own defaults, so it need not
    /// happen on the main actor — and must not, or `shared` above could only be
    /// reached from main-actor code.
    nonisolated private init() {}

    /// What `AppState` should do with the polished transcription.
    enum Outcome {
        /// The live text was corrected in place; nothing more to do.
        case corrected
        /// The user typed or switched away — their text was left untouched.
        case keptAsTyped
        /// Nothing was live-typed, so the caller should insert the text itself.
        case nothingTyped
    }

    /// The intake side, reachable from any thread and synchronised by `lock`
    /// rather than by the actor. `nonisolated(unsafe)` states exactly that: the
    /// compiler is being told the synchronisation is the lock's job here, and
    /// nowhere else in this type.
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var queue: [String] = []
    private nonisolated(unsafe) var enabled = false

    /// Everything below is main-actor isolated by the annotation on the class.
    private var typed = ""
    private var active = false
    private var abandoned = false
    private var draining = false
    private var targetPID: pid_t?
    private var interferenceMonitor: Any?

    // MARK: - Session lifecycle

    @MainActor
    func begin(liveTyping: Bool) {
        end()
        typed = ""
        active = true
        abandoned = false
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lock.lock()
        queue = []
        enabled = liveTyping
        lock.unlock()
        TypingTrace.log("session begin, liveTyping=\(liveTyping) target=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") pid=\(targetPID ?? -1)")
        guard liveTyping else { return }

        // Modifier keys arrive as .flagsChanged, so holding the dictation hotkey
        // isn't mistaken for typing.
        interferenceMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { event in
            guard !LiveTyper.isSynthetic(event) else { return }
            Task { @MainActor in TypingSession.shared.noteInterference(event.type) }
        }
    }

    @MainActor
    func typedText() -> String { typed }

    /// Applies the polished transcription, or reports why it wasn't applied.
    @MainActor
    func finish(with polished: String) -> Outcome {
        defer { end() }
        guard active else { return .nothingTyped }
        guard !typed.isEmpty else { return .nothingTyped }
        guard !abandoned, isTargetStillFocused() else { return .keptAsTyped }
        LiveTyper.applyDiff(from: typed, to: polished)
        typed = polished
        return .corrected
    }

    /// Ends the session without typing anything further.
    @MainActor
    func end() {
        active = false
        if let interferenceMonitor {
            NSEvent.removeMonitor(interferenceMonitor)
            self.interferenceMonitor = nil
        }
        lock.lock()
        queue = []
        enabled = false
        lock.unlock()
    }

    // MARK: - Edit stream

    /// Callable from any thread — the recognizer's callbacks arrive on its own
    /// queue, and hopping to the main actor per partial is what lost ordering.
    nonisolated func submit(_ text: String) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        queue.append(text)
        lock.unlock()
        // Reached through `shared` rather than by capturing `self`: a capture
        // would have to cross into the main actor and so demand the whole type be
        // Sendable, which would mean vouching for state the lock does not cover.
        Task { @MainActor in TypingSession.shared.drain() }
    }

    @MainActor
    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while true {
            lock.lock()
            // Monotonic growth means the newest value supersedes the rest.
            let latest = queue.last
            queue = []
            lock.unlock()
            guard let latest else { return }
            apply(latest)
        }
    }

    @MainActor
    private func apply(_ text: String) {
        // NSLog reaches nowhere from a Finder-launched app on this machine, so
        // these used to be silent exactly when they mattered.
        guard active, !abandoned else {
            TypingTrace.log("apply dropped — active=\(active) abandoned=\(abandoned)")
            return
        }
        guard isTargetStillFocused() else {
            TypingTrace.log("apply dropped — focus moved to \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            abandoned = true
            return
        }
        guard text != typed else { return }
        if text.count < typed.count {
            // The stabilizer is append-only; if this ever fires, that invariant
            // broke and the user is watching their text get deleted.
            TypingTrace.log("apply SHRANK \(typed.count) -> \(text.count) chars — stabilizer invariant broken")
        }
        LiveTyper.applyDiff(from: typed, to: text)
        typed = text
    }

    // MARK: - Interference

    /// Once the user has acted, their text wins. Forcing a better transcript
    /// into a document that has moved on is not a trade worth making — the
    /// polished version still reaches History, so nothing is actually lost.
    @MainActor
    private func noteInterference(_ type: NSEvent.EventType) {
        // Logging every event here wrote one line per keystroke. A monitor that
        // outlived its session then filled the trace with 2505 of them and
        // pushed the dictation history out of the file — the diagnostics
        // destroyed the evidence they exist to preserve. One line per session.
        guard active else {
            // A session that ended without reaching end() left this monitor
            // watching every keystroke on the machine. Tear it down on first
            // sight rather than trusting every exit path to be perfect.
            if let interferenceMonitor {
                TypingTrace.log("interference monitor outlived its session — removed")
                NSEvent.removeMonitor(interferenceMonitor)
                self.interferenceMonitor = nil
            }
            return
        }
        guard !abandoned else { return }
        TypingTrace.log("interference — user acted (event type \(type.rawValue)), keeping their text")
        abandoned = true
        if !typed.isEmpty {
            SnippetHUD.shared.flash("✏️ Kept what you typed — dictation won't overwrite it")
        }
    }

    @MainActor
    private func isTargetStillFocused() -> Bool {
        guard let targetPID else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
    }
}
