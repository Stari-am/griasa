import Foundation

/// Installs llama.cpp and the chosen model, exactly as `WhisperInstaller` does
/// for speech: Homebrew for the engine, a pinned file checked against its
/// SHA-256 before it is moved into place.
enum LlamaInstaller {
    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Griasa/models", isDirectory: true)
    }

    static func modelURL(_ entry: LocalModelEntry) -> URL {
        modelsDirectory.appendingPathComponent(entry.pinned.fileName)
    }

    static var serverBinary: String? {
        ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static func installEngine() async -> Bool {
        if serverBinary != nil { return true }
        guard let brew = WhisperInstaller.brewPath else { return false }
        _ = await WhisperInstaller.runProcess(brew, ["install", "llama.cpp"])
        return serverBinary != nil
    }

    /// Size only — the full hash was checked when the file arrived, and
    /// re-reading 12 GB at every launch would cost a minute of disk.
    static func isDownloaded(_ entry: LocalModelEntry) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL(entry).path)[.size] as? NSNumber)?.int64Value
        return size == entry.pinned.size
    }

    /// The model whose `.part` is being written right now; its part is never
    /// swept as abandoned.
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var activeDownloadID: String?

    /// Continues a download an earlier attempt, or an earlier run, left in
    /// `<model>.part`; see `ResumableDownloader`.
    /// The caller marks the download active (`markActive`) from before the
    /// engine install until it ends, so no sweep takes the part meanwhile.
    static func download(_ entry: LocalModelEntry,
                         onProgress: @escaping @Sendable (Int) -> Void,
                         onWaiting: @escaping @Sendable (Bool) -> Void = { _ in },
                         onRestart: @escaping @Sendable () -> Void = {}) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        removeAbandonedParts(keeping: entry)
        let downloader = ResumableDownloader(destination: modelURL(entry), expected: entry.pinned,
                                             onProgress: onProgress, onWaiting: onWaiting,
                                             onRestart: onRestart)
        try await downloader.download(from: entry.pinned.url)
    }

    /// `id` is about to download (or nil: nothing is); its part is kept by every sweep.
    static func markActive(_ id: String?) {
        activeLock.withLock { activeDownloadID = id }
    }

    static func partSize(_ entry: LocalModelEntry) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: partURL(entry).path)[.size] as? NSNumber)?.int64Value
    }

    static func partURL(_ entry: LocalModelEntry) -> URL {
        modelURL(entry).appendingPathExtension("part")
    }

    static func remove(_ entry: LocalModelEntry) {
        try? FileManager.default.removeItem(at: modelURL(entry))
        removeAbandonedParts(keeping: nil)
    }

    /// Deletes the half-downloaded models nobody is fetching any more — a
    /// model switched away from, or removed — except `keeping`'s and the one
    /// downloading now. They can be tens of gigabytes.
    static func removeAbandonedParts(keeping: LocalModelEntry?) {
        let active = activeLock.withLock { activeDownloadID }
        for entry in LocalModelCatalog.entries where entry.id != keeping?.id && entry.id != active {
            try? FileManager.default.removeItem(at: partURL(entry))
        }
    }
}

