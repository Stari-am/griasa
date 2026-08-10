import Foundation

/// First-launch provisioning for the Whisper engine: installs whisper-cpp via
/// Homebrew if needed and downloads the ggml model, so the app is ready to use
/// right after install with no manual setup. Until (or unless) this succeeds,
/// transcription falls back to the Apple recognizer.
enum WhisperInstaller {
    static let modelDownloadURL = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    static let vadModelDownloadURL = URL(string:
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    static var brewPath: String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Runs `brew install whisper-cpp`. Returns true if whisper-cli is
    /// executable afterwards.
    static func installEngine() async -> Bool {
        guard let brew = brewPath else { return false }
        _ = await runProcess(brew, ["install", "whisper-cpp"])
        return WhisperTranscriber.binaryPath != nil
    }

    static func downloadModel(onProgress: @escaping @Sendable (Int) -> Void) async throws {
        let downloader = ModelDownloader(destination: WhisperTranscriber.modelURL, onProgress: onProgress)
        try await downloader.download(from: modelDownloadURL)
    }

    /// The VAD model is ~1 MB — download without progress; failure is
    /// non-fatal (transcription works without it, just hallucination-prone
    /// on silence).
    static func downloadVADModelIfNeeded() async {
        guard !FileManager.default.fileExists(atPath: WhisperTranscriber.vadModelURL.path) else { return }
        let downloader = ModelDownloader(destination: WhisperTranscriber.vadModelURL, onProgress: { _ in })
        do {
            try await downloader.download(from: vadModelDownloadURL)
        } catch {
            NSLog("Griasa: VAD model download failed: %@", error.localizedDescription)
        }
    }

    private static func runProcess(_ launchPath: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}

/// Streams a large file to disk with progress callbacks (URLSession's async
/// `download(from:)` has no progress reporting, so this uses the delegate API).
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var lastPercent = -1
    private let lock = NSLock()

    init(destination: URL, onProgress: @escaping @Sendable (Int) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        switch result {
        case .success: cont?.resume()
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
        lock.lock()
        let changed = percent != lastPercent
        lastPercent = percent
        lock.unlock()
        if changed {
            onProgress(percent)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(domain: "Griasa", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Model download failed (HTTP \(http.statusCode))."
                ])
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }
}
