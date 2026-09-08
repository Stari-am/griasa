import Foundation

/// Manages a local `whisper-server` subprocess so the model stays loaded in
/// memory: per-region transcription during meetings costs milliseconds of
/// overhead instead of a full model load, and dictation becomes near-instant.
final class WhisperServer: @unchecked Sendable {
    static let shared = WhisperServer()

    private let port = 8178
    private var process: Process?
    private var launchVocabulary: [String] = []
    private let lock = NSLock()

    /// Swept once, here, because at the moment this object is first built no
    /// server of ours can exist yet — so anything answering on our port is a
    /// leftover, and killing it is unambiguous.
    private init() { killOrphans() }

    static var binaryPath: String? {
        for path in ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private var inferenceURL: URL { URL(string: "http://127.0.0.1:\(port)/inference")! }

    /// True when the server responds right now (no waiting).
    func isUp() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 1
        // Any HTTP response (including 404) means the server is listening.
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// Starts the server if needed and waits for it to accept requests
    /// (model load can take a few seconds). Returns false when whisper-server
    /// or the model is unavailable or startup failed.
    func ensureRunning(vocabulary: [String]) async -> Bool {
        if await isUp() { return true }
        guard let binary = Self.binaryPath, WhisperTranscriber.isAvailable else { return false }

        launchProcess(binary: binary, vocabulary: vocabulary)

        for _ in 0..<60 {
            if await isUp() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func launchProcess(binary: String, vocabulary: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning != true else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = [
            "-m", WhisperTranscriber.modelURL.path,
            "-l", "auto",
            "--prompt", "Glossary: " + vocabulary.joined(separator: ", ") + ".",
            "--suppress-nst",
            // Bound the carried text context and raise the entropy threshold so
            // the decoder escalates out of a repetition loop instead of riding
            // it to the end of the segment. See WhisperTranscriber.loopGuards.
            "-mc", "64",
            "-et", "2.6",
            "--host", "127.0.0.1",
            "--port", String(port),
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            process = p
            launchVocabulary = vocabulary
        } catch {
            NSLog("Griasa: failed to launch whisper-server: %@", error.localizedDescription)
        }
    }

    /// Kills a whisper-server left behind by a previous run.
    ///
    /// The app aborted twice in a week on a microphone format mismatch, and an
    /// abort skips `applicationWillTerminate`, so the child survived. A fresh
    /// launch has no handle to it, and `ensureRunning` decides whether to start
    /// one from a health check with a one-second timeout — which a server busy
    /// transcribing does not answer in time. So the orphan is declared dead and
    /// a second one is launched. whisper-server sets SO_REUSEPORT, so both then
    /// hold 127.0.0.1:8178 and the kernel splits transcription requests between
    /// them. Measured on this machine: two listeners on the same port, one of
    /// them 40 days old, carrying the glossary it was launched with that day.
    ///
    /// Sweeping costs one model load after a crash. Adopting the orphan instead
    /// would be cheaper and is what the health check already tries to do — but
    /// it cannot tell one orphan from two, and two is the state that quietly
    /// sends half your dictation to a server configured weeks ago.
    ///
    /// The pattern requires both the binary name and this app's own model file,
    /// so a whisper-server somebody else is running is left alone.
    private func killOrphans() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "whisper-server.*\(WhisperTranscriber.modelURL.lastPathComponent)"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        do {
            try pkill.run()
            pkill.waitUntilExit()
        } catch {
            // Nothing to do about it: the worst case is the state we were
            // already in, and it must not stop a server from starting.
            NSLog("Griasa: could not check for a leftover whisper-server: %@",
                  error.localizedDescription)
        }
    }

    func stop() {
        lock.lock()
        process?.terminate()
        process = nil
        lock.unlock()
    }

    /// Transcribes one WAV file via the warm server. Returns nil on failure.
    func transcribe(wav: URL) async -> String? {
        guard let fileData = try? Data(contentsOf: wav) else { return nil }

        let boundary = "griasa-\(UUID().uuidString)"
        var body = Data()
        body.appendUTF8("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n")
        body.appendUTF8("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: inferenceURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
