import Foundation

/// A second `llama-server`, for the search model only: it turns text into
/// vectors and generates nothing. Kept apart from `LlamaServer` because the two
/// run side by side — a search while a summary is being written must not stop
/// the chat model — and because an embedding server is started with other
/// flags (`--embedding --pooling cls`). Loopback only, and like the chat server
/// it unloads its model after ten idle minutes.
final class EmbeddingServer: @unchecked Sendable {
    static let shared = EmbeddingServer()
    /// Below the chat server's 8177; Whisper is on 8178, MCP from 8179 up.
    static let port = 8176

    /// bge-m3, Q8_0, as published by ggml-org. Chosen on the search benchmark
    /// (benchmark/search): with word search it found the answer in the first
    /// five pieces for 81% of queries, against 60% for words alone, and it is
    /// the one tried that matches across Russian, Ukrainian and English.
    static let model = PinnedModel(
        fileName: "bge-m3-q8_0.gguf",
        url: URL(string: "https://huggingface.co/ggml-org/bge-m3-Q8_0-GGUF/resolve/9eba04c5d75ba5a1595e45de734d36bef4e5cb98/bge-m3-q8_0.gguf")!,
        sha256: "aa473d51f451a22f0fcf39ba3330c14bed38a385712b1113440f69df4047a173",
        size: 634_553_760)
    /// Recorded with each indexed meeting, so a future model change re-indexes.
    static let modelID = "bge-m3-q8_0"

    static var modelURL: URL { LlamaInstaller.modelsDirectory.appendingPathComponent(model.fileName) }
    static var partURL: URL { modelURL.appendingPathExtension("part") }

    /// Size only; the hash was checked when the file arrived.
    static var isDownloaded: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int64) ?? nil
        return size == model.size
    }

    private var process: Process?
    private var adopted = false
    private var starting: Task<Bool, Never>?
    private let lock = NSLock()

    private func get(_ path: String, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)\(path)")!)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func isHealthy() async -> Bool { await get("/health", timeout: 1) != nil }

    /// Starts the server if it is not running. Concurrent callers share one start.
    func ensureRunning() async -> Bool {
        let task = lock.withLock { () -> Task<Bool, Never> in
            if let starting { return starting }
            let task = Task { await self.start() }
            starting = task
            return task
        }
        let ok = await task.value
        lock.withLock { starting = nil }
        return ok
    }

    private func start() async -> Bool {
        if lock.withLock({ process?.isRunning == true || adopted }), await isHealthy() { return true }
        guard let binary = LlamaInstaller.serverBinary, Self.isDownloaded else { return false }
        // A server left by an earlier run: taken over when it serves our file,
        // stopped otherwise. Anything else on the port is not ours to touch.
        if await isHealthy() {
            let served = await get("/props", timeout: 2).flatMap(LlamaServerRules.servedModel)
            if LlamaServerRules.mayAdopt(served: served, wantedPath: Self.modelURL.path) {
                lock.withLock { adopted = true }
                return true
            }
            await stopOrphans()
            if await isHealthy() {
                NSLog("Griasa: search model not started: port %d is used by another program", Self.port)
                return false
            }
        }
        let launched: Bool = lock.withLock {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = [
                "-m", Self.modelURL.path,
                "--embedding", "--pooling", "cls",
                "-c", "8192", "-b", "8192", "-ub", "8192",
                "--host", "127.0.0.1", "--port", String(Self.port),
                "-ngl", "99", "--sleep-idle-seconds", "600",
            ]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); process = p; adopted = false; return true } catch {
                NSLog("Griasa: failed to launch the search model: %@", error.localizedDescription)
                return false
            }
        }
        guard launched else { return false }
        for _ in 0..<120 {
            if await isHealthy() { return true }
            if lock.withLock({ process?.isRunning != true }) { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private struct Reply: Decodable {
        struct Item: Decodable { var index: Int; var embedding: [Float] }
        var data: [Item]
    }

    /// Unit-length vectors for `texts`, in order, eight per request.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard await ensureRunning() else { throw URLError(.cannotConnectToHost) }
        let url = URL(string: "http://127.0.0.1:\(Self.port)/v1/embeddings")!
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: texts.count, by: 8) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["input": Array(texts[start..<min(start + 8, texts.count)])])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            vectors += reply.data.sorted { $0.index < $1.index }.map { HybridRank.normalized($0.embedding) }
        }
        return vectors
    }

    func stop() {
        let wasAdopted = lock.withLock { () -> Bool in
            process?.terminate()
            process = nil
            defer { adopted = false }
            return adopted
        }
        if wasAdopted { for pid in orphanPIDs() { kill(pid, SIGTERM) } }
    }

    private func orphanPIDs() -> [pid_t] {
        let pattern = LlamaServerRules.orphanPattern(modelsDirectory: LlamaInstaller.modelsDirectory.path, port: Self.port)
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let own = lock.withLock { process?.processIdentifier }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }.filter { $0 != own && $0 != getpid() }
    }

    private func stopOrphans() async {
        let orphans = orphanPIDs()
        guard !orphans.isEmpty else { return }
        for pid in orphans { kill(pid, SIGTERM) }
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if orphans.allSatisfy({ kill($0, 0) != 0 }) { return }
        }
        for pid in orphans { kill(pid, SIGKILL) }
    }
}
