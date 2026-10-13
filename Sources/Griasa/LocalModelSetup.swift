import Foundation
import NaturalLanguage
import UserNotifications

/// Where the local model stands, for the coordinator and the cards that show it.
enum LocalModelState: Equatable {
    case checking
    case ready(engine: LocalEngine, model: String, displayName: String)
    case needsConsent(entry: LocalModelEntry, intoOllama: String?)   // tag when pulling into Ollama
    case noSpace(neededGB: Int)
    case installing
    case downloading(percent: Int)
    case failed(String)
}

/// Makes the local model work without the person having to know what one is:
/// looks at what this Mac has, uses a runtime that already has a suitable
/// model, and otherwise asks once to download one. See the 2026-10-12 design.
@MainActor
final class LocalModelSetup: ObservableObject {
    static let shared = LocalModelSetup()
    nonisolated static let engineKey = "localEngine"
    nonisolated static let modelKey = "localEngineModel"
    nonisolated static let declinedKey = "localModelDeclinedAt"
    nonisolated static let preferredEngineKey = "localEnginePreferred"
    nonisolated static let chosenIDKey = "localModelID"
    nonisolated static let autoDownloadKey = "localModelAutoDownload"
    /// The model the person said "Download" for, kept until a "Not now" or a
    /// removal, so a download cut by a quit continues without asking again.
    nonisolated static let consentedIDKey = "localModelDownloadConsented"
    /// The smaller tier Griasa moved to after the chosen one ran out of memory.
    /// Its own key, not `localModelID`: that one is the organization's (and the
    /// expert's) pin, and writing it would lock Settings and outrank a later
    /// MDM value with a choice nobody made.
    nonisolated static let steppedDownIDKey = "localModelSteppedDown"

    @Published private(set) var state: LocalModelState = .checking
    /// The stored Ollama or LM Studio, kept after every wait went unanswered:
    /// the status says it is not answering instead of offering a download.
    @Published private(set) var notAnswering: LocalEngine?
    /// Griasa's own download lost the network and is waiting for it to come
    /// back; it continues from where it stopped.
    @Published private(set) var waitingForNetwork = false
    /// The download in progress picked up a `.part` left by an earlier run.
    @Published private(set) var resuming = false
    private(set) var entry: LocalModelEntry?
    private var pending = PendingSummaries.load(from: UserDefaults.standard.data(forKey: PendingSummaries.defaultsKey))
    private var catchingUp = false
    /// `catchUp()` was called while a round ran: run one more after it.
    private var catchUpAgain = false
    /// Griasa's own download (or a pull into Ollama) in progress, so a
    /// removal, another pick or a move to the cloud can stop it.
    private var downloadTask: Task<Void, Never>?
    /// Models whose download was continued without asking in this launch;
    /// see `DownloadResume.resumesWithoutAsking`.
    private var resumedThisLaunch: Set<String> = []
    private var lastFailureWasNetwork = false
    /// When each meeting was queued in this session; see `PendingSummaries.isFresh`.
    private var queuedAt: [UUID: Date] = [:]
    private var delayedCatchUp: Task<Void, Never>?
    /// Refreshes in a row that kept a silent Ollama or LM Studio; see `LocalRuntimeWait`.
    private var runtimeWaits = 0
    private var retryTask: Task<Void, Never>?
    /// Stepping down is for a model that cannot fit; a second failure in the
    /// same launch is more likely something else, and walking down every tier
    /// on it would leave the person with the smallest model for no reason.
    private var steppedDownThisLaunch = false
    private let defaults = UserDefaults.standard

