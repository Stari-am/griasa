import Foundation

/// Turns each chat day into a summary and promises, one day at a time, off the
/// main thread's way: the model call is awaited, the rest is quick.
///
/// What it trusts and does not: the model says which message holds a promise,
/// the task, the deadline words and the quote — never who made it. The owner is
/// the message's author (`ChatDayText.owner`), `isMine` is what the source
/// said, and a promise whose quote is not in that message is dropped.
///
/// A day the model cannot finish goes back to `pending` and is tried again by
/// `resume()` — at launch, and when the model becomes available — until
/// `ConversationStore.maxAttempts` tries are used up. It is never marked `done`
/// for a failure: that would lose its promises for good.
///
/// Logs carry counts and ids, never message text or names.
@MainActor
final class ConversationProcessor: ObservableObject {
    static let shared = ConversationProcessor()

    /// Days finished and days queued in this run; nil when idle.
    @Published var progress: (done: Int, total: Int)?

    /// Context for a day's first new message, and the most one request renders.
    static let contextMessages = 20
    static let requestBudget = 12_000
    /// Two failed days in a row mean the model is not there; stop instead of
    /// spending every day's attempts on it. `resume()` starts again.
    private static let stopAfterFailures = 2

    /// True after the person pressed Cancel, until the next import or an
    /// explicit Resume: opening the tab must not quietly start the work again.
    @Published private(set) var cancelledByUser = false
    /// Whether the queue is working now; retention waits for it to finish.
    var isRunning: Bool { running }
    /// Set while retention rewrites the database file; nothing starts then.
    var maintenance = false

    private var store: ConversationStore?
    private var queue: [(chat: Int64, day: String)] = []
    private var running = false
    private var cancelled = false
    private var done = 0
    private var total = 0

    private struct Unreadable: Error {}

    /// Whether there is a model to ask now; see `ConversationModelGate`.
    private static var modelReady: Bool {
        let config = LLMConfig.current()
        return ConversationModelGate.mayRun(providerIsLocal: config.provider == .custom,
                                            providerIsConfigured: config.isConfigured,
                                            localEngineReady: LocalModelSetup.shared.isReady)
    }

    private func openStore() -> ConversationStore? {
        if store == nil { store = try? ConversationStore.live() }
        return store
    }

    /// An import or an accepted batch: new work, which ends a Cancel.
    func enqueue(_ days: [(Int64, String)]) {
        cancelledByUser = false
        enqueueDays(days)
    }

    private func enqueueDays(_ days: [(Int64, String)]) {
        for (chat, day) in days where !queue.contains(where: { $0.chat == chat && $0.day == day }) {
            queue.append((chat, day))
            total += 1
        }
        guard !queue.isEmpty else { return }
        progress = (done, total)
        cancelled = false
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    /// Puts days a quit or a crash cut off back in line and queues everything
    /// waiting. Safe to call whenever: it does nothing while the queue runs, or
    /// after a Cancel (until `explicit`, the Resume button).
    func resume(explicit: Bool = false) {
        if explicit { cancelledByUser = false }
        guard !cancelledByUser, !maintenance,
              ManagedPolicy.live.conversationsEnabled, Self.modelReady, let store = openStore() else { return }
        if !running { _ = try? store.resetInterrupted() }
        guard let waiting = try? store.pendingDays(), !waiting.isEmpty else { return }
        enqueueDays(waiting.map { ($0.chat, $0.day) })
    }

    /// The person's Retry on a failed day: attempts start over.
    func retry(chat: Int64, day: String) {
        guard let store = openStore() else { return }
        _ = try? store.resetFailed(chat: chat, day: day)
        resume(explicit: true)
    }

    /// Stops after the day in hand; the rest stay `pending` for `resume()`.
    func cancel() {
        cancelled = true
        cancelledByUser = true
        queue.removeAll()
    }

    // MARK: Queue

    private func drain() async {
        var failures = 0
        while !cancelled, !queue.isEmpty, ManagedPolicy.live.conversationsEnabled, Self.modelReady,
              failures < Self.stopAfterFailures {
            let next = queue.removeFirst()
            switch await process(chat: next.chat, day: next.day) {
            case .finished: failures = 0
            case .skipped: break
            case .retry: failures += 1
            }
            done += 1
            progress = (done, total)
        }
        queue.removeAll()
        // A release that met a locked database leaves a day `processing`; nothing
        // is working now, so put it back (or to `failed` if its tries are used up).
        _ = try? store?.resetInterrupted()
        running = false
        done = 0
        total = 0
        progress = nil
    }

    private enum Outcome { case finished, skipped, retry }

    private func process(chat: Int64, day: String) async -> Outcome {
        guard let store, (try? store.dayState(chat: chat, day: day)) == .pending,
              let info = try? store.chat(chat) else { return .skipped }
        do { try store.beginAttempt(chat: chat, day: day) } catch { return .skipped }
        do {
            let all = try store.messages(chat: chat, day: day)
            let fresh = try store.unprocessedMessages(chat: chat, day: day)
            guard let last = fresh.last else {
                try store.complete(chat: chat, day: day, summary: nil, processedUpTo: nil)
                return .finished
            }
            let title = info.ref.title
            let name: (StoredMessage) -> String = { $0.authorName.isEmpty ? title : $0.authorName }

            // Both questions are asked before anything is saved, so a failure in
            // the second leaves nothing half-done for the retry to repeat.
            var summary: String?
            if all.count >= 3 {
                summary = try await summarize(all, names: name)
            }
            let promises = try await findPromises(fresh, chat: chat, day: day, chatTitle: title, names: name)

            var added = 0
            var seen = CommitmentStore.shared.commitments
                .filter { $0.sourceChatID == String(chat) }
                .map { PromiseDuplicate.entry(text: $0.text, owner: $0.owner, quote: $0.sourceQuote) }
            let people = PersonStore.shared.people.map { (name: $0.name, handles: $0.handles) }
            let myName = ParticipantRoster.shared.myName
            for kept in promises.kept {
                let m = kept.message
                let match = m.isMine ? ChatIdentity.Match.unknown
                    : ChatIdentity.person(forAuthorID: m.authorID, name: m.authorName,
                                          source: info.ref.source, people: people)
                let owner = ChatDayText.owner(of: m, chatTitle: title, myName: myName, match: match)
                if PromiseDuplicate.duplicate(text: kept.task, owner: owner, quote: kept.quote, of: seen) != nil {
                    continue
                }
                seen.append(PromiseDuplicate.entry(text: kept.task, owner: owner, quote: kept.quote))
                let commitment = Commitment(
                    text: kept.task, owner: owner, isMine: m.isMine, dueHint: kept.due,
                    sourceTitle: title, sourceEntryID: nil, date: m.sentAt,
                    sourceQuote: kept.quote, sourceChatID: String(chat), sourceChatDay: day,
                    sourceMessageID: m.sourceMessageID)
                if CommitmentStore.shared.add(commitment) { added += 1 }
            }
            try store.complete(chat: chat, day: day, summary: summary,
                               processedUpTo: ConversationStore.mark(last.sentAt))
            NSLog("Griasa: conversations — chat %lld day %@: %d messages read, %d promises proposed, %d added, %d dropped",
                  chat, day, fresh.count, promises.proposed, added, promises.proposed - promises.kept.count)
            return .finished
        } catch {
            // Another connection held the database (retention, an import): not the
            // day's fault, so the attempt is given back. If even that is refused,
            // the day stays `processing` until `resetInterrupted` puts it back.
            if ConversationStore.isBusy(error) {
                try? store.releaseWithoutCounting(chat: chat, day: day)
                NSLog("Griasa: conversations — chat %lld day %@ waits for the database", chat, day)
                return .retry
            }
            // The model went away mid-day: nothing was wrong with the day.
            if !Self.modelReady {
                try? store.releaseWithoutCounting(chat: chat, day: day)
                NSLog("Griasa: conversations — chat %lld day %@ waits for a model", chat, day)
                return .retry
            }
            let state = (try? store.releaseAfterFailure(chat: chat, day: day)) ?? .pending
            NSLog("Griasa: conversations — chat %lld day %@ failed (%@), now %@",
                  chat, day, error is Unreadable ? "unreadable reply" : "model error", state.rawValue)
            return .retry
        }
    }

    // MARK: Model calls

    private func summarize(_ messages: [StoredMessage], names: (StoredMessage) -> String) async throws -> String {
        var parts: [String] = []
        for group in ChatDayText.groups(messages, budget: Self.requestBudget) {
            let reply = try await AIFormatter.complete(
                system: Prompts.text(.chatDaySummary),
                user: ChatDayText.render(group, names: names),
                tier: .fast, maxTokens: 600, timeout: 120,
                allowCloudFallback: false, allowApple: false)
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Unreadable() }
            parts.append(text)
        }
        return parts.joined(separator: "\n\n")
    }

