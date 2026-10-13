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
    /// The smaller tier Griasa moved to after the chosen one ran out of memory.
    /// Its own key, not `localModelID`: that one is the organization's (and the
    /// expert's) pin, and writing it would lock Settings and outrank a later
    /// MDM value with a choice nobody made.
    nonisolated static let steppedDownIDKey = "localModelSteppedDown"

    @Published private(set) var state: LocalModelState = .checking
    private(set) var entry: LocalModelEntry?
    private var pending = PendingSummaries.load(from: UserDefaults.standard.data(forKey: PendingSummaries.defaultsKey))
    private var catchingUp = false
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
                                memoryGB: memoryGB, freeDiskGB: freeDiskGB)
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

    /// Concurrent callers share one probe instead of racing each other.
    func refresh() async {
        if let running = refreshTask { await running.value; return }
        let task = Task { @MainActor in await self.performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        let busy: Bool
        switch state {
        case .installing, .downloading: busy = true
        default: busy = false
        }
        // A user-typed server is theirs; nothing to set up, whatever the disk says.
        switch LocalRefreshGate.action(typedBaseURL: typedBaseURL, typedModelNames: typedModelNames, busy: busy) {
        case .skip: return
        case .userServer:
            state = .ready(engine: .userServer, model: "", displayName: "Your server")
            return
        case .proceed: break
        }
        guard let entry = chooseEntry() else {
            clearStoredEngine()
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
        if case .keep(let delay) = LocalRuntimeWait.verdict(stored: stored, answered: answered, waitsSoFar: runtimeWaits),
           let stored {
            // Still starting, most likely: keep what works and ask again later.
            runtimeWaits += 1
            let model = defaults.string(forKey: Self.modelKey) ?? ""
            state = .ready(engine: stored, model: model, displayName: model)
            retryTask?.cancel()
            retryTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if !Task.isCancelled { await LocalModelSetup.shared.refresh() }
            }
            return
        }
        runtimeWaits = 0
        // A runtime that never answered may still be on this Mac, just not
        // running; an organization's pre-approval is for setting up a Mac
        // that has nothing, not for downloading beside a runtime that is off.
        let mayAutoDownload = defaults.bool(forKey: Self.autoDownloadKey) && onLocalProvider && answered
        let preferred = LocalEngine(rawValue: defaults.string(forKey: Self.preferredEngineKey) ?? "")
        switch LocalEngineChoice.decide(probe, entry: entry, preferred: preferred) {
        case .use(let engine, let model):
            apply(engine: engine, model: model, entry: entry)
        case .pullIntoOllama(let tag):
            clearStoredEngine()
            state = .needsConsent(entry: entry, intoOllama: tag)
            if mayAutoDownload { consent() }
        case .download:
            clearStoredEngine()
            state = .needsConsent(entry: entry, intoOllama: nil)
            if mayAutoDownload { consent() }
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
        if engine != .userServer {
            defaults.set(engine.rawValue, forKey: Self.engineKey)
            defaults.set(model, forKey: Self.modelKey)
        }
        let name = engine == .griasa ? entry.displayName : model
        state = .ready(engine: engine, model: model, displayName: name)
        if previous == nil, !downloaded, engine == .ollama || engine == .lmStudio, onLocalProvider {
            LocalNotice.post(title: "Local AI is ready",
                          body: "Griasa uses the AI model already on this Mac (\(engine == .ollama ? "Ollama" : "LM Studio")).")
        }
        catchUp()
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

    func decline() { defaults.set(Date(), forKey: Self.declinedKey) }

    func consent() {
        guard case .needsConsent(let entry, let tag) = state else { return }
        defaults.removeObject(forKey: Self.declinedKey)
        // Set before the task starts, so a second tap or a refresh sees a busy state.
        state = tag == nil ? .installing : .downloading(percent: 0)
        Task {
            if let tag { await pullIntoOllama(tag, entry: entry) } else { await downloadOwn(entry) }
        }
    }

    private func downloadOwn(_ entry: LocalModelEntry) async {
        guard await LlamaInstaller.installEngine() else {
            state = .failed(WhisperInstaller.brewPath == nil
                ? "Homebrew is needed to install the AI engine — install it from brew.sh, then try again."
                : "Installing the AI engine failed — run `brew install llama.cpp` in Terminal, then try again.")
            return
        }
        state = .downloading(percent: 0)
        for attempt in 1...2 {
            do {
                try await LlamaInstaller.download(entry) { percent in
                    Task { @MainActor in
                        if case .downloading = LocalModelSetup.shared.state {
                            LocalModelSetup.shared.state = .downloading(percent: percent)
                        }
                    }
                }
                apply(engine: .griasa, model: entry.id, entry: entry)
                LocalNotice.post(title: "Local AI is ready", body: "Summaries and promises now work on this Mac.")
                return
            } catch {
                if attempt == 2 { state = .failed(error.localizedDescription) }
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
            state = .failed(error.localizedDescription)
        }
    }

    func removeModel() {
        // The file of the model in use, which after a step-down or an
        // earlier pick need not be the one this Mac would pick today.
        let inUse = storedEngine == .griasa
            ? LocalModelCatalog.entry(id: defaults.string(forKey: Self.modelKey) ?? "") ?? entry
            : entry
        guard let inUse else { return }
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
    func enqueuePending(_ id: UUID) {
        pending.add(id)
        defaults.set(pending.encoded(), forKey: PendingSummaries.defaultsKey)
    }

    /// Summarizes waiting meetings one at a time, oldest first.
    private func catchUp() {
        guard !catchingUp, onLocalProvider else { return }
        catchingUp = true
        Task { @MainActor in
            defer { catchingUp = false }
            while true {
                let history = HistoryStore.shared.entries
                let existing = Set(history.map(\.id))
                let summarized = Set(history.filter { !$0.text.contains("Meeting transcript (raw)") }.map(\.id))
                guard let id = pending.next(existing: existing, alreadySummarized: summarized),
                      let entry = history.first(where: { $0.id == id }) else { break }
                // Never the cloud: nobody is there to answer the question, and
                // a meeting summarized in the background must stay on this Mac.
                let status = await HistoryStore.shared.reprocessMeeting(entry, allowCloudFallback: false,
                                                                        requireExtraction: true)
                // A real failure keeps the id for the next time the model is
                // ready; a transcript that is gone will never succeed, so it goes.
                guard status.hasPrefix("✓") || status.contains("isn't on disk anymore") else { break }
                pending.remove(id)
                defaults.set(pending.encoded(), forKey: PendingSummaries.defaultsKey)
            }
            // Clean out ids that are gone or done (not the ones that failed).
            let history = HistoryStore.shared.entries
            let existing = Set(history.map(\.id))
            let summarized = Set(history.filter { !$0.text.contains("Meeting transcript (raw)") }.map(\.id))
            for id in pending.ids where !existing.contains(id) || summarized.contains(id) { pending.remove(id) }
            defaults.set(pending.encoded(), forKey: PendingSummaries.defaultsKey)
        }
    }

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