    private var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    private var freeDiskGB: Int {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int((values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000)
    }

    private var storedEngine: LocalEngine? { LocalEngine(rawValue: defaults.string(forKey: Self.engineKey) ?? "") }

    /// The order is in `LocalSetupMemory.choose`: a pin, then what is already
    /// set up, and only then a fresh pick from memory and free disk.
    private func chooseEntry() -> LocalModelEntry? {
        LocalSetupMemory.choose(pinnedID: defaults.string(forKey: Self.chosenIDKey),
                                steppedDownID: defaults.string(forKey: Self.steppedDownIDKey),
                                storedEngine: storedEngine,
                                storedModel: defaults.string(forKey: Self.modelKey),
                                isDownloaded: LlamaInstaller.isDownloaded,
                                memoryGB: memoryGB, freeDiskGB: freeDiskGB,
                                consentedPart: consentedPart)
    }

    /// The model the person said yes to, with how much of it is on disk.
    private var consentedPart: (id: String, bytes: Int64)? {
        guard let id = defaults.string(forKey: Self.consentedIDKey),
              let entry = LocalModelCatalog.entry(id: id),
              let bytes = LlamaInstaller.partSize(entry), bytes > 0 else { return nil }
        return (id, bytes)
    }

    /// Local setup is for people on the local provider. Somebody who chose a
    /// cloud provider is never asked about, or sent, a multi-gigabyte download,
    /// and nothing runs a meeting through their cloud provider in the background.
    private var onLocalProvider: Bool { LLMConfig.current().provider == .custom }

    private func get(_ url: String) async -> Data? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private var refreshTask: Task<Void, Never>?

    private var typedBaseURL: String { defaults.string(forKey: "customBaseURL") ?? "" }
    private var typedModelNames: [String] {
        [defaults.string(forKey: "customFastModel") ?? "", defaults.string(forKey: "customSmartModel") ?? ""]
    }

    /// Who asked for a refresh. `request` is the reconnect after a request
    /// failed to connect: it never spends the waits kept for a runtime still
    /// starting. `typing` is Settings while the server address or model names
    /// are being typed: on a typed server it updates the status only, and
    /// never starts catch-up against a half-typed name; once the fields are
    /// emptied and Griasa's own setup is back, it is a normal refresh.
    ///
    /// The probe after a meeting was queued is a plain refresh and does start
    /// catch-up when the model is ready. That cannot bring back the cloud
    /// question seconds after the person said no: catch-up sends only to the
    /// model on this Mac (`requireLocal`), so it has no cloud fallback to offer.
    enum RefreshOrigin { case normal, request, typing }
    private var refreshOrigin: RefreshOrigin = .normal

    /// Concurrent callers share one probe instead of racing each other. A
    /// plain refresh that found a narrower one running runs its own after it,
    /// so the waits and the catch-up it owes are not lost.
    func refresh(_ origin: RefreshOrigin = .normal) async {
        while let running = refreshTask {
            let joined = refreshOrigin
            await running.value
            guard origin == .normal, joined != .normal else { return }
        }
        refreshOrigin = origin
        // Cleared inside the task, before it completes, so a caller woken by
        // its end never sees a finished task still recorded as running.
        let task = Task { @MainActor in
            await self.performRefresh(origin)
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    /// Whether pending meetings may be summarized now; see `LocalCatchUpGate`.
    private var mayCatchUp: Bool {
        LocalCatchUpGate.mayRun(providerIsCustom: onLocalProvider, typedBaseURL: typedBaseURL,
                                typedModelNames: typedModelNames, storedEngine: storedEngine)
    }

    private func performRefresh(_ origin: RefreshOrigin) async {
        let busy: Bool
        switch state {
        case .installing, .downloading: busy = true
        default: busy = false
        }
        // A user-typed server is theirs; nothing to set up, whatever the disk says.
        switch LocalRefreshGate.action(typedBaseURL: typedBaseURL, typedModelNames: typedModelNames, busy: busy) {
        case .skip: return
        case .userServer:
            notAnswering = nil
            state = .ready(engine: .userServer, model: "", displayName: "Your server")
            // Meetings that waited for a model get it here too — when the
            // typed server is on this Mac (`catchUp` checks).
            if origin != .typing { catchUp() }
            return
        case .proceed: break
        }
        guard let entry = chooseEntry() else {
            notAnswering = nil
            clearStoredEngine()
            // A part that cannot be finished here is only disk the person is
            // being asked to free.
            LlamaInstaller.removeAbandonedParts(keeping: nil)
            let smallest = LocalModelCatalog.entries[0]
            state = .noSpace(neededGB: Int((Double(smallest.pinned.size) / 1e9).rounded(.up)) + LocalModelCatalog.diskHeadroomGB)
            return
        }
        self.entry = entry
        let probe = LocalProbe(
            userBaseURL: "",
            ollamaModels: await get("http://127.0.0.1:11434/api/tags").flatMap(LocalRuntimeParsing.ollamaModelNames),
            lmStudioModels: await get("http://127.0.0.1:1234/api/v1/models").flatMap(LocalRuntimeParsing.lmStudioModelKeys),
            griasaModelOnDisk: LlamaInstaller.isDownloaded(entry))
        let stored = storedEngine
        let answered: Bool
        switch stored {
        case .ollama: answered = probe.ollamaModels != nil
        case .lmStudio: answered = probe.lmStudioModels != nil
        default: answered = true
        }
        let preferred = LocalEngine(rawValue: defaults.string(forKey: Self.preferredEngineKey) ?? "")
        let decision = LocalEngineChoice.decide(probe, entry: entry, preferred: preferred)
        let verdict = LocalRuntimeWait.verdict(stored: stored, answered: answered, waitsSoFar: runtimeWaits,
                                               preferred: preferred, decision: decision,
                                               fromRequest: origin == .request)
        if verdict != .decide, let stored {
            let model = defaults.string(forKey: Self.modelKey) ?? ""
            state = .ready(engine: stored, model: model, displayName: model)
            if case .keep(let delay) = verdict {
                // Still starting, most likely: keep what works and ask again later.
                runtimeWaits += 1
                notAnswering = nil
                retryTask?.cancel()
                retryTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if !Task.isCancelled { await LocalModelSetup.shared.refresh() }
                }
            } else if LocalRuntimeWait.showsNotAnswering(verdict, waitsSoFar: runtimeWaits) {
                // Every wait is spent: keep it, and say it is not answering.
                notAnswering = stored
            }
            return
        }
        runtimeWaits = 0
        notAnswering = nil
        // A runtime that never answered may still be on this Mac, just not
        // running; an organization's pre-approval is for setting up a Mac
        // that has nothing, not for downloading beside a runtime that is off.
        let mayAutoDownload = defaults.bool(forKey: Self.autoDownloadKey) && onLocalProvider && answered
        switch decision {
        case .use(let engine, let model):
            // Even from typing: an emptied address or name lands here, on
            // Griasa's own setup, and that is a return to the normal case.
            apply(engine: engine, model: model, entry: entry)
        case .pullIntoOllama(let tag):
            clearStoredEngine()
            state = .needsConsent(entry: entry, intoOllama: tag)
            if mayAutoDownload { consent() }
        case .download:
            clearStoredEngine()
            state = .needsConsent(entry: entry, intoOllama: nil)
            let partSize = LlamaInstaller.partSize(entry)
            if onLocalProvider, answered,
               DownloadResume.resumesWithoutAsking(partSize: partSize,
                                                   consentedID: defaults.string(forKey: Self.consentedIDKey),
                                                   entryID: entry.id,
                                                   autoDownload: defaults.bool(forKey: Self.autoDownloadKey),
                                                   resumedThisLaunch: resumedThisLaunch.contains(entry.id),
                                                   lastFailureWasNetwork: lastFailureWasNetwork) {
                resumedThisLaunch.insert(entry.id)
                let percent = DownloadResume.percent(have: partSize ?? 0, of: entry.pinned.size)
                resuming = true
                state = .downloading(percent: percent)
                downloadTask = Task { await downloadOwn(entry, from: percent) }
            } else if mayAutoDownload { consent() }
        }
    }

    /// A stored engine that no longer has a model behind it must not keep
    /// pointing `LLMConfig` at a dead server.
    private func clearStoredEngine() {
        defaults.removeObject(forKey: Self.engineKey)
        defaults.removeObject(forKey: Self.modelKey)
    }

    private func apply(engine: LocalEngine, model: String, entry: LocalModelEntry, downloaded: Bool = false) {
        let previous = defaults.string(forKey: Self.engineKey)
        // A larger tier than the one stepped down to is working: the reason
        // for the step-down is gone.
        if defaults.string(forKey: Self.steppedDownIDKey) != nil,
           !LocalSetupMemory.keepsStepDown(steppedDownID: defaults.string(forKey: Self.steppedDownIDKey),
                                           readyID: entry.id) {
            defaults.removeObject(forKey: Self.steppedDownIDKey)
        }
        if engine != .userServer {
            defaults.set(engine.rawValue, forKey: Self.engineKey)
            defaults.set(model, forKey: Self.modelKey)
        }
        // Whatever is ready now, a half-downloaded model of another choice is
        // abandoned (the one downloading, if any, is never touched).
        LlamaInstaller.removeAbandonedParts(keeping: nil)
        let name = engine == .griasa ? entry.displayName : model
        state = .ready(engine: engine, model: model, displayName: name)
        if previous == nil, !downloaded, engine == .ollama || engine == .lmStudio, onLocalProvider {
            LocalNotice.post(title: "Local AI is ready",
                          body: "Griasa uses the AI model already on this Mac (\(engine == .ollama ? "Ollama" : "LM Studio")).")
        }
        catchUp()
    }

    /// Promises for `id` were collected outside the catch-up; see
    /// `PendingSummaries.promisesCollected`.
    func promisesCollected(_ id: UUID) {
        pending.promisesCollected(id)
        defaults.set(pending.encoded(), forKey: PendingSummaries.defaultsKey)
    }

    /// The person picked a model in Settings: any step-down Griasa made on
    /// its own gives way to that choice, and a download of the model picked
    /// before stops (its part stays, for if they pick it again).
    func modelPickedByPerson() async {
        defaults.removeObject(forKey: Self.steppedDownIDKey)
        await cancelDownload()
        await refresh()
    }

    /// Another engine was preferred in Settings: a download for the old
    /// choice stops, and the setup is decided again.
    func enginePreferenceChanged() async {
        await cancelDownload()
        await refresh()
    }

    /// The provider changed in Settings. Away from local, a download stops
    /// and half-downloaded models go: a cloud user is never sent gigabytes.
    func providerChanged() async {
        guard !onLocalProvider else { return }
        let stopped = await cancelDownload()
        LlamaInstaller.removeAbandonedParts(keeping: nil)
        if stopped { await refresh() }
    }

    /// Stops the download in progress and waits for it to end. Returns
    /// whether there was one.
    @discardableResult
    private func cancelDownload() async -> Bool {
        guard let task = downloadTask else { return false }
        downloadTask = nil
        task.cancel()
        await task.value
        return true
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var shouldOfferCard: Bool {
        switch state {
        case .needsConsent, .noSpace: break
        default: return false
        }
        if defaults.bool(forKey: Self.autoDownloadKey) { return false }
        if !onLocalProvider || LLMConfig.localConfiguredByHand { return false }
        if let declined = defaults.object(forKey: Self.declinedKey) as? Date,
           Date().timeIntervalSince(declined) < 7 * 86_400 { return false }
        return true
    }

    func decline() {
        defaults.set(Date(), forKey: Self.declinedKey)
        defaults.removeObject(forKey: Self.consentedIDKey)
        // Without the yes, a part will never be finished.
        LlamaInstaller.removeAbandonedParts(keeping: nil)
    }

    func consent() {
        guard case .needsConsent(let entry, let tag) = state else { return }
        defaults.removeObject(forKey: Self.declinedKey)
        if tag == nil { defaults.set(entry.id, forKey: Self.consentedIDKey) }
        // Set before the task starts, so a second tap or a refresh sees a busy state.
        state = tag == nil ? .installing : .downloading(percent: 0)
        downloadTask = Task {
            if let tag { await pullIntoOllama(tag, entry: entry) } else { await downloadOwn(entry) }
        }
    }

    /// A download stopped by `cancelDownload`: back to a state a refresh
    /// decides from (a busy one would be skipped).
    private func settleCancelled() {
        waitingForNetwork = false
        resuming = false
        state = .checking
    }

    private func downloadOwn(_ entry: LocalModelEntry, from startPercent: Int = 0) async {
        // Active from before the engine install, which can take minutes: a
        // sweep meanwhile would take the part this download is about to use.
        LlamaInstaller.markActive(entry.id)
        defer {
            LlamaInstaller.markActive(nil)
            resuming = false
        }
        guard await LlamaInstaller.installEngine() else {
            if Task.isCancelled { settleCancelled(); return }
            state = .failed(WhisperInstaller.brewPath == nil
                ? "Homebrew is needed to install the AI engine — install it from brew.sh, then try again."
                : "Installing the AI engine failed — run `brew install llama.cpp` in Terminal, then try again.")
            return
        }
        if Task.isCancelled { settleCancelled(); return }
        state = .downloading(percent: startPercent)
        for attempt in 1...2 {
            do {
                try await LlamaInstaller.download(entry, onProgress: { percent in
                    Task { @MainActor in
                        if case .downloading = LocalModelSetup.shared.state {
                            LocalModelSetup.shared.state = .downloading(percent: percent)
                        }
                    }
                }, onWaiting: { waiting in
                    Task { @MainActor in LocalModelSetup.shared.waitingForNetwork = waiting }
                }, onRestart: {
                    Task { @MainActor in LocalModelSetup.shared.resuming = false }
                })
                waitingForNetwork = false
                lastFailureWasNetwork = false
                if Task.isCancelled { settleCancelled(); return }
                apply(engine: .griasa, model: entry.id, entry: entry)
                LocalNotice.post(title: "Local AI is ready", body: "Summaries and promises now work on this Mac.")
                return
            } catch {
                waitingForNetwork = false
                if Task.isCancelled { settleCancelled(); return }
                let network = DownloadResume.isNetworkError(error)
                lastFailureWasNetwork = network
                // The downloader already waited out the network for half an
                // hour; a second try would wait as long again. A file that
                // failed its check starts over from nothing, so the second
                // try is no longer a resume.
                if attempt == 2 || network {
                    state = .failed(error.localizedDescription)
                    return
                }
                resuming = false
            }
        }
    }

    private func pullIntoOllama(_ tag: String, entry: LocalModelEntry) async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/pull")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": tag, "stream": true])
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                state = .failed("Ollama could not start the download (it returned \(status)). Try again.")
                return
            }
            for try await line in bytes.lines {
                guard let progress = LocalRuntimeParsing.ollamaPullProgress(Data(line.utf8)) else { continue }
                if let error = progress.error { state = .failed("Ollama: \(error)"); return }
                if progress.done {
                    apply(engine: .ollama, model: tag, entry: entry, downloaded: true)
                    LocalNotice.post(title: "Local AI is ready", body: "Summaries and promises now work on this Mac.")
                    return
                }
                if progress.total > 0 {
                    state = .downloading(percent: Int(progress.completed * 100 / progress.total))
                }
            }
            // The stream ended without "success" or an error: Ollama quit or
            // dropped the connection. Left as it was, the card and the menu
            // would show the download running forever.
            if case .downloading = state { state = .failed("The download from Ollama stopped. Try again.") }
        } catch {
            if Task.isCancelled { settleCancelled(); return }
            state = .failed(error.localizedDescription)
        }
    }

    func removeModel() {
        defaults.removeObject(forKey: Self.consentedIDKey)
        // A download in progress stops, and its part goes with the rest.
        Task {
            await cancelDownload()
            removeFiles()
        }
    }

    private func removeFiles() {
        // The file of the model in use, which after a step-down or an
        // earlier pick need not be the one this Mac would pick today.
        let inUse = storedEngine == .griasa
            ? LocalModelCatalog.entry(id: defaults.string(forKey: Self.modelKey) ?? "") ?? entry
            : entry
        guard let inUse else {
            LlamaInstaller.removeAbandonedParts(keeping: nil)
            Task { await refresh() }
            return
        }
        LlamaServer.shared.stop()
        LlamaInstaller.remove(inUse)
        defaults.removeObject(forKey: Self.engineKey)
        defaults.removeObject(forKey: Self.modelKey)
        Task { await refresh() }
    }

    /// Griasa's engine died while loading `failed`, most likely because the
    /// model needed more memory than was free. Moves to the next tier down
    /// once per launch, says so once, and leaves a pinned model alone — the
    /// organization or the expert chose it.
    func stepDown(from failed: LocalModelEntry) {
        guard !steppedDownThisLaunch,
              (defaults.string(forKey: Self.chosenIDKey) ?? "").isEmpty,
              let smaller = LocalModelCatalog.smaller(than: failed) else { return }
        steppedDownThisLaunch = true
        defaults.set(smaller.id, forKey: Self.steppedDownIDKey)
        LocalNotice.post(title: "Local AI switched to a smaller model",
                         body: "The AI model needed more memory than this Mac had free; Griasa switched to a smaller one.")
        entry = smaller
        if LlamaInstaller.isDownloaded(smaller) {
            apply(engine: .griasa, model: smaller.id, entry: smaller)
        } else {
            // The smaller file is another download, and a download still
            // needs the person's yes.
            clearStoredEngine()
            state = .needsConsent(entry: smaller, intoOllama: nil)
        }
    }

    // MARK: Pending meetings

    /// Only remembers the meeting. Summarizing it here would run it at once
    /// against a model that may be busy or about to change; catch-up runs when
    /// the model becomes ready and at launch.
    ///
    /// A fresh meeting is passed over by catch-up for ten minutes (see
    /// `PendingSummaries.isFresh`), so one delayed catch-up is scheduled for
    /// after that; it runs if the model is ready then.
    func enqueuePending(_ id: UUID) {
        pending.add(id)
        queuedAt[id] = Date()
        defaults.set(pending.encoded(), forKey: PendingSummaries.defaultsKey)
        delayedCatchUp?.cancel()
        delayedCatchUp = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((PendingSummaries.freshGrace + 5) * 1_000_000_000))
            guard !Task.isCancelled, self.isReady else { return }
            self.catchUp()
        }
    }

    /// Summarizes waiting meetings one at a time, oldest first.
    ///
    /// A call while a round runs is not dropped (the delayed retry for a
    /// fresh meeting may land then): it runs one more round after this one.
    private func catchUp() {
        if catchingUp { catchUpAgain = true; return }
        guard mayCatchUp else { return }
        catchingUp = true
        Task { @MainActor in
            defer { catchingUp = false }
            repeat {
                catchUpAgain = false
                await catchUpRound()
            } while catchUpAgain && mayCatchUp
        }
    }

    private func catchUpRound() async {
        // Passed over this round: being worked on by hand right now.
        var skipped: Set<UUID> = []
        // Checked before every meeting: the person may have moved to a
        // cloud provider since the last one, and catch-up never uses one.
        while mayCatchUp {
            // Fresh per meeting, not per round: a meeting queued while the
            // round runs gets its ten minutes too.
            let now = Date()
            let fresh = Set(queuedAt.filter { PendingSummaries.isFresh(queuedAt: $0.value, now: now) }.keys)
            let history = HistoryStore.shared.entries
            let existing = Set(history.map(\.id))
            let summarized = Set(history.filter { !$0.text.contains(Self.rawMarker) }.map(\.id))
            guard let id = pending.next(existing: existing, alreadySummarized: summarized,
                                        skipping: skipped.union(fresh)),
                  let entry = history.first(where: { $0.id == id }) else { break }
            if HistoryStore.shared.working.contains(id) { skipped.insert(id); continue }
            // Never the cloud: nobody is there to answer the question, and
            // a meeting summarized in the background must stay on this Mac.
            let done: Bool
            let status: String
            if pending.needsOnlyExtraction(id, alreadySummarized: summarized) {
                status = await HistoryStore.shared.collectCommitments(entry, requireLocal: true)
                done = status.hasPrefix("✓") || status.hasPrefix("No new commitments")
            } else {
                status = await HistoryStore.shared.reprocessMeeting(entry, allowCloudFallback: false,
                                                                    requireExtraction: true, requireLocal: true)
                // A transcript that is gone will never succeed, so it goes.
                done = status.hasPrefix("✓") || status.contains("isn't on disk anymore")
            }
            if status == HistoryStore.alreadyWorking { skipped.insert(id); continue }
            if !done {
                // A real failure keeps the id for the next time the model
                // is ready. If the summary was saved before the promises
                // failed, only the promises are owed now.
                if HistoryStore.shared.entries.first(where: { $0.id == id })
                    .map({ !$0.text.contains(Self.rawMarker) }) == true {
                    pending.summarySaved(id)
                    defaults.set(pending.encoded(), forKey: PendingSummaries.defaultsKey)
                }
                break
            }
            pending.remove(id)
            defaults.set(pending.encoded(), forKey: PendingSummaries.defaultsKey)
        }
        // Clean out ids that are gone or done (not the ones that failed).
        let history = HistoryStore.shared.entries
        pending.prune(existing: Set(history.map(\.id)),
                      alreadySummarized: Set(history.filter { !$0.text.contains(Self.rawMarker) }.map(\.id)))
        defaults.set(pending.encoded(), forKey: PendingSummaries.defaultsKey)
    }

    /// The heading a meeting whose summary failed keeps in History.
    private static let rawMarker = "Meeting transcript (raw)"

    /// English confidence for routing (NaturalLanguage stays out of the
    /// Foundation-only router).
    nonisolated static func englishConfidence(_ text: String) -> Double {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        return recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0
    }
}

/// A quiet banner for the two moments that matter (a runtime was found; the
/// download finished). Asks for permission the first time; a refusal or any
/// failure just means no banner.
private enum LocalNotice {
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