    private func findPromises(_ fresh: [StoredMessage], chat: Int64, day: String, chatTitle: String,
                              names: (StoredMessage) -> String) async throws
        -> (kept: [(message: StoredMessage, task: String, due: String?, quote: String)], proposed: Int) {
        guard let store else { throw Unreadable() }
        var kept: [(message: StoredMessage, task: String, due: String?, quote: String)] = []
        var proposed = 0
        for group in ChatDayText.groups(fresh, budget: Self.requestBudget) {
            let context = try store.messages(chat: chat, before: group[0].sentAt, limit: Self.contextMessages)
            let reply = try await AIFormatter.complete(
                system: Prompts.text(.chatPromises).filling(["today": day]),
                user: ChatDayText.render(context + group, names: names, contextCount: context.count),
                tier: .fast, maxTokens: 2048, timeout: 120,
                allowCloudFallback: false, allowApple: false)
            guard !LongMeetingMap.arrayCandidates(reply).isEmpty else { throw Unreadable() }
            let items = ChatDayText.parsePromises(reply)
            proposed += items.count
            kept += ChatDayText.keep(items, messages: group)
        }
        return (kept, proposed)
    }
}

// Lives here, not in ConversationRetention.swift, because it needs the queue and
// that file is Foundation-only for test.sh.
extension ConversationRetention {
    /// At launch and once a day, off the main thread: rebuilding the index and a
    /// VACUUM on a large database are not instant.
    ///
    /// It never overlaps the queue: it is skipped while days are being read (the
    /// next daily run catches up), and the queue is held off while it works and
    /// started again after (`thenResume`, at launch), so neither stalls on the
    /// other's lock. Its connection waits up to 30 s for a lock rather than 3.
    @MainActor
    static func runLive(now: Date = Date(), thenResume: Bool = false) {
        let processor = ConversationProcessor.shared
        guard !processor.isRunning, !processor.maintenance else { return }
        processor.maintenance = true
        let days = ManagedPolicy.live.conversationRetentionDays
        Task.detached(priority: .utility) {
            if let store = try? ConversationStore.live(busyTimeout: 30_000),
               let outcome = try? run(store: store, retentionDays: days, now: now),
               outcome.messages > 0 || outcome.reviews > 0 {
                NSLog("Griasa: conversation retention removed %d message(s) and %d waiting batch(es)",
                      outcome.messages, outcome.reviews)
            }
            await MainActor.run {
                processor.maintenance = false
                if thenResume { processor.resume() }
            }
        }
    }
}