/// Griasa's own `llama-server`, started on the first AI request and left to
/// unload its model after ten idle minutes, so it does not sit beside Whisper
/// holding gigabytes. Loopback only.
final class LlamaServer: @unchecked Sendable {
    static let shared = LlamaServer()
    /// 8177 because Griasa already holds its neighbours: Whisper is on 8178 and
    /// the MCP server binds upward from 8179.
    static let port = 8177
    static var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    private var process: Process?
    private var runningModel: String?
    /// A server left by an earlier run (a crash, or a probe that ended in
    /// `exit()`) that serves the wanted file and was taken over rather than
    /// restarted. There is no `Process` for it, so stopping it means a signal
    /// to the processes the orphan pattern finds.
    private var adoptedOrphan = false
    private var stderrTail = Data()
    /// The start in progress, if any. Starts run one at a time: two at once
    /// each swept the other's fresh server as an orphan, and the survivor
    /// read the death as "out of memory" and stepped the model down.
    private var startTask: Task<Start, Never>?
    private var startEntryID: String?
    private var startGeneration = 0
    private let lock = NSLock()

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The model a server on the port serves, if it says.
    private func servedModel() async -> String? {
        for path in ["/props", "/v1/models"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)\(path)")!)
            request.timeoutInterval = 2
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let model = LlamaServerRules.servedModel(data) {
                return model
            }
        }
        return nil
    }

    /// How a start ended, with the reason when it failed. `died` is kept apart
    /// from the rest because it is the one that says the model is too big for
    /// this Mac right now (the process exits when it cannot allocate the
    /// model), and the caller steps down a tier on it; a missing binary or
    /// file, a port taken by another program, or a slow start is no reason to.
    enum Start: Equatable {
        case running
        case died(reason: String?)
        case unavailable(reason: String?)

        var reason: String? {
            switch self {
            case .running: return nil
            case .died(let reason), .unavailable(let reason): return reason
            }
        }
    }

    /// Concurrent callers for the same model share one start; a caller for
    /// another model waits for the running one to finish first.
    func ensureRunning(_ entry: LocalModelEntry) async -> Start {
        let (task, generation) = lock.withLock { () -> (Task<Start, Never>, Int) in
            if let running = startTask, startEntryID == entry.id { return (running, startGeneration) }
            let previous = startTask
            let task = Task { () -> Start in
                _ = await previous?.value
                return await self.start(entry)
            }
            startGeneration += 1
            startTask = task
            startEntryID = entry.id
            return (task, startGeneration)
        }
        let result = await task.value
        lock.withLock { if startGeneration == generation { startTask = nil; startEntryID = nil } }
        return result
    }

    /// Only ever runs inside `ensureRunning`'s single flight.
    private func start(_ entry: LocalModelEntry) async -> Start {
        let current = lock.withLock { runningModel }
        if current == entry.id, await isHealthy() { return .running }
        // A model switch: the old process must be gone before the new one
        // asks for the port and the memory.
        if current != nil, current != entry.id { await stopAndWait() }
        guard let binary = LlamaInstaller.serverBinary, LlamaInstaller.isDownloaded(entry) else {
            return .unavailable(reason: nil)
        }
        if lock.withLock({ process?.isRunning != true }) {
            // Nothing of ours is running, so a Griasa llama-server on the port
            // is a leftover. One serving the wanted file is taken over; any
            // other would answer every request with the wrong model, so it goes.
            let wanted = LlamaInstaller.modelURL(entry).path
            if await isHealthy(), LlamaServerRules.mayAdopt(served: await servedModel(), wantedPath: wanted) {
                lock.withLock { runningModel = entry.id; adoptedOrphan = true }
                return .running
            }
            await killOrphans()
            // Still answering: not Griasa's. Launching would lose the bind and
            // look like a model too big for memory.
            if await isHealthy() {
                NSLog("Griasa: llama-server not started: %@", LlamaServerRules.portTakenReason)
                return .unavailable(reason: LlamaServerRules.portTakenReason)
            }
        }
        var launchError: String?
        let launched: Bool = lock.withLock {
            guard process?.isRunning != true else { return true }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = [
                "-m", LlamaInstaller.modelURL(entry).path,
                "-c", String(entry.contextTokens),
                "--host", "127.0.0.1", "--port", String(Self.port),
                "-ngl", "99", "--jinja", "-np", "1",
                "--sleep-idle-seconds", "600",
            ]
            p.standardOutput = FileHandle.nullDevice
            // Kept, the last few KB only: when a start fails, its last lines say why.
            stderrTail = Data()
            let pipe = Pipe()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self else { return }
                if chunk.isEmpty { handle.readabilityHandler = nil; return }
                self.lock.withLock { LlamaServerRules.appendTail(&self.stderrTail, chunk) }
            }
            p.standardError = pipe
            do {
                try p.run(); process = p; runningModel = entry.id; adoptedOrphan = false
                return true
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                launchError = error.localizedDescription
                NSLog("Griasa: failed to launch llama-server: %@", error.localizedDescription)
                return false
            }
        }
        guard launched else { return .unavailable(reason: launchError) }
        // Loading 12 GB from disk takes a while on first start.
        for _ in 0..<240 {
            if await isHealthy() { return .running }
            if lock.withLock({ process?.isRunning != true }) {  // likely out of memory
                // The pipe may still hold the last lines; give it a moment.
                try? await Task.sleep(nanoseconds: 200_000_000)
                return .died(reason: failureReason("exited while loading \(entry.pinned.fileName)"))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .unavailable(reason: failureReason("did not answer within 2 minutes"))
    }

    private func failureReason(_ what: String) -> String? {
        let reason = lock.withLock {
            LlamaServerRules.failureReason(stderrTail: String(decoding: stderrTail, as: UTF8.self))
        }
        NSLog("Griasa: llama-server %@: %@", what, reason ?? "no output")
        return reason
    }

    /// Stops the server and waits (5 s at most, then SIGKILL) until it has
    /// exited, so a server started next does not find the port, or the
    /// memory, still taken.
    func stopAndWait() async {
        let (old, adopted) = lock.withLock { () -> (Process?, Bool) in
            let state = (process, adoptedOrphan)
            process = nil
            runningModel = nil
            adoptedOrphan = false
            return state
        }
        if adopted { await killOrphans(); return }
        guard let old, old.isRunning else { return }
        old.terminate()
        for _ in 0..<50 {
            if !old.isRunning { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        kill(old.processIdentifier, SIGKILL)
        for _ in 0..<10 where old.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// The Griasa llama-servers this object did not launch: those whose
    /// command line names the binary, a model in Griasa's models folder and
    /// Griasa's port, minus the process held right now. Never this object's own.
    private func orphanPIDs() -> [pid_t] {
        let pattern = LlamaServerRules.orphanPattern(modelsDirectory: LlamaInstaller.modelsDirectory.path,
                                                     port: Self.port)
        let pids = Self.pgrep(pattern)
        let own = lock.withLock { process.map(\.processIdentifier) }
        return pids.filter { $0 != own && $0 != getpid() }
    }

    /// Stops leftovers from an earlier run: SIGTERM, then SIGKILL for any
    /// still there after 5 s.
    private func killOrphans() async {
        let orphans = orphanPIDs()
        guard !orphans.isEmpty else { return }
        NSLog("Griasa: stopping %d llama-server(s) left by an earlier run", orphans.count)
        for pid in orphans { kill(pid, SIGTERM) }
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if orphans.allSatisfy({ kill($0, 0) != 0 }) { return }
        }
        for pid in orphanPIDs() where orphans.contains(pid) { kill(pid, SIGKILL) }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func pgrep(_ pattern: String) -> [pid_t] {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    func stop() {
        let adopted = lock.withLock { () -> Bool in
            process?.terminate()
            process = nil
            runningModel = nil
            defer { adoptedOrphan = false }
            return adoptedOrphan
        }
        if adopted { for pid in orphanPIDs() { kill(pid, SIGTERM) } }
    }
}
