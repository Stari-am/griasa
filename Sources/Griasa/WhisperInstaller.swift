import Foundation

/// First-launch provisioning for the Whisper engine: installs whisper-cpp via
/// Homebrew if needed and downloads the ggml model, so the app is ready to use
/// right after install with no manual setup. Until (or unless) this succeeds,
/// transcription falls back to the Apple recognizer.
enum WhisperInstaller {

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
        let downloader = ModelDownloader(destination: WhisperTranscriber.modelURL,
                                         expected: ModelManifest.whisper, onProgress: onProgress)
        try await downloader.download(from: ModelManifest.whisper.url)
    }

    /// Checks each pinned model already on disk against the manifest.
    ///
    /// Installs from before checksums existed have models nobody verified, and
    /// those are the ones on people's machines today. Hashing the large one
    /// takes a few seconds, so a file that passed is remembered by its size and
    /// modification date and not hashed again until either changes. One that
    /// fails is renamed rather than deleted — it is evidence, and 1.6 GB is not
    /// something to destroy on a single reading — and nothing loads it.
    static func setAsideUnverifiedModels() async {
        let pairs: [(URL, PinnedModel)] = [(WhisperTranscriber.modelURL, ModelManifest.whisper),
                                           (WhisperTranscriber.vadModelURL, ModelManifest.vad)]
        for (file, expected) in pairs {
            guard let stamp = fileStamp(file) else { continue }  // not downloaded yet
            let key = "verifiedModel.\(expected.fileName)"
            let remembered = "\(expected.sha256):\(stamp)"
            if UserDefaults.standard.string(forKey: key) == remembered { continue }
            let verdict = await Task.detached(priority: .utility) {
                ModelManifest.verify(file, against: expected)
            }.value
            if verdict == .matches {
                UserDefaults.standard.set(remembered, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
                let aside = file.appendingPathExtension("unverified")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: file, to: aside)
                NSLog("Griasa: %@ — moved aside to %@", ModelManifest.explain(verdict, model: expected),
                      aside.lastPathComponent)
            }
        }
    }

    private static func fileStamp(_ file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value):\(Int(modified.timeIntervalSince1970))"
    }

    /// The VAD model is ~1 MB — download without progress; failure is
    /// non-fatal (transcription works without it, just hallucination-prone
    /// on silence).
    static func downloadVADModelIfNeeded() async {
        guard !FileManager.default.fileExists(atPath: WhisperTranscriber.vadModelURL.path) else { return }
        let downloader = ModelDownloader(destination: WhisperTranscriber.vadModelURL,
                                         expected: ModelManifest.vad, onProgress: { _ in })
        do {
            try await downloader.download(from: ModelManifest.vad.url)
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
    private let expected: PinnedModel
    private let onProgress: @Sendable (Int) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var lastPercent = -1
    private let lock = NSLock()

    init(destination: URL, expected: PinnedModel, onProgress: @escaping @Sendable (Int) -> Void) {
        self.destination = destination
        self.expected = expected
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
            // Checked beside the destination, never in it: the model path is
            // what whisper loads, so nothing unverified may ever sit there,
            // even for the seconds the check takes. URLSession deletes
            // `location` when this method returns, so it is moved first.
            let staging = destination.appendingPathExtension("download")
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: location, to: staging)
            let verdict = ModelManifest.verify(staging, against: expected)
            guard verdict == .matches else {
                try? FileManager.default.removeItem(at: staging)
                throw NSError(domain: "Griasa", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: ModelManifest.explain(verdict, model: expected)
                ])
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staging, to: destination)
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
