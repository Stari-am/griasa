import Foundation

/// Downloads a local model into `<model>.part`, continuing from what is
/// already there, and moves it into place only after the size and SHA-256
/// match the pin. The rules are in `DownloadResume`.
///
/// Whisper's models stay on `ModelDownloader`: they are 1.6 GB at most, and
/// that path already works.
final class ResumableDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let expected: PinnedModel
    private let onProgress: @Sendable (Int) -> Void
    private let onWaiting: @Sendable (Bool) -> Void
    var part: URL { destination.appendingPathExtension("part") }

    // One attempt's state, touched only on the session's serial delegate queue
    // (and before the task is resumed).
    private var handle: FileHandle?
    private var offset: Int64 = 0
    private var written: Int64 = 0
    private var sinceSync: Int64 = 0
    private var lastPercent = -1
    private var outcome: Result<Void, Error>?
    /// Whether "waiting for the network" is showing; cleared by the first
    /// answer after the wait.
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Error>?

    /// Flushed to disk every 64 MB, so a power loss costs at most that much.
    private static let syncEvery: Int64 = 64 << 20

    init(destination: URL, expected: PinnedModel,
         onProgress: @escaping @Sendable (Int) -> Void,
         onWaiting: @escaping @Sendable (Bool) -> Void) {
        self.destination = destination
        self.expected = expected
        self.onProgress = onProgress
        self.onWaiting = onWaiting
    }

    private static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "Griasa", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func download(from url: URL) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var failures = 0
        var waited: TimeInterval = 0
        fetching: while true {
            try Task.checkCancellation()
            let start: Int64
            switch DownloadResume.existing(partSize: Self.size(part), expectedSize: expected.size) {
            case .verifyNow: break fetching
            case .discard:
                try? FileManager.default.removeItem(at: part)
                start = 0
            case .requestFrom(let from):
                start = from
            }
            let before = Self.size(part) ?? 0
            do {
                try await attempt(url, from: start)
                // Ended cleanly but short: the connection closed early. Treated
                // like a drop, so the next pass asks for the rest.
                if (Self.size(part) ?? 0) >= expected.size { break fetching }
                throw URLError(.networkConnectionLost)
            } catch {
                guard DownloadResume.isNetworkError(error) else { setWaiting(false); throw error }
                // Bytes arrived since the last failure: the network was back,
                // so the wait starts over.
                if (Self.size(part) ?? 0) > before { failures = 0; waited = 0 }
                failures += 1
                guard let pause = DownloadResume.delay(afterFailures: failures, waited: waited) else {
                    setWaiting(false)
                    throw error
                }
                setWaiting(true)
                try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                waited += pause
            }
        }
        setWaiting(false)
        let verdict = ModelManifest.verify(part, against: expected)
        guard verdict == .matches else {
            // A resumed file that does not match must not be resumed again:
            // the next try starts from nothing.
            try? FileManager.default.removeItem(at: part)
            throw Self.failure(9, ModelManifest.explain(verdict, model: expected))
        }
        // `replaceItemAt` swaps in one step, so the model path never holds a
        // half-written or unchecked file.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: part)
        } else {
            try FileManager.default.moveItem(at: part, to: destination)
        }
    }

    private func setWaiting(_ on: Bool) {
        guard on != waiting else { return }
        waiting = on
        onWaiting(on)
    }

    /// One request from `start`, writing into the part until the server
    /// closes the body or the connection fails.
    private func attempt(_ url: URL, from start: Int64) async throws {
        if !FileManager.default.fileExists(atPath: part.path) {
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
                throw Self.failure(10, "Could not write \(part.lastPathComponent) in the models folder.")
            }
        }
        let handle = try FileHandle(forWritingTo: part)
        try handle.truncate(atOffset: UInt64(start))
        try handle.seekToEnd()
        self.handle = handle
        offset = start
        written = 0
        sinceSync = 0
        outcome = nil
        var request = URLRequest(url: url)
        if start > 0 { request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            session.dataTask(with: request).resume()
        }
    }

    // MARK: URLSessionDataDelegate — all on the session's serial queue.

    /// Hugging Face answers with a redirect to its CDN; the Range must go
    /// along, or the CDN would send the whole file from byte 0.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            next.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let rangeStart = DownloadResume.contentRangeStart(http?.value(forHTTPHeaderField: "Content-Range"))
        switch DownloadResume.response(status: status, requestedFrom: offset, contentRangeStart: rangeStart) {
        case .append:
            setWaiting(false)
            completionHandler(.allow)
        case .restartFromZero:
            do {
                try handle?.truncate(atOffset: 0)
                offset = 0
                setWaiting(false)
                completionHandler(.allow)
            } catch {
                outcome = .failure(error)
                completionHandler(.cancel)
            }
        case .discardAndRetry:
            // Emptied here; the next pass sees no part and asks from 0. Said
            // as a network error so the caller tries again rather than failing.
            try? handle?.truncate(atOffset: 0)
            outcome = .failure(URLError(.networkConnectionLost))
            completionHandler(.cancel)
        case .fail(let status):
            outcome = .failure(Self.failure(8, "Model download failed (HTTP \(status))."))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard outcome == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            outcome = .failure(error)
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        sinceSync += Int64(data.count)
        if sinceSync >= Self.syncEvery {
            try? handle.synchronize()
            sinceSync = 0
        }
        let percent = DownloadResume.percent(have: offset + written, of: expected.size)
        if percent != lastPercent {
            lastPercent = percent
            onProgress(percent)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        let result: Result<Void, Error> = outcome ?? (error.map { .failure($0) } ?? .success(()))
        let cont = continuation
        continuation = nil
        switch result {
        case .success: cont?.resume()
        case .failure(let failure): cont?.resume(throwing: failure)
        }
    }
}
