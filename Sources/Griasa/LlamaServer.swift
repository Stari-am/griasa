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

    static func download(_ entry: LocalModelEntry,
                         onProgress: @escaping @Sendable (Int) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let downloader = ModelDownloader(destination: modelURL(entry), expected: entry.pinned,
                                         onProgress: onProgress)
        try await downloader.download(from: entry.pinned.url)
    }

    static func remove(_ entry: LocalModelEntry) {
        try? FileManager.default.removeItem(at: modelURL(entry))
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
    /// restarted. There is no `Process` for it, so stopping it means `pkill`.
    private var adoptedOrphan = false
    private var stderrTail = Data()
    /// One line on why the last start failed, for the error the person sees.
    private(set) var lastFailureReason: String?
    private let lock = NSLock()

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The model file a server on the port serves, if it says.
    private func servedModelFile() async -> String? {
        for path in ["/props", "/v1/models"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)\(path)")!)
            request.timeoutInterval = 2
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let file = LlamaServerRules.servedModelFile(data) {
                return file
            }
        }
        return nil
    }

    /// How a start ended. `died` is kept apart from the rest because it is the
    /// one that says the model is too big for this Mac right now (the process
    /// exits when it cannot allocate the model), and the caller steps down a
    /// tier on it; a missing binary or file, or a slow start, is no reason to.
    enum Start { case running, died, unavailable }

    func ensureRunning(_ entry: LocalModelEntry) async -> Start {
        let current = lock.withLock { runningModel }
        if current == entry.id, await isHealthy() { return .running }
        // A model switch: the old process must be gone before the new one
        // asks for the port and the memory.
        if current != nil, current != entry.id { await stopAndWait() }
        guard let binary = LlamaInstaller.serverBinary, LlamaInstaller.isDownloaded(entry) else { return .unavailable }
        if lock.withLock({ process?.isRunning != true }) {
            // Nothing of ours is running, so anything on the port is a leftover.
            // One serving the wanted file is taken over; any other would answer
            // every request with the wrong model, so it goes.
            if await isHealthy(), LlamaServerRules.mayAdopt(servedFile: await servedModelFile(),
                                                            wantedFile: entry.pinned.fileName) {
                lock.withLock { runningModel = entry.id; adoptedOrphan = true }
                return .running
            }
            await killOrphans()
        }
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
                try p.run(); process = p; runningModel = entry.id; adoptedOrphan = false; lastFailureReason = nil
                return true
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                lastFailureReason = error.localizedDescription
                NSLog("Griasa: failed to launch llama-server: %@", error.localizedDescription)
                return false
            }
        }
        guard launched else { return .unavailable }
        // Loading 12 GB from disk takes a while on first start.
        for _ in 0..<240 {
            if await isHealthy() { return .running }
            if lock.withLock({ process?.isRunning != true }) {  // likely out of memory
                // The pipe may still hold the last lines; give it a moment.
                try? await Task.sleep(nanoseconds: 200_000_000)
                noteFailure("exited while loading \(entry.pinned.fileName)")
                return .died
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        noteFailure("did not answer within 2 minutes")
        return .unavailable
    }

    private func noteFailure(_ what: String) {
        let reason = lock.withLock { () -> String? in
            let reason = LlamaServerRules.failureReason(stderrTail: String(decoding: stderrTail, as: UTF8.self))
            lastFailureReason = reason
            return reason
        }
        NSLog("Griasa: llama-server %@: %@", what, reason ?? "no output")
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

    /// Kills llama-servers Griasa started in an earlier run: only those whose
    /// command line names the binary, a model in Griasa's models folder and
    /// Griasa's port. SIGTERM, then SIGKILL for any still there after 5 s.
    private func killOrphans() async {
        let pattern = LlamaServerRules.orphanPattern(modelsDirectory: LlamaInstaller.modelsDirectory.path,
                                                     port: Self.port)
        guard Self.run("/usr/bin/pkill", ["-f", pattern]) == 0 else { return }  // 1: none found
        NSLog("Griasa: stopped a llama-server left by an earlier run")
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Self.run("/usr/bin/pgrep", ["-f", pattern]) != 0 { return }
        }
        _ = Self.run("/usr/bin/pkill", ["-9", "-f", pattern])
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    func stop() {
        let adopted = lock.withLock { () -> Bool in
            process?.terminate()
            process = nil
            runningModel = nil
            defer { adoptedOrphan = false }
            return adoptedOrphan
        }
        if adopted {
            _ = Self.run("/usr/bin/pkill", ["-f", LlamaServerRules.orphanPattern(
                modelsDirectory: LlamaInstaller.modelsDirectory.path, port: Self.port)])
        }
    }
}
