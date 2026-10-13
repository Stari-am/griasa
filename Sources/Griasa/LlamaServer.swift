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
    private let lock = NSLock()

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// How a start ended. `died` is kept apart from the rest because it is the
    /// one that says the model is too big for this Mac right now (the process
    /// exits when it cannot allocate the model), and the caller steps down a
    /// tier on it; a missing binary or file, or a slow start, is no reason to.
    enum Start { case running, died, unavailable }

    func ensureRunning(_ entry: LocalModelEntry) async -> Start {
        let current = lock.withLock { runningModel }
        if current == entry.id, await isHealthy() { return .running }
        if current != nil, current != entry.id { stop() }
        guard let binary = LlamaInstaller.serverBinary, LlamaInstaller.isDownloaded(entry) else { return .unavailable }
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
            p.standardError = FileHandle.nullDevice
            do { try p.run(); process = p; runningModel = entry.id; return true }
            catch { NSLog("Griasa: failed to launch llama-server: %@", error.localizedDescription); return false }
        }
        guard launched else { return .unavailable }
        // Loading 12 GB from disk takes a while on first start.
        for _ in 0..<240 {
            if await isHealthy() { return .running }
            if lock.withLock({ process?.isRunning != true }) { return .died }  // likely out of memory
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .unavailable
    }

    func stop() {
        lock.withLock {
            process?.terminate()
            process = nil
            runningModel = nil
        }
    }
}
