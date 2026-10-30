import Foundation
import Combine

/// Search by meaning: the opt-in model, the index of meeting pieces it builds,
/// and the ranking the MCP tools use.
///
/// Nothing happens until the person downloads the model (634 MB) in Settings.
/// From then on every meeting is cut into pieces (`SearchChunks`), each piece
/// becomes a vector (`EmbeddingServer`), and the vectors are kept in
/// `search.sqlite` (`SearchIndex`), re-made when a meeting's text changes and
/// removed when it is deleted. A query is ranked by the model and by word
/// search together (`HybridRank`); without the model, or while it is not
/// answering, word search alone answers, as before.
///
/// The MCP tools run synchronously on the main thread, so they never wait for
/// the model: `MCPServer` asks for the query's vector first (`prepare`), and
/// the tool uses it if it is there.
@MainActor
final class SemanticSearch: ObservableObject {
    static let shared = SemanticSearch()
    static let enabledKey = "semanticSearchOn"

    enum State: Equatable {
        case notDownloaded
        case downloading(percent: Int)
        case indexing(done: Int, total: Int)
        case ready(meetings: Int)
        case off
        case failed(String)
    }

    @Published private(set) var state: State = .notDownloaded

    /// The person's own switch. On by default: downloading the model is the
    /// consent, and the switch is there to pause it without deleting anything.
    var userOn: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            refresh()
            if isOn { scheduleIndexing() }
        }
    }

    var allowed: Bool { ManagedPolicy.live.semanticSearchAllowed }
    var isOn: Bool { allowed && userOn && EmbeddingServer.isDownloaded }

    private var index: SearchIndex?
    private var pieces: [SearchVectors.Piece] = []
    private var indexedCount = 0
    private var queryVectors: [String: [Float]] = [:]
    private var queryOrder: [String] = []
    private var watching: AnyCancellable?
    private var indexing: Task<Void, Never>?
    private var again = false
    private var download: Task<Void, Never>?

    /// Called once at launch: loads the index and follows the history.
    func start() {
        index = try? SearchIndex.live()
        if !allowed { try? index?.removeAll() }
        pieces = (try? index?.pieces()) ?? []
        indexedCount = Set(pieces.map(\.entry)).count
        refresh()
        // A burst of edits (a meeting being processed) re-indexes once.
        watching = HistoryStore.shared.$entries
            .dropFirst()
            .debounce(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleIndexing() }
        scheduleIndexing()
    }

    private func refresh() {
        if case .downloading = state { return }
        if case .indexing = state, indexing != nil { return }
        if !EmbeddingServer.isDownloaded { state = .notDownloaded }
        else if !allowed || !userOn { state = .off }
        else { state = .ready(meetings: indexedCount) }
    }

    // MARK: Model

    func downloadModel() {
        guard allowed, download == nil else { return }
        state = .downloading(percent: 0)
        download = Task {
            defer { download = nil }
            do {
                guard await LlamaInstaller.installEngine() else {
                    state = .failed("llama.cpp could not be installed with Homebrew.")
                    return
                }
                try FileManager.default.createDirectory(at: LlamaInstaller.modelsDirectory, withIntermediateDirectories: true)
                let downloader = ResumableDownloader(
                    destination: EmbeddingServer.modelURL, expected: EmbeddingServer.model,
                    onProgress: { percent in Task { @MainActor in
                        if case .downloading = SemanticSearch.shared.state {
                            SemanticSearch.shared.state = .downloading(percent: percent)
                        }
                    } },
                    onWaiting: { _ in }, onRestart: {}, mayContinue: { !Task.isCancelled })
                try await downloader.download(from: EmbeddingServer.model.url)
                state = .notDownloaded
                refresh()
                scheduleIndexing()
            } catch is CancellationError {
                state = .notDownloaded
            } catch {
                state = Task.isCancelled ? .notDownloaded : .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        download?.cancel()
    }

    /// Deletes the model, its half-downloaded part and the whole index.
    func removeModel() {
        download?.cancel()
        indexing?.cancel()
        EmbeddingServer.shared.stop()
        try? FileManager.default.removeItem(at: EmbeddingServer.modelURL)
        try? FileManager.default.removeItem(at: EmbeddingServer.partURL)
        try? index?.removeAll()
        pieces = []
        indexedCount = 0
        queryVectors = [:]
        queryOrder = []
        state = .notDownloaded
    }

    // MARK: Index

    private func scheduleIndexing() {
        guard isOn else { return }
        if indexing != nil { again = true; return }
        indexing = Task {
            repeat {
                again = false
                await indexOnce()
            } while again && !Task.isCancelled
            indexing = nil
            refresh()
        }
    }

    /// Brings the index in line with the history: new and changed meetings are
    /// cut and embedded, newest first; deleted ones are removed.
    private func indexOnce() async {
        guard isOn, let index else { return }
        let meetings = HistoryStore.shared.entries.filter { $0.kind == .meeting }
        let known = (try? index.indexed()) ?? [:]
        let ids = Set(meetings.map(\.id))
        let gone = known.keys.filter { !ids.contains($0) }
        if !gone.isEmpty {
            try? index.remove(gone)
            pieces.removeAll { gone.contains($0.entry) }
        }
        let stale = meetings.filter { entry in
            guard let record = known[entry.id] else { return true }
            return record.model != EmbeddingServer.modelID || record.hash != SearchVectors.hash(entry.title + "\n" + entry.text)
        }
        indexedCount = meetings.count - stale.count
        for (done, entry) in stale.enumerated() {
            if Task.isCancelled || !isOn { return }
            state = .indexing(done: done, total: stale.count)
            let text = entry.title + "\n" + entry.text
            let chunks = SearchChunks.split(text)
            do {
                let vectors = try await EmbeddingServer.shared.embed(chunks)
                let packed = vectors.map(SearchVectors.pack)
                try index.replace(entry: entry.id, hash: SearchVectors.hash(text), model: EmbeddingServer.modelID,
                                  pieces: Array(zip(chunks, packed)).map { (text: $0.0, vector: $0.1) })
                pieces.removeAll { $0.entry == entry.id }
                pieces += zip(chunks, packed).map { SearchVectors.Piece(entry: entry.id, text: $0.0, vector: $0.1) }
                indexedCount += 1
            } catch {
                // The model is not answering; try again on the next change.
                NSLog("Griasa: search indexing paused: %@", error.localizedDescription)
                return
            }
        }
    }

    // MARK: Queries

    /// Fetches and keeps the vector for `query`, so a synchronous tool can use it.
    func prepare(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOn, !query.isEmpty, !pieces.isEmpty, queryVectors[query] == nil else { return }
        // A cold start loads the model in a few seconds; past ten, the
        // assistant gets word search rather than a hung call.
        let vector = await withTaskGroup(of: [Float]?.self) { group -> [Float]? in
            group.addTask { try? await EmbeddingServer.shared.embed([query]).first }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let vector else { return }
        queryVectors[query] = vector
        queryOrder.append(query)
        if queryOrder.count > 64 { queryVectors[queryOrder.removeFirst()] = nil }
    }

    /// The query a tool call will search for, if it needs a vector that is not
    /// kept yet: `search_meetings`'s `query`, `get_context`'s `about`.
    func pendingQuery(in body: Data) -> String? {
        guard isOn, !pieces.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["method"] as? String == "tools/call",
              let params = json["params"] as? [String: Any],
              let arguments = params["arguments"] as? [String: Any] else { return nil }
        let text: String?
        switch params["name"] as? String {
        case "search_meetings": text = arguments["query"] as? String
        case "get_context": text = arguments["about"] as? String
        default: text = nil
        }
        guard let query = text?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
              queryVectors[query] == nil else { return nil }
        return query
    }

    /// Meetings from `among` that match `query`, best first, each with what
    /// matched. With the model's vector for the query: the model's ranking fused
    /// with the meetings that contain every word. Without: word search alone.
    func rankMeetings(_ query: String, among entries: [HistoryEntry], limit: Int) -> [(entry: HistoryEntry, matched: String)] {
        let documents = entries.map { WordSearch.Document(title: $0.title, text: $0.text) }
        let words = WordSearch.rank(query, in: documents, limit: max(limit, 50))
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOn, let vector = queryVectors[key], !pieces.isEmpty else {
            return words.prefix(limit).map { (entries[$0.index], $0.snippet) }
        }
        let wanted = WordSearch.terms(query).count
        let allWords = words.filter { $0.matchedTerms == wanted }
        let position = Dictionary(entries.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let byModel = SearchVectors.rankMeetings(vector, pieces: pieces, among: Set(position.keys), limit: 50)
        let fused = HybridRank.fuse(vector: byModel.compactMap { position[$0.entry] }, allWords: allWords.map(\.index))
        let snippets = Dictionary(words.map { ($0.index, $0.snippet) }, uniquingKeysWith: { a, _ in a })
        let pieceText = Dictionary(byModel.compactMap { item in position[item.entry].map { ($0, item.piece) } },
                                   uniquingKeysWith: { a, _ in a })
        return fused.prefix(limit).map { i in
            let snippet = snippets[i].flatMap { $0.isEmpty ? nil : $0 } ?? pieceText[i].map(SearchVectors.excerpt) ?? ""
            return (entries[i], snippet)
        }
    }
}
